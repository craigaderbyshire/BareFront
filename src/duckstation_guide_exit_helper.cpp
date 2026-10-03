#include <SDL2/SDL.h>

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <csignal>
#include <signal.h>
#include <sys/types.h>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>

namespace
{
volatile std::sig_atomic_t stopRequested = 0;

void requestStop(int)
{
    stopRequested = 1;
}

bool requestDuckStationExit(bool probe)
{
    if (probe)
    {
        std::cout
            << "PROBE: Guide held 1500 ms; SIGTERM NOT sent\n";
        std::cout.flush();
        return false;
    }

    Display* display = XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr << "Cannot open nested X display\n";
        return false;
    }

    Window focused;
    int revert;

    XGetInputFocus(display, &focused, &revert);

    if (focused == None ||
        focused == PointerRoot)
    {
        std::cerr << "No focused emulator window\n";
        XCloseDisplay(display);
        return false;
    }

    const Atom pidAtom =
        XInternAtom(display, "_NET_WM_PID", True);

    if (pidAtom == None)
    {
        std::cerr << "_NET_WM_PID atom unavailable\n";
        XCloseDisplay(display);
        return false;
    }

    Atom actualType = None;
    int actualFormat = 0;
    unsigned long itemCount = 0;
    unsigned long bytesAfter = 0;
    unsigned char* data = nullptr;

    const int propertyResult =
        XGetWindowProperty(
            display,
            focused,
            pidAtom,
            0,
            1,
            False,
            XA_CARDINAL,
            &actualType,
            &actualFormat,
            &itemCount,
            &bytesAfter,
            &data
        );

    if (propertyResult != Success ||
        !data ||
        actualType != XA_CARDINAL ||
        actualFormat != 32 ||
        itemCount != 1)
    {
        std::cerr
            << "Focused window has no valid _NET_WM_PID\n";

        if (data)
            XFree(data);

        XCloseDisplay(display);
        return false;
    }

    const unsigned long rawPid =
        *reinterpret_cast<unsigned long*>(data);

    XFree(data);
    XCloseDisplay(display);

    const pid_t targetPid =
        static_cast<pid_t>(rawPid);

    if (targetPid <= 1 ||
        static_cast<unsigned long>(targetPid) != rawPid)
    {
        std::cerr
            << "Invalid DuckStation target PID "
            << rawPid
            << "\n";
        return false;
    }

    std::cout
        << "Sending SIGTERM to DuckStation AppRun PID "
        << targetPid
        << "\n";
    std::cout.flush();

    if (::kill(targetPid, SIGTERM) != 0)
    {
        std::cerr
            << "Failed to send SIGTERM to PID "
            << targetPid
            << "\n";
        return false;
    }

    std::cout << "SIGTERM sent\n";
    std::cout.flush();

    return true;
}
}

int main()
{
    // Only operate when started by BareFront's DuckStation launcher.
    const char* session =
        std::getenv("BAREFRONT_PS1_GUIDE_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr << "Not a BareFront DuckStation session\n";
        return 1;
    }

    // Disabled unless explicitly enabled by the test launcher.
    const char* discSetting =
        std::getenv("BAREFRONT_PS1_DISC_CONTROL");

    const char* probeSetting =
        std::getenv("BAREFRONT_PS1_DISC_PROBE");

    const bool discEnabled =
        discSetting && std::string(discSetting) == "1";

    const bool probe =
        probeSetting && std::string(probeSetting) == "1";

    if (probe && !discEnabled)
    {
        std::cerr << "Disc probe requires disc control enabled\n";
        return 1;
    }

    if (probe)
    {
        std::cout
            << "PROBE MODE: no keyboard events will be sent\n";
        std::cout.flush();
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
        << "DuckStation Guide helper active. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n"
        << "Quick Guide tap -> ignored\n"
        << "Guide hold: 1500 ms -> Exit\n";

    std::cout.flush();

    SDL_Event event;
    std::unordered_set<SDL_JoystickID> yHeld;
    Uint64 lastDiscAction = 0;
    bool hadDiscAction = false;

    constexpr Uint64 GUIDE_HOLD_MS = 1500;

    std::unordered_map<SDL_JoystickID, Uint64> guideStarted;
    std::unordered_set<SDL_JoystickID> guideFired;

    while (!stopRequested)
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

                if (requestDuckStationExit(probe))
                {
                    stopRequested = 1;
                    break;
                }
            }
        }

        if (stopRequested)
            break;

        // Wake periodically so Ctrl+C does not leave
        // the helper blocked waiting for controller input.
        if (!SDL_WaitEventTimeout(&event, 100))
            continue;

        if (event.type == SDL_QUIT)
            break;

        if (stopRequested)
            break;

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

        if (event.type == SDL_CONTROLLERBUTTONUP &&
            event.cbutton.button == SDL_CONTROLLER_BUTTON_Y)
        {
            yHeld.erase(event.cbutton.which);
            continue;
        }

        if (event.type == SDL_CONTROLLERDEVICEREMOVED)
        {
            yHeld.erase(event.cdevice.which);
            guideStarted.erase(event.cdevice.which);
            guideFired.erase(event.cdevice.which);
            continue;
        }

        if (event.type != SDL_CONTROLLERBUTTONDOWN)
            continue;

        // Ignore repeated Y-down events until the matching release.
        if (event.cbutton.button == SDL_CONTROLLER_BUTTON_Y &&
            !yHeld.insert(event.cbutton.which).second)
        {
            if (probe)
            {
                std::cout << "PROBE: Duplicate Y-down ignored\n";
                std::cout.flush();
            }
            continue;
        }

        // Hold LB + RB, then press Y to request
        // DuckStation's native Change Disc action.
        //
        // SDL observes these buttons; it does not consume
        // them. Gameplay interference must be tested.
        if (discEnabled &&
            event.cbutton.button == SDL_CONTROLLER_BUTTON_Y)
        {
            SDL_GameController* current =
                SDL_GameControllerFromInstanceID(
                    event.cbutton.which
                );

            const bool bothShoulders =
                current &&
                SDL_GameControllerGetButton(
                    current,
                    SDL_CONTROLLER_BUTTON_LEFTSHOULDER
                ) &&
                SDL_GameControllerGetButton(
                    current,
                    SDL_CONTROLLER_BUTTON_RIGHTSHOULDER
                );

            if (bothShoulders)
            {
                // Also suppress very rapid release/repress bounce.
                const Uint64 now = SDL_GetTicks64();

                if (hadDiscAction &&
                    now - lastDiscAction < 450)
                {
                    if (probe)
                    {
                        std::cout << "PROBE: Disc shortcut debounced\n";
                        std::cout.flush();
                    }
                    continue;
                }

                lastDiscAction = now;
                hadDiscAction = true;

                if (probe)
                {
                    std::cout
                        << "PROBE: LB+RB+Y detected; "
                        << "F5 NOT sent\n";
                    std::cout.flush();
                }
                else
                {
                    Display* discDisplay =
                        XOpenDisplay(nullptr);

                    if (!discDisplay)
                    {
                        std::cerr
                            << "Cannot open disc-control display\n";
                    }
                    else
                    {
                        Window focused;
                        int revert;

                        XGetInputFocus(
                            discDisplay,
                            &focused,
                            &revert
                        );

                        const KeyCode f5 =
                            XKeysymToKeycode(
                                discDisplay,
                                XK_F5
                            );

                        if (focused != None &&
                            focused != PointerRoot &&
                            f5)
                        {
                            std::cout
                                << "Sending F5 to DuckStation\n";
                            std::cout.flush();

                            XTestFakeKeyEvent(
                                discDisplay, f5, True, 0
                            );

                            XSync(
                                discDisplay, False
                            );

                            SDL_Delay(100);

                            XTestFakeKeyEvent(
                                discDisplay, f5, False, 0
                            );

                            XSync(
                                discDisplay, False
                            );
                        }
                        else
                        {
                            std::cerr
                                << "No focused disc-control target\n";
                        }

                        XCloseDisplay(discDisplay);
                    }
                }

                // One action per Y button-down event.
                continue;
            }
        }

        // The M7 Xbox controller reports its physical
        // Guide button as SDL misc1 (raw button 11).
        if (event.cbutton.button !=
            SDL_CONTROLLER_BUTTON_MISC1)
        {
            continue;
        }

        const SDL_JoystickID id =
            event.cbutton.which;

        if (!guideStarted.count(id))
        {
            guideStarted[id] = SDL_GetTicks64();
            guideFired.erase(id);

            std::cout << "Xbox Guide pressed\n";
            std::cout.flush();
        }

        // Exit is deliberately deferred until GUIDE_HOLD_MS.
        continue;

    }

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();

    return 0;
}
