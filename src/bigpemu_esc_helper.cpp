#include <X11/Xlib.h>
#include <X11/keysym.h>

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <unistd.h>

int main(int argc, char* argv[])
{
    if (argc != 2) {
        std::cerr << "Usage: bigpemu_esc_helper <pid>\n";
        return 1;
    }

    char* end = nullptr;
    long parsed = std::strtol(argv[1], &end, 10);

    if (!end || *end != '\0' || parsed <= 1) {
        std::cerr << "Invalid BigPEmu PID\n";
        return 1;
    }

    const pid_t pid = static_cast<pid_t>(parsed);

    Display* display = XOpenDisplay(nullptr);
    if (!display) {
        std::cerr << "Unable to open X display\n";
        return 1;
    }

    Window root = DefaultRootWindow(display);
    KeyCode escape = XKeysymToKeycode(display, XK_Escape);

    const unsigned int modifiers[] = {
        0,
        LockMask,
        Mod2Mask,
        LockMask | Mod2Mask
    };

    for (unsigned int mod : modifiers) {
        XGrabKey(
            display,
            escape,
            mod,
            root,
            False,
            GrabModeAsync,
            GrabModeAsync
        );
    }

    XSync(display, False);

    while (kill(pid, 0) == 0 || errno == EPERM) {

        while (XPending(display)) {
            XEvent event;
            XNextEvent(display, &event);

            if (event.type == KeyPress &&
                event.xkey.keycode == escape) {

                if (kill(pid, SIGTERM) != 0 &&
                    errno != ESRCH) {
                    perror("Unable to terminate BigPEmu");
                    XCloseDisplay(display);
                    return 1;
                }

                XCloseDisplay(display);
                return 0;
            }
        }

        usleep(10000);
    }

    XCloseDisplay(display);
    return 0;
}
