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

bool sendKey(KeySym keysym, bool pressed)
{
    Display* display = XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr << "Cannot open SNES control display\n";
        return false;
    }

    const KeyCode key =
        XKeysymToKeycode(display, keysym);

    if (!key)
    {
        std::cerr << "SNES gameplay key unavailable\n";
        XCloseDisplay(display);
        return false;
    }

    XTestFakeKeyEvent(
        display,
        key,
        pressed ? True : False,
        CurrentTime
    );

    XSync(display, False);
    XCloseDisplay(display);

    return true;
}

bool sendEscape()
{
    Display* display = XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr << "Cannot open SNES control display\n";
        return false;
    }

    Window focused = None;
    int revert = 0;

    XGetInputFocus(display, &focused, &revert);

    if (focused == None || focused == PointerRoot)
    {
        std::cerr << "No focused SNES window\n";
        XCloseDisplay(display);
        return false;
    }

    const KeyCode key =
        XKeysymToKeycode(display, XK_Escape);

    if (!key)
    {
        std::cerr << "Escape key unavailable\n";
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

    std::cout << "Sent Escape to bsnes\n";
    std::cout.flush();

    return true;
}

}

int main()
{
    const char* session =
        std::getenv("BAREFRONT_SNES_CONTROL_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr
            << "Not a BareFront SNES control session\n";

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
        std::cerr << "No SDL game controller available\n";
        SDL_Quit();
        return 1;
    }

    constexpr Uint64 GUIDE_HOLD_MS = 1500;

    std::map<SDL_JoystickID, Uint64> guideStarted;
    std::set<SDL_JoystickID> guideFired;

    std::cout
        << "SNES controller helper active. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n"
        << "Quick Guide tap -> ignored\n"
        << "Guide hold: 1500 ms -> Exit\n";

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

            if (event.type == SDL_CONTROLLERBUTTONDOWN)
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                switch (event.cbutton.button)
                {
                    case SDL_CONTROLLER_BUTTON_DPAD_UP:
                        sendKey(XK_Up, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
                        sendKey(XK_Down, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_LEFT:
                        sendKey(XK_Left, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_RIGHT:
                        sendKey(XK_Right, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_A:
                        sendKey(XK_z, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_B:
                        sendKey(XK_x, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_X:
                        sendKey(XK_a, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_Y:
                        sendKey(XK_s, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
                        sendKey(XK_q, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:
                        sendKey(XK_w, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_BACK:
                        sendKey(XK_Tab, true);
                        break;

                    case SDL_CONTROLLER_BUTTON_START:
                        sendKey(XK_Return, true);
                        break;

                    default:
                        break;
                }

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
            }

            if (event.type == SDL_CONTROLLERBUTTONUP)
            {
                const SDL_JoystickID id =
                    event.cbutton.which;

                switch (event.cbutton.button)
                {
                    case SDL_CONTROLLER_BUTTON_DPAD_UP:
                        sendKey(XK_Up, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
                        sendKey(XK_Down, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_LEFT:
                        sendKey(XK_Left, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_DPAD_RIGHT:
                        sendKey(XK_Right, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_A:
                        sendKey(XK_z, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_B:
                        sendKey(XK_x, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_X:
                        sendKey(XK_a, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_Y:
                        sendKey(XK_s, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
                        sendKey(XK_q, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:
                        sendKey(XK_w, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_BACK:
                        sendKey(XK_Tab, false);
                        break;

                    case SDL_CONTROLLER_BUTTON_START:
                        sendKey(XK_Return, false);
                        break;

                    default:
                        break;
                }

                if (event.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1)
                {
                    guideStarted.erase(id);
                    guideFired.erase(id);
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
                    << "Guide hold detected\n";

                std::cout.flush();

                sendEscape();
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
