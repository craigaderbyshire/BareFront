#include <SDL2/SDL.h>

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

int main()
{
    // Only operate when explicitly started by our
    // NES Gamescope launcher.
    const char* session =
        std::getenv("BAREFRONT_NES_GUIDE_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr << "Not a BareFront NES session\n";
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

    auto openControllers = [&]()
    {
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
    };

    openControllers();

    std::cout
        << "NES Guide helper active. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n";

    std::cout.flush();

    SDL_Event event;

    while (SDL_WaitEvent(&event))
    {
        if (event.type != SDL_CONTROLLERBUTTONDOWN)
            continue;

        // The M7 Xbox controller reports its physical
        // Guide button as SDL misc1 (raw button 11).
        if (event.cbutton.button !=
            SDL_CONTROLLER_BUTTON_MISC1)
        {
            continue;
        }

        std::cout << "Xbox Guide detected\n";
        std::cout.flush();

        Display* display = XOpenDisplay(nullptr);

        if (!display)
        {
            std::cerr << "Cannot open nested X display\n";
            continue;
        }

        Window focused;
        int revert;

        XGetInputFocus(display, &focused, &revert);

        if (focused == None ||
            focused == PointerRoot)
        {
            std::cerr << "No focused emulator window\n";
            XCloseDisplay(display);
            continue;
        }

        KeyCode key =
            XKeysymToKeycode(display, XK_Escape);

        if (!key)
        {
            std::cerr << "Escape key unavailable\n";
            XCloseDisplay(display);
            continue;
        }

        std::cout << "Sending Escape to Mesen\n";
        std::cout.flush();

        XTestFakeKeyEvent(display, key, True, 0);
        XSync(display, False);

        SDL_Delay(100);

        XTestFakeKeyEvent(display, key, False, 0);
        XSync(display, False);

        XCloseDisplay(display);

        std::cout << "Escape sent\n";
        std::cout.flush();

        break;
    }

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();

    return 0;
}
