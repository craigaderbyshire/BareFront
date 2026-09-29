#pragma once

#include <algorithm>
#include <filesystem>
#include <map>
#include <regex>
#include <string>
#include <vector>
#include "favourites.h"
#include <cctype>
#include "playlist.h"

namespace bflibrary
{
namespace fs = std::filesystem;

struct Game
{
    // Relative to the collection folder. A multi-disc
    // folder is one game, regardless of its disc count.
    fs::path key;
    fs::path titlePath;
    fs::path launchPath;
    std::vector<fs::path> media;
    fs::path playlistPath;
    std::string playlistError;
    bool folderGame = false;
    bool missingDiscOne = false;
};

inline int discNumber(const fs::path& path)
{
    static const std::regex pattern(
        "(disc|disk|cd)[[:space:]]*([0-9]+)",
        std::regex_constants::icase
    );

    std::smatch match;
    const std::string name = path.filename().string();

    if (std::regex_search(name, match, pattern))
        return std::stoi(match[2].str());

    return 1000;
}

// Recognise the same playlist extensions as the scanner,
// parser and launch guard.
inline bool isPlaylistPath(const fs::path& path)
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

// Takes ROM paths already accepted by BareFront's existing
// scanner, preserving its extension and VICE fliplist rules.
inline std::vector<Game> groupGames(
    const fs::path& collectionFolder,
    const std::vector<fs::path>& scanned)
{
    std::map<fs::path, Game> grouped;

    for (const fs::path& rom : scanned)
    {
        const fs::path relative =
            rom.lexically_relative(collectionFolder);

        if (relative.empty() || relative.is_absolute())
            continue;

        auto part = relative.begin();

        if (part == relative.end() ||
            *part == ".." || *part == ".")
            continue;

        const fs::path first = *part;
        ++part;

        const bool inGameFolder =
            part != relative.end();

        const fs::path key =
            inGameFolder ? first : relative;

        auto [it, inserted] =
            grouped.try_emplace(key);

        Game& game = it->second;

        if (inserted)
        {
            game.key = key;
            game.folderGame = inGameFolder;
            game.titlePath = inGameFolder
                ? collectionFolder / first
                : rom;
        }

        game.media.push_back(rom);
    }

    std::vector<Game> result;
    result.reserve(grouped.size());

    for (auto& item : grouped)
    {
        Game& game = item.second;

        std::sort(
            game.media.begin(),
            game.media.end(),
            [](const fs::path& a, const fs::path& b)
            {
                const int da = discNumber(a);
                const int db = discNumber(b);

                if (da != db)
                    return da < db;

                return a < b;
            }
        );

        // A playlist is the authoritative launch source.
        // Never silently fall back to Disc 1 if it is invalid.
        std::vector<fs::path> playlists;

        for (const fs::path& path : game.media)
        {
            if (isPlaylistPath(path))
                playlists.push_back(path);
        }

        if (!playlists.empty())
        {
            game.playlistPath = playlists.front();
            game.launchPath = game.playlistPath;

            // The playlist is metadata, not physical media.
            game.media.erase(
                std::remove_if(
                    game.media.begin(),
                    game.media.end(),
                    [](const fs::path& path)
                    {
                        return isPlaylistPath(path);
                    }
                ),
                game.media.end()
            );

            if (playlists.size() != 1)
            {
                game.playlistError =
                    "Multiple .m3u playlists in one game folder";
            }
            else
            {
                try
                {
                    auto parsed =
                        bfplaylist::parse(game.playlistPath);

                    // Playlist order overrides filename sorting.
                    game.media = std::move(parsed.media);
                }
                catch (const std::exception& error)
                {
                    game.playlistError = error.what();
                }
            }

            // Invalid playlists remain identifiable.
            // The frontend launch guard must block them.
            result.push_back(std::move(game));
            continue;
        }

        if (game.media.empty())
            continue;

        game.launchPath = game.media.front();

        // Keep incomplete multi-disc folders detectable.
        if (game.folderGame &&
            discNumber(game.launchPath) > 1 &&
            discNumber(game.launchPath) < 1000)
        {
            game.missingDiscOne = true;
        }

        result.push_back(std::move(game));
    }

    return result;
}


// Physical curated collections. Favourites is virtual.
inline std::vector<std::string> collectionNames(
    const std::string& system)
{
    std::vector<std::string> names = {
        "Favourites",
        "Must Have",
        "Excellent",
        "Deep Cut"
    };

    if (system == "amiga" || system == "c64")
        names.push_back("Demos");

    return names;
}

struct Collection
{
    std::string name;
    std::vector<Game> games;
};

struct ListedGame
{
    std::string collection;
    Game game;
    bool favourite = false;
};

// Return entries for a physical collection or the virtual
// Favourites view. The original collection and launch path
// are retained, including for multi-disc folders.
inline std::vector<ListedGame> gamesFor(
    const std::vector<Collection>& collections,
    const std::string& selected,
    const bffavourites::Entries& favourites)
{
    std::vector<ListedGame> result;

    for (const Collection& collection : collections)
    {
        if (selected != "Favourites" &&
            selected != collection.name)
            continue;

        for (const Game& game : collection.games)
        {
            const std::string key =
                bffavourites::gameKey(
                    collection.name,
                    game.key
                );

            const bool liked =
                favourites.count(key) != 0;

            if (selected == "Favourites" && !liked)
                continue;

            result.push_back({
                collection.name,
                game,
                liked
            });
        }
    }

    return result;
}

} // namespace bflibrary
