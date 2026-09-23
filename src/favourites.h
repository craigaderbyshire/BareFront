#pragma once

#include <filesystem>
#include <fstream>
#include <set>
#include <string>
#include <system_error>

namespace bffavourites
{
namespace fs = std::filesystem;

using Entries = std::set<std::string>;

// A favourite identifies one game relative to its
// system ROM directory, including its collection name.
inline bool validKey(const std::string& key)
{
    if (key.empty() ||
        key.find('\n') != std::string::npos ||
        key.find('\r') != std::string::npos ||
        key.find('\0') != std::string::npos)
        return false;

    const fs::path path(key);

    if (path.is_absolute() ||
        path.has_root_path() ||
        path.lexically_normal().generic_string() != key)
        return false;

    for (const auto& component : path)
    {
        if (component == "." ||
            component == ".." ||
            component.empty())
            return false;
    }

    return true;
}

inline std::string gameKey(
    const std::string& collection,
    const fs::path& gameKey)
{
    return (fs::path(collection) / gameKey)
        .generic_string();
}

inline Entries load(const fs::path& file)
{
    Entries result;
    std::ifstream input(file);

    std::string line;

    while (std::getline(input, line))
    {
        if (!line.empty() && line.back() == '\r')
            line.pop_back();

        if (validKey(line))
            result.insert(line);
    }

    return result;
}

// Write beside the existing file, then rename into place.
// A failed write must not truncate saved favourites.
inline bool save(
    const fs::path& file,
    const Entries& entries)
{
    std::error_code error;

    fs::create_directories(
        file.parent_path(), error
    );

    if (error)
        return false;

    const fs::path temporary =
        file.string() + ".tmp";

    {
        std::ofstream output(
            temporary,
            std::ios::trunc
        );

        if (!output)
            return false;

        for (const auto& key : entries)
        {
            if (!validKey(key))
            {
                output.close();
                fs::remove(temporary, error);
                return false;
            }

            output << key << '\n';
        }

        output.close();

        if (!output)
        {
            fs::remove(temporary, error);
            return false;
        }
    }

    fs::rename(temporary, file, error);

    if (error)
    {
        fs::remove(temporary, error);
        return false;
    }

    return true;
}

} // namespace bffavourites
