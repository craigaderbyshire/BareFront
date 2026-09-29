#pragma once

#include "playlist.h"

#include <algorithm>
#include <cctype>
#include <exception>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <system_error>
#include <vector>

namespace bfmultidisc {

namespace fs = std::filesystem;

struct ScanResult
{
    std::vector<fs::path> visible;
    std::vector<fs::path> invalidPlaylists;

    // Keyed by the original scanned playlist path.
    // Must be passed to the frontend launch guard later.
    std::map<fs::path, std::string> playlistErrors;

    std::size_t suppressedMedia = 0;
};

inline bool isM3u(const fs::path& path)
{
    std::string extension = path.extension().string();

    std::transform(
        extension.begin(),
        extension.end(),
        extension.begin(),
        [](unsigned char c)
        {
            return static_cast<char>(std::tolower(c));
        }
    );

    return extension == ".m3u";
}

inline ScanResult filterScanned(
    const std::vector<fs::path>& scanned)
{
    ScanResult result;

    // Canonical media path -> playlists claiming that media.
    std::map<fs::path, std::set<fs::path>> claims;

    const auto addError =
        [&](const fs::path& playlist,
            const std::string& message)
        {
            auto [it, inserted] =
                result.playlistErrors.try_emplace(
                    playlist, message
                );

            if (inserted)
            {
                result.invalidPlaylists.push_back(playlist);
            }
            else if (it->second.find(message) ==
                     std::string::npos)
            {
                it->second += "; " + message;
            }
        };

    // First pass: establish ownership from parser-verified
    // media only. An invalid playlist never becomes launchable.
    for (const fs::path& path : scanned)
    {
        if (!isM3u(path))
            continue;

        std::vector<fs::path> verifiedMedia;

        try
        {
            bfplaylist::parse(path, &verifiedMedia);
        }
        catch (const std::exception& error)
        {
            addError(path, error.what());
        }

        // The parser has already checked containment,
        // regular-file status and duplicate references.
        // On failure, this contains only the verified prefix.
        for (const fs::path& media : verifiedMedia)
            claims[media].insert(path);
    }

    // Conflicting ownership invalidates every claimant.
    // Never pick a winning playlist arbitrarily.
    for (const auto& claim : claims)
    {
        if (claim.second.size() <= 1)
            continue;

        const std::string message =
            "Disc image claimed by multiple playlists: " +
            claim.first.string();

        for (const fs::path& playlist : claim.second)
            addError(playlist, message);
    }

    // Second pass: retain playlist identity and suppress
    // only physical media that the parser verified.
    for (const fs::path& path : scanned)
    {
        if (isM3u(path))
        {
            result.visible.push_back(path);
            continue;
        }

        std::error_code ec;

        const fs::path resolved =
            fs::weakly_canonical(path, ec);

        // If resolution fails, retain the entry rather
        // than accidentally suppressing it.
        if (!ec && claims.count(resolved) != 0)
        {
            ++result.suppressedMedia;
            continue;
        }

        result.visible.push_back(path);
    }

    // Preserve original scanner order.
    return result;
}

} // namespace bfmultidisc
