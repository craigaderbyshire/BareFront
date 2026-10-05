#include <SDL2/SDL.h>

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <csignal>
#include <cstdlib>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace
{
volatile std::sig_atomic_t stopRequested = 0;

void requestStop(int)
{
    stopRequested = 1;
}

bool sendKey(KeySym symbol, const char* description)
{
    Display* display = XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr << "Cannot open Dreamcast control display\n";
        return false;
    }

    Window focused = None;
    int revert = 0;

    XGetInputFocus(display, &focused, &revert);

    if (focused == None || focused == PointerRoot)
    {
        std::cerr << "No focused Dreamcast window\n";
        XCloseDisplay(display);
        return false;
    }

    const KeyCode key =
        XKeysymToKeycode(display, symbol);

    if (!key)
    {
        std::cerr
            << "Key unavailable for "
            << description
            << "\n";

        XCloseDisplay(display);
        return false;
    }

    XTestFakeKeyEvent(
        display,
        key,
        True,
        CurrentTime
    );

    XSync(display, False);
    SDL_Delay(100);

    XTestFakeKeyEvent(
        display,
        key,
        False,
        CurrentTime
    );

    XSync(display, False);
    XCloseDisplay(display);

    std::cout
        << "Sent "
        << description
        << "\n";

    std::cout.flush();

    return true;
}
}

int main()
{
    const char* session =
        std::getenv("BAREFRONT_DREAMCAST_CONTROL_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr
            << "Not a BareFront Dreamcast control session\n";

        return 1;
    }

    std::signal(SIGINT, requestStop);
    std::signal(SIGTERM, requestStop);

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

        SDL_GameController* controller =
            SDL_GameControllerOpen(i);

        if (controller)
        {
            controllers.push_back(controller);

            std::cout
                << "Controller: "
                << SDL_GameControllerName(controller)
                << "\n";
        }
    }

    if (controllers.empty())
    {
        std::cerr
            << "No SDL game controller available\n";

        SDL_Quit();
        return 1;
    }

    constexpr Uint64 GUIDE_HOLD_MS = 1500;
    constexpr Uint64 DISC_DEBOUNCE_MS = 450;

    std::map<SDL_JoystickID, Uint64> guideStarted;
    std::set<SDL_JoystickID> guideFired;
    std::set<SDL_JoystickID> yHeld;

    Uint64 lastDiscAction = 0;
    bool hadDiscAction = false;

    std::cout
        << "Dreamcast controller helper active. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n"
        << "Share hold: 1500 ms -> Exit\n"
        << "LB+RB+Y -> Flycast menu\n";

    std::cout.flush();

    SDL_Event event;

    while (!stopRequested)
    {
        while (SDL_PollEvent(&event))
        {
            if (event.type == SDL_QUIT)
            {
                stopRequested = 1;
                break;
            }

            if (event.type ==
                SDL_CONTROLLERBUTTONDOWN)
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                if (event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1)
                {
                    if (!guideStarted.count(id))
                    {
                        guideStarted[id] =
                            SDL_GetTicks64();

                        guideFired.erase(id);
                    }
                }

                if (event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_Y)
                {
                    if (!yHeld.insert(id).second)
                        continue;

                    SDL_GameController* controller =
                        SDL_GameControllerFromInstanceID(id);

                    const bool leftShoulder =
                        controller &&
                        SDL_GameControllerGetButton(
                            controller,
                            SDL_CONTROLLER_BUTTON_LEFTSHOULDER
                        );

                    const bool rightShoulder =
                        controller &&
                        SDL_GameControllerGetButton(
                            controller,
                            SDL_CONTROLLER_BUTTON_RIGHTSHOULDER
                        );

                    if (leftShoulder && rightShoulder)
                    {
                        const Uint64 now =
                            SDL_GetTicks64();

                        if (!hadDiscAction ||
                            now - lastDiscAction >=
                                DISC_DEBOUNCE_MS)
                        {
                            hadDiscAction = true;
                            lastDiscAction = now;

                            std::cout
                                << "LB+RB+Y detected\n";

                            std::cout.flush();

                            sendKey(
                                XK_Tab,
                                "Tab to Flycast"
                            );
                        }
                    }
                }
            }

            if (event.type ==
                SDL_CONTROLLERBUTTONUP)
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                if (event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1)
                {
                    guideStarted.erase(id);
                    guideFired.erase(id);
                }

                if (event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_Y)
                {
                    yHeld.erase(id);
                }
            }

            if (event.type ==
                SDL_CONTROLLERDEVICEREMOVED)
            {
                guideStarted.erase(
                    event.cdevice.which
                );

                guideFired.erase(
                    event.cdevice.which
                );

                yHeld.erase(
                    event.cdevice.which
                );
            }
        }

        const Uint64 now = SDL_GetTicks64();

        for (const auto& guide : guideStarted)
        {
            if (!guideFired.count(guide.first) &&
                now - guide.second >= GUIDE_HOLD_MS)
            {
                guideFired.insert(guide.first);

                std::cout
                    << "Share hold detected\n";

                std::cout.flush();

                sendKey(
                    XK_Escape,
                    "Escape to Flycast"
                );
            }
        }

        SDL_Delay(10);
    }

    for (SDL_GameController* controller :
         controllers)
    {
        SDL_GameControllerClose(controller);
    }

    SDL_Quit();
    return 0;
}
