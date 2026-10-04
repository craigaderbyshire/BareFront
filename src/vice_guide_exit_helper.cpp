#include <SDL2/SDL.h>

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <cstdlib>
#include <iostream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

int main()
{
    // Only operate when started by BareFront's VICE launcher.
    const char* session =
        std::getenv("BAREFRONT_C64_GUIDE_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr << "Not a BareFront VICE session\n";
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

    auto sendViceDiscKey = [](bool previous) -> bool
    {
        Display* display = XOpenDisplay(nullptr);

        if (!display)
        {
            std::cerr << "Cannot open nested X display for disc change\n";
            return false;
        }

        Window focused = None;
        int revert = 0;

        XGetInputFocus(display, &focused, &revert);

        if (focused == None || focused == PointerRoot)
        {
            std::cerr << "No focused VICE window for disc change\n";
            XCloseDisplay(display);
            return false;
        }

        const KeyCode alt =
            XKeysymToKeycode(display, XK_Alt_L);

        const KeyCode shift =
            XKeysymToKeycode(display, XK_Shift_L);

        const KeyCode n =
            XKeysymToKeycode(display, XK_n);

        if (!alt || !shift || !n)
        {
            std::cerr << "Required disc-change key unavailable\n";
            XCloseDisplay(display);
            return false;
        }

        if (previous)
        {
            XTestFakeKeyEvent(display, shift, True, 0);
        }

        XTestFakeKeyEvent(display, alt, True, 0);
        XTestFakeKeyEvent(display, n, True, 0);
        XSync(display, False);

        SDL_Delay(50);

        XTestFakeKeyEvent(display, n, False, 0);
        XTestFakeKeyEvent(display, alt, False, 0);

        if (previous)
        {
            XTestFakeKeyEvent(display, shift, False, 0);
        }

        XSync(display, False);
        XCloseDisplay(display);

        return true;
    };

    std::cout
        << "VICE Guide helper active. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n"
        << "Quick Guide tap -> ignored\n"
        << "Guide hold: 1500 ms -> Exit\n"
        << "LB+RB+Y -> Next disk\n"
        << "LB+RB+X -> Previous disk\n";

    std::cout.flush();

    constexpr Uint64 GUIDE_HOLD_MS = 1500;

    std::unordered_map<SDL_JoystickID, Uint64> guideStarted;
    std::unordered_set<SDL_JoystickID> guideFired;

    SDL_Event event;

    while (true)
    {
        const Uint64 now = SDL_GetTicks64();

        for (const auto& guide : guideStarted)
        {
            if (!guideFired.count(guide.first) &&
                now - guide.second >= GUIDE_HOLD_MS)
            {
                guideFired.insert(guide.first);

                std::cout << "Guide hold detected\n";
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

                std::cout << "Sending Escape to VICE\n";
                std::cout.flush();

                XTestFakeKeyEvent(display, key, True, 0);
                XSync(display, False);

                SDL_Delay(100);

                XTestFakeKeyEvent(display, key, False, 0);
                XSync(display, False);

                XCloseDisplay(display);

                std::cout << "Escape sent\n";
                std::cout.flush();

                goto done;
            }
        }

        if (!SDL_WaitEventTimeout(&event, 100))
            continue;

        // SDL converts its handled termination signals into SDL_QUIT.
        // Allow the launcher's SIGTERM cleanup to end this helper.
        if (event.type == SDL_QUIT)
        {
            std::cout << "VICE Guide helper quitting" << std::endl;
            break;
        }

        if (event.type == SDL_CONTROLLERBUTTONDOWN)
        {
            SDL_GameController* controller =
                SDL_GameControllerFromInstanceID(
                    event.cbutton.which
                );

            if (controller)
            {
                const bool lb =
                    SDL_GameControllerGetButton(
                        controller,
                        SDL_CONTROLLER_BUTTON_LEFTSHOULDER
                    );

                const bool rb =
                    SDL_GameControllerGetButton(
                        controller,
                        SDL_CONTROLLER_BUTTON_RIGHTSHOULDER
                    );

                if (lb && rb &&
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_Y)
                {
                    std::cout << "Disc NEXT chord detected\n";
                    std::cout.flush();

                    if (sendViceDiscKey(false))
                    {
                        std::cout << "Alt+N sent to VICE\n";
                        std::cout.flush();
                    }

                    continue;
                }

                if (lb && rb &&
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_X)
                {
                    std::cout << "Disc PREVIOUS chord detected\n";
                    std::cout.flush();

                    if (sendViceDiscKey(true))
                    {
                        std::cout << "Shift+Alt+N sent to VICE\n";
                        std::cout.flush();
                    }

                    continue;
                }
            }
        }

        if (event.type == SDL_CONTROLLERBUTTONUP &&
            event.cbutton.button == SDL_CONTROLLER_BUTTON_MISC1)
        {
            const SDL_JoystickID id = event.cbutton.which;

            if (guideStarted.count(id) &&
                !guideFired.count(id))
            {
                std::cout << "Quick Guide tap ignored\n";
                std::cout.flush();
            }

            guideStarted.erase(id);
            guideFired.erase(id);
            continue;
        }

        if (event.type == SDL_CONTROLLERDEVICEREMOVED)
        {
            guideStarted.erase(event.cdevice.which);
            guideFired.erase(event.cdevice.which);
            continue;
        }

        if (event.type != SDL_CONTROLLERBUTTONDOWN)
            continue;

        // The M7 Xbox controller reports its physical
        // Guide button as SDL misc1 (raw button 11).
        if (event.cbutton.button !=
            SDL_CONTROLLER_BUTTON_MISC1)
        {
            continue;
        }

        const SDL_JoystickID id = event.cbutton.which;

        if (!guideStarted.count(id))
        {
            guideStarted[id] = SDL_GetTicks64();
            guideFired.erase(id);

            std::cout << "Xbox Guide pressed\n";
            std::cout.flush();
        }
    }

done:

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();

    return 0;
}
