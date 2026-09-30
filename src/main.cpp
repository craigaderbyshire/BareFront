#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>
#include <SDL2/SDL_ttf.h>
#include "shader_preferences.h"
#include "curated_library.h"
#include "multidisc_launch_guard.h"
#include "multidisc_scanner.h"
#include <map>
#include <sstream>

#include <algorithm>
#include <cstdlib>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <unordered_map>
#include <atomic>
#include <cstdio>
#include <cstdint>
#include <cerrno>
#include <mutex>
#include <thread>

#include <csignal>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;



// --------------------------------------------------
// Clean ROM filename for display only
//
// The real filename on disk is never changed.
// Common ROM-set metadata at the end of the filename
// is hidden from the BareFront game list.
// --------------------------------------------------

std::string cleanGameTitle(
    const fs::path& game)
{
    std::string title =
        game.stem().string();


    // Amiga WHDLoad archives commonly end with metadata such as:
    //
    // _v1.8_2063
    // _v3.2_AGA_0047
    //
    // Strip only an obvious trailing WHDLoad metadata chain.
    // The real filename on disk is never changed.
    std::string extension =
        game.extension().string();

    std::transform(
        extension.begin(),
        extension.end(),
        extension.begin(),
        [](unsigned char character)
        {
            return static_cast<char>(
                std::tolower(character)
            );
        }
    );


    if (extension == ".lha")
    {
        auto isNumericToken =
            [](const std::string& token)
            {
                if (token.empty())
                    return false;

                return std::all_of(
                    token.begin(),
                    token.end(),
                    [](unsigned char character)
                    {
                        return std::isdigit(
                            character
                        ) != 0;
                    }
                );
            };


        auto isVersionToken =
            [](const std::string& token)
            {
                if (token.size() < 2 ||
                    (token[0] != 'v' &&
                     token[0] != 'V'))
                {
                    return false;
                }

                bool sawDigit =
                    false;

                for (std::size_t index = 1;
                     index < token.size();
                     ++index)
                {
                    unsigned char character =
                        static_cast<unsigned char>(
                            token[index]
                        );

                    if (std::isdigit(character))
                    {
                        sawDigit =
                            true;
                    }
                    else if (character != '.')
                    {
                        return false;
                    }
                }

                return sawDigit;
            };


        auto isPlatformToken =
            [](std::string token)
            {
                std::transform(
                    token.begin(),
                    token.end(),
                    token.begin(),
                    [](unsigned char character)
                    {
                        return static_cast<char>(
                            std::toupper(character)
                        );
                    }
                );

                return
                    token == "AGA" ||
                    token == "ECS" ||
                    token == "OCS" ||
                    token == "CD32" ||
                    token == "CDTV";
            };


        std::string candidate =
            title;

        bool sawVersionToken =
            false;

        while (true)
        {
            std::size_t separator =
                candidate.rfind('_');

            if (separator ==
                std::string::npos)
            {
                break;
            }

            std::string token =
                candidate.substr(
                    separator + 1
                );

            if (isVersionToken(token))
            {
                sawVersionToken =
                    true;

                candidate.erase(
                    separator
                );

                continue;
            }

            if (isNumericToken(token) ||
                isPlatformToken(token))
            {
                candidate.erase(
                    separator
                );

                continue;
            }

            break;
        }


        // Requiring a version token prevents an ordinary title
        // ending in a number or platform-like word being stripped.
        if (sawVersionToken &&
            !candidate.empty())
        {
            title =
                candidate;
        }
    }


    // Underscores are usually just filename separators.
    std::replace(
        title.begin(),
        title.end(),
        '_',
        ' '
    );


    // WHDLoad filenames often join normal title words together,
    // for example "PinballFantasies" or
    // "SensibleWorldOfSoccer9697".
    //
    // Add display-only spaces at obvious word/number boundaries.
    // The real filename remains unchanged.
    if (extension == ".lha")
    {
        std::string spaced;

        for (std::size_t index = 0;
             index < title.size();
             ++index)
        {
            unsigned char current =
                static_cast<unsigned char>(
                    title[index]
                );

            if (index > 0)
            {
                unsigned char previous =
                    static_cast<unsigned char>(
                        title[index - 1]
                    );

                bool lowerToUpper =
                    std::islower(previous) &&
                    std::isupper(current);

                bool letterToDigit =
                    std::isalpha(previous) &&
                    std::isdigit(current);

                if ((lowerToUpper ||
                     letterToDigit) &&
                    previous != ' ')
                {
                    spaced += ' ';
                }
            }

            spaced +=
                title[index];
        }

        title =
            spaced;
    }


    auto trimRight =
        [](std::string& value)
        {
            while (!value.empty() &&
                   std::isspace(
                       static_cast<unsigned char>(
                           value.back())))
            {
                value.pop_back();
            }
        };


    trimRight(title);


    // Remove trailing ROM-set tags such as:
    // (USA), (Europe), (Rev A), (En,Fr,De),
    // [!], [b1], [h1], etc.
    bool removedTag =
        true;

    while (removedTag &&
           !title.empty())
    {
        removedTag =
            false;

        trimRight(title);

        if (title.empty())
            break;


        char closing =
            title.back();

        char opening =
            '\0';


        if (closing == ')')
            opening = '(';
        else if (closing == ']')
            opening = '[';
        else if (closing == '}')
            opening = '{';


        if (opening != '\0')
        {
            std::size_t position =
                title.find_last_of(
                    opening
                );

            if (position !=
                std::string::npos)
            {
                title.erase(
                    position
                );

                trimRight(title);

                removedTag =
                    true;
            }
        }
    }


    // Collapse repeated spaces created by cleaning.
    std::string cleaned;

    bool previousWasSpace =
        false;

    for (char character :
         title)
    {
        bool isSpace =
            std::isspace(
                static_cast<unsigned char>(
                    character));

        if (isSpace)
        {
            if (!previousWasSpace)
            {
                cleaned += ' ';
            }
        }
        else
        {
            cleaned +=
                character;
        }

        previousWasSpace =
            isSpace;
    }


    trimRight(cleaned);

    // Never return an empty display title.
    if (cleaned.empty())
    {
        return game.stem().string();
    }

    return cleaned;
}



// --------------------------------------------------
// MAME display titles
//
// Arcade and Neo Geo ROM archives use MAME set names such
// as "pacman" and "mslug".  Those names must remain unchanged
// for launching, screenshots and video filenames.
//
// When a MAME-backed system opens, BareFront asks MAME for
// the human-readable descriptions once and caches them.
// --------------------------------------------------

std::string shellQuote(
    const std::string& text);


std::unordered_map<std::string, std::string>
loadMameDisplayTitles(
    const std::vector<fs::path>& games)
{
    std::unordered_map<std::string, std::string>
        titles;

    if (games.empty())
        return titles;

    std::string command =
        "/usr/games/mame -listfull";

    for (const auto& game : games)
    {
        command +=
            " " +
            shellQuote(
                game.stem().string()
            );
    }

    command +=
        " 2>/dev/null";

    FILE* pipe =
        popen(
            command.c_str(),
            "r"
        );

    if (!pipe)
        return titles;

    char buffer[4096];

    while (fgets(
               buffer,
               sizeof(buffer),
               pipe))
    {
        std::string line =
            buffer;

        std::size_t quoteStart =
            line.find('"');

        std::size_t quoteEnd =
            line.rfind('"');

        if (quoteStart ==
                std::string::npos ||
            quoteEnd ==
                std::string::npos ||
            quoteEnd <= quoteStart)
        {
            continue;
        }

        std::string setName =
            line.substr(
                0,
                quoteStart
            );

        while (!setName.empty() &&
               std::isspace(
                   static_cast<unsigned char>(
                       setName.back())))
        {
            setName.pop_back();
        }

        std::string description =
            line.substr(
                quoteStart + 1,
                quoteEnd -
                    quoteStart - 1
            );


        // MAME descriptions commonly append machine/set metadata
        // in a final parenthesised suffix, for example:
        //
        // Donkey Kong (US set 1)
        // Out Run (sitdown/upright, Rev B)
        // Wonder Boy (set 1, 315-5177)
        //
        // Keep MAME's authoritative title, but hide that final
        // set/revision detail from BareFront's display only.
        if (!description.empty() &&
            description.back() == ')')
        {
            std::size_t suffixStart =
                description.rfind(" (");

            if (suffixStart !=
                std::string::npos)
            {
                description.erase(
                    suffixStart
                );
            }
        }


        if (!setName.empty())
        {
            titles[setName] =
                description;
        }
    }

    pclose(pipe);

    return titles;
}


// --------------------------------------------------
// System definition
// --------------------------------------------------

struct System
{
    std::string name;
    std::string screenTitle;
    std::string configSection;
    std::string imagePath;
    fs::path romFolder;
    fs::path screenshotFolder;
    std::vector<std::string> romExtensions;

    // Machine-specific launcher settings come from barefront.ini.
    std::string emulator;
    std::string arguments;

    SDL_Texture* texture = nullptr;
};


// --------------------------------------------------
// Draw text
// --------------------------------------------------

void drawText(
    SDL_Renderer* renderer,
    TTF_Font* font,
    const std::string& text,
    int x,
    int y,
    SDL_Color colour)
{
    SDL_Surface* surface =
        TTF_RenderUTF8_Blended(
            font,
            text.c_str(),
            colour
        );

    if (!surface)
        return;

    SDL_Texture* texture =
        SDL_CreateTextureFromSurface(
            renderer,
            surface
        );

    if (!texture)
    {
        SDL_FreeSurface(surface);
        return;
    }

    SDL_Rect destination =
    {
        x,
        y,
        surface->w,
        surface->h
    };

    SDL_FreeSurface(surface);

    SDL_RenderCopy(
        renderer,
        texture,
        nullptr,
        &destination
    );

    SDL_DestroyTexture(texture);
}


// --------------------------------------------------
// Draw centred text
// --------------------------------------------------

void drawTextCentered(
    SDL_Renderer* renderer,
    TTF_Font* font,
    const std::string& text,
    SDL_Rect area,
    SDL_Color colour)
{
    int width = 0;
    int height = 0;

    TTF_SizeUTF8(
        font,
        text.c_str(),
        &width,
        &height
    );

    int x =
        area.x +
        (area.w - width) / 2;

    int y =
        area.y +
        (area.h - height) / 2;

    drawText(
        renderer,
        font,
        text,
        x,
        y,
        colour
    );
}


// --------------------------------------------------
// Draw game title
//
// Long selected titles scroll right to left
// --------------------------------------------------

void drawGameTitle(
    SDL_Renderer* renderer,
    TTF_Font* font,
    const std::string& text,
    int x,
    int y,
    int maxWidth,
    SDL_Color colour,
    bool selected,
    Uint32 selectedSince)
{
    int textWidth = 0;
    int textHeight = 0;

    TTF_SizeUTF8(
        font,
        text.c_str(),
        &textWidth,
        &textHeight
    );

    // If it fits, just draw it
    if (textWidth <= maxWidth)
    {
        drawText(
            renderer,
            font,
            text,
            x,
            y,
            colour
        );

        return;
    }

    // Clip long titles
    SDL_Rect clip =
    {
        x,
        y - 4,
        maxWidth,
        textHeight + 8
    };

    SDL_RenderSetClipRect(
        renderer,
        &clip
    );

    int drawX = x;

    // Only selected title scrolls
    if (selected)
    {
        Uint32 elapsed =
            SDL_GetTicks() -
            selectedSince;

        const Uint32 pauseTime =
            1000;

        if (elapsed > pauseTime)
        {
            Uint32 scrollTime =
                elapsed - pauseTime;

            // Roughly 40 pixels per second
            int offset =
                static_cast<int>(
                    scrollTime / 25
                );

            int totalTravel =
                textWidth + 120;

            offset =
                offset % totalTravel;

            drawX =
                x - offset;
        }
    }

    drawText(
        renderer,
        font,
        text,
        drawX,
        y,
        colour
    );

    SDL_RenderSetClipRect(
        renderer,
        nullptr
    );
}


// --------------------------------------------------
// Draw texture while preserving aspect ratio
// --------------------------------------------------

void drawTextureContained(
    SDL_Renderer* renderer,
    SDL_Texture* texture,
    SDL_Rect area)
{
    if (!texture)
        return;

    int imageWidth = 0;
    int imageHeight = 0;

    SDL_QueryTexture(
        texture,
        nullptr,
        nullptr,
        &imageWidth,
        &imageHeight
    );

    float imageRatio =
        static_cast<float>(imageWidth) /
        static_cast<float>(imageHeight);

    float areaRatio =
        static_cast<float>(area.w) /
        static_cast<float>(area.h);

    SDL_Rect destination;

    if (imageRatio > areaRatio)
    {
        destination.w =
            area.w;

        destination.h =
            static_cast<int>(
                area.w /
                imageRatio
            );

        destination.x =
            area.x;

        destination.y =
            area.y +
            (area.h - destination.h) / 2;
    }
    else
    {
        destination.h =
            area.h;

        destination.w =
            static_cast<int>(
                area.h *
                imageRatio
            );

        destination.x =
            area.x +
            (area.w - destination.w) / 2;

        destination.y =
            area.y;
    }

    SDL_RenderCopy(
        renderer,
        texture,
        nullptr,
        &destination
    );
}


// --------------------------------------------------
// Draw system image
//
// Fits the entire console artwork inside the area
// without cropping
// --------------------------------------------------

void drawSystemImage(
    SDL_Renderer* renderer,
    SDL_Texture* texture,
    SDL_Rect area)
{
    // System artwork should always fit inside the available
    // area without cropping any part of the console.
    drawTextureContained(
        renderer,
        texture,
        area
    );
}


// --------------------------------------------------
// Draw CRT television frame
// --------------------------------------------------

void drawCRTFrame(
    SDL_Renderer* renderer,
    SDL_Texture* tvTexture,
    SDL_Rect tvArea,
    double angleDegrees)
{
    if (!tvTexture)
        return;

    // Crop transparent border around generated TV
    SDL_Rect source =
    {
        17,
        95,
        1218,
        1016
    };

    SDL_RenderCopyEx(
        renderer,
        tvTexture,
        &source,
        &tvArea,
        angleDegrees,
        nullptr,
        SDL_FLIP_NONE
    );
}


void drawCRT(
    SDL_Renderer* renderer,
    SDL_Texture* tvTexture,
    SDL_Rect tvArea)
{
    drawCRTFrame(
        renderer,
        tvTexture,
        tvArea,
        0.0
    );
}


void drawCRTTate(
    SDL_Renderer* renderer,
    SDL_Texture* tvTexture,
    SDL_Rect tvArea)
{
    drawCRTFrame(
        renderer,
        tvTexture,
        tvArea,
        90.0
    );
}


// --------------------------------------------------
// Find screenshot belonging to selected game
// --------------------------------------------------

fs::path findScreenshot(
    const fs::path& screenshotFolder,
    const fs::path& game)
{
    const std::string gameName =
        game.stem().string();

    const std::vector<std::string> extensions =
    {
        ".png",
        ".jpg",
        ".jpeg"
    };

    for (const auto& extension :
         extensions)
    {
        fs::path candidate =
            screenshotFolder /
            (gameName + extension);

        if (fs::exists(candidate))
        {
            return candidate;
        }
    }

    return {};
}


// --------------------------------------------------
// Load screenshot
// --------------------------------------------------

SDL_Texture* loadScreenshot(
    SDL_Renderer* renderer,
    const fs::path& screenshotFolder,
    const fs::path& game)
{
    fs::path screenshot =
        findScreenshot(
            screenshotFolder,
            game
        );

    if (screenshot.empty())
        return nullptr;

    SDL_Surface* surface =
        IMG_Load(
            screenshot
                .string()
                .c_str()
        );

    if (!surface)
        return nullptr;

    SDL_Texture* texture =
        SDL_CreateTextureFromSurface(
            renderer,
            surface
        );

    SDL_FreeSurface(
        surface
    );

    return texture;
}



// --------------------------------------------------
// Find a video preview belonging to selected game
// --------------------------------------------------

fs::path findVideo(
    const System& system,
    const fs::path& game)
{
    fs::path videoFolder =
        fs::path("assets/videos") /
        system.configSection;

    fs::path candidate =
        videoFolder /
        (game.stem().string() + ".mp4");

    if (fs::exists(candidate))
    {
        return candidate;
    }

    return {};
}


// --------------------------------------------------
// Quote text safely for shell commands.
// Used by ffprobe and MAME metadata queries.
// --------------------------------------------------

std::string shellQuote(
    const std::string& text)
{
    std::string quoted = "'";

    for (char c : text)
    {
        if (c == '\'')
        {
            quoted += "'\\''";
        }
        else
        {
            quoted += c;
        }
    }

    quoted += "'";

    return quoted;
}


// --------------------------------------------------
// Ask ffprobe for the stored preview dimensions.
// This lets portrait and widescreen captures keep
// their real aspect ratio inside the CRT screen.
// --------------------------------------------------

bool probeVideoDimensions(
    const fs::path& videoPath,
    int& width,
    int& height)
{
    std::string command =
        "ffprobe -v error "
        "-select_streams v:0 "
        "-show_entries stream=width,height "
        "-of csv=s=x:p=0 " +
        shellQuote(videoPath.string()) +
        " 2>/dev/null";

    FILE* pipe =
        popen(
            command.c_str(),
            "r"
        );

    if (!pipe)
    {
        return false;
    }

    char buffer[128] = {};

    bool gotLine =
        fgets(
            buffer,
            sizeof(buffer),
            pipe
        ) != nullptr;

    pclose(pipe);

    if (!gotLine)
    {
        return false;
    }

    int foundWidth = 0;
    int foundHeight = 0;

    if (std::sscanf(
            buffer,
            "%dx%d",
            &foundWidth,
            &foundHeight) != 2)
    {
        return false;
    }

    if (foundWidth <= 0 ||
        foundHeight <= 0)
    {
        return false;
    }

    width = foundWidth;
    height = foundHeight;

    return true;
}


// --------------------------------------------------
// Lightweight looping video player for CRT previews.
//
// FFmpeg does the decoding in a child process and
// sends silent RGBA frames through a pipe. A small
// reader thread keeps the newest frame ready for SDL.
//
// No FFmpeg development libraries are required.
// --------------------------------------------------

class VideoPlayer
{
public:
    ~VideoPlayer()
    {
        stop();
    }


    bool start(
        SDL_Renderer* renderer,
        const fs::path& videoPath)
    {
        stop();

        if (videoPath.empty() ||
            !fs::exists(videoPath))
        {
            return false;
        }

        int sourceWidth = 0;
        int sourceHeight = 0;

        if (!probeVideoDimensions(
                videoPath,
                sourceWidth,
                sourceHeight))
        {
            std::cerr
                << "Could not probe video: "
                << videoPath
                << "\n";

            return false;
        }

        // Keep the stored preview dimensions.
        //
        // The video is stretched only when SDL renders it
        // into the CRT screen opening. This keeps portrait
        // detection based on the real capture geometry while
        // making every preview fill the monitor exactly.
        frameWidth =
            sourceWidth;

        frameHeight =
            sourceHeight;

        texture =
            SDL_CreateTexture(
                renderer,
                SDL_PIXELFORMAT_RGBA32,
                SDL_TEXTUREACCESS_STREAMING,
                frameWidth,
                frameHeight
            );

        if (!texture)
        {
            std::cerr
                << "Video texture error: "
                << SDL_GetError()
                << "\n";

            stop();
            return false;
        }

        int pipeFd[2] = {-1, -1};

        if (pipe(pipeFd) != 0)
        {
            stop();
            return false;
        }

        std::string scaleFilter =
            "fps=30";

        childPid =
            fork();

        if (childPid == 0)
        {
            // Child: FFmpeg writes raw frames to stdout.
            close(pipeFd[0]);

            dup2(
                pipeFd[1],
                STDOUT_FILENO
            );

            close(pipeFd[1]);

            int nullFd =
                open(
                    "/dev/null",
                    O_WRONLY
                );

            if (nullFd >= 0)
            {
                dup2(
                    nullFd,
                    STDERR_FILENO
                );

                close(nullFd);
            }

            execlp(
                "ffmpeg",
                "ffmpeg",
                "-loglevel", "error",
                "-nostdin",
                "-re",
                "-stream_loop", "-1",
                "-i", videoPath.c_str(),
                "-an",
                "-sn",
                "-dn",
                "-vf", scaleFilter.c_str(),
                "-f", "rawvideo",
                "-pix_fmt", "rgba",
                "pipe:1",
                static_cast<char*>(nullptr)
            );

            _exit(127);
        }

        if (childPid < 0)
        {
            close(pipeFd[0]);
            close(pipeFd[1]);
            stop();
            return false;
        }

        close(pipeFd[1]);

        readFd =
            pipeFd[0];

        const std::size_t frameBytes =
            static_cast<std::size_t>(
                frameWidth) *
            static_cast<std::size_t>(
                frameHeight) *
            4;

        latestFrame.assign(
            frameBytes,
            0
        );

        running =
            true;

        frameSerial =
            0;

        uploadedSerial =
            0;

        readerThread =
            std::thread(
                [this, frameBytes]()
                {
                    std::vector<unsigned char> frame(
                        frameBytes
                    );

                    while (running)
                    {
                        std::size_t received = 0;

                        while (received < frameBytes &&
                               running)
                        {
                            ssize_t amount =
                                read(
                                    readFd,
                                    frame.data() + received,
                                    frameBytes - received
                                );

                            if (amount <= 0)
                            {
                                running = false;
                                return;
                            }

                            received +=
                                static_cast<std::size_t>(
                                    amount
                                );
                        }

                        if (!running)
                        {
                            break;
                        }

                        {
                            std::lock_guard<std::mutex> lock(
                                frameMutex
                            );

                            latestFrame =
                                frame;

                            ++frameSerial;
                        }
                    }
                }
            );

        return true;
    }


    void stop()
    {
        running =
            false;

        if (childPid > 0)
        {
            kill(
                childPid,
                SIGTERM
            );
        }

        if (readerThread.joinable())
        {
            readerThread.join();
        }

        if (readFd >= 0)
        {
            close(readFd);
            readFd = -1;
        }

        if (childPid > 0)
        {
            int status = 0;

            waitpid(
                childPid,
                &status,
                0
            );

            childPid = -1;
        }

        if (texture)
        {
            SDL_DestroyTexture(
                texture
            );

            texture =
                nullptr;
        }

        {
            std::lock_guard<std::mutex> lock(
                frameMutex
            );

            latestFrame.clear();
            frameSerial = 0;
            uploadedSerial = 0;
        }

        frameWidth = 0;
        frameHeight = 0;
    }


    bool hasFrame()
    {
        std::lock_guard<std::mutex> lock(
            frameMutex
        );

        return frameSerial > 0;
    }


    bool isPortrait()
    {
        return frameHeight >
            frameWidth;
    }


    void draw(
        SDL_Renderer* renderer,
        SDL_Rect area)
    {
        if (!texture)
        {
            return;
        }

        {
            std::lock_guard<std::mutex> lock(
                frameMutex
            );

            if (frameSerial > 0 &&
                frameSerial != uploadedSerial &&
                !latestFrame.empty())
            {
                SDL_UpdateTexture(
                    texture,
                    nullptr,
                    latestFrame.data(),
                    frameWidth * 4
                );

                uploadedSerial =
                    frameSerial;
            }
        }

        SDL_RenderCopy(
            renderer,
            texture,
            nullptr,
            &area
        );
    }


private:
    SDL_Texture* texture =
        nullptr;

    pid_t childPid =
        -1;

    int readFd =
        -1;

    int frameWidth =
        0;

    int frameHeight =
        0;

    std::atomic<bool> running =
        false;

    std::thread readerThread;

    std::mutex frameMutex;

    std::vector<unsigned char> latestFrame;

    std::uint64_t frameSerial =
        0;

    std::uint64_t uploadedSerial =
        0;
};


bool isArcadeSystem(
    const System& system)
{
    return system.configSection ==
        "arcade";
}


bool textureIsPortrait(
    SDL_Texture* texture)
{
    if (!texture)
    {
        return false;
    }

    int width = 0;
    int height = 0;

    if (SDL_QueryTexture(
            texture,
            nullptr,
            nullptr,
            &width,
            &height) != 0)
    {
        return false;
    }

    return height >
        width;
}


bool probeImageDimensions(
    const fs::path& imagePath,
    int& width,
    int& height)
{
    SDL_Surface* surface =
        IMG_Load(
            imagePath.string().c_str()
        );

    if (!surface)
    {
        return false;
    }

    width =
        surface->w;

    height =
        surface->h;

    SDL_FreeSurface(
        surface
    );

    return true;
}


bool determineTatePreview(
    const System& system,
    const fs::path& game)
{
    if (!isArcadeSystem(system))
    {
        return false;
    }

    // Arcade orientation comes from MAME machine metadata,
    // never from the dimensions of a screenshot or video.
    //
    // A capture can be almost square or temporarily contain
    // black borders depending on the title/attract/gameplay
    // frame that happened to be recorded. MAME's display
    // rotation is the authoritative orientation.
    static std::unordered_map<std::string, bool>
        tateCache;

    const std::string setName =
        game.stem().string();

    auto cached =
        tateCache.find(
            setName
        );

    if (cached !=
        tateCache.end())
    {
        return cached->second;
    }

    std::string command =
        "/usr/games/mame -listxml " +
        shellQuote(setName) +
        " 2>/dev/null";

    FILE* pipe =
        popen(
            command.c_str(),
            "r"
        );

    if (!pipe)
    {
        return false;
    }

    bool orientationFound =
        false;

    bool tate =
        false;

    char buffer[4096];

    while (fgets(
               buffer,
               sizeof(buffer),
               pipe))
    {
        std::string line =
            buffer;

        if (line.find("<display ") ==
            std::string::npos)
        {
            continue;
        }

        std::size_t rotateStart =
            line.find("rotate=\"");

        if (rotateStart ==
            std::string::npos)
        {
            continue;
        }

        rotateStart +=
            8;

        std::size_t rotateEnd =
            line.find(
                '"',
                rotateStart
            );

        if (rotateEnd ==
            std::string::npos)
        {
            continue;
        }

        std::string rotate =
            line.substr(
                rotateStart,
                rotateEnd -
                    rotateStart
            );

        if (rotate == "0" ||
            rotate == "180")
        {
            orientationFound =
                true;

            tate =
                false;

            break;
        }

        if (rotate == "90" ||
            rotate == "270")
        {
            orientationFound =
                true;

            tate =
                true;

            break;
        }
    }

    pclose(pipe);

    if (orientationFound)
    {
        tateCache[setName] =
            tate;
    }

    return tate;
}


// --------------------------------------------------
// Refresh the CRT preview for a selected game.
//
// Priority:
//   1. Matching MP4 video
//   2. Matching screenshot
//   3. NO SIGNAL
//
// Screenshot is loaded even when a video exists so
// BareFront has an immediate fallback while FFmpeg is
// producing the first video frame.
// --------------------------------------------------

void refreshGamePreview(
    SDL_Renderer* renderer,
    VideoPlayer& videoPlayer,
    SDL_Texture*& screenshotTexture,
    bool& useTatePreview,
    const System& system,
    const fs::path& game,
    const fs::path& artworkIdentity = {})
{
    const fs::path& artworkGame =
        artworkIdentity.empty() ? game : artworkIdentity;

    useTatePreview =
        determineTatePreview(
            system,
            game
        );

    videoPlayer.stop();

    if (screenshotTexture)
    {
        SDL_DestroyTexture(
            screenshotTexture
        );

        screenshotTexture =
            nullptr;
    }

    screenshotTexture =
        loadScreenshot(
            renderer,
            system.screenshotFolder,
            artworkGame
        );

    if (!screenshotTexture && artworkGame != game)
        screenshotTexture = loadScreenshot(
            renderer, system.screenshotFolder, game);

    fs::path videoPath =
        findVideo(system, artworkGame);

    if (videoPath.empty() && artworkGame != game)
        videoPath = findVideo(system, game);

    if (!videoPath.empty())
    {
        videoPlayer.start(
            renderer,
            videoPath
        );
    }
}


// --------------------------------------------------
// Small BareFront INI configuration reader
//
// BareFront keeps its UI/system definitions in code.
// Machine-specific paths and emulator commands live in
// barefront.ini so this same executable can be used on
// different machines without recompiling.
// --------------------------------------------------

std::string trim(
    const std::string& text)
{
    std::size_t first =
        text.find_first_not_of(
            " \t\r\n"
        );

    if (first ==
        std::string::npos)
    {
        return "";
    }

    std::size_t last =
        text.find_last_not_of(
            " \t\r\n"
        );

    return text.substr(
        first,
        last - first + 1
    );
}


System* findSystemByConfigSection(
    std::vector<System>& systems,
    const std::string& section)
{
    for (System& system :
         systems)
    {
        if (system.configSection ==
            section)
        {
            return &system;
        }
    }

    return nullptr;
}


bool loadBareFrontConfig(
    const fs::path& configPath,
    std::vector<System>& systems)
{
    std::ifstream file(
        configPath
    );

    if (!file)
    {
        std::cerr
            << "BareFront config not found: "
            << configPath
            << "\n";

        return false;
    }


    System* currentSystem =
        nullptr;

    std::string line;


    while (std::getline(
        file,
        line))
    {
        line =
            trim(
                line
            );


        if (line.empty())
        {
            continue;
        }


        if (line[0] == '#' ||
            line[0] == ';')
        {
            continue;
        }


        // [megadrive]
        if (line.front() == '[' &&
            line.back() == ']')
        {
            std::string section =
                trim(
                    line.substr(
                        1,
                        line.size() - 2
                    )
                );

            currentSystem =
                findSystemByConfigSection(
                    systems,
                    section
                );

            continue;
        }


        if (!currentSystem)
        {
            continue;
        }


        std::size_t equals =
            line.find('=');


        if (equals ==
            std::string::npos)
        {
            continue;
        }


        std::string key =
            trim(
                line.substr(
                    0,
                    equals
                )
            );

        std::string value =
            trim(
                line.substr(
                    equals + 1
                )
            );


        if (key == "roms")
        {
            currentSystem->romFolder =
                value;
        }
        else if (
            key == "screenshots")
        {
            currentSystem->screenshotFolder =
                value;
        }
        else if (
            key == "emulator")
        {
            currentSystem->emulator =
                value;
        }
        else if (
            key == "arguments")
        {
            currentSystem->arguments =
                value;
        }
    }


    return true;
}


// --------------------------------------------------
// Replace every occurrence of a small placeholder.
// --------------------------------------------------

void replaceAll(
    std::string& text,
    const std::string& from,
    const std::string& to)
{
    if (from.empty())
    {
        return;
    }


    std::size_t position =
        0;


    while ((
        position =
            text.find(
                from,
                position
            )
        ) != std::string::npos)
    {
        text.replace(
            position,
            from.length(),
            to
        );

        position +=
            to.length();
    }
}


// --------------------------------------------------
// Preview capture size for each system.
//
// 240p-era systems are stored no larger than 320x240.
// Later 480-line systems keep up to 640x480.
//
// The capture helper preserves the game's aspect ratio,
// so widescreen and portrait sources are NOT stretched.
// --------------------------------------------------

void getCapturePreviewSize(
    const System& system,
    int& maxWidth,
    int& maxHeight)
{
    maxWidth = 320;
    maxHeight = 240;

    if (system.configSection == "ps1" ||
        system.configSection == "ps2" ||
        system.configSection == "dreamcast" ||
        system.configSection == "saturn" ||
        system.configSection == "gamecube")
    {
        maxWidth = 640;
        maxHeight = 480;
    }
}


void drawWrappedCenteredText(
    SDL_Renderer* renderer,
    TTF_Font* font,
    const std::string& text,
    const SDL_Rect& area,
    SDL_Color color)
{
    if (!renderer || !font ||
        area.w <= 0 || area.h <= 0)
        return;

    SDL_Surface* surface =
        TTF_RenderUTF8_Blended_Wrapped(
            font,
            text.c_str(),
            color,
            static_cast<Uint32>(area.w)
        );

    if (!surface)
        return;

    SDL_Texture* texture =
        SDL_CreateTextureFromSurface(
            renderer,
            surface
        );

    const int originalWidth = surface->w;
    const int originalHeight = surface->h;

    SDL_FreeSurface(surface);

    if (!texture ||
        originalWidth <= 0 ||
        originalHeight <= 0)
    {
        if (texture)
            SDL_DestroyTexture(texture);

        return;
    }

    int width = originalWidth;
    int height = originalHeight;

    if (width > area.w || height > area.h)
    {
        const double scale = std::min(
            static_cast<double>(area.w) / width,
            static_cast<double>(area.h) / height
        );

        width = std::max(
            1,
            static_cast<int>(width * scale)
        );

        height = std::max(
            1,
            static_cast<int>(height * scale)
        );
    }

    SDL_Rect destination = {
        area.x + (area.w - width) / 2,
        area.y + (area.h - height) / 2,
        width,
        height
    };

    SDL_RenderCopy(
        renderer,
        texture,
        nullptr,
        &destination
    );

    SDL_DestroyTexture(texture);
}

// --------------------------------------------------
// Launch selected game using the active system's
// emulator and arguments from barefront.ini.
//
// {rom} in the arguments line is replaced with the
// selected ROM path.
// --------------------------------------------------

void launchGame(
    const System& system,
    const fs::path& game,
    const fs::path& emulatorGame)
{
    if (system.emulator.empty())
    {
        std::cerr
            << "No emulator configured for "
            << system.name
            << "\n";

        return;
    }


    // --------------------------------------------------
    // Prepare automatic BareFront capture filenames.
    //
    // The REAL ROM stem is used, not the cleaned title,
    // so media matching stays exact even for archive names.
    // --------------------------------------------------

    fs::path videoFolder =
        fs::path("assets/videos") /
        system.configSection;


    std::error_code folderError;

    fs::create_directories(
        system.screenshotFolder,
        folderError
    );

    folderError.clear();

    fs::create_directories(
        videoFolder,
        folderError
    );


    const std::string romStem =
        game.stem().string();


    fs::path screenshotPath =
        system.screenshotFolder /
        (romStem + ".png");


    fs::path videoPath =
        videoFolder /
        (romStem + ".mp4");


    int captureMaxWidth = 320;
    int captureMaxHeight = 240;

    getCapturePreviewSize(
        system,
        captureMaxWidth,
        captureMaxHeight
    );


    // --------------------------------------------------
    // Start the capture helper beside the emulator.
    //
    // It watches global P/R keys plus the controller
    // Select+Left / Select+Right combinations while
    // BareFront itself is waiting for the emulator.
    //
    // Missing helper = no capture, but games still launch.
    // --------------------------------------------------

    pid_t captureHelperPid =
        -1;


    const fs::path captureHelper =
        "./capture_helper";


    if (fs::exists(captureHelper))
    {
        captureHelperPid =
            fork();


        if (captureHelperPid == 0)
        {
            std::string captureWidth =
                std::to_string(
                    captureMaxWidth
                );

            std::string captureHeight =
                std::to_string(
                    captureMaxHeight
                );

            execl(
                captureHelper.c_str(),
                captureHelper.c_str(),
                screenshotPath.c_str(),
                videoPath.c_str(),
                captureWidth.c_str(),
                captureHeight.c_str(),
                static_cast<char*>(nullptr)
            );

            // execl only returns if it failed.
            _exit(127);
        }
    }
    else
    {
        std::cerr
            << "Capture helper not found: "
            << captureHelper
            << " (capture disabled)\n";
    }


    // --------------------------------------------------
    // Start the Gamescope presentation overlay.
    //
    // The helper is deliberately optional: if it is missing,
    // games still launch normally.
    //
    // BareFront owns per-game presentation regardless of how
    // the menu itself was started.  If this system has tracked
    // overlay artwork, start the presentation helper for gameplay.
    // --------------------------------------------------

    pid_t overlayHelperPid =
        -1;





    const fs::path overlayHelper =
        "./overlay_helper";


    // Plain-black overlay systems use their measured, protected
    // gameplay apertures. The four exceptional systems retain
    // their existing presentation until individually validated.
    struct OverlaySpec
    {
        const char* name;
        int x;
        int y;
        int width;
        int height;
    };

    static constexpr OverlaySpec overlaySpecs[] =
    {
        {"atari2600",    320,  84, 1280, 912},
        {"dreamcast",    320,  60, 1280, 960},
        {"gamecube",     320,  60, 1280, 960},
        {"jaguar",       320,  60, 1280, 960},
        {"mastersystem", 448, 156, 1024, 768},
        {"megadrive",    320,  92, 1280, 896},
        {"nes",          448,  60, 1024, 960},
        {"pcengine",     384,  76, 1152, 928},
        {"ps1",          320,  60, 1280, 960},
        {"ps2",          320,  60, 1280, 960},
        {"saturn",       256,  60, 1408, 960},
        {"snes",         448,  92, 1024, 896}
    };

    const OverlaySpec* overlaySpec = nullptr;

    for (const auto& candidate : overlaySpecs)
    {
        if (system.configSection == candidate.name)
        {
            overlaySpec = &candidate;
            break;
        }
    }

    const fs::path overlayRoot =
        "assets/overlays";

    const fs::path defaultOverlayArtwork =
        overlaySpec
            ? overlayRoot / "plain" / (system.configSection + ".png")
            : overlayRoot / (system.configSection + ".png");

    fs::path overlayArtwork =
        defaultOverlayArtwork;

    if (overlaySpec)
    {
        fs::path mapping =
            overlayRoot / "overlays.ini";

        if (!fs::exists(mapping))
        {
            mapping =
                overlayRoot / "overlays.ini.example";
        }

        std::ifstream selections(mapping);
        std::string line;

        const auto trim = [](std::string value)
        {
            const auto first =
                value.find_first_not_of(" \t\r\n");

            if (first == std::string::npos)
            {
                return std::string{};
            }

            const auto last =
                value.find_last_not_of(" \t\r\n");

            return value.substr(first, last - first + 1);
        };

        while (std::getline(selections, line))
        {
            line = trim(line);

            if (line.empty() ||
                line[0] == '#' ||
                line[0] == ';')
            {
                continue;
            }

            const auto equals = line.find('=');

            if (equals == std::string::npos ||
                trim(line.substr(0, equals)) != system.configSection)
            {
                continue;
            }

            const fs::path relative(
                trim(line.substr(equals + 1))
            );

            bool safe =
                !relative.empty() &&
                !relative.is_absolute() &&
                relative.extension() == ".png";

            for (const auto& part : relative)
            {
                if (part == "..")
                {
                    safe = false;
                }
            }

            if (safe)
            {
                const fs::path candidate =
                    overlayRoot / relative;

                if (fs::is_regular_file(candidate))
                {
                    SDL_Surface* loaded =
                        IMG_Load(candidate.string().c_str());

                    if (loaded)
                    {
                        bool valid =
                            loaded->w == 1920 &&
                            loaded->h == 1080;

                        SDL_Surface* rgba = nullptr;
                        bool surfaceLocked = false;

                        if (valid)
                        {
                            rgba = SDL_ConvertSurfaceFormat(
                                loaded,
                                SDL_PIXELFORMAT_RGBA32,
                                0
                            );

                            valid = rgba != nullptr;
                        }

                        if (valid && SDL_MUSTLOCK(rgba))
                        {
                            surfaceLocked =
                                SDL_LockSurface(rgba) == 0;
                            valid = surfaceLocked;
                        }

                        if (valid)
                        {
                            // The complete native gameplay image must
                            // remain unobscured by custom artwork.
                            for (int y = overlaySpec->y;
                                 y < overlaySpec->y + overlaySpec->height && valid;
                                 ++y)
                            {
                                const auto* row =
                                    reinterpret_cast<const Uint32*>(
                                        static_cast<const Uint8*>(rgba->pixels) +
                                        y * rgba->pitch
                                    );

                                for (int x = overlaySpec->x;
                                     x < overlaySpec->x + overlaySpec->width;
                                     ++x)
                                {
                                    Uint8 r, g, b, a;

                                    SDL_GetRGBA(
                                        row[x],
                                        rgba->format,
                                        &r, &g, &b, &a
                                    );

                                    if (a != 0)
                                    {
                                        valid = false;
                                        break;
                                    }
                                }
                            }
                        }

                        if (rgba)
                        {
                            if (surfaceLocked)
                            {
                                SDL_UnlockSurface(rgba);
                            }

                            SDL_FreeSurface(rgba);
                        }

                        SDL_FreeSurface(loaded);

                        if (valid)
                        {
                            overlayArtwork = candidate;
                        }
                    }
                }
            }

            if (overlayArtwork == defaultOverlayArtwork &&
                relative != (fs::path("plain") /
                             (system.configSection + ".png")))
            {
                std::cerr
                    << "Invalid " << system.configSection
                    << " overlay selection; "
                    << "using plain default\n";
            }

            break;
        }

        std::cout
            << system.configSection << " overlay: "
            << overlayArtwork.string()
            << "\n";
    }





    const char* gamescopeEnvironment =
        std::getenv(
            "BAREFRONT_GAMESCOPE_CAPTURE"
        );


    const bool gamescopeActive =
        gamescopeEnvironment &&
        std::string(gamescopeEnvironment) == "1";


    if (
        gamescopeActive &&
        overlaySpec != nullptr &&
        fs::exists(overlayArtwork)
    )
    {
        if (fs::exists(overlayHelper))
        {
            overlayHelperPid =
                fork();


            if (overlayHelperPid == 0)
            {
                // Keep the presentation overlay out of the
                // emulator/Gamescope process group.  Gamescope
                // lifecycle signalling must never terminate the
                // BareFront-owned overlay helper.
                if (setpgid(0, 0) != 0)
                {
                    _exit(126);
                }

                execl(
                    overlayHelper.c_str(),
                    overlayHelper.c_str(),
                    overlayArtwork.c_str(),
                    static_cast<char*>(nullptr)
                );

                // execl only returns if it failed.
                _exit(127);
            }


            if (overlayHelperPid < 0)
            {
                std::cerr
                    << "Unable to start overlay helper\n";
            }
        }
        else
        {
            std::cerr
                << "Overlay helper not found: "
                << overlayHelper
                << " (overlay disabled)\n";
        }
    }


    std::string arguments =
        system.arguments;


    replaceAll(
        arguments,
        "{rom}",
        shellQuote(
            emulatorGame.string()
        )
    );


    std::string command =
        shellQuote(
            system.emulator
        );


    if (!arguments.empty())
    {
        command +=
            " " +
            arguments;
    }


    std::cout
        << "Launching: "
        << command
        << "\n";


    // --------------------------------------------------
    // Launch gameplay as a managed child process group.
    //
    // Do not use std::system() here. BareFront must remain
    // able to react to SDL_QUIT / SIGTERM while a game is
    // running, and it must own the complete gameplay tree.
    // --------------------------------------------------

    bool quitRequested =
        false;


    pid_t gameProcessPid =
        fork();


    if (gameProcessPid == 0)
    {
        // Wrapper + Gamescope + emulator all belong to one
        // gameplay process group owned by BareFront.
        if (setpgid(0, 0) != 0)
        {
            _exit(126);
        }


        execl(
            "/bin/sh",
            "sh",
            "-c",
            command.c_str(),
            static_cast<char*>(nullptr)
        );


        _exit(127);
    }


    if (gameProcessPid < 0)
    {
        std::cerr
            << "Unable to start gameplay process\n";
    }
    else
    {
        // Close the small fork/setpgid race from the parent
        // side as well. Failure here is harmless if the child
        // already established its own group.
        setpgid(
            gameProcessPid,
            gameProcessPid
        );


        int gameStatus =
            0;

        bool gameExited =
            false;


        while (!gameExited)
        {
            pid_t result =
                waitpid(
                    gameProcessPid,
                    &gameStatus,
                    WNOHANG
                );


            if (result == gameProcessPid)
            {
                gameExited =
                    true;

                break;
            }


            if (result < 0)
            {
                if (errno == EINTR)
                {
                    continue;
                }

                gameExited =
                    true;

                break;
            }


            // SDL converts desktop close / SIGTERM into an
            // SDL_QUIT event. Pump only that event here while
            // BareFront is supervising gameplay.
            SDL_PumpEvents();


            SDL_Event quitEvent {};


            int quitEventCount =
                SDL_PeepEvents(
                    &quitEvent,
                    1,
                    SDL_GETEVENT,
                    SDL_QUIT,
                    SDL_QUIT
                );


            if (quitEventCount > 0)
            {
                quitRequested =
                    true;


                // Ask the entire gameplay tree to exit cleanly.
                kill(
                    -gameProcessPid,
                    SIGTERM
                );


                // Give wrappers time to run EXIT traps such as
                // restoring the host display refresh rate.
                for (int attempt = 0;
                     attempt < 20;
                     ++attempt)
                {
                    result =
                        waitpid(
                            gameProcessPid,
                            &gameStatus,
                            WNOHANG
                        );


                    if (result == gameProcessPid)
                    {
                        gameExited =
                            true;

                        break;
                    }


                    if (result < 0)
                    {
                        if (errno == EINTR)
                        {
                            continue;
                        }

                        gameExited =
                            true;

                        break;
                    }


                    usleep(
                        100000
                    );
                }


                // A stuck emulator must never survive BareFront.
                if (!gameExited)
                {
                    kill(
                        -gameProcessPid,
                        SIGKILL
                    );


                    while (
                        waitpid(
                            gameProcessPid,
                            &gameStatus,
                            0
                        ) < 0 &&
                        errno == EINTR
                    )
                    {
                    }


                    gameExited =
                        true;
                }


                break;
            }


            usleep(
                100000
            );
        }
    }


    // Emulator has closed: remove the presentation overlay.
    if (overlayHelperPid > 0)
    {
        kill(
            overlayHelperPid,
            SIGTERM
        );

        waitpid(
            overlayHelperPid,
            nullptr,
            0
        );
    }


    // Stop the capture helper cleanly.
    if (captureHelperPid > 0)
    {
        kill(
            captureHelperPid,
            SIGTERM
        );

        waitpid(
            captureHelperPid,
            nullptr,
            0
        );
    }


    if (quitRequested)
    {
        SDL_Event quitEvent {};

        quitEvent.type =
            SDL_QUIT;

        SDL_PushEvent(
            &quitEvent
        );
    }
}


// --------------------------------------------------
// Scan ROM folder
// --------------------------------------------------

std::vector<fs::path> scanGames(
    const fs::path& folder,
    const std::vector<std::string>& allowedExtensions,
    std::map<fs::path, std::string>* playlistErrors = nullptr)
{
    std::vector<fs::path> games;

    // A system can be opened before its ROM folder exists.
    // BareFront simply shows NO GAMES FOUND instead of failing.
    if (!fs::exists(folder) ||
        !fs::is_directory(folder))
    {
        return games;
    }

    for (const auto& entry :
         fs::recursive_directory_iterator(folder))
    {
        if (!entry.is_regular_file())
            continue;

        std::string extension =
            entry.path()
                .extension()
                .string();

        std::transform(
            extension.begin(),
            extension.end(),
            extension.begin(),
            [](unsigned char c)
            {
                return static_cast<char>(
                    std::tolower(c)
                );
            }
        );

        bool supported =
            std::find(
                allowedExtensions.begin(),
                allowedExtensions.end(),
                extension
            ) != allowedExtensions.end();

        if (supported)
        {
            games.push_back(
                entry.path()
            );
        }
    }

    // --------------------------------------------------
    // VICE fliplist support
    //
    // A .vfl file represents one multi-disk game.
    // Media explicitly referenced by that fliplist is
    // support media and should not appear separately in
    // BareFront's game list.
    // --------------------------------------------------

    std::vector<fs::path> fliplistMedia;

    for (const auto& game : games)
    {
        std::string extension =
            game.extension().string();

        std::transform(
            extension.begin(),
            extension.end(),
            extension.begin(),
            [](unsigned char c)
            {
                return static_cast<char>(
                    std::tolower(c)
                );
            }
        );

        if (extension != ".vfl")
            continue;

        std::ifstream fliplist(game);

        if (!fliplist)
            continue;

        std::string line;

        while (std::getline(fliplist, line))
        {
            if (!line.empty() &&
                line.back() == '\r')
            {
                line.pop_back();
            }

            const std::size_t first =
                line.find_first_not_of(" \t");

            if (first == std::string::npos ||
                line[first] == ';')
            {
                continue;
            }

            const std::size_t last =
                line.find_last_not_of(" \t");

            line =
                line.substr(
                    first,
                    last - first + 1
                );

            fs::path mediaPath(line);

            if (mediaPath.is_relative())
            {
                mediaPath =
                    game.parent_path() /
                    mediaPath;
            }

            fliplistMedia.push_back(
                mediaPath.lexically_normal()
            );
        }
    }

    if (!fliplistMedia.empty())
    {
        games.erase(
            std::remove_if(
                games.begin(),
                games.end(),
                [&](const fs::path& game)
                {
                    std::string extension =
                        game.extension().string();

                    std::transform(
                        extension.begin(),
                        extension.end(),
                        extension.begin(),
                        [](unsigned char c)
                        {
                            return static_cast<char>(
                                std::tolower(c)
                            );
                        }
                    );

                    // The .vfl itself remains the visible
                    // BareFront game entry.
                    if (extension == ".vfl")
                        return false;

                    const fs::path normalisedGame =
                        game.lexically_normal();

                    return
                        std::find(
                            fliplistMedia.begin(),
                            fliplistMedia.end(),
                            normalisedGame
                        ) != fliplistMedia.end();
                }
            ),
            games.end()
        );
    }

    // --------------------------------------------------
    // BareFront universal multidisc playlist filtering.
    //
    // Existing scanner rules run first, including VICE
    // .vfl handling. Valid .m3u playlists then own their
    // referenced media so those discs do not appear as
    // duplicate game entries.
    // --------------------------------------------------

    const auto multidisc =
        bfmultidisc::filterScanned(games);

    if (playlistErrors)
    {
        for (const auto& [path, error] :
             multidisc.playlistErrors)
        {
            auto [it, inserted] =
                playlistErrors->try_emplace(path, error);

            if (!inserted &&
                it->second.find(error) == std::string::npos)
            {
                it->second += "; " + error;
            }
        }
    }

    games = multidisc.visible;

    std::sort(
        games.begin(),
        games.end()
    );

    return games;
}



// --------------------------------------------------
// Load a normal UI texture
// --------------------------------------------------

SDL_Texture* loadTexture(
    SDL_Renderer* renderer,
    const std::string& filename)
{
    SDL_Surface* surface =
        IMG_Load(
            filename.c_str()
        );

    if (!surface)
    {
        std::cerr
            << "Unable to load image: "
            << filename
            << '\n';

        return nullptr;
    }

    SDL_Texture* texture =
        SDL_CreateTextureFromSurface(
            renderer,
            surface
        );

    SDL_FreeSurface(
        surface
    );

    if (texture)
    {
        SDL_SetTextureBlendMode(
            texture,
            SDL_BLENDMODE_BLEND
        );
    }

    return texture;
}


// --------------------------------------------------
// Simple queued WAV sound effect
// --------------------------------------------------

struct SoundEffect
{
    SDL_AudioDeviceID device = 0;
    Uint8* buffer = nullptr;
    Uint32 length = 0;
};


bool loadSoundEffect(
    const std::string& filename,
    SoundEffect& sound)
{
    SDL_AudioSpec sourceSpec {};
    Uint8* sourceBuffer = nullptr;
    Uint32 sourceLength = 0;

    if (!SDL_LoadWAV(
            filename.c_str(),
            &sourceSpec,
            &sourceBuffer,
            &sourceLength))
    {
        std::cerr
            << "Sound error: "
            << SDL_GetError()
            << '\n';

        return false;
    }


    SDL_AudioSpec desiredSpec =
        sourceSpec;

    // BareFront's UI click WAV is 44.1 kHz mono, but the
    // emulator/gameplay audio path is standardised on 48 kHz.
    //
    // Request 48 kHz stereo here so BareFront does not keep the
    // HDMI/Pulse sink pinned at 44.1 kHz while gameplay is active.
    // SDL_AudioCVT below converts the small click once at load time.
    desiredSpec.freq =
        48000;

    desiredSpec.channels =
        2;

    desiredSpec.callback =
        nullptr;

    desiredSpec.userdata =
        nullptr;


    SDL_AudioSpec obtainedSpec {};

    sound.device =
        SDL_OpenAudioDevice(
            nullptr,
            0,
            &desiredSpec,
            &obtainedSpec,
            SDL_AUDIO_ALLOW_FREQUENCY_CHANGE |
            SDL_AUDIO_ALLOW_FORMAT_CHANGE |
            SDL_AUDIO_ALLOW_CHANNELS_CHANGE
        );


    if (sound.device == 0)
    {
        std::cerr
            << "Audio device error: "
            << SDL_GetError()
            << '\n';

        SDL_FreeWAV(
            sourceBuffer
        );

        return false;
    }


    SDL_AudioCVT converter {};

    int conversionNeeded =
        SDL_BuildAudioCVT(
            &converter,
            sourceSpec.format,
            sourceSpec.channels,
            sourceSpec.freq,
            obtainedSpec.format,
            obtainedSpec.channels,
            obtainedSpec.freq
        );


    if (conversionNeeded < 0)
    {
        std::cerr
            << "Audio conversion error: "
            << SDL_GetError()
            << '\n';

        SDL_CloseAudioDevice(
            sound.device
        );

        sound.device =
            0;

        SDL_FreeWAV(
            sourceBuffer
        );

        return false;
    }


    if (conversionNeeded == 0)
    {
        sound.buffer =
            static_cast<Uint8*>(
                SDL_malloc(
                    sourceLength
                )
            );

        if (!sound.buffer)
        {
            SDL_CloseAudioDevice(
                sound.device
            );

            sound.device =
                0;

            SDL_FreeWAV(
                sourceBuffer
            );

            return false;
        }

        SDL_memcpy(
            sound.buffer,
            sourceBuffer,
            sourceLength
        );

        sound.length =
            sourceLength;
    }
    else
    {
        converter.len =
            static_cast<int>(
                sourceLength
            );

        converter.buf =
            static_cast<Uint8*>(
                SDL_malloc(
                    sourceLength *
                    converter.len_mult
                )
            );

        if (!converter.buf)
        {
            SDL_CloseAudioDevice(
                sound.device
            );

            sound.device =
                0;

            SDL_FreeWAV(
                sourceBuffer
            );

            return false;
        }

        SDL_memcpy(
            converter.buf,
            sourceBuffer,
            sourceLength
        );


        if (SDL_ConvertAudio(
                &converter) < 0)
        {
            std::cerr
                << "Audio conversion error: "
                << SDL_GetError()
                << '\n';

            SDL_free(
                converter.buf
            );

            SDL_CloseAudioDevice(
                sound.device
            );

            sound.device =
                0;

            SDL_FreeWAV(
                sourceBuffer
            );

            return false;
        }


        sound.buffer =
            converter.buf;

        sound.length =
            static_cast<Uint32>(
                converter.len_cvt
            );
    }


    SDL_FreeWAV(
        sourceBuffer
    );

    SDL_PauseAudioDevice(
        sound.device,
        0
    );

    return true;
}


void playSoundEffect(
    const SoundEffect& sound)
{
    if (sound.device == 0 ||
        !sound.buffer ||
        sound.length == 0)
    {
        return;
    }

    // Keep the click immediate even if buttons are pressed quickly.
    SDL_ClearQueuedAudio(
        sound.device
    );

    SDL_QueueAudio(
        sound.device,
        sound.buffer,
        sound.length
    );
}


void freeSoundEffect(
    SoundEffect& sound)
{
    if (sound.device != 0)
    {
        SDL_ClearQueuedAudio(
            sound.device
        );

        SDL_CloseAudioDevice(
            sound.device
        );

        sound.device =
            0;
    }

    if (sound.buffer)
    {
        SDL_free(
            sound.buffer
        );

        sound.buffer =
            nullptr;
    }

    sound.length =
        0;
}


// --------------------------------------------------
// Rounded rectangle
// Used by the selected system tile
// --------------------------------------------------

void fillRoundedRect(
    SDL_Renderer* renderer,
    const SDL_Rect& rect,
    int radius)
{
    SDL_Rect middle =
    {
        rect.x + radius,
        rect.y,
        rect.w - (radius * 2),
        rect.h
    };

    SDL_RenderFillRect(
        renderer,
        &middle
    );

    SDL_Rect middle2 =
    {
        rect.x,
        rect.y + radius,
        rect.w,
        rect.h - (radius * 2)
    };

    SDL_RenderFillRect(
        renderer,
        &middle2
    );

    for (int y = 0; y < radius; ++y)
    {
        for (int x = 0; x < radius; ++x)
        {
            int dx =
                radius - x;

            int dy =
                radius - y;

            if ((dx * dx) + (dy * dy) <=
                radius * radius)
            {
                SDL_RenderDrawPoint(
                    renderer,
                    rect.x + x,
                    rect.y + y
                );

                SDL_RenderDrawPoint(
                    renderer,
                    rect.x + rect.w - 1 - x,
                    rect.y + y
                );

                SDL_RenderDrawPoint(
                    renderer,
                    rect.x + x,
                    rect.y + rect.h - 1 - y
                );

                SDL_RenderDrawPoint(
                    renderer,
                    rect.x + rect.w - 1 - x,
                    rect.y + rect.h - 1 - y
                );
            }
        }
    }
}


// --------------------------------------------------
// Filled circle
// Used by the two page indicator dots
// --------------------------------------------------

void fillCircle(
    SDL_Renderer* renderer,
    int centreX,
    int centreY,
    int radius)
{
    for (int y = -radius;
         y <= radius;
         ++y)
    {
        for (int x = -radius;
             x <= radius;
             ++x)
        {
            if ((x * x) + (y * y) <=
                radius * radius)
            {
                SDL_RenderDrawPoint(
                    renderer,
                    centreX + x,
                    centreY + y
                );
            }
        }
    }
}


// --------------------------------------------------
// BareFront title with coloured stripes
// --------------------------------------------------

void drawBareFrontTitle(
    SDL_Renderer* renderer,
    TTF_Font* titleFont)
{
    SDL_Color white =
    {
        255,
        255,
        255,
        255
    };

    const int titleX =
        135;

    const int titleY =
        55;

    const int stripeWidth =
        50;

    const int stripeHeight =
        6;

    const int stripeGap =
        2;

    int titleWidth = 0;
    int titleHeight = 0;

    TTF_SizeUTF8(
        titleFont,
        "BAREFRONT",
        &titleWidth,
        &titleHeight
    );

    int stripeBlockHeight =
        (stripeHeight * 4) +
        (stripeGap * 3);

    int stripeStartY =
        titleY +
        (titleHeight - stripeBlockHeight) / 2;

    const int leftStripeX =
        65;

    const int rightStripeX =
        titleX +
        titleWidth +
        20;


    // Blue
    SDL_SetRenderDrawColor(
        renderer,
        0,
        130,
        255,
        255
    );

    SDL_Rect blueLeft =
    {
        leftStripeX,
        stripeStartY,
        stripeWidth,
        stripeHeight
    };

    SDL_Rect blueRight =
    {
        rightStripeX,
        stripeStartY,
        stripeWidth,
        stripeHeight
    };

    SDL_RenderFillRect(
        renderer,
        &blueLeft
    );

    SDL_RenderFillRect(
        renderer,
        &blueRight
    );


    // Green
    SDL_SetRenderDrawColor(
        renderer,
        0,
        200,
        90,
        255
    );

    SDL_Rect greenLeft =
    {
        leftStripeX,
        stripeStartY +
            stripeHeight +
            stripeGap,
        stripeWidth,
        stripeHeight
    };

    SDL_Rect greenRight =
    {
        rightStripeX,
        stripeStartY +
            stripeHeight +
            stripeGap,
        stripeWidth,
        stripeHeight
    };

    SDL_RenderFillRect(
        renderer,
        &greenLeft
    );

    SDL_RenderFillRect(
        renderer,
        &greenRight
    );


    // Yellow
    SDL_SetRenderDrawColor(
        renderer,
        255,
        210,
        0,
        255
    );

    SDL_Rect yellowLeft =
    {
        leftStripeX,
        stripeStartY +
            ((stripeHeight + stripeGap) * 2),
        stripeWidth,
        stripeHeight
    };

    SDL_Rect yellowRight =
    {
        rightStripeX,
        stripeStartY +
            ((stripeHeight + stripeGap) * 2),
        stripeWidth,
        stripeHeight
    };

    SDL_RenderFillRect(
        renderer,
        &yellowLeft
    );

    SDL_RenderFillRect(
        renderer,
        &yellowRight
    );


    // Red
    SDL_SetRenderDrawColor(
        renderer,
        255,
        55,
        55,
        255
    );

    SDL_Rect redLeft =
    {
        leftStripeX,
        stripeStartY +
            ((stripeHeight + stripeGap) * 3),
        stripeWidth,
        stripeHeight
    };

    SDL_Rect redRight =
    {
        rightStripeX,
        stripeStartY +
            ((stripeHeight + stripeGap) * 3),
        stripeWidth,
        stripeHeight
    };

    SDL_RenderFillRect(
        renderer,
        &redLeft
    );

    SDL_RenderFillRect(
        renderer,
        &redRight
    );


    drawText(
        renderer,
        titleFont,
        "BAREFRONT",
        titleX,
        titleY,
        white
    );
}


// --------------------------------------------------
// Draw one complete home-system page
//
// xOffset lets page 1 and page 2 slide horizontally.
// --------------------------------------------------

void drawHomePage(
    SDL_Renderer* renderer,
    TTF_Font* systemFont,
    std::vector<System>& systems,
    int page,
    int selected,
    int xOffset,
    bool showSelection)
{
    const int columns =
        4;

    const int tileWidth =
        260;

    const int tileHeight =
        235;

    const int horizontalGap =
        35;

    const int verticalGap =
        25;

    const int gridStartX =
        65;

    const int gridStartY =
        125;

    const int tileRadius =
        18;

    SDL_Color white =
    {
        255,
        255,
        255,
        255
    };

    int pageStart =
        page * 8;

    for (int localIndex = 0;
         localIndex < 8;
         ++localIndex)
    {
        int globalIndex =
            pageStart +
            localIndex;

        int row =
            localIndex /
            columns;

        int column =
            localIndex %
            columns;

        int x =
            gridStartX +
            column *
            (tileWidth + horizontalGap) +
            xOffset;

        int y =
            gridStartY +
            row *
            (tileHeight + verticalGap);


        if (showSelection &&
            localIndex == selected)
        {
            SDL_SetRenderDrawColor(
                renderer,
                75,
                75,
                75,
                255
            );

            SDL_Rect selectionRect =
            {
                x,
                y,
                tileWidth,
                tileHeight
            };

            fillRoundedRect(
                renderer,
                selectionRect,
                tileRadius
            );
        }


        SDL_Rect imageArea =
        {
            x + 10,
            y + 8,
            tileWidth - 20,
            175
        };

        drawTextureContained(
            renderer,
            systems[globalIndex].texture,
            imageArea
        );


        SDL_Rect nameArea =
        {
            x,
            y + 178,
            tileWidth,
            42
        };

        drawTextCentered(
            renderer,
            systemFont,
            systems[globalIndex].name,
            nameArea,
            white
        );
    }
}



// --------------------------------------------------
// BareFront logical input actions
//
// Keyboard and controller input are translated into
// the same small set of actions so both behave alike.
// --------------------------------------------------

enum class InputAction
{
    None,
    Left,
    Right,
    Up,
    Down,
    Select,
    Back,
    Favourite,
    Quit
};


// --------------------------------------------------
// Open one SDL GameController
// --------------------------------------------------

SDL_GameController* openGameController(
    int deviceIndex)
{
    if (!SDL_IsGameController(
            deviceIndex))
    {
        return nullptr;
    }


    SDL_GameController* controller =
        SDL_GameControllerOpen(
            deviceIndex
        );


    if (controller)
    {
        const char* name =
            SDL_GameControllerName(
                controller
            );

        std::cout
            << "Controller connected: "
            << (name ? name : "Unknown controller")
            << '\n';
    }
    else
    {
        std::cerr
            << "Unable to open controller: "
            << SDL_GetError()
            << '\n';
    }


    return controller;
}


// --------------------------------------------------
// Find the first SDL-compatible controller
//
// SDL_IsGameController filters out things such as the
// VirtualBox mouse/tablet devices that Linux may also
// expose through /dev/input/js*.
// --------------------------------------------------

SDL_GameController* openFirstGameController()
{
    int joystickCount =
        SDL_NumJoysticks();


    for (int index = 0;
         index < joystickCount;
         ++index)
    {
        if (!SDL_IsGameController(
                index))
        {
            continue;
        }


        SDL_GameController* controller =
            openGameController(
                index
            );


        if (controller)
        {
            return controller;
        }
    }


    std::cout
        << "No SDL game controller connected.\n";

    return nullptr;
}


// --------------------------------------------------
// SDL instance ID for the currently open controller
// --------------------------------------------------

SDL_JoystickID controllerInstanceId(
    SDL_GameController* controller)
{
    if (!controller)
    {
        return -1;
    }


    SDL_Joystick* joystick =
        SDL_GameControllerGetJoystick(
            controller
        );


    if (!joystick)
    {
        return -1;
    }


    return SDL_JoystickInstanceID(
        joystick
    );
}


// --------------------------------------------------
// Current top-level BareFront screen
// --------------------------------------------------

enum class Screen
{
    Home,
    Collections,
    Games
};



// --------------------------------------------------
// Main
// --------------------------------------------------

int main()
{
    // --------------------------------------------------
    // Per-game presentation environment
    //
    // BareFront owns Gamescope presentation regardless of
    // how the menu itself was started: launcher script,
    // terminal, Thunar, autostart, etc.
    // --------------------------------------------------

    setenv(
        "BAREFRONT_GAMESCOPE_CAPTURE",
        "1",
        1
    );


    // --------------------------------------------------
    // BareFront base resolution
    // --------------------------------------------------

    const int SCREEN_WIDTH =
        1280;

    const int SCREEN_HEIGHT =
        720;


    // --------------------------------------------------
    // The active game list is loaded when a system opens.
    // --------------------------------------------------

    std::vector<fs::path> games;

    std::vector<std::string>
        gameDisplayTitles;


    // Keep pixel graphics crisp
    SDL_SetHint(
        SDL_HINT_RENDER_SCALE_QUALITY,
        "0"
    );


    // --------------------------------------------------
    // Initialise SDL
    // --------------------------------------------------

    if (SDL_Init(
            SDL_INIT_VIDEO |
            SDL_INIT_GAMECONTROLLER |
            SDL_INIT_AUDIO) != 0)
    {
        std::cerr
            << "SDL error: "
            << SDL_GetError()
            << '\n';

        return 1;
    }


    // BareFront is a controller-first frontend.
    // Keep the desktop mouse pointer out of the presentation.
    if (SDL_ShowCursor(SDL_DISABLE) < 0)
    {
        std::cerr
            << "Warning: unable to hide mouse cursor: "
            << SDL_GetError()
            << '\n';
    }


    if (TTF_Init() != 0)
    {
        SDL_Quit();

        return 1;
    }


    IMG_Init(
        IMG_INIT_PNG |
        IMG_INIT_JPG
    );


    // --------------------------------------------------
    // Fullscreen window
    // --------------------------------------------------

    SDL_Window* window =
        SDL_CreateWindow(
            "BareFront",
            SDL_WINDOWPOS_CENTERED,
            SDL_WINDOWPOS_CENTERED,
            SCREEN_WIDTH,
            SCREEN_HEIGHT,
            SDL_WINDOW_FULLSCREEN_DESKTOP
        );


    if (!window)
    {
        return 1;
    }


    // BareFront application icon.
    // Missing artwork must never prevent the frontend starting.
    SDL_Surface* windowIcon =
        IMG_Load("assets/icons/barefront.png");

    if (windowIcon)
    {
        SDL_SetWindowIcon(window, windowIcon);
        SDL_FreeSurface(windowIcon);

        std::cout
            << "BareFront window icon: assets/icons/barefront.png\n";
    }
    else
    {
        std::cerr
            << "Warning: BareFront window icon unavailable: "
            << IMG_GetError()
            << '\n';
    }


    // --------------------------------------------------
    // Renderer
    // --------------------------------------------------

    SDL_Renderer* renderer =
        SDL_CreateRenderer(
            window,
            -1,
            SDL_RENDERER_ACCELERATED |
            SDL_RENDERER_PRESENTVSYNC
        );


    if (!renderer)
    {
        SDL_DestroyWindow(
            window
        );

        return 1;
    }


    // --------------------------------------------------
    // Startup splash
    //
    // Render before enabling BareFront's 1280x720 logical
    // canvas so the splash can use the real display output.
    //
    // On a 1920x1080 display the 1080p splash is presented
    // 1:1. Other aspect ratios are fitted and centred.
    // A short minimum display time lets the branding register.
    // --------------------------------------------------

    SDL_Texture* splashTexture =
        loadTexture(
            renderer,
            "assets/ui/splash.png"
        );


    if (splashTexture)
    {
        int outputWidth = 0;
        int outputHeight = 0;
        int splashWidth = 0;
        int splashHeight = 0;

        SDL_GetRendererOutputSize(
            renderer,
            &outputWidth,
            &outputHeight
        );

        SDL_QueryTexture(
            splashTexture,
            nullptr,
            nullptr,
            &splashWidth,
            &splashHeight
        );

        SDL_SetRenderDrawColor(
            renderer,
            0,
            0,
            0,
            255
        );

        SDL_RenderClear(
            renderer
        );

        if (outputWidth > 0 &&
            outputHeight > 0 &&
            splashWidth > 0 &&
            splashHeight > 0)
        {
            const double scaleX =
                static_cast<double>(outputWidth) /
                splashWidth;

            const double scaleY =
                static_cast<double>(outputHeight) /
                splashHeight;

            const double scale =
                std::min(
                    scaleX,
                    scaleY
                );

            SDL_Rect splashArea =
            {
                0,
                0,
                static_cast<int>(
                    splashWidth * scale
                ),
                static_cast<int>(
                    splashHeight * scale
                )
            };

            splashArea.x =
                (outputWidth - splashArea.w) / 2;

            splashArea.y =
                (outputHeight - splashArea.h) / 2;

            SDL_RenderCopy(
                renderer,
                splashTexture,
                nullptr,
                &splashArea
            );
        }

        SDL_RenderPresent(
            renderer
        );
    }

    const Uint32 splashPresentedAt =
        SDL_GetTicks();


    SDL_RenderSetLogicalSize(
        renderer,
        SCREEN_WIDTH,
        SCREEN_HEIGHT
    );


    SDL_SetRenderDrawBlendMode(
        renderer,
        SDL_BLENDMODE_BLEND
    );


    // --------------------------------------------------
    // Fonts
    //
    // Game screen fonts keep their existing sizes.
    // Home screen fonts keep the sizes we just approved.
    // --------------------------------------------------

    const char* fontPath =
        "assets/fonts/PetMe64.ttf";


    TTF_Font* gameFont =
        TTF_OpenFont(
            fontPath,
            29
        );


    TTF_Font* gameTitleFont =
        TTF_OpenFont(
            fontPath,
            38
        );


    TTF_Font* homeTitleFont =
        TTF_OpenFont(
            fontPath,
            42
        );


    TTF_Font* homeSystemFont =
        TTF_OpenFont(
            fontPath,
            20
        );


    TTF_Font* homeFooterFont =
        TTF_OpenFont(
            fontPath,
            22
        );


    TTF_Font* homeArrowFont =
        TTF_OpenFont(
            fontPath,
            34
        );


    if (!gameFont ||
        !gameTitleFont ||
        !homeTitleFont ||
        !homeSystemFont ||
        !homeFooterFont ||
        !homeArrowFont)
    {
        std::cerr
            << "Font error: "
            << TTF_GetError()
            << '\n';

        return 1;
    }


    // --------------------------------------------------
    // The 16 BareFront systems
    // --------------------------------------------------

    std::vector<System> systems =
    {
        // PAGE 1

        {
            "MEGA DRIVE",
            "MEGA DRIVE",
            "megadrive",
            "assets/systems/megadrive.png",
            "testroms/megadrive",
            "assets/games/megadrive",
            { ".md", ".bin", ".gen", ".zip", ".7z" }
        },

        {
            "NES",
            "NES",
            "nes",
            "assets/systems/nes.png",
            "testroms/nes",
            "assets/games/nes",
            { ".nes", ".zip", ".7z" }
        },

        {
            "SUPER NES",
            "SUPER NES",
            "snes",
            "assets/systems/snes.png",
            "testroms/snes",
            "assets/games/snes",
            { ".sfc", ".smc", ".zip", ".7z" }
        },

        {
            "PLAYSTATION",
            "PLAYSTATION",
            "ps1",
            "assets/systems/ps1.png",
            "roms/ps1",
            "assets/games/ps1",
            { ".cue", ".chd", ".pbp", ".iso", ".m3u" }
        },

        {
            "PLAYSTATION 2",
            "PLAYSTATION 2",
            "ps2",
            "assets/systems/ps2.png",
            "testroms/ps2",
            "assets/games/ps2",
            { ".iso", ".chd", ".cso" }
        },

        {
            "MASTER SYSTEM",
            "MASTER SYSTEM",
            "mastersystem",
            "assets/systems/mastersystem.png",
            "testroms/mastersystem",
            "assets/games/mastersystem",
            { ".sms", ".bin", ".zip", ".7z" }
        },

        {
            "ATARI 2600",
            "ATARI 2600",
            "atari2600",
            "assets/systems/atari2600.png",
            "testroms/atari2600",
            "assets/games/atari2600",
            { ".a26", ".bin", ".zip", ".7z" }
        },

        {
            "COMMODORE 64",
            "COMMODORE 64",
            "c64",
            "assets/systems/c64.png",
            "testroms/c64",
            "assets/games/c64",
            { ".d64", ".t64", ".prg", ".crt", ".vfl", ".zip" }
        },


        // PAGE 2

        {
            "ARCADE",
            "ARCADE",
            "arcade",
            "assets/systems/arcade.png",
            "testroms/arcade",
            "assets/games/arcade",
            { ".zip", ".7z" }
        },

        {
            "NEO GEO",
            "NEO GEO",
            "neogeo",
            "assets/systems/neogeo.png",
            "testroms/neogeo",
            "assets/games/neogeo",
            { ".zip", ".7z" }
        },

        {
            "DREAMCAST",
            "DREAMCAST",
            "dreamcast",
            "assets/systems/dreamcast.png",
            "testroms/dreamcast",
            "assets/games/dreamcast",
            { ".cdi", ".gdi", ".chd", ".m3u" }
        },

        {
            "SATURN",
            "SATURN",
            "saturn",
            "assets/systems/saturn.png",
            "testroms/saturn",
            "assets/games/saturn",
            { ".cue", ".ccd", ".toc", ".m3u", ".zip" }
        },

        {
            "PC ENGINE",
            "PC ENGINE",
            "pcengine",
            "assets/systems/pcengine.png",
            "testroms/pcengine",
            "assets/games/pcengine",
            { ".pce", ".sgx", ".cue", ".ccd", ".toc", ".m3u", ".zip" }
        },

        {
            "ATARI JAGUAR",
            "ATARI JAGUAR",
            "jaguar",
            "assets/systems/jaguar.png",
            "testroms/jaguar",
            "assets/games/jaguar",
            { ".j64", ".jag", ".rom", ".zip" }
        },

        {
            "GAMECUBE",
            "GAMECUBE",
            "gamecube",
            "assets/systems/gamecube.png",
            "testroms/gamecube",
            "assets/games/gamecube",
            { ".iso", ".gcm", ".rvz", ".gcz" }
        },

        {
            "AMIGA",
            "AMIGA",
            "amiga",
            "assets/systems/amiga.png",
            "testroms/amiga",
            "assets/games/amiga",
            { ".adf", ".adz", ".lha", ".hdf", ".ipf", ".zip" }
        }
    };


    // --------------------------------------------------
    // Read machine-specific ROM/emulator paths.
    //
    // If barefront.ini is missing, the built-in ROM and
    // screenshot paths still work, but no emulator command
    // will be configured until the file is added.
    // --------------------------------------------------

    loadBareFrontConfig(
        "barefront.ini",
        systems
    );


    // --------------------------------------------------
    // Load all system artwork
    // --------------------------------------------------

    for (System& system :
         systems)
    {
        system.texture =
            loadTexture(
                renderer,
                system.imagePath
            );
    }


    // --------------------------------------------------
    // Load CRT frame
    // --------------------------------------------------

    SDL_Texture* tvTexture =
        loadTexture(
            renderer,
            "assets/ui/crt_tv.png"
        );


    // --------------------------------------------------
    // Load the single BareFront button-click sound
    // --------------------------------------------------

    SoundEffect clickSound;

    loadSoundEffect(
        "assets/audio/click.wav",
        clickSound
    );


    // --------------------------------------------------
    // Controller support
    //
    // BareFront uses SDL's GameController API so Xbox,
    // PlayStation and most SDL-mapped USB/Bluetooth pads
    // all present the same logical buttons.
    // --------------------------------------------------

    SDL_GameControllerEventState(
        SDL_ENABLE
    );


    SDL_GameController* controller =
        openFirstGameController();


    // Left-stick latches stop one physical stick movement
    // creating a stream of repeated menu actions.
    bool stickLeftHeld = false;
    bool stickRightHeld = false;
    bool stickUpHeld = false;
    bool stickDownHeld = false;

    const Sint16 stickPressThreshold =
        16000;

    const Sint16 stickReleaseThreshold =
        8000;


    // --------------------------------------------------
    // Deliberate controller quit combo
    //
    // Hold Start + Select for one second to exit
    // BareFront.  B remains a Back button only.
    //
    // SDL calls the Xbox-style Select/View button BACK.
    // --------------------------------------------------

    bool controllerSelectHeld =
        false;

    bool controllerStartHeld =
        false;

    Uint32 quitComboStarted =
        0;

    bool quitComboTriggered =
        false;

    const Uint32 quitComboHoldTime =
        1000;


    // --------------------------------------------------
    // Colours
    // --------------------------------------------------

    SDL_Color white =
    {
        255,
        255,
        255,
        255
    };


    SDL_Color grey =
    {
        150,
        150,
        150,
        255
    };


    SDL_Color noSignalColour =
    {
        170,
        170,
        170,
        255
    };


    // --------------------------------------------------
    // Which BareFront screen are we on?
    // --------------------------------------------------

    Screen screen =
        Screen::Home;


    // --------------------------------------------------
    // Home-screen state
    // --------------------------------------------------

    const int columns =
        4;

    int currentPage =
        0;

    int homeSelected =
        0;


    // --------------------------------------------------
    // Home-screen slide animation
    // --------------------------------------------------

    bool sliding =
        false;

    int targetPage =
        0;

    int targetSelected =
        0;

    // +1 = moving to page on right
    // -1 = moving to page on left

    int slideDirection =
        0;

    Uint32 slideStart =
        0;

    const Uint32 slideDuration =
        180;


    // --------------------------------------------------
    // Game-list state
    // --------------------------------------------------

    int activeSystemIndex =
        0;

    // Curated collections and virtual favourites.
    std::vector<bflibrary::Collection>
        curatedCollections;

    std::vector<bflibrary::ListedGame>
        curatedVisibleGames;
    std::map<fs::path, std::string> playlistScanErrors;

    std::vector<std::string>
        curatedCollectionNames;

    std::size_t curatedCollectionSelected = 0;
    std::string curatedActiveCollection;

    bffavourites::Entries curatedFavourites;
    fs::path curatedFavouritesPath;

    std::size_t gameSelected =
        0;

    // Use a multi-disc folder name for artwork, while
    // keeping the actual disc path for emulator launching.
    auto currentPreviewArtwork = [&]() -> fs::path
    {
        if (curatedFavouritesPath.empty() ||
            gameSelected >= curatedVisibleGames.size() ||
            !curatedVisibleGames[gameSelected].game.folderGame)
            return {};

        return curatedVisibleGames[gameSelected].game.titlePath;
    };

    Uint32 selectedSince =
        SDL_GetTicks();

    SDL_Texture* screenshotTexture =
        nullptr;

    VideoPlayer videoPlayer;

    bool useTatePreview =
        false;

    // Shader selection is remembered per system.
    const fs::path shaderPrefsPath =
        "saves/presentation/shaders.ini";

    bfshader::Preferences shaderPrefs =
        bfshader::load(shaderPrefsPath);

    const std::vector<std::string> shaderChoices =
    {
        "NONE",
        "BARECRT",
        "CRT-LITE",
        "CRT-LOTTES"
    };

    bool shaderMenuOpen = false;
    bool shaderMenuSaveFailed = false;
    bool launchErrorOpen = false;
    std::string launchErrorText;
    std::size_t shaderMenuSelected = 0;



    bool running =
        true;


    // --------------------------------------------------
    // Startup is complete.
    // The normal BareFront presentation takes over now.
    // --------------------------------------------------

    if (splashTexture)
    {
        const Uint32 splashElapsed =
            SDL_GetTicks() -
            splashPresentedAt;

        const Uint32 splashMinimumTime =
            2000;

        if (splashElapsed <
            splashMinimumTime)
        {
            SDL_Delay(
                splashMinimumTime -
                splashElapsed
            );
        }

        SDL_DestroyTexture(
            splashTexture
        );

        splashTexture =
            nullptr;
    }


    // --------------------------------------------------
    // Main loop
    // --------------------------------------------------

    while (running)
    {
        // --------------------------------------------------
        // Finish a home-page slide
        // --------------------------------------------------

        if (screen == Screen::Home &&
            sliding)
        {
            Uint32 elapsed =
                SDL_GetTicks() -
                slideStart;

            if (elapsed >=
                slideDuration)
            {
                currentPage =
                    targetPage;

                homeSelected =
                    targetSelected;

                sliding =
                    false;
            }
        }


        // --------------------------------------------------
        // Start + Select quit hold
        // --------------------------------------------------

        if (controllerStartHeld &&
            controllerSelectHeld &&
            !quitComboTriggered)
        {
            if (quitComboStarted == 0)
            {
                quitComboStarted =
                    SDL_GetTicks();
            }
            else if (SDL_GetTicks() -
                         quitComboStarted >=
                     quitComboHoldTime)
            {
                quitComboTriggered =
                    true;

                playSoundEffect(
                    clickSound
                );

                running =
                    false;
            }
        }
        else if (!controllerStartHeld ||
                 !controllerSelectHeld)
        {
            quitComboStarted =
                0;

            quitComboTriggered =
                false;
        }


        // --------------------------------------------------
        // Input
        //
        // Keyboard and gamepad events are converted to the
        // same BareFront action before menu logic runs.
        // --------------------------------------------------

        SDL_Event event;


        while (SDL_PollEvent(
                   &event))
        {
            if (event.type ==
                SDL_QUIT)
            {
                running =
                    false;

                continue;
            }


            // ----------------------------------------------
            // Controller hot-plug
            // ----------------------------------------------

            if (event.type ==
                SDL_CONTROLLERDEVICEADDED)
            {
                // event.cdevice.which is a device index here.
                if (!controller)
                {
                    controller =
                        openGameController(
                            event.cdevice.which
                        );
                }

                continue;
            }


            if (event.type ==
                SDL_CONTROLLERDEVICEREMOVED)
            {
                // event.cdevice.which is an instance ID here.
                if (controller &&
                    controllerInstanceId(
                        controller) ==
                        event.cdevice.which)
                {
                    const char* name =
                        SDL_GameControllerName(
                            controller
                        );

                    std::cout
                        << "Controller disconnected: "
                        << (name ? name : "Unknown controller")
                        << '\n';

                    SDL_GameControllerClose(
                        controller
                    );

                    controller =
                        nullptr;

                    stickLeftHeld =
                        false;

                    stickRightHeld =
                        false;

                    stickUpHeld =
                        false;

                    stickDownHeld =
                        false;

                    controllerSelectHeld =
                        false;

                    controllerStartHeld =
                        false;

                    quitComboStarted =
                        0;

                    quitComboTriggered =
                        false;


                    // If another mapped controller is already
                    // connected, automatically take it over.
                    controller =
                        openFirstGameController();
                }

                continue;
            }


            InputAction action =
                InputAction::None;

            // Open/close the shader popup without launching a game.
            const bool shaderKey =
                event.type == SDL_KEYDOWN &&
                event.key.keysym.sym == SDLK_s &&
                event.key.repeat == 0;

            const bool shaderButton =
                event.type == SDL_CONTROLLERBUTTONDOWN &&
                controller &&
                event.cbutton.which ==
                    controllerInstanceId(controller) &&
                event.cbutton.button == SDL_CONTROLLER_BUTTON_Y;

            if (screen == Screen::Games &&
                (shaderKey || shaderButton))
            {
                shaderMenuOpen = !shaderMenuOpen;
                shaderMenuSaveFailed = false;

                if (shaderMenuOpen)
                {
                    const std::string selected =
                        bfshader::get(
                            shaderPrefs,
                            systems[activeSystemIndex].configSection
                        );

                    auto found = std::find(
                        shaderChoices.begin(),
                        shaderChoices.end(),
                        selected
                    );

                    shaderMenuSelected =
                        static_cast<std::size_t>(
                            found - shaderChoices.begin()
                        );
                }

                playSoundEffect(clickSound);
                continue;
            }



            // ----------------------------------------------
            // Keyboard
            // ----------------------------------------------

            if (event.type ==
                SDL_KEYDOWN)
            {
                switch (
                    event.key.keysym.sym)
                {
                    case SDLK_LEFT:
                        action =
                            InputAction::Left;
                        break;

                    case SDLK_RIGHT:
                        action =
                            InputAction::Right;
                        break;

                    case SDLK_UP:
                        action =
                            InputAction::Up;
                        break;

                    case SDLK_DOWN:
                        action =
                            InputAction::Down;
                        break;

                    case SDLK_RETURN:
                    case SDLK_KP_ENTER:
                        action =
                            InputAction::Select;
                        break;

                    case SDLK_ESCAPE:
                        action =
                            (screen == Screen::Home)
                                ? InputAction::Quit
                                : InputAction::Back;
                        break;

                    case SDLK_f:
                        action = InputAction::Favourite;
                        break;

                    case SDLK_q:
                        action =
                            InputAction::Quit;
                        break;
                }
            }


            // ----------------------------------------------
            // Controller buttons
            //
            // SDL logical layout:
            // A = south face button / Select
            // B = east face button / Back
            // ----------------------------------------------

            else if (
                event.type ==
                SDL_CONTROLLERBUTTONDOWN &&
                controller &&
                event.cbutton.which ==
                    controllerInstanceId(
                        controller))
            {
                switch (
                    event.cbutton.button)
                {
                    case SDL_CONTROLLER_BUTTON_DPAD_LEFT:
                        action =
                            InputAction::Left;
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_RIGHT:
                        action =
                            InputAction::Right;
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_UP:
                        action =
                            InputAction::Up;
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
                        action =
                            InputAction::Down;
                        break;

                    case SDL_CONTROLLER_BUTTON_A:
                        action =
                            InputAction::Select;
                        break;

                    case SDL_CONTROLLER_BUTTON_X:
                        action = InputAction::Favourite;
                        break;

                    case SDL_CONTROLLER_BUTTON_B:
                        action =
                            InputAction::Back;
                        break;

                    case SDL_CONTROLLER_BUTTON_BACK:
                        controllerSelectHeld =
                            true;

                        if (controllerStartHeld &&
                            quitComboStarted == 0)
                        {
                            quitComboStarted =
                                SDL_GetTicks();
                        }
                        break;

                    case SDL_CONTROLLER_BUTTON_START:
                        controllerStartHeld =
                            true;

                        if (controllerSelectHeld &&
                            quitComboStarted == 0)
                        {
                            quitComboStarted =
                                SDL_GetTicks();
                        }
                        break;
                }
            }


            // ----------------------------------------------
            // Controller button releases
            // ----------------------------------------------

            else if (
                event.type ==
                SDL_CONTROLLERBUTTONUP &&
                controller &&
                event.cbutton.which ==
                    controllerInstanceId(
                        controller))
            {
                switch (
                    event.cbutton.button)
                {
                    case SDL_CONTROLLER_BUTTON_BACK:
                        controllerSelectHeld =
                            false;

                        quitComboStarted =
                            0;

                        quitComboTriggered =
                            false;
                        break;

                    case SDL_CONTROLLER_BUTTON_START:
                        controllerStartHeld =
                            false;

                        quitComboStarted =
                            0;

                        quitComboTriggered =
                            false;
                        break;
                }

                continue;
            }


            // ----------------------------------------------
            // Left analogue stick
            //
            // One menu action is generated each time the
            // stick crosses the press threshold. It must come
            // back near centre before another action occurs.
            // ----------------------------------------------

            else if (
                event.type ==
                SDL_CONTROLLERAXISMOTION &&
                controller &&
                event.caxis.which ==
                    controllerInstanceId(
                        controller))
            {
                if (event.caxis.axis ==
                    SDL_CONTROLLER_AXIS_LEFTX)
                {
                    Sint16 value =
                        event.caxis.value;


                    if (value <=
                        -stickPressThreshold)
                    {
                        if (!stickLeftHeld)
                        {
                            action =
                                InputAction::Left;

                            stickLeftHeld =
                                true;
                        }

                        stickRightHeld =
                            false;
                    }
                    else if (value >=
                             stickPressThreshold)
                    {
                        if (!stickRightHeld)
                        {
                            action =
                                InputAction::Right;

                            stickRightHeld =
                                true;
                        }

                        stickLeftHeld =
                            false;
                    }
                    else if (value >
                                 -stickReleaseThreshold &&
                             value <
                                 stickReleaseThreshold)
                    {
                        stickLeftHeld =
                            false;

                        stickRightHeld =
                            false;
                    }
                }


                if (event.caxis.axis ==
                    SDL_CONTROLLER_AXIS_LEFTY)
                {
                    Sint16 value =
                        event.caxis.value;


                    if (value <=
                        -stickPressThreshold)
                    {
                        if (!stickUpHeld)
                        {
                            action =
                                InputAction::Up;

                            stickUpHeld =
                                true;
                        }

                        stickDownHeld =
                            false;
                    }
                    else if (value >=
                             stickPressThreshold)
                    {
                        if (!stickDownHeld)
                        {
                            action =
                                InputAction::Down;

                            stickDownHeld =
                                true;
                        }

                        stickUpHeld =
                            false;
                    }
                    else if (value >
                                 -stickReleaseThreshold &&
                             value <
                                 stickReleaseThreshold)
                    {
                        stickUpHeld =
                            false;

                        stickDownHeld =
                            false;
                    }
                }
            }


            if (action ==
                InputAction::None)
            {
                continue;
            }


            // ==================================================
            // HOME SCREEN INPUT
            // ==================================================

            if (screen ==
                Screen::Home)
            {
                // Keep the existing behaviour: navigation and
                // Back are ignored during the 180 ms slide.
                if (sliding)
                {
                    continue;
                }


                int row =
                    homeSelected /
                    columns;

                int column =
                    homeSelected %
                    columns;


                switch (action)
                {
                    case InputAction::Back:

                        // Controller B is deliberately harmless
                        // on the Home screen.  It only ever
                        // moves back one screen.
                        break;


                    case InputAction::Quit:

                        playSoundEffect(
                            clickSound
                        );

                        running =
                            false;

                        break;


                    case InputAction::Left:

                        if (column > 0)
                        {
                            homeSelected--;

                            playSoundEffect(
                                clickSound
                            );
                        }
                        else if (
                            currentPage == 1)
                        {
                            targetPage =
                                0;

                            targetSelected =
                                (row * columns) +
                                (columns - 1);

                            slideDirection =
                                -1;

                            slideStart =
                                SDL_GetTicks();

                            sliding =
                                true;

                            playSoundEffect(
                                clickSound
                            );
                        }

                        break;


                    case InputAction::Right:

                        if (column <
                            columns - 1)
                        {
                            homeSelected++;

                            playSoundEffect(
                                clickSound
                            );
                        }
                        else if (
                            currentPage == 0)
                        {
                            targetPage =
                                1;

                            targetSelected =
                                row * columns;

                            slideDirection =
                                1;

                            slideStart =
                                SDL_GetTicks();

                            sliding =
                                true;

                            playSoundEffect(
                                clickSound
                            );
                        }

                        break;


                    case InputAction::Up:

                        if (row > 0)
                        {
                            homeSelected -=
                                columns;

                            playSoundEffect(
                                clickSound
                            );
                        }

                        break;


                    case InputAction::Down:

                        if (row < 1)
                        {
                            homeSelected +=
                                columns;

                            playSoundEffect(
                                clickSound
                            );
                        }

                        break;


                    case InputAction::Select:
                    {
                        playSoundEffect(
                            clickSound
                        );

                        int globalIndex =
                            (currentPage * 8) +
                            homeSelected;

                        activeSystemIndex =
                            globalIndex;

                        // Prepare curated catalogues for supported systems.
                        // before entering the Collections screen.
                        curatedCollections.clear();
                        curatedVisibleGames.clear();
                        playlistScanErrors.clear();
                        curatedCollectionNames.clear();
                        curatedFavourites.clear();
                        curatedActiveCollection.clear();
                        curatedCollectionSelected = 0;
                        curatedFavouritesPath.clear();

                        if (systems[activeSystemIndex].configSection == "dreamcast" ||
                             systems[activeSystemIndex].configSection == "nes" ||
                             systems[activeSystemIndex].configSection == "ps1" ||
                             systems[activeSystemIndex].configSection == "saturn")
                        {
                            curatedCollectionNames =
                                bflibrary::collectionNames(systems[activeSystemIndex].configSection);

                            curatedFavouritesPath =
                                fs::path("saves/presentation/favourites") /
                                  (systems[activeSystemIndex].configSection + ".txt");

                            curatedFavourites =
                                bffavourites::load(curatedFavouritesPath);

                            for (const std::string& name :
                                 curatedCollectionNames)
                            {
                                // Favourites is virtual, not a ROM folder.
                                if (name == "Favourites")
                                    continue;

                                const fs::path collectionFolder =
                                    systems[activeSystemIndex].romFolder /
                                    name;

                                const auto scanned =
                                    scanGames(
                                        collectionFolder,
                                        systems[activeSystemIndex]
                                            .romExtensions,
                                        &playlistScanErrors
                                    );

                                curatedCollections.push_back({
                                    name,
                                    bflibrary::groupGames(
                                        collectionFolder,
                                        scanned
                                    )
                                });

                                std::cout
                                    << systems[activeSystemIndex].configSection << " collection: "
                                    << name << " — "
                                    << curatedCollections.back()
                                           .games.size()
                                    << " games\n";
                            }
                        }


                        games =
                            scanGames(
                                systems[activeSystemIndex].romFolder,
                                systems[activeSystemIndex].romExtensions,
                                &playlistScanErrors
                            );

                        gameDisplayTitles.clear();
                        gameDisplayTitles.reserve(
                            games.size()
                        );

                        for (const auto& game :
                             games)
                        {
                            gameDisplayTitles.push_back(
                                cleanGameTitle(
                                    game
                                )
                            );
                        }

                        const std::string& activeSection =
                            systems[activeSystemIndex]
                                .configSection;

                        if (activeSection == "arcade" ||
                            activeSection == "neogeo")
                        {
                            auto mameTitles =
                                loadMameDisplayTitles(
                                    games
                                );

                            for (std::size_t index = 0;
                                 index < games.size();
                                 ++index)
                            {
                                auto found =
                                    mameTitles.find(
                                        games[index]
                                            .stem()
                                            .string()
                                    );

                                if (found !=
                                    mameTitles.end())
                                {
                                    gameDisplayTitles[index] =
                                        found->second;
                                }
                            }
                        }

                        gameSelected =
                            0;

                        selectedSince =
                            SDL_GetTicks();


                        videoPlayer.stop();

                        useTatePreview =
                            false;

                        if (screenshotTexture)
                        {
                            SDL_DestroyTexture(
                                screenshotTexture
                            );

                            screenshotTexture =
                                nullptr;
                        }


                        if (!games.empty())
                        {
                            refreshGamePreview(
                                renderer,
                                videoPlayer,
                                screenshotTexture,
                                useTatePreview,
                                systems[activeSystemIndex],
                                games[gameSelected],
                                currentPreviewArtwork()
                            );
                        }


                        screen =
                            ((activeSection == "dreamcast" || activeSection == "nes" || activeSection == "ps1" || activeSection == "saturn"))
                                ? Screen::Collections
                                : Screen::Games;

                        if ((activeSection == "dreamcast" || activeSection == "nes" || activeSection == "ps1" || activeSection == "saturn"))
                        {
                            // The Collections screen needs no game preview.
                            videoPlayer.stop();

                            if (screenshotTexture)
                            {
                                SDL_DestroyTexture(screenshotTexture);
                                screenshotTexture = nullptr;
                            }

                            games.clear();
                            gameDisplayTitles.clear();
                            gameSelected = 0;
                        }

                        break;
                    }


                    case InputAction::None:
                        break;
                }
            }


            // ==================================================
            // GAME-LIST INPUT
            // ==================================================

            else if (
                screen ==
                Screen::Collections)
            {
                switch (action)
                {
                    case InputAction::Up:
                        if (curatedCollectionSelected > 0)
                        {
                            --curatedCollectionSelected;
                            playSoundEffect(clickSound);
                        }
                        break;

                    case InputAction::Down:
                        if (curatedCollectionSelected + 1 <
                            curatedCollectionNames.size())
                        {
                            ++curatedCollectionSelected;
                            playSoundEffect(clickSound);
                        }
                        break;

                    case InputAction::Select:
                    {
                        if (curatedCollectionNames.empty())
                            break;

                        curatedActiveCollection =
                            curatedCollectionNames[
                                curatedCollectionSelected
                            ];

                        curatedVisibleGames =
                            bflibrary::gamesFor(
                                curatedCollections,
                                curatedActiveCollection,
                                curatedFavourites
                            );

                        games.clear();
                        gameDisplayTitles.clear();

                        for (const auto& entry :
                             curatedVisibleGames)
                        {
                            games.push_back(
                                entry.game.launchPath
                            );

                            gameDisplayTitles.push_back(
                                cleanGameTitle(
                                    entry.game.titlePath
                                )
                            );
                        }

                        gameSelected = 0;
                        selectedSince = SDL_GetTicks();

                        videoPlayer.stop();

                        if (screenshotTexture)
                        {
                            SDL_DestroyTexture(screenshotTexture);
                            screenshotTexture = nullptr;
                        }

                        useTatePreview = false;

                        if (!games.empty())
                        {
                            refreshGamePreview(
                                renderer,
                                videoPlayer,
                                screenshotTexture,
                                useTatePreview,
                                systems[activeSystemIndex],
                                games[gameSelected],
                                currentPreviewArtwork()
                            );
                        }

                        screen = Screen::Games;
                        playSoundEffect(clickSound);
                        break;
                    }

                    case InputAction::Back:
                        screen = Screen::Home;
                        playSoundEffect(clickSound);
                        break;

                    case InputAction::Quit:
                        running = false;
                        break;

                    default:
                        break;
                }
            }

            else if (
                screen ==
                Screen::Games)
            {
                bool selectionChanged =
                    false;



                if (launchErrorOpen)
                {
                    switch (action)
                    {
                        case InputAction::Select:
                        case InputAction::Back:
                            launchErrorOpen = false;
                            launchErrorText.clear();
                            playSoundEffect(clickSound);
                            break;

                        case InputAction::Quit:
                            running = false;
                            break;

                        default:
                            break;
                    }
                }
                else if (shaderMenuOpen)
                {
                    switch (action)
                    {
                        case InputAction::Up:
                            if (shaderMenuSelected > 0)
                                --shaderMenuSelected;
                            playSoundEffect(clickSound);
                            break;

                        case InputAction::Down:
                            if (shaderMenuSelected + 1 <
                                shaderChoices.size())
                                ++shaderMenuSelected;
                            playSoundEffect(clickSound);
                            break;

                        case InputAction::Select:
                            if (bfshader::set(
                                    shaderPrefs,
                                    shaderPrefsPath,
                                    systems[activeSystemIndex].configSection,
                                    shaderChoices[shaderMenuSelected]))
                            {
                                shaderMenuOpen = false;
                                shaderMenuSaveFailed = false;
                            }
                            else
                            {
                                shaderMenuSaveFailed = true;
                                std::cerr
                                    << "Could not save shader preference\n";
                            }
                            playSoundEffect(clickSound);
                            break;

                        case InputAction::Back:
                            shaderMenuOpen = false;
                            playSoundEffect(clickSound);
                            break;

                        case InputAction::Quit:
                            running = false;
                            break;

                        default:
                            break;
                    }
                }
                else
                {
switch (action)
                {
                    case InputAction::Favourite:
                    {
                        if (curatedFavouritesPath.empty() ||
                            gameSelected >= curatedVisibleGames.size())
                            break;

                        const auto& entry = curatedVisibleGames[gameSelected];
                        const std::string key = bffavourites::gameKey(
                            entry.collection, entry.game.key);

                        auto updated = curatedFavourites;
                        const bool removing = updated.erase(key) != 0;

                        if (!removing)
                            updated.insert(key);

                        if (bffavourites::save(curatedFavouritesPath, updated))
                        {
                            curatedFavourites = updated;
                            curatedVisibleGames[gameSelected].favourite = !removing;
                            playSoundEffect(clickSound);
                            if (curatedActiveCollection == "Favourites" &&
                                removing)
                            {
                                curatedVisibleGames.erase(
                                    curatedVisibleGames.begin() + gameSelected);
                                games.erase(games.begin() + gameSelected);
                                gameDisplayTitles.erase(
                                    gameDisplayTitles.begin() + gameSelected);

                                gameSelected = games.empty()
                                    ? 0
                                    : std::min(gameSelected, games.size() - 1);

                                if (games.empty())
                                {
                                    videoPlayer.stop();

                                    if (screenshotTexture)
                                    {
                                        SDL_DestroyTexture(screenshotTexture);
                                        screenshotTexture = nullptr;
                                    }

                                    useTatePreview = false;
                                }

                                selectionChanged = true;
                            }

                            std::cout << (removing ? "Favourite removed: "
                                                   : "Favourite added: ")
                                      << key << '\n';
                        }
                        else
                        {
                            std::cerr << "Could not save favourite\n";
                        }

                        break;
                    }

                    case InputAction::Up:

                        if (!games.empty() &&
                            gameSelected > 0)
                        {
                            gameSelected--;

                            selectionChanged =
                                true;

                            playSoundEffect(
                                clickSound
                            );
                        }

                        break;


                    case InputAction::Down:

                        if (!games.empty() &&
                            gameSelected <
                            games.size() - 1)
                        {
                            gameSelected++;

                            selectionChanged =
                                true;

                            playSoundEffect(
                                clickSound
                            );
                        }

                        break;


                    case InputAction::Left:

                        if (!games.empty())
                        {
                            std::size_t oldSelected =
                                gameSelected;


                            if (gameSelected >= 8)
                            {
                                gameSelected -=
                                    8;
                            }
                            else
                            {
                                gameSelected =
                                    0;
                            }


                            if (gameSelected !=
                                oldSelected)
                            {
                                selectionChanged =
                                    true;

                                playSoundEffect(
                                    clickSound
                                );
                            }
                        }

                        break;


                    case InputAction::Right:

                        if (!games.empty())
                        {
                            std::size_t oldSelected =
                                gameSelected;


                            if (gameSelected + 8 <
                                games.size())
                            {
                                gameSelected +=
                                    8;
                            }
                            else
                            {
                                gameSelected =
                                    games.size() - 1;
                            }


                            if (gameSelected !=
                                oldSelected)
                            {
                                selectionChanged =
                                    true;

                                playSoundEffect(
                                    clickSound
                                );
                            }
                        }

                        break;


                    case InputAction::Select:

                        if (!games.empty())
                        {
                            // Validate selected media before changing presentation.
                            std::string knownPlaylistError;

                            // Curated entries can carry errors discovered during
                            // library scanning, including ambiguous playlists.
                            if (gameSelected < curatedVisibleGames.size() &&
                                curatedVisibleGames[gameSelected]
                                    .game.launchPath == games[gameSelected])
                            {
                                knownPlaylistError =
                                    curatedVisibleGames[gameSelected]
                                        .game.playlistError;
                            }

                            // Scanner diagnostics include missing media and
                            // shared-disc ownership conflicts. Apply them to both
                            // ordinary and curated game entries.
                            const auto scanError =
                                playlistScanErrors.find(games[gameSelected]);

                            if (scanError != playlistScanErrors.end())
                            {
                                if (knownPlaylistError.empty())
                                {
                                    knownPlaylistError = scanError->second;
                                }
                                else if (knownPlaylistError.find(
                                             scanError->second) ==
                                         std::string::npos)
                                {
                                    knownPlaylistError +=
                                        "; " + scanError->second;
                                }
                            }

                            // Reparse playlists at launch to detect missing media
                            // or disconnected storage since the library was scanned.
                            const auto launchCheck =
                                bfmultidisc::check(
                                    games[gameSelected],
                                    knownPlaylistError
                                );

                            if (!launchCheck.allowed)
                            {
                                launchErrorText = launchCheck.error;
                                launchErrorOpen = true;
                                shaderMenuOpen = false;

                                std::cerr
                                    << "BareFront launch blocked: "
                                    << launchCheck.error
                                    << '\n';

                                // Exit this Select case without starting the emulator.
                                break;
                            }

                            // Keep the canonical BareFront game path
                            // unchanged. Standalone DuckStation and Flycast
                            // do not consume BareFront's canonical .m3u here,
                            // so launch the first verified disc directly and
                            // let the emulator provide native disc switching.
                            fs::path emulatorLaunchPath =
                                games[gameSelected];

                            if (
                                (systems[activeSystemIndex].configSection == "ps1" ||
                                 systems[activeSystemIndex].configSection == "dreamcast") &&
                                bfmultidisc::isPlaylist(
                                    games[gameSelected]
                                )
                            )
                            {
                                emulatorLaunchPath =
                                    launchCheck.firstMedia;
                            }


                            playSoundEffect(
                                clickSound
                            );

                            // Stop preview decoding before launching
                            // the emulator. BareFront is blocked while
                            // the game is running, so there is no reason
                            // to keep FFmpeg working in the background.
                            videoPlayer.stop();


                            // Present a clean launch transition before
                            // Gamescope and the emulator begin creating
                            // their windows. If the desktop compositor
                            // briefly exposes BareFront during startup,
                            // only this black loading frame is visible.
                            SDL_SetRenderDrawColor(
                                renderer,
                                0,
                                0,
                                0,
                                255
                            );

                            SDL_RenderClear(
                                renderer
                            );


                            SDL_Rect loadingArea =
                            {
                                0,
                                0,
                                SCREEN_WIDTH,
                                SCREEN_HEIGHT
                            };


                            drawTextCentered(
                                renderer,
                                gameTitleFont,
                                "Loading...",
                                loadingArea,
                                SDL_Color
                                {
                                    255,
                                    255,
                                    255,
                                    255
                                }
                            );


                            SDL_RenderPresent(
                                renderer
                            );


                            // Hold the clean BareFront launch screen
                            // briefly before any gameplay presentation
                            // helpers or emulator windows are started.
                            SDL_Delay(
                                2000
                            );


                            // Leave a plain black BareFront frame
                            // underneath gameplay. If Gamescope or an
                            // emulator window disappears during handover,
                            // no stale menu or Loading... text is exposed.
                            SDL_SetRenderDrawColor(
                                renderer,
                                0,
                                0,
                                0,
                                255
                            );

                            SDL_RenderClear(
                                renderer
                            );

                            SDL_RenderPresent(
                                renderer
                            );


                            launchGame(
                                systems[activeSystemIndex],
                                games[gameSelected],
                                emulatorLaunchPath
                            );


                            // Gameplay and its presentation helpers have
                            // completely closed. Hold a clean transition
                            // before revealing the BareFront game menu.
                            SDL_SetRenderDrawColor(
                                renderer,
                                0,
                                0,
                                0,
                                255
                            );

                            SDL_RenderClear(
                                renderer
                            );


                            SDL_Rect returningArea =
                            {
                                0,
                                0,
                                SCREEN_WIDTH,
                                SCREEN_HEIGHT
                            };


                            drawTextCentered(
                                renderer,
                                gameTitleFont,
                                "Returning...",
                                returningArea,
                                SDL_Color
                                {
                                    255,
                                    255,
                                    255,
                                    255
                                }
                            );


                            SDL_RenderPresent(
                                renderer
                            );

                            SDL_Delay(
                                2000
                            );


                            // P/R may have created new media while the
                            // emulator was running. Refresh immediately
                            // so a new video takes priority over the
                            // screenshot when BareFront returns.
                            refreshGamePreview(
                                renderer,
                                videoPlayer,
                                screenshotTexture,
                                useTatePreview,
                                systems[activeSystemIndex],
                                games[gameSelected],
                                currentPreviewArtwork()
                            );


                            // BareFront is blocked while the
                            // emulator runs. Throw away any stale
                            // input that accumulated in that time.
                            SDL_FlushEvent(
                                SDL_KEYDOWN
                            );

                            SDL_FlushEvent(
                                SDL_KEYUP
                            );

                            SDL_FlushEvent(
                                SDL_CONTROLLERBUTTONDOWN
                            );

                            SDL_FlushEvent(
                                SDL_CONTROLLERBUTTONUP
                            );

                            SDL_FlushEvent(
                                SDL_CONTROLLERAXISMOTION
                            );

                            stickLeftHeld =
                                false;

                            stickRightHeld =
                                false;

                            stickUpHeld =
                                false;

                            stickDownHeld =
                                false;

                            controllerSelectHeld =
                                false;

                            controllerStartHeld =
                                false;

                            quitComboStarted =
                                0;

                            quitComboTriggered =
                                false;
                        }

                        break;


                    case InputAction::Back:

                        playSoundEffect(
                            clickSound
                        );

                        videoPlayer.stop();

                        screen =
                            (!curatedFavouritesPath.empty())
                                ? Screen::Collections
                                : Screen::Home;


                        if (screenshotTexture)
                        {
                            SDL_DestroyTexture(
                                screenshotTexture
                            );

                            screenshotTexture =
                                nullptr;
                        }

                        break;


                    case InputAction::Quit:

                        playSoundEffect(
                            clickSound
                        );

                        running =
                            false;

                        break;


                    case InputAction::None:
                        break;
                }
                }


                if (selectionChanged)
                {
                    selectedSince =
                        SDL_GetTicks();


                    if (!games.empty())
                    {
                        refreshGamePreview(
                            renderer,
                            videoPlayer,
                            screenshotTexture,
                            useTatePreview,
                            systems[activeSystemIndex],
                            games[gameSelected],
                            currentPreviewArtwork()
                        );
                    }
                }
            }
        }


        // --------------------------------------------------
        // Background
        // --------------------------------------------------

        SDL_SetRenderDrawColor(
            renderer,
            0,
            0,
            0,
            255
        );


        SDL_RenderClear(
            renderer
        );


        // ==================================================
        // DRAW HOME SCREEN
        // ==================================================

        if (screen ==
            Screen::Home)
        {
            // ----------------------------------------------
            // BareFront striped title
            // ----------------------------------------------

            drawBareFrontTitle(
                renderer,
                homeTitleFont
            );


            // ----------------------------------------------
            // Draw one page, or both during slide
            // ----------------------------------------------

            if (!sliding)
            {
                drawHomePage(
                    renderer,
                    homeSystemFont,
                    systems,
                    currentPage,
                    homeSelected,
                    0,
                    true
                );
            }
            else
            {
                Uint32 elapsed =
                    SDL_GetTicks() -
                    slideStart;

                float progress =
                    static_cast<float>(
                        elapsed) /
                    static_cast<float>(
                        slideDuration);

                if (progress > 1.0f)
                {
                    progress =
                        1.0f;
                }


                // Smoothstep easing
                float eased =
                    progress *
                    progress *
                    (3.0f -
                     2.0f * progress);


                int oldOffset =
                    0;

                int newOffset =
                    0;


                if (slideDirection == 1)
                {
                    oldOffset =
                        static_cast<int>(
                            -SCREEN_WIDTH *
                            eased
                        );

                    newOffset =
                        static_cast<int>(
                            SCREEN_WIDTH *
                            (1.0f - eased)
                        );
                }
                else
                {
                    oldOffset =
                        static_cast<int>(
                            SCREEN_WIDTH *
                            eased
                        );

                    newOffset =
                        static_cast<int>(
                            -SCREEN_WIDTH *
                            (1.0f - eased)
                        );
                }


                drawHomePage(
                    renderer,
                    homeSystemFont,
                    systems,
                    currentPage,
                    homeSelected,
                    oldOffset,
                    true
                );


                drawHomePage(
                    renderer,
                    homeSystemFont,
                    systems,
                    targetPage,
                    targetSelected,
                    newOffset,
                    true
                );
            }


            // ----------------------------------------------
            // Page chevrons
            // ----------------------------------------------

            SDL_Rect leftArrowArea =
            {
                10,
                325,
                45,
                70
            };

            SDL_Rect rightArrowArea =
            {
                1225,
                325,
                45,
                70
            };


            if (!sliding)
            {
                if (currentPage == 0)
                {
                    drawTextCentered(
                        renderer,
                        homeArrowFont,
                        ">",
                        rightArrowArea,
                        grey
                    );
                }


                if (currentPage == 1)
                {
                    drawTextCentered(
                        renderer,
                        homeArrowFont,
                        "<",
                        leftArrowArea,
                        grey
                    );
                }
            }


            // ----------------------------------------------
            // Page dots
            // ----------------------------------------------

            int displayPage =
                sliding
                    ? targetPage
                    : currentPage;


            const int dotY =
                626;

            const int dot1X =
                628;

            const int dot2X =
                652;

            const int dotRadius =
                6;


            if (displayPage == 0)
            {
                SDL_SetRenderDrawColor(
                    renderer,
                    255,
                    255,
                    255,
                    255
                );
            }
            else
            {
                SDL_SetRenderDrawColor(
                    renderer,
                    90,
                    90,
                    90,
                    255
                );
            }


            fillCircle(
                renderer,
                dot1X,
                dotY,
                dotRadius
            );


            if (displayPage == 1)
            {
                SDL_SetRenderDrawColor(
                    renderer,
                    255,
                    255,
                    255,
                    255
                );
            }
            else
            {
                SDL_SetRenderDrawColor(
                    renderer,
                    90,
                    90,
                    90,
                    255
                );
            }


            fillCircle(
                renderer,
                dot2X,
                dotY,
                dotRadius
            );


            // ----------------------------------------------
            // Home footer
            // ----------------------------------------------

            drawText(
                renderer,
                homeFooterFont,
                "ARROWS Select",
                65,
                665,
                grey
            );


            drawText(
                renderer,
                homeFooterFont,
                "ENTER Open",
                465,
                665,
                grey
            );


            drawText(
                renderer,
                homeFooterFont,
                "ESC Quit",
                860,
                665,
                grey
            );
        }



        // ==================================================
        // DRAW CURATED COLLECTIONS SCREEN
        // ==================================================

        else if (screen == Screen::Collections)
        {
            drawText(
                renderer,
                gameTitleFont,
                systems[activeSystemIndex].screenTitle,
                64, 12, white
            );

            drawText(
                renderer,
                gameFont,
                "COLLECTIONS",
                64, 96, grey
            );

            SDL_Rect systemArea = {
                760, 1, 500, 250
            };

            drawSystemImage(
                renderer,
                systems[activeSystemIndex].texture,
                systemArea
            );

            SDL_SetRenderDrawColor(
                renderer, 80, 80, 80, 255
            );

            SDL_Rect divider = {
                724, 120, 2, 500
            };

            SDL_RenderFillRect(renderer, &divider);

            for (std::size_t index = 0;
                 index < curatedCollectionNames.size();
                 ++index)
            {
                const std::string& name =
                    curatedCollectionNames[index];

                const int y =
                    158 + static_cast<int>(index) * 76;

                if (index == curatedCollectionSelected)
                {
                    SDL_SetRenderDrawColor(
                        renderer, 75, 75, 75, 220
                    );

                    SDL_Rect highlight = {
                        45, y - 8, 640, 55
                    };

                    SDL_RenderFillRect(
                        renderer, &highlight
                    );
                }

                // Small red pixel heart for the virtual
                // Favourites collection.
                if (name == "Favourites")
                {
                    static const char* heart[] = {
                        " ##   ## ",
                        "#### ####",
                        "#########",
                        "#########",
                        " ####### ",
                        "  #####  ",
                        "   ###   ",
                        "    #    "
                    };

                    SDL_SetRenderDrawColor(
                        renderer, 230, 54, 75, 255
                    );

                    for (int row = 0; row < 8; ++row)
                    {
                        for (int column = 0;
                             column < 9;
                             ++column)
                        {
                            if (heart[row][column] != '#')
                                continue;

                            SDL_Rect pixel = {
                                65 + column * 4,
                                y + row * 4,
                                4, 4
                            };

                            SDL_RenderFillRect(
                                renderer, &pixel
                            );
                        }
                    }
                }

                drawText(
                    renderer,
                    gameFont,
                    name,
                    115,
                    y,
                    white
                );

                std::size_t count = 0;

                if (name == "Favourites")
                {
                    count = bflibrary::gamesFor(
                        curatedCollections,
                        "Favourites",
                        curatedFavourites
                    ).size();
                }
                else
                {
                    for (const auto& collection :
                         curatedCollections)
                    {
                        if (collection.name == name)
                        {
                            count = collection.games.size();
                            break;
                        }
                    }
                }

                drawText(
                    renderer,
                    gameFont,
                    std::to_string(count),
                    605,
                    y,
                    white
                );
            }
        }


        // ==================================================
        // DRAW CURRENT SYSTEM GAME SCREEN
        //
        // These coordinates are kept from your current
        // hand-tuned main.cpp.
        // ==================================================

        else if (
            screen ==
            Screen::Games)
        {
            // ----------------------------------------------
            // Title
            // ----------------------------------------------

            drawText(
                renderer,
                gameTitleFont,
                systems[activeSystemIndex].screenTitle,
                64,
                12,
                white
            );


            // ----------------------------------------------
            // Divider
            // ----------------------------------------------

            SDL_SetRenderDrawColor(
                renderer,
                80,
                80,
                80,
                255
            );


            SDL_Rect divider =
            {
                724,
                120,
                2,
                500
            };


            SDL_RenderFillRect(
                renderer,
                &divider
            );


            // ----------------------------------------------
            // Current system artwork
            // ----------------------------------------------

            SDL_Rect systemArea =
            {
                760,
                1,
                500,
                250
            };


            drawSystemImage(
                renderer,
                systems[activeSystemIndex].texture,
                systemArea
            );


            // ----------------------------------------------
            // Game list
            //
            // Maximum 8 visible items
            // ----------------------------------------------

            const int visibleGames =
                8;

            const int lineHeight =
                60;

            const int gameTextX =
                64;

            const int gameTextWidth =
                610;

            const bool curatedGameList = !curatedFavouritesPath.empty();

            const int highlightX =
                curatedGameList ? 56 : 45;

            const int highlightWidth =
                curatedGameList ? 629 : 640;

            const int listStartY =
                144;


            int firstVisible =
                0;


            if (games.size() >
                visibleGames)
            {
                if (gameSelected <
                    visibleGames / 2)
                {
                    firstVisible =
                        0;
                }
                else if (
                    gameSelected >=
                    games.size() -
                    (visibleGames / 2))
                {
                    firstVisible =
                        static_cast<int>(
                            games.size()) -
                        visibleGames;
                }
                else
                {
                    firstVisible =
                        static_cast<int>(
                            gameSelected) -
                        (visibleGames / 2);
                }
            }


            SDL_Rect listClip =
            {
                curatedGameList ? 20 : 45,
                138,
                curatedGameList ? 665 : 640,
                visibleGames *
                    lineHeight
            };


            if (games.empty())
            {
                drawText(
                    renderer,
                    gameFont,
                    "NO GAMES FOUND",
                    64,
                    300,
                    grey
                );
            }


            SDL_RenderSetClipRect(
                renderer,
                &listClip
            );


            for (int row = 0;
                 row < visibleGames;
                 ++row)
            {
                int gameIndex =
                    firstVisible +
                    row;


                if (gameIndex >=
                    static_cast<int>(
                        games.size()))
                {
                    break;
                }


                int y =
                    listStartY +
                    (row * lineHeight);


                if (gameIndex ==
                    static_cast<int>(
                        gameSelected))
                {
                    SDL_SetRenderDrawColor(
                        renderer,
                        75,
                        75,
                        75,
                        220
                    );


                    SDL_Rect highlight =
                    {
                        highlightX,
                        y - 6,
                        highlightWidth,
                        50
                    };


                    SDL_RenderFillRect(
                        renderer,
                        &highlight
                    );
                }


                const bool favouriteMarked =
                    !curatedFavouritesPath.empty() &&
                    gameIndex < static_cast<int>(curatedVisibleGames.size()) &&
                    curatedVisibleGames[gameIndex].favourite;

                if (favouriteMarked)
                {
                    static const char* heart[] = {
                        " ##   ## ", "#### ####", "#########",
                        "#########", " ####### ", "  #####  ",
                        "   ###   ", "    #    "
                    };

                    SDL_SetRenderDrawColor(renderer, 230, 54, 75, 255);

                    for (int heartRow = 0; heartRow < 8; ++heartRow)
                    {
                        for (int heartColumn = 0; heartColumn < 9; ++heartColumn)
                        {
                            if (heart[heartRow][heartColumn] != '#')
                                continue;

                            SDL_Rect pixel = {
                                gameTextX - 40 + heartColumn * 3,
                                y + 3 + heartRow * 3,
                                3, 3
                            };
                            SDL_RenderFillRect(renderer, &pixel);
                        }
                    }
                }

                drawGameTitle(
                    renderer,
                    gameFont,
                    gameDisplayTitles[
                        gameIndex
                    ],
                    gameTextX,
                    y,
                    gameTextWidth,
                    white,
                    gameIndex ==
                        static_cast<int>(
                            gameSelected),
                    selectedSince
                );
            }


            SDL_RenderSetClipRect(
                renderer,
                nullptr
            );


            // ----------------------------------------------
            // Game position counter
            // ----------------------------------------------

            std::string gameCounter;

            if (games.empty())
            {
                gameCounter =
                    "0 GAMES";
            }
            else
            {
                gameCounter =
                    std::to_string(
                        gameSelected + 1) +
                    " OF " +
                    std::to_string(
                        games.size());
            }


            drawText(
                renderer,
                gameFont,
                gameCounter,
                64,
                615,
                grey
            );


            // ----------------------------------------------
            // CRT television
            // ----------------------------------------------

            SDL_Rect tvArea =
            {
                755,
                260,
                486,
                380
            };


            // ----------------------------------------------
            // CRT screen
            // ----------------------------------------------

            SDL_Rect screenArea =
            {
                805,
                326,
                320,
                240
            };


            // Arcade TATE orientation comes from MAME metadata.
            // Preview media dimensions must never decide whether
            // the machine is horizontal or vertical.
            bool tateNow =
                isArcadeSystem(
                    systems[activeSystemIndex]) &&
                useTatePreview;


            if (tateNow)
            {
                // TATE uses the SAME CRT artwork, just rendered a
                // little smaller and rotated 90 degrees.  Keeping
                // the original CRT aspect ratio here means the
                // rotated cabinet remains correctly proportioned.
                //
                // Before rotation: 380 x 297
                // Visible after rotation: roughly 297 x 380
                //
                // This keeps it clear of the footer and console art.
                tvArea =
                {
                    815,
                    285,
                    380,
                    297
                };

                // Rotated equivalent of the normal CRT screen opening.
                // The gameplay itself remains upright.
                screenArea =
                {
                    914,
                    283,
                    188,
                    250
                };
            }


            SDL_SetRenderDrawColor(
                renderer,
                5,
                5,
                5,
                255
            );


            SDL_RenderFillRect(
                renderer,
                &screenArea
            );


            if (videoPlayer.hasFrame())
            {
                videoPlayer.draw(
                    renderer,
                    screenArea
                );
            }
            else if (screenshotTexture)
            {
                drawTextureContained(
                    renderer,
                    screenshotTexture,
                    screenArea
                );
            }
            else
            {
                drawTextCentered(
                    renderer,
                    gameFont,
                    "NO SIGNAL",
                    screenArea,
                    noSignalColour
                );
            }


            if (tateNow)
            {
                drawCRTTate(
                    renderer,
                    tvTexture,
                    tvArea
                );
            }
            else
            {
                drawCRT(
                    renderer,
                    tvTexture,
                    tvArea
                );
            }


            // ----------------------------------------------
            // Existing game footer
            // ----------------------------------------------

            drawText(
                renderer,
                gameFont,
                "UP/DOWN Select",
                64,
                678,
                grey
            );


            drawText(
                renderer,
                gameFont,
                "ENTER Play",
                860,
                678,
                grey
            );
        }


        // --------------------------------------------------
        // Display completed frame
        // --------------------------------------------------


        // --------------------------------------------------
        // Minimal controller-native invalid-disc panel.
        if (screen == Screen::Games && launchErrorOpen)
        {
            SDL_BlendMode previousBlend = SDL_BLENDMODE_NONE;

            SDL_GetRenderDrawBlendMode(
                renderer, &previousBlend
            );

            SDL_SetRenderDrawBlendMode(
                renderer, SDL_BLENDMODE_BLEND
            );

            SDL_SetRenderDrawColor(renderer, 0, 0, 0, 205);

            SDL_Rect scrim = {
                0, 0, SCREEN_WIDTH, SCREEN_HEIGHT
            };

            SDL_RenderFillRect(renderer, &scrim);

            SDL_SetRenderDrawColor(renderer, 25, 25, 25, 255);

            SDL_Rect panelArea = {
                230, 170, 820, 380
            };

            SDL_RenderFillRect(renderer, &panelArea);

            SDL_SetRenderDrawColor(renderer, 125, 125, 125, 255);
            SDL_RenderDrawRect(renderer, &panelArea);

            const SDL_Color white = {
                255, 255, 255, 255
            };

            const SDL_Color grey = {
                190, 190, 190, 255
            };

            const SDL_Color dark = {
                25, 25, 25, 255
            };

            // Wrapped heading, constrained to panel width.
            SDL_Rect heading = {
                260, 200, 760, 90
            };

            drawWrappedCenteredText(
                renderer,
                gameTitleFont,
                "INVALID DISC IMAGE!",
                heading,
                white
            );

            // Short guidance, also wrapped and bounded.
            SDL_Rect message = {
                260, 302, 760, 65
            };

            drawWrappedCenteredText(
                renderer,
                gameFont,
                "See README for info.",
                message,
                grey
            );

            // Single highlighted OK button.
            SDL_Rect buttonArea = {
                520, 405, 240, 72
            };

            SDL_SetRenderDrawColor(
                renderer, 235, 235, 235, 255
            );

            SDL_RenderFillRect(renderer, &buttonArea);

            drawTextCentered(
                renderer,
                gameTitleFont,
                "OK",
                buttonArea,
                dark
            );

            SDL_SetRenderDrawBlendMode(
                renderer,
                previousBlend
            );
        }

        // Shader selector overlays the game list and CRT preview.
        if (screen == Screen::Games && shaderMenuOpen)
        {
            SDL_BlendMode previousBlend = SDL_BLENDMODE_NONE;
            SDL_GetRenderDrawBlendMode(renderer, &previousBlend);
            SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);

            SDL_SetRenderDrawColor(renderer, 0, 0, 0, 205);
            SDL_Rect scrim = {0, 0, SCREEN_WIDTH, SCREEN_HEIGHT};
            SDL_RenderFillRect(renderer, &scrim);

            // Hide the underlying game-screen footer completely.
            SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
            SDL_Rect footerMask =
            {
                0, 645, SCREEN_WIDTH, SCREEN_HEIGHT - 645
            };
            SDL_RenderFillRect(renderer, &footerMask);

            // The popup itself must be fully opaque.
            SDL_Rect panel = {180, 120, 920, 480};
            SDL_SetRenderDrawColor(renderer, 25, 25, 25, 255);
            SDL_RenderFillRect(renderer, &panel);

            SDL_SetRenderDrawColor(renderer, 125, 125, 125, 255);
            SDL_RenderDrawRect(renderer, &panel);

            SDL_Rect heading = {205, 145, 870, 55};
            drawTextCentered(
                renderer, gameTitleFont,
                "SHADER PRESET", heading, white
            );

            SDL_Rect systemHeading = {205, 205, 870, 35};
            drawTextCentered(
                renderer, gameFont,
                systems[activeSystemIndex].screenTitle,
                systemHeading, grey
            );

            for (std::size_t index = 0;
                 index < shaderChoices.size();
                 ++index)
            {
                SDL_Rect option =
                {
                    220,
                    260 + static_cast<int>(index) * 68,
                    840,
                    60
                };

                if (index == shaderMenuSelected)
                {
                    SDL_SetRenderDrawColor(
                        renderer, 75, 75, 75, 255
                    );
                    SDL_RenderFillRect(renderer, &option);
                }

                drawTextCentered(
                    renderer, gameFont,
                    shaderChoices[index], option, white
                );
            }

            if (shaderMenuSaveFailed)
            {
                SDL_Rect errorArea = {205, 540, 870, 35};

                drawTextCentered(
                    renderer, gameFont,
                    "SAVE FAILED - CHECK PERMISSIONS",
                    errorArea, white
                );
            }
            else
            {
                SDL_Rect selectArea = {215, 540, 420, 35};
                SDL_Rect cancelArea = {645, 540, 420, 35};

                drawTextCentered(
                    renderer, gameFont,
                    "A / ENTER SELECT",
                    selectArea, grey
                );

                drawTextCentered(
                    renderer, gameFont,
                    "B / ESC CANCEL",
                    cancelArea, grey
                );
            }

            SDL_SetRenderDrawBlendMode(
                renderer, previousBlend
            );
        }

        SDL_RenderPresent(
            renderer
        );
    }


    // --------------------------------------------------
    // Cleanup
    // --------------------------------------------------

    videoPlayer.stop();


    if (screenshotTexture)
    {
        SDL_DestroyTexture(
            screenshotTexture
        );
    }


    if (tvTexture)
    {
        SDL_DestroyTexture(
            tvTexture
        );
    }


    for (System& system :
         systems)
    {
        if (system.texture)
        {
            SDL_DestroyTexture(
                system.texture
            );
        }
    }


    freeSoundEffect(
        clickSound
    );


    if (controller)
    {
        SDL_GameControllerClose(
            controller
        );

        controller =
            nullptr;
    }


    TTF_CloseFont(
        gameTitleFont
    );


    TTF_CloseFont(
        gameFont
    );


    TTF_CloseFont(
        homeTitleFont
    );


    TTF_CloseFont(
        homeSystemFont
    );


    TTF_CloseFont(
        homeFooterFont
    );


    TTF_CloseFont(
        homeArrowFont
    );


    SDL_DestroyRenderer(
        renderer
    );


    SDL_DestroyWindow(
        window
    );


    IMG_Quit();
    TTF_Quit();
    SDL_Quit();


    return 0;
}
