#pragma once

#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <system_error>

namespace bfshader
{
namespace fs = std::filesystem;

using Preferences = std::map<std::string, std::string>;

inline bool valid(const std::string& value)
{
    return value == "NONE" ||
           value == "BARECRT" ||
           value == "CRT-LITE" ||
           value == "CRT-LOTTES";
}

inline std::string trim(const std::string& text)
{
    const auto first = text.find_first_not_of(" \t\r\n");

    if (first == std::string::npos)
        return "";

    const auto last = text.find_last_not_of(" \t\r\n");

    return text.substr(first, last - first + 1);
}

inline std::string get(
    const Preferences& preferences,
    const std::string& system)
{
    const auto it = preferences.find(system);

    if (it == preferences.end() || !valid(it->second))
        return "NONE";

    return it->second;
}

inline Preferences load(const fs::path& path)
{
    Preferences preferences;
    std::ifstream file(path);
    std::string line;

    while (std::getline(file, line))
    {
        line = trim(line);

        if (line.empty() || line[0] == '#' || line[0] == ';')
            continue;

        const auto equals = line.find('=');

        if (equals == std::string::npos)
            continue;

        const std::string system = trim(line.substr(0, equals));
        const std::string preset = trim(line.substr(equals + 1));

        if (!system.empty() && valid(preset))
            preferences[system] = preset;
    }

    return preferences;
}

inline bool save(
    const fs::path& path,
    const Preferences& preferences)
{
    std::error_code error;

    fs::create_directories(path.parent_path(), error);

    if (error)
        return false;

    fs::path temporary = path;
    temporary += ".tmp";

    {
        std::ofstream file(temporary, std::ios::trunc);

        if (!file)
            return false;

        file << "# BareFront shader preferences — per system\n";

        for (const auto& entry : preferences)
        {
            if (!entry.first.empty() && valid(entry.second))
                file << entry.first << "=" << entry.second << "\n";
        }

        file.flush();

        if (!file)
        {
            file.close();
            fs::remove(temporary, error);
            return false;
        }
    }

    fs::rename(temporary, path, error);

    if (error)
    {
        std::error_code cleanupError;
        fs::remove(temporary, cleanupError);
        return false;
    }

    return true;
}

inline bool set(
    Preferences& preferences,
    const fs::path& path,
    const std::string& system,
    const std::string& preset)
{
    if (system.empty() || !valid(preset))
        return false;

    Preferences updated = preferences;
    updated[system] = preset;

    if (!save(path, updated))
        return false;

    preferences = updated;
    return true;
}

} // namespace bfshader
