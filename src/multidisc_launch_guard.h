#pragma once

#include "playlist.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <string>

namespace bfmultidisc {

namespace fs = std::filesystem;

struct LaunchCheck
{
    bool allowed = false;
    std::string error;
    std::size_t mediaCount = 0;
    fs::path firstMedia;
};

inline bool isPlaylist(const fs::path& path)
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

// Validate immediately before launching.
//
// knownError carries errors already detected by curated grouping,
// including multiple playlists in the same game folder.
//
// A playlist is always reparsed at launch. This catches files
// removed or disconnected since the library was scanned.
//
// Ordinary non-playlist games retain their existing behaviour.
inline LaunchCheck check(
    const fs::path& launchPath,
    const std::string& knownError = {})
{
    if (!knownError.empty())
    {
        return {
            false,
            "Cannot launch multidisc game:\n" + knownError,
            0,
            {}
        };
    }

    if (!isPlaylist(launchPath))
    {
        return {true, {}, 0, {}};
    }

    try
    {
        const auto playlist =
            bfplaylist::parse(launchPath);

        return {
            true,
            {},
            playlist.media.size(),
            playlist.media.front()
        };
    }
    catch (const std::exception& error)
    {
        return {
            false,
            "Cannot launch multidisc game:\n" +
                launchPath.filename().string() +
                "\n\n" +
                error.what(),
            0,
            {}
        };
    }
}

} // namespace bfmultidisc
