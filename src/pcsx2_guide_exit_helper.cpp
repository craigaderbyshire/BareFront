#include <SDL2/SDL.h>

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <cstdlib>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <vector>

int main()
{
    // Only operate when started by BareFront's PCSX2 launcher.
    const char* session =
        std::getenv("BAREFRONT_PS2_GUIDE_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr << "Not a BareFront PCSX2 session\n";
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
        << "PCSX2 Share helper active. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n";

    std::cout.flush();

    std::map<SDL_JoystickID, Uint64> guideDown;

    std::set<SDL_JoystickID> lbDown;
    std::set<SDL_JoystickID> rbDown;
    std::set<SDL_JoystickID> yDown;
    std::set<SDL_JoystickID> discChordLatched;

    auto sendF7 = []() -> bool
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

        if (focused == None ||
            focused == PointerRoot)
        {
            std::cerr << "No focused emulator window\n";
            XCloseDisplay(display);
            return false;
        }

        KeyCode key =
            XKeysymToKeycode(display, XK_F7);

        if (!key)
        {
            std::cerr << "F7 key unavailable\n";
            XCloseDisplay(display);
            return false;
        }

        XTestFakeKeyEvent(display, key, True, 0);
        XSync(display, False);

        SDL_Delay(100);

        XTestFakeKeyEvent(display, key, False, 0);
        XSync(display, False);

        XCloseDisplay(display);

        return true;
    };

    bool exitRequested = false;

    while (!exitRequested)
    {
        SDL_Event event;

        while (SDL_PollEvent(&event))
        {
            if (event.type == SDL_QUIT)
            {
                exitRequested = true;
                break;
            }

            if (event.type == SDL_CONTROLLERBUTTONDOWN &&
                event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1)
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                if (guideDown.find(id) ==
                    guideDown.end())
                {
                    guideDown[id] = SDL_GetTicks64();

                    std::cout << "Xbox Share pressed\n";
                    std::cout.flush();
                }
            }
            else if (
                event.type == SDL_CONTROLLERBUTTONUP &&
                event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1)
            {
                guideDown.erase(event.cbutton.which);

                std::cout << "Xbox Share released\n";
                std::cout.flush();
            }
            else if (
                event.type == SDL_CONTROLLERBUTTONDOWN &&
                (
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_LEFTSHOULDER ||
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_RIGHTSHOULDER ||
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_Y
                ))
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                if (event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_LEFTSHOULDER)
                {
                    lbDown.insert(id);
                }
                else if (event.cbutton.button ==
                         SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)
                {
                    rbDown.insert(id);
                }
                else
                {
                    yDown.insert(id);
                }

                if (lbDown.count(id) &&
                    rbDown.count(id) &&
                    yDown.count(id) &&
                    discChordLatched.insert(id).second)
                {
                    std::cout
                        << "LB+RB+Y detected — sending F7 to PCSX2\n";
                    std::cout.flush();

                    if (sendF7())
                    {
                        std::cout << "F7 sent\n";
                        std::cout.flush();
                    }
                }
            }
            else if (
                event.type == SDL_CONTROLLERBUTTONUP &&
                (
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_LEFTSHOULDER ||
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_RIGHTSHOULDER ||
                    event.cbutton.button ==
                        SDL_CONTROLLER_BUTTON_Y
                ))
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                if (event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_LEFTSHOULDER)
                {
                    lbDown.erase(id);
                }
                else if (event.cbutton.button ==
                         SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)
                {
                    rbDown.erase(id);
                }
                else
                {
                    yDown.erase(id);
                }

                discChordLatched.erase(id);
            }
            else if (
                event.type == SDL_CONTROLLERDEVICEREMOVED)
            {
                const SDL_JoystickID id =
                    event.cdevice.which;

                guideDown.erase(id);
                lbDown.erase(id);
                rbDown.erase(id);
                yDown.erase(id);
                discChordLatched.erase(id);
            }
        }

        if (exitRequested)
            break;

        const Uint64 now = SDL_GetTicks64();

        for (auto held = guideDown.begin();
             held != guideDown.end();
             ++held)
        {
            if (now - held->second < 1500)
                continue;

            const SDL_JoystickID id = held->first;

            std::cout
                << "Share held 1500 ms — sending Escape to PCSX2\n";
            std::cout.flush();

            Display* display = XOpenDisplay(nullptr);

            if (!display)
            {
                std::cerr << "Cannot open nested X display\n";
                guideDown.erase(id);
                break;
            }

            Window focused = None;
            int revert = 0;

            XGetInputFocus(display, &focused, &revert);

            if (focused == None ||
                focused == PointerRoot)
            {
                std::cerr << "No focused emulator window\n";
                XCloseDisplay(display);
                guideDown.erase(id);
                break;
            }

            KeyCode key =
                XKeysymToKeycode(display, XK_Escape);

            if (!key)
            {
                std::cerr << "Escape key unavailable\n";
                XCloseDisplay(display);
                guideDown.erase(id);
                break;
            }

            XTestFakeKeyEvent(display, key, True, 0);
            XSync(display, False);

            SDL_Delay(100);

            XTestFakeKeyEvent(display, key, False, 0);
            XSync(display, False);

            XCloseDisplay(display);

            std::cout << "Escape sent\n";
            std::cout.flush();

            exitRequested = true;
            break;
        }

        SDL_Delay(10);
    }

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();

    return 0;
}
