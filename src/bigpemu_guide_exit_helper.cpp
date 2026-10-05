#include <SDL.h>

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <unistd.h>

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

        if (event.type == SDL_CONTROLLERBUTTONUP &&
            event.cbutton.button == SDL_CONTROLLER_BUTTON_MISC1) {
            const SDL_JoystickID id = event.cbutton.which;

            if (guideStarted.count(id) &&
                !guideFired.count(id)) {
                std::cout << "Quick Share tap ignored\n";
                std::cout.flush();
            }

            guideStarted.erase(id);
            guideFired.erase(id);
            continue;
        }

        if (event.type == SDL_CONTROLLERDEVICEREMOVED) {
            guideStarted.erase(event.cdevice.which);
            guideFired.erase(event.cdevice.which);
            continue;
        }

        if (event.type != SDL_CONTROLLERBUTTONDOWN)
            continue;

        if (event.cbutton.button !=
            SDL_CONTROLLER_BUTTON_MISC1)
            continue;

        const SDL_JoystickID id = event.cbutton.which;

        if (!guideStarted.count(id)) {
            guideStarted[id] = SDL_GetTicks64();
            guideFired.erase(id);

            std::cout << "Xbox Share pressed\n";
            std::cout.flush();
        }
    }

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();
    return 0;
}
