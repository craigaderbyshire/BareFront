#include <SDL2/SDL.h>

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <vector>

static constexpr Uint64 GUIDE_HOLD_MS = 1500;

static bool sendEscape()
{
    Display* display = XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr << "Cannot open nested X display\n";
        return false;
    }

    Window focused = None;
    int revert = 0;

    XGetInputFocus(display, &focused, &revert);

    if (focused == None || focused == PointerRoot)
    {
        std::cerr << "No focused emulator window\n";
        XCloseDisplay(display);
        return false;
    }

    KeyCode key =
        XKeysymToKeycode(display, XK_Escape);

    if (!key)
    {
        std::cerr << "Escape key unavailable\n";
        XCloseDisplay(display);
        return false;
    }

    std::cout << "Guide held 1500 ms — sending Escape to MAME\n";
    std::cout.flush();

    XTestFakeKeyEvent(display, key, True, 0);
    XSync(display, False);

    SDL_Delay(100);

    XTestFakeKeyEvent(display, key, False, 0);
    XSync(display, False);

    XCloseDisplay(display);

    std::cout << "Escape sent\n";
    std::cout.flush();

    return true;
}

int main()
{
    const char* session =
        std::getenv("BAREFRONT_MAME_GUIDE_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr << "Not a BareFront MAME session\n";
        return 1;
    }

    SDL_SetHint(
        SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS,
        "1"
    );

    if (SDL_Init(SDL_INIT_GAMECONTROLLER) != 0)
    {
        std::cerr << SDL_GetError() << "\n";
        return 1;
    }

    std::vector<SDL_GameController*> controllers;

    for (int i = 0; i < SDL_NumJoysticks(); ++i)
    {
        if (!SDL_IsGameController(i))
            continue;

        auto* controller = SDL_GameControllerOpen(i);

        if (controller)
        {
            controllers.push_back(controller);

            std::cout
                << "Controller: "
                << SDL_GameControllerName(controller)
                << "\n";
        }
    }

    std::cout
        << "MAME Guide helper active — 1500 ms hold required. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n";

    std::cout.flush();

    std::map<SDL_JoystickID, Uint64> guideDown;

    bool exitRequested = false;

    while (!exitRequested)
    {
        SDL_Event event;

        while (SDL_PollEvent(&event))
        {
            if (event.type == SDL_QUIT)
            {
                exitRequested = true;
            }
            else if (event.type == SDL_CONTROLLERBUTTONDOWN &&
                event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1)
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                if (guideDown.find(id) ==
                    guideDown.end())
                {
                    guideDown[id] = SDL_GetTicks64();

                    std::cout << "Xbox Guide pressed\n";
                    std::cout.flush();
                }
            }
            else if (
                event.type == SDL_CONTROLLERBUTTONUP &&
                event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1)
            {
                guideDown.erase(event.cbutton.which);

                std::cout << "Xbox Guide released\n";
                std::cout.flush();
            }
            else if (
                event.type == SDL_CONTROLLERDEVICEREMOVED)
            {
                guideDown.erase(event.cdevice.which);
            }
        }

        const Uint64 now = SDL_GetTicks64();

        for (const auto& held : guideDown)
        {
            if (now - held.second >= GUIDE_HOLD_MS)
            {
                exitRequested = sendEscape();
                break;
            }
        }

        SDL_Delay(10);
    }

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();

    return 0;
}
