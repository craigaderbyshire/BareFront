#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

#include <cstring>
#include <iostream>
#include <string>
#include <vector>

static bool isDockWindow(
    Display* display,
    Window window)
{
    const Atom typeProperty =
        XInternAtom(
            display,
            "_NET_WM_WINDOW_TYPE",
            False
        );

    const Atom dockType =
        XInternAtom(
            display,
            "_NET_WM_WINDOW_TYPE_DOCK",
            False
        );

    Atom actualType {};
    int actualFormat = 0;
    unsigned long itemCount = 0;
    unsigned long bytesAfter = 0;
    unsigned char* data = nullptr;

    const int result =
        XGetWindowProperty(
            display,
            window,
            typeProperty,
            0,
            32,
            False,
            XA_ATOM,
            &actualType,
            &actualFormat,
            &itemCount,
            &bytesAfter,
            &data
        );

    bool isDock = false;

    if (result == Success &&
        actualType == XA_ATOM &&
        actualFormat == 32 &&
        data)
    {
        const Atom* atoms =
            reinterpret_cast<const Atom*>(data);

        for (unsigned long i = 0; i < itemCount; ++i)
        {
            if (atoms[i] == dockType)
            {
                isDock = true;
                break;
            }
        }
    }

    if (data)
        XFree(data);

    return isDock;
}


static void findPanelWindows(
    Display* display,
    Window parent,
    std::vector<Window>& panels)
{
    Window root {};
    Window parentReturn {};
    Window* children = nullptr;
    unsigned int childCount = 0;

    if (!XQueryTree(
            display,
            parent,
            &root,
            &parentReturn,
            &children,
            &childCount))
    {
        return;
    }

    for (unsigned int i = 0; i < childCount; ++i)
    {
        XClassHint hint {};

        if (XGetClassHint(display, children[i], &hint))
        {
            const bool isPanel =
                (hint.res_name &&
                 std::strcmp(hint.res_name, "xfce4-panel") == 0) ||
                (hint.res_class &&
                 std::strcmp(hint.res_class, "Xfce4-panel") == 0);

            if (hint.res_name)
                XFree(hint.res_name);

            if (hint.res_class)
                XFree(hint.res_class);

            if (isPanel &&
                isDockWindow(
                    display,
                    children[i]
                ))
            {
                panels.push_back(children[i]);
            }
        }

        findPanelWindows(
            display,
            children[i],
            panels
        );
    }

    if (children)
        XFree(children);
}


static Window findGamescopeWindow(
    Display* display,
    Window parent)
{
    Window root {};
    Window parentReturn {};
    Window* children = nullptr;
    unsigned int childCount = 0;

    if (!XQueryTree(
            display,
            parent,
            &root,
            &parentReturn,
            &children,
            &childCount))
    {
        return 0;
    }

    Window result = 0;

    for (unsigned int i = 0; i < childCount && !result; ++i)
    {
        XClassHint hint {};

        if (XGetClassHint(display, children[i], &hint))
        {
            const bool isGamescope =
                (hint.res_name &&
                 std::strcmp(hint.res_name, "gamescope") == 0) ||
                (hint.res_class &&
                 std::strcmp(hint.res_class, "gamescope") == 0);

            if (hint.res_name)
                XFree(hint.res_name);

            if (hint.res_class)
                XFree(hint.res_class);

            if (isGamescope)
            {
                result = children[i];
            }
        }

        if (!result)
        {
            result =
                findGamescopeWindow(
                    display,
                    children[i]
                );
        }
    }

    if (children)
        XFree(children);

    return result;
}


static int controlPanels(
    Display* display,
    Window root,
    bool show)
{
    std::vector<Window> panels;

    findPanelWindows(
        display,
        root,
        panels
    );

    for (Window window : panels)
    {
        if (show)
            XMapRaised(display, window);
        else
            XUnmapWindow(display, window);
    }

    XSync(display, False);

    std::cout
        << (show ? "show" : "hide")
        << ": "
        << panels.size()
        << " XFCE panel window(s)\n";

    return 0;
}


static int hideGamescopeCursor(
    Display* display,
    Window root)
{
    const Window target =
        findGamescopeWindow(
            display,
            root
        );

    if (!target)
    {
        std::cerr
            << "Gamescope window not found\n";
        return 2;
    }

    static const char emptyData[] = { 0 };

    const Pixmap empty =
        XCreateBitmapFromData(
            display,
            target,
            emptyData,
            1,
            1
        );

    XColor dummy {};

    const Cursor invisible =
        XCreatePixmapCursor(
            display,
            empty,
            empty,
            &dummy,
            &dummy,
            0,
            0
        );

    XDefineCursor(
        display,
        target,
        invisible
    );

    XSync(display, False);

    XFreeCursor(display, invisible);
    XFreePixmap(display, empty);

    std::cout
        << "Invisible cursor applied to Gamescope window\n";

    return 0;
}


int main(
    int argc,
    char** argv)
{
    if (argc != 2)
    {
        std::cerr
            << "Usage: c64_presentation_helper "
            << "hide-panels|show-panels|hide-cursor\n";
        return 1;
    }

    const std::string command = argv[1];

    Display* display =
        XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr
            << "Unable to open X display\n";
        return 1;
    }

    const Window root =
        RootWindow(
            display,
            DefaultScreen(display)
        );

    int result = 1;

    if (command == "hide-panels")
    {
        result =
            controlPanels(
                display,
                root,
                false
            );
    }
    else if (command == "show-panels")
    {
        result =
            controlPanels(
                display,
                root,
                true
            );
    }
    else if (command == "hide-cursor")
    {
        result =
            hideGamescopeCursor(
                display,
                root
            );
    }
    else
    {
        std::cerr
            << "Unknown command: "
            << command
            << "\n";
    }

    XCloseDisplay(display);

    return result;
}
