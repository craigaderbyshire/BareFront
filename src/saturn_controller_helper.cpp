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
        std::cerr << "Cannot open Saturn control display\n";
        return false;
    }

    Window focused = None;
    int revert = 0;

    XGetInputFocus(display, &focused, &revert);

    if (focused == None || focused == PointerRoot)
    {
        std::cerr << "No focused Saturn window\n";
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

KeySym gameplayKeyForButton(Uint8 button)
{
    switch (button)
    {
        case SDL_CONTROLLER_BUTTON_DPAD_UP:
            return XK_Up;

        case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
            return XK_Down;

        case SDL_CONTROLLER_BUTTON_DPAD_LEFT:
            return XK_Left;

        case SDL_CONTROLLER_BUTTON_DPAD_RIGHT:
            return XK_Right;

        // Existing BareFront Saturn layout:
        // Xbox X -> Saturn A
        // Xbox A -> Saturn B
        // Xbox B -> Saturn C
        // Xbox Y -> Saturn X
        // LB     -> Saturn Y
        // RB     -> Saturn Z
        case SDL_CONTROLLER_BUTTON_X:
            return XK_z;

        case SDL_CONTROLLER_BUTTON_A:
            return XK_x;

        case SDL_CONTROLLER_BUTTON_B:
            return XK_c;

        case SDL_CONTROLLER_BUTTON_Y:
            return XK_a;

        case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
            return XK_s;

        case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:
            return XK_d;

        case SDL_CONTROLLER_BUTTON_START:
            return XK_Return;

        default:
            return NoSymbol;
    }
}

bool sendGameplayKey(KeySym symbol, bool pressed)
{
    Display* display = XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr << "Cannot open Saturn control display\n";
        return false;
    }

    Window focused = None;
    int revert = 0;

    XGetInputFocus(display, &focused, &revert);

    if (focused == None || focused == PointerRoot)
    {
        XCloseDisplay(display);
        return false;
    }

    const KeyCode key =
        XKeysymToKeycode(display, symbol);

    if (!key)
    {
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

void nextDisc()
{
    std::cout
        << "Saturn disc change: eject -> select next -> insert\n";

    std::cout.flush();

    if (!sendKey(XK_F8, "F8 eject"))
        return;

    SDL_Delay(400);

    if (!sendKey(XK_F6, "F6 select next disc"))
        return;

    SDL_Delay(400);

    sendKey(XK_F8, "F8 insert");
}
}

int main()
{
    const char* session =
        std::getenv("BAREFRONT_SATURN_CONTROL_SESSION");

    if (!session || std::string(session) != "1")
    {
        std::cerr
            << "Not a BareFront Saturn control session\n";

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
    std::set<SDL_JoystickID> leftTriggerHeld;
    std::set<SDL_JoystickID> rightTriggerHeld;

    Uint64 lastDiscAction = 0;
    bool hadDiscAction = false;

    std::cout
        << "Saturn controller helper active. DISPLAY="
        << (std::getenv("DISPLAY")
                ? std::getenv("DISPLAY")
                : "unset")
        << "\n"
        << "Quick Guide tap -> ignored\n"
        << "Guide hold: 1500 ms -> Exit\n"
        << "LB+RB+Y -> next Saturn disc\n";

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

                const KeySym gameplayKey =
                    gameplayKeyForButton(
                        event.cbutton.button
                    );

                if (gameplayKey != NoSymbol)
                {
                    sendGameplayKey(
                        gameplayKey,
                        true
                    );
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

                            nextDisc();
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

                const KeySym gameplayKey =
                    gameplayKeyForButton(
                        event.cbutton.button
                    );

                if (gameplayKey != NoSymbol)
                {
                    sendGameplayKey(
                        gameplayKey,
                        false
                    );
                }
            }

            if (event.type ==
                SDL_CONTROLLERAXISMOTION)
            {
                const SDL_JoystickID id =
                    event.caxis.which;

                constexpr Sint16 TRIGGER_THRESHOLD = 16000;

                if (event.caxis.axis ==
                    SDL_CONTROLLER_AXIS_TRIGGERLEFT)
                {
                    const bool pressed =
                        event.caxis.value >
                        TRIGGER_THRESHOLD;

                    const bool wasPressed =
                        leftTriggerHeld.count(id);

                    if (pressed && !wasPressed)
                    {
                        leftTriggerHeld.insert(id);
                        sendGameplayKey(XK_q, true);
                    }
                    else if (!pressed && wasPressed)
                    {
                        leftTriggerHeld.erase(id);
                        sendGameplayKey(XK_q, false);
                    }
                }

                if (event.caxis.axis ==
                    SDL_CONTROLLER_AXIS_TRIGGERRIGHT)
                {
                    const bool pressed =
                        event.caxis.value >
                        TRIGGER_THRESHOLD;

                    const bool wasPressed =
                        rightTriggerHeld.count(id);

                    if (pressed && !wasPressed)
                    {
                        rightTriggerHeld.insert(id);
                        sendGameplayKey(XK_e, true);
                    }
                    else if (!pressed && wasPressed)
                    {
                        rightTriggerHeld.erase(id);
                        sendGameplayKey(XK_e, false);
                    }
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

                leftTriggerHeld.erase(
                    event.cdevice.which
                );

                rightTriggerHeld.erase(
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

                sendKey(
                    XK_Escape,
                    "Escape to Mednafen"
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
