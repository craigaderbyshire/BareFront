#include <SDL.h>

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <utility>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <unistd.h>

static bool sendKey(KeySym keysym, bool pressed)
{
    Display* display = XOpenDisplay(nullptr);

    if (!display) {
        std::cerr << "Cannot open Jaguar control display\n";
        return false;
    }

    const KeyCode key =
        XKeysymToKeycode(display, keysym);

    if (!key) {
        std::cerr << "Jaguar gameplay key unavailable\n";
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

static KeySym gameplayKey(
    SDL_GameControllerButton button,
    bool leftTrigger)
{
    switch (button) {
        case SDL_CONTROLLER_BUTTON_DPAD_UP:
            return XK_Up;

        case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
            return XK_Down;

        case SDL_CONTROLLER_BUTTON_DPAD_LEFT:
            return XK_Left;

        case SDL_CONTROLLER_BUTTON_DPAD_RIGHT:
            return XK_Right;

        // Jaguar A / keypad 1
        case SDL_CONTROLLER_BUTTON_X:
            return leftTrigger ? XK_1 : XK_a;

        // Jaguar B / keypad 8
        case SDL_CONTROLLER_BUTTON_A:
            return leftTrigger ? XK_8 : XK_s;

        // Jaguar C / keypad 3
        case SDL_CONTROLLER_BUTTON_B:
            return leftTrigger ? XK_3 : XK_d;

        // Keypad 5 / keypad 2
        case SDL_CONTROLLER_BUTTON_Y:
            return leftTrigger ? XK_2 : XK_5;

        // Keypad 4 / keypad 7
        case SDL_CONTROLLER_BUTTON_LEFTSHOULDER:
            return leftTrigger ? XK_7 : XK_4;

        // Keypad 6 / keypad 9
        case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER:
            return leftTrigger ? XK_9 : XK_6;

        // Keypad *
        case SDL_CONTROLLER_BUTTON_LEFTSTICK:
            return XK_o;

        // Keypad # / keypad 0
        case SDL_CONTROLLER_BUTTON_RIGHTSTICK:
            return leftTrigger ? XK_0 : XK_p;

        // Jaguar Pause
        case SDL_CONTROLLER_BUTTON_BACK:
            return XK_q;

        // Jaguar Option
        case SDL_CONTROLLER_BUTTON_START:
            return XK_w;

        default:
            return NoSymbol;
    }
}

static bool isBigPEmu(pid_t pid)
{
    std::ifstream comm(
        "/proc/" + std::to_string(pid) + "/comm"
    );

    std::string name;
    return static_cast<bool>(std::getline(comm, name)) &&
           name == "BigPEmu";
}

int main(int argc, char* argv[])
{
    const char* session =
        std::getenv("BAREFRONT_JAGUAR_GUIDE_SESSION");

    if (!session || std::string(session) != "1") {
        std::cerr << "Not a BareFront Jaguar session\n";
        return 1;
    }

    if (argc != 2) {
        std::cerr << "Usage: bigpemu_guide_exit_helper <pid>\n";
        return 1;
    }

    errno = 0;
    char* end = nullptr;
    long parsed = std::strtol(argv[1], &end, 10);

    if (errno != 0 || !end || *end != '\0' ||
        parsed <= 1 ||
        parsed > std::numeric_limits<pid_t>::max()) {
        std::cerr << "Invalid BigPEmu PID\n";
        return 1;
    }

    const pid_t pid = static_cast<pid_t>(parsed);

    if (!isBigPEmu(pid)) {
        std::cerr << "Refusing non-BigPEmu PID\n";
        return 1;
    }

    if (SDL_Init(SDL_INIT_GAMECONTROLLER) != 0) {
        std::cerr << "SDL initialization failed: "
                  << SDL_GetError() << "\n";
        return 1;
    }

    std::vector<SDL_GameController*> controllers;

    for (int i = 0; i < SDL_NumJoysticks(); ++i) {
        if (!SDL_IsGameController(i))
            continue;

        SDL_GameController* controller =
            SDL_GameControllerOpen(i);

        if (controller) {
            controllers.push_back(controller);

            std::cout << "Controller: "
                      << SDL_GameControllerName(controller)
                      << "\n";
        }
    }

    std::cout << "Jaguar Share helper active. PID="
              << pid << "\n"
              << "Quick Share tap -> ignored\n"
              << "Share hold: 1500 ms -> Exit\n";
    std::cout.flush();

    constexpr Uint64 GUIDE_HOLD_MS = 1500;

    std::unordered_map<SDL_JoystickID, Uint64> guideStarted;
    std::unordered_set<SDL_JoystickID> guideFired;

    std::map<
        std::pair<SDL_JoystickID, Uint8>,
        KeySym
    > activeKeys;

    SDL_Event event;

    while (isBigPEmu(pid)) {
        const Uint64 now = SDL_GetTicks64();
        bool exitRequested = false;

        for (const auto& guide : guideStarted) {
            if (!guideFired.count(guide.first) &&
                now - guide.second >= GUIDE_HOLD_MS) {
                guideFired.insert(guide.first);

                std::cout << "Share hold detected\n";
                std::cout.flush();

                // Never signal a PID that has ceased to be BigPEmu.
                if (!isBigPEmu(pid)) {
                    exitRequested = true;
                    break;
                }

                std::cout << "Sending SIGTERM to BigPEmu\n";
                std::cout.flush();

                if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
                    perror("Unable to terminate BigPEmu");

                    for (auto* controller : controllers)
                        SDL_GameControllerClose(controller);

                    SDL_Quit();
                    return 1;
                }

                std::cout << "SIGTERM sent\n";
                std::cout.flush();

                exitRequested = true;
                break;
            }
        }

        if (exitRequested)
            break;

        if (!SDL_WaitEventTimeout(&event, 100))
            continue;

        // SDL may translate launcher termination into SDL_QUIT.
        if (event.type == SDL_QUIT) {
            std::cout << "Jaguar Share helper quitting\n";
            std::cout.flush();
            break;
        }

        if (event.type == SDL_CONTROLLERBUTTONUP) {
            const SDL_JoystickID id =
                event.cbutton.which;

            const auto activeKey =
                std::make_pair(
                    id,
                    event.cbutton.button
                );

            const auto active =
                activeKeys.find(activeKey);

            if (active != activeKeys.end()) {
                sendKey(active->second, false);
                activeKeys.erase(active);
            }

            if (event.cbutton.button ==
                SDL_CONTROLLER_BUTTON_MISC1) {

                if (guideStarted.count(id) &&
                    !guideFired.count(id)) {
                    std::cout
                        << "Quick Share tap ignored\n";
                    std::cout.flush();
                }

                guideStarted.erase(id);
                guideFired.erase(id);
            }

            continue;
        }

        if (event.type == SDL_CONTROLLERDEVICEREMOVED) {
            const SDL_JoystickID id =
                event.cdevice.which;

            guideStarted.erase(id);
            guideFired.erase(id);

            for (auto it = activeKeys.begin();
                 it != activeKeys.end();) {
                if (it->first.first == id) {
                    sendKey(it->second, false);
                    it = activeKeys.erase(it);
                } else {
                    ++it;
                }
            }

            continue;
        }

        if (event.type != SDL_CONTROLLERBUTTONDOWN)
            continue;

        const SDL_JoystickID id =
            event.cbutton.which;

        SDL_GameController* eventController =
            SDL_GameControllerFromInstanceID(id);

        bool leftTrigger = false;

        if (eventController) {
            leftTrigger =
                SDL_GameControllerGetAxis(
                    eventController,
                    SDL_CONTROLLER_AXIS_TRIGGERLEFT
                ) > 16000;
        }

        const KeySym key =
            gameplayKey(
                static_cast<SDL_GameControllerButton>(
                    event.cbutton.button
                ),
                leftTrigger
            );

        if (key != NoSymbol) {
            const auto activeKey =
                std::make_pair(
                    id,
                    event.cbutton.button
                );

            if (!activeKeys.count(activeKey)) {
                if (sendKey(key, true))
                    activeKeys[activeKey] = key;
            }
        }

        if (event.cbutton.button !=
            SDL_CONTROLLER_BUTTON_MISC1)
            continue;

        if (!guideStarted.count(id)) {
            guideStarted[id] = SDL_GetTicks64();
            guideFired.erase(id);

            std::cout << "Xbox Share pressed\n";
            std::cout.flush();
        }
    }

    for (const auto& active : activeKeys)
        sendKey(active.second, false);

    activeKeys.clear();

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();
    return 0;
}
