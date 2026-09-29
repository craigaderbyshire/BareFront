#pragma once

#include <filesystem>
#include <fstream>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <cctype>

namespace bfplaylist {

namespace fs = std::filesystem;

struct Playlist {
    std::vector<fs::path> media;
};

inline std::string trim(const std::string& input)
{
    const auto first = input.find_first_not_of(" \t\r\n");

    if (first == std::string::npos)
        return {};

    const auto last = input.find_last_not_of(" \t\r\n");

    return input.substr(first, last - first + 1);
}

inline bool inside(const fs::path& root, const fs::path& target)
{
    auto r = root.begin();
    auto t = target.begin();

    for (; r != root.end(); ++r, ++t) {
        if (t == target.end() || *r != *t)
            return false;
    }

    return true;
}

inline Playlist parse(
    const fs::path& file,
    std::vector<fs::path>* verifiedMedia = nullptr)
{
    std::string extension = file.extension().string();

    for (char& character : extension)
    {
        character = static_cast<char>(
            std::tolower(
                static_cast<unsigned char>(character)
            )
        );
    }

    if (verifiedMedia)
        verifiedMedia->clear();

    if (extension != ".m3u")
        throw std::runtime_error("Not an .m3u playlist");

    const fs::path root =
        fs::canonical(fs::absolute(file).parent_path());

    const fs::path actualPlaylist = fs::canonical(file);

    if (!inside(root, actualPlaylist))
        throw std::runtime_error(
            "Playlist resolves outside its game directory");

    if (!fs::is_regular_file(actualPlaylist))
        throw std::runtime_error("Playlist is not a regular file");

    std::ifstream input(file, std::ios::binary);

    if (!input)
        throw std::runtime_error("Cannot open playlist");

    Playlist result;
    std::set<fs::path> seen;

    std::string line;
    std::size_t lineNumber = 0;

    while (std::getline(input, line)) {
        ++lineNumber;

        if (lineNumber == 1 &&
            line.size() >= 3 &&
            static_cast<unsigned char>(line[0]) == 0xEF &&
            static_cast<unsigned char>(line[1]) == 0xBB &&
            static_cast<unsigned char>(line[2]) == 0xBF) {
            line.erase(0, 3);
        }

        line = trim(line);

        if (line.empty() || line.front() == '#')
            continue;

        const auto reject = [&](const std::string& reason) {
            throw std::runtime_error(
                "Line " + std::to_string(lineNumber) +
                ": " + reason);
        };

        if (line.find('\0') != std::string::npos)
            reject("NUL character in media path");

        if (line.find('\\') != std::string::npos)
            reject("Backslash path separator");

        if (line.size() >= 2 &&
            std::isalpha(static_cast<unsigned char>(line[0])) &&
            line[1] == ':')
            reject("Windows absolute path");

        const fs::path relative(line);

        if (relative.is_absolute() || relative.has_root_path())
            reject("Absolute path");

        for (const auto& component : relative) {
            if (component == "..")
                reject("Parent-directory traversal");
        }

        const fs::path resolved =
            fs::weakly_canonical(root / relative);

        if (!inside(root, resolved))
            reject("Media resolves outside game directory");

        if (resolved == actualPlaylist)
            reject("Playlist references itself");

        if (!fs::is_regular_file(resolved))
            reject("Referenced media is missing or not a regular file");

        if (!seen.insert(resolved).second)
            reject("Duplicate media path");

        result.media.push_back(resolved);

        if (verifiedMedia)
            verifiedMedia->push_back(resolved);
    }

    if (input.bad())
        throw std::runtime_error("Error reading playlist");

    if (result.media.empty())
        throw std::runtime_error("Playlist contains no media");

    return result;
}

}
