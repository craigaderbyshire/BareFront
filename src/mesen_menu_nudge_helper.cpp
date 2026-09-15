#include <X11/Xlib.h>

#include <iostream>
#include <unistd.h>

int main()
{
    // Mesen starts with AutoHideMenu enabled, but its menu remains
    // visible until the pointer enters the renderer. Give the window
    // time to appear, then generate one harmless pointer movement.
    usleep(1500000);

    Display* display = XOpenDisplay(nullptr);

    if (!display) {
        std::cerr << "Unable to open X display\n";
        return 1;
    }

    const int screen = DefaultScreen(display);
    Window root = RootWindow(display, screen);

    const int width = DisplayWidth(display, screen);
    const int height = DisplayHeight(display, screen);

    XWarpPointer(
        display,
        None,
        root,
        0, 0, 0, 0,
        1, 1
    );

    XSync(display, False);

    usleep(100000);

    XWarpPointer(
        display,
        None,
        root,
        0, 0, 0, 0,
        width / 2,
        height / 2
    );

    XSync(display, False);
    XCloseDisplay(display);

    return 0;
}
