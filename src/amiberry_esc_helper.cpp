#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XInput2.h>
#include <SDL.h>

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <algorithm>
#include <vector>
#include <unordered_map>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace
{

constexpr Uint64 GUIDE_HOLD_MS = 1500;

bool requestQuit(const std::string& socketPath)
{
    sockaddr_un address{};

    if (socketPath.size() >= sizeof(address.sun_path)) {
        std::cerr << "Amiberry IPC socket path is too long\n";
        return false;
    }

    const int socketFd =
        socket(AF_UNIX, SOCK_STREAM, 0);

    if (socketFd < 0) {
        perror("Unable to create Amiberry IPC socket");
        return false;
    }

    address.sun_family = AF_UNIX;
    std::memcpy(
        address.sun_path,
        socketPath.c_str(),
        socketPath.size() + 1
    );

    if (connect(
            socketFd,
            reinterpret_cast<sockaddr*>(&address),
            sizeof(address)
        ) != 0) {
        perror("Unable to connect to Amiberry IPC socket");
        close(socketFd);
        return false;
    }

    constexpr char command[] = "QUIT\n";

    const ssize_t sent =
        send(
            socketFd,
            command,
            sizeof(command) - 1,
            MSG_NOSIGNAL
        );

    close(socketFd);

    if (sent != static_cast<ssize_t>(sizeof(command) - 1)) {
        std::cerr << "Unable to send Amiberry IPC QUIT command\n";
        return false;
    }

    return true;
}

}

int main(int argc, char* argv[])
{
    if (argc != 3) {
        std::cerr
            << "Usage: amiberry_esc_helper <pid> <socket-path>\n";
        return 1;
    }

    char* end = nullptr;
    const long parsed =
        std::strtol(argv[1], &end, 10);

    if (!end || *end != '\0' || parsed <= 1) {
        std::cerr << "Invalid Amiberry PID\n";
        return 1;
    }

    const pid_t pid =
        static_cast<pid_t>(parsed);

    const std::string socketPath =
        argv[2];

    Display* display =
        XOpenDisplay(nullptr);

    if (!display) {
        std::cerr << "Unable to open X display\n";
        return 1;
    }

    int xiOpcode = 0;
    int xiEvent = 0;
    int xiError = 0;

    if (!XQueryExtension(
            display,
            "XInputExtension",
            &xiOpcode,
            &xiEvent,
            &xiError
        )) {
        std::cerr << "XInput2 is unavailable\n";
        XCloseDisplay(display);
        return 1;
    }

    unsigned char maskData[
        XIMaskLen(XI_LASTEVENT)
    ] = {};

    XIEventMask mask;
    mask.deviceid = XIAllMasterDevices;
    mask.mask_len = sizeof(maskData);
    mask.mask = maskData;

    XISetMask(mask.mask, XI_RawKeyPress);

    XISelectEvents(
        display,
        DefaultRootWindow(display),
        &mask,
        1
    );

    XFlush(display);

    // Preserve XInput2 keyboard Esc. SDL handles Xbox Guide
    // independently and uses the same Amiberry IPC QUIT path.
    if (SDL_Init(SDL_INIT_GAMECONTROLLER | SDL_INIT_EVENTS) != 0) {
        std::cerr << "SDL initialization failed: "
                  << SDL_GetError() << "\n";
        XCloseDisplay(display);
        return 1;
    }

    SDL_GameControllerEventState(SDL_ENABLE);

    std::vector<SDL_GameController*> controllers;
    std::unordered_map<SDL_JoystickID, Uint64> guideDownAt;

    auto openController = [&](int index) {
        if (!SDL_IsGameController(index)) {
            return;
        }

        const SDL_JoystickID instance =
            SDL_JoystickGetDeviceInstanceID(index);

        if (instance >= 0 &&
            SDL_GameControllerFromInstanceID(instance)) {
            return;
        }

        SDL_GameController* controller =
            SDL_GameControllerOpen(index);

        if (controller) {
            controllers.push_back(controller);

            std::cout
                << "Amiberry controller opened: "
                << SDL_GameControllerName(controller)
                << "\n";
        }
    };

    auto closeSDL = [&]() {
        for (SDL_GameController* controller : controllers) {
            SDL_GameControllerClose(controller);
        }

        controllers.clear();
        SDL_Quit();
    };

    for (int index = 0; index < SDL_NumJoysticks(); ++index) {
        openController(index);
    }

    std::cout << "Amiberry Guide helper active. DISPLAY="
              << (std::getenv("DISPLAY")
                      ? std::getenv("DISPLAY")
                      : "<unset>")
              << "\n";

    while (kill(pid, 0) == 0 || errno == EPERM) {
        SDL_Event sdlEvent;

        while (SDL_PollEvent(&sdlEvent)) {
            if (sdlEvent.type == SDL_QUIT) {
                std::cout
                    << "Amiberry Guide helper received SDL_QUIT\n";

                closeSDL();
                XCloseDisplay(display);
                return 0;
            }

            if (sdlEvent.type == SDL_CONTROLLERDEVICEADDED) {
                openController(sdlEvent.cdevice.which);
                continue;
            }

            if (sdlEvent.type == SDL_CONTROLLERDEVICEREMOVED) {
                guideDownAt.erase(sdlEvent.cdevice.which);

                SDL_GameController* removed =
                    SDL_GameControllerFromInstanceID(
                        sdlEvent.cdevice.which
                    );

                if (removed) {
                    controllers.erase(
                        std::remove(
                            controllers.begin(),
                            controllers.end(),
                            removed
                        ),
                        controllers.end()
                    );

                    SDL_GameControllerClose(removed);
                }

                continue;
            }

            // Physical Xbox-logo button on the M7 arrives
            // through SDL as MISC1.
            //
            // BareFront owns it exclusively:
            //   tap              -> no action
            //   hold >= 1500 ms  -> native Amiberry IPC QUIT
            if (sdlEvent.type == SDL_CONTROLLERBUTTONDOWN &&
                sdlEvent.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1) {

                const SDL_JoystickID instance =
                    sdlEvent.cbutton.which;

                if (guideDownAt.find(instance) ==
                    guideDownAt.end()) {

                    guideDownAt.emplace(
                        instance,
                        SDL_GetTicks64()
                    );

                    std::cout << "Xbox Guide down\n";
                }

                continue;
            }

            if (sdlEvent.type == SDL_CONTROLLERBUTTONUP &&
                sdlEvent.cbutton.button ==
                    SDL_CONTROLLER_BUTTON_MISC1) {

                const SDL_JoystickID instance =
                    sdlEvent.cbutton.which;

                const auto found =
                    guideDownAt.find(instance);

                if (found != guideDownAt.end()) {
                    const Uint64 elapsed =
                        SDL_GetTicks64() - found->second;

                    std::cout
                        << "Xbox Guide released after "
                        << elapsed
                        << " ms\n";

                    guideDownAt.erase(found);
                }

                continue;
            }
        }

        bool guideHoldReached = false;

        const Uint64 now =
            SDL_GetTicks64();

        for (const auto& entry : guideDownAt) {
            if (now - entry.second >= GUIDE_HOLD_MS) {
                guideHoldReached = true;
                break;
            }
        }

        if (guideHoldReached) {
            std::cout
                << "Xbox Guide hold detected after "
                << GUIDE_HOLD_MS
                << " ms\n";

            // Clear first so a failed QUIT cannot repeat every
            // loop while the physical button remains held.
            guideDownAt.clear();

            if (requestQuit(socketPath)) {
                std::cout
                    << "Amiberry IPC QUIT requested by Xbox Guide hold\n";

                closeSDL();
                XCloseDisplay(display);
                return 10;
            }
        }

        while (XPending(display)) {
            XEvent event;
            XNextEvent(display, &event);

            if (event.xcookie.type != GenericEvent ||
                event.xcookie.extension != xiOpcode) {
                continue;
            }

            if (!XGetEventData(display, &event.xcookie)) {
                continue;
            }

            bool quitRequested = false;

            if (event.xcookie.evtype == XI_RawKeyPress) {
                auto* rawEvent =
                    static_cast<XIRawEvent*>(
                        event.xcookie.data
                    );

                const KeySym key =
                    XkbKeycodeToKeysym(
                        display,
                        rawEvent->detail,
                        0,
                        0
                    );

                if (key == XK_Escape) {
                    quitRequested =
                        requestQuit(socketPath);
                }
            }

            XFreeEventData(display, &event.xcookie);

            if (quitRequested) {
                closeSDL();
                XCloseDisplay(display);
                return 10;
            }
        }

        usleep(10000);
    }

    closeSDL();
    XCloseDisplay(display);
    return 0;
}
