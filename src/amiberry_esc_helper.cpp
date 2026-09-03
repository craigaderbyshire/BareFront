#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XInput2.h>

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace
{

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

    while (kill(pid, 0) == 0 || errno == EPERM) {
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
                XCloseDisplay(display);
                return 0;
            }
        }

        usleep(10000);
    }

    XCloseDisplay(display);
    return 0;
}
