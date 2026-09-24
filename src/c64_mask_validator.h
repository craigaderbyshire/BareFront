#pragma once

#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>
#include <cstdint>
#include <iostream>

static int validateC64Mask(
    const char* selectedPath,
    const char* referencePath)
{
    if (SDL_Init(0) != 0)
        return 1;

    if ((IMG_Init(IMG_INIT_PNG) & IMG_INIT_PNG) == 0)
    {
        SDL_Quit();
        return 1;
    }

    auto load = [](const char* path) -> SDL_Surface*
    {
        SDL_Surface* raw = IMG_Load(path);
        if (!raw) return nullptr;

        SDL_Surface* rgba = SDL_ConvertSurfaceFormat(
            raw, SDL_PIXELFORMAT_RGBA32, 0);

        SDL_FreeSurface(raw);
        return rgba;
    };

    SDL_Surface* selected = load(selectedPath);
    SDL_Surface* reference = load(referencePath);

    bool valid =
        selected && reference &&
        selected->w == 1920 && selected->h == 1080 &&
        reference->w == 1920 && reference->h == 1080;

    bool selectedLocked = false;
    bool referenceLocked = false;
    std::uint64_t mismatches = 0;

    if (valid)
    {
        selectedLocked = SDL_LockSurface(selected) == 0;

        if (selectedLocked)
            referenceLocked = SDL_LockSurface(reference) == 0;

        valid = selectedLocked && referenceLocked;
    }

    if (valid)
    {
        for (int y = 0; y < 1080; ++y)
        {
            const auto* a = reinterpret_cast<const Uint32*>(
                static_cast<const Uint8*>(selected->pixels) +
                y * selected->pitch);

            const auto* b = reinterpret_cast<const Uint32*>(
                static_cast<const Uint8*>(reference->pixels) +
                y * reference->pitch);

            for (int x = 0; x < 1920; ++x)
            {
                const Uint32 alphaA =
                    (a[x] & selected->format->Amask) >>
                    selected->format->Ashift;

                const Uint32 alphaB =
                    (b[x] & reference->format->Amask) >>
                    reference->format->Ashift;

                if (alphaA != alphaB)
                    ++mismatches;
            }
        }

        valid = mismatches == 0;
    }

    if (referenceLocked) SDL_UnlockSurface(reference);
    if (selectedLocked) SDL_UnlockSurface(selected);

    if (reference) SDL_FreeSurface(reference);
    if (selected) SDL_FreeSurface(selected);

    IMG_Quit();
    SDL_Quit();

    if (!valid)
    {
        std::cerr << "FAIL: C64 dimensions or alpha mask\n"
                  << "Alpha mismatches: " << mismatches << '\n';
        return 1;
    }

    std::cout << "PASS: C64 exact alpha mask\n";
    return 0;
}
