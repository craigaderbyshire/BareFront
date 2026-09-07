#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/shape.h>
#include <X11/extensions/Xrender.h>

#include <csignal>
#include <cstdint>
#include <iostream>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void handleSignal(int)
{
    running = 0;
}

static void fillRect(
    Display* display,
    Picture picture,
    const XRenderColor& colour,
    int x,
    int y,
    unsigned int width,
    unsigned int height)
{
    XRenderFillRectangle(
        display,
        PictOpSrc,
        picture,
        &colour,
        x,
        y,
        width,
        height
    );
}

int main()
{
    // Gamescope external overlays are NoScale.
    // Therefore this canvas matches the PRESENTATION OUTPUT,
    // not the 1280x720 Xwayland root.
    constexpr int WIDTH  = 1920;
    constexpr int HEIGHT = 1080;

    // Deliberately obvious centred 4:3 test opening.
    constexpr int OPEN_W = 1344;
    constexpr int OPEN_H = 1008;

    constexpr int OPEN_X = (WIDTH  - OPEN_W) / 2;
    constexpr int OPEN_Y = (HEIGHT - OPEN_H) / 2;

    constexpr int BORDER = 12;

    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);

    Display* display = XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr << "Unable to open X11 display.\n";
        return 1;
    }

    const int screen = DefaultScreen(display);
    Window root = RootWindow(display, screen);

    //
    // Find a genuine 32-bit ARGB visual.
    //
    XVisualInfo visualTemplate {};
    visualTemplate.screen = screen;

    int visualCount = 0;

    XVisualInfo* visuals =
        XGetVisualInfo(
            display,
            VisualScreenMask,
            &visualTemplate,
            &visualCount
        );

    if (!visuals)
    {
        std::cerr << "Unable to enumerate X11 visuals.\n";
        XCloseDisplay(display);
        return 1;
    }

    XVisualInfo* chosenVisual = nullptr;
    XRenderPictFormat* chosenFormat = nullptr;

    for (int i = 0; i < visualCount; ++i)
    {
        if (visuals[i].depth != 32)
            continue;

        XRenderPictFormat* format =
            XRenderFindVisualFormat(
                display,
                visuals[i].visual
            );

        if (!format)
            continue;

        if (format->type != PictTypeDirect)
            continue;

        if (format->direct.alphaMask == 0)
            continue;

        chosenVisual = &visuals[i];
        chosenFormat = format;
        break;
    }

    if (!chosenVisual || !chosenFormat)
    {
        std::cerr << "No 32-bit ARGB X11 visual found.\n";
        XFree(visuals);
        XCloseDisplay(display);
        return 1;
    }

    Colormap colormap =
        XCreateColormap(
            display,
            root,
            chosenVisual->visual,
            AllocNone
        );

    XSetWindowAttributes attributes {};
    attributes.colormap = colormap;
    attributes.border_pixel = 0;
    attributes.background_pixel = 0;
    attributes.override_redirect = True;
    attributes.event_mask =
        ExposureMask |
        StructureNotifyMask;

    Window window =
        XCreateWindow(
            display,
            root,
            0,
            0,
            WIDTH,
            HEIGHT,
            0,
            chosenVisual->depth,
            InputOutput,
            chosenVisual->visual,
            CWColormap |
            CWBorderPixel |
            CWBackPixel |
            CWOverrideRedirect |
            CWEventMask,
            &attributes
        );

    if (!window)
    {
        std::cerr << "Unable to create overlay window.\n";

        XFreeColormap(display, colormap);
        XFree(visuals);
        XCloseDisplay(display);

        return 1;
    }

    XStoreName(
        display,
        window,
        "BareFront Overlay Test V2"
    );

    //
    // Gamescope external-overlay tag.
    //
    Atom externalOverlay =
        XInternAtom(
            display,
            "GAMESCOPE_EXTERNAL_OVERLAY",
            False
        );

    unsigned long enabled = 1;

    XChangeProperty(
        display,
        window,
        externalOverlay,
        XA_CARDINAL,
        32,
        PropModeReplace,
        reinterpret_cast<unsigned char*>(&enabled),
        1
    );

    //
    // Keep the overall window fully enabled in Gamescope.
    // Per-pixel alpha provides the transparent opening.
    //
    Atom opacityAtom =
        XInternAtom(
            display,
            "_NET_WM_WINDOW_OPACITY",
            False
        );

    unsigned long fullOpacity = 0xffffffffUL;

    XChangeProperty(
        display,
        window,
        opacityAtom,
        XA_CARDINAL,
        32,
        PropModeReplace,
        reinterpret_cast<unsigned char*>(&fullOpacity),
        1
    );

    //
    // Never accept mouse input.
    //
    XserverRegion emptyInput =
        XFixesCreateRegion(
            display,
            nullptr,
            0
        );

    XFixesSetWindowShapeRegion(
        display,
        window,
        ShapeInput,
        0,
        0,
        emptyInput
    );

    XFixesDestroyRegion(
        display,
        emptyInput
    );

    XMapRaised(display, window);
    XSync(display, False);

    Picture picture =
        XRenderCreatePicture(
            display,
            window,
            chosenFormat,
            0,
            nullptr
        );

    //
    // Completely transparent background.
    //
    const XRenderColor transparent =
    {
        0x0000,
        0x0000,
        0x0000,
        0x0000
    };

    fillRect(
        display,
        picture,
        transparent,
        0,
        0,
        WIDTH,
        HEIGHT
    );

    //
    // Dark opaque surround.
    //
    const XRenderColor dark =
    {
        0x0800,
        0x0800,
        0x0800,
        0xffff
    };

    // Top
    fillRect(
        display,
        picture,
        dark,
        0,
        0,
        WIDTH,
        OPEN_Y
    );

    // Bottom
    fillRect(
        display,
        picture,
        dark,
        0,
        OPEN_Y + OPEN_H,
        WIDTH,
        HEIGHT - (OPEN_Y + OPEN_H)
    );

    // Left
    fillRect(
        display,
        picture,
        dark,
        0,
        OPEN_Y,
        OPEN_X,
        OPEN_H
    );

    // Right
    fillRect(
        display,
        picture,
        dark,
        OPEN_X + OPEN_W,
        OPEN_Y,
        WIDTH - (OPEN_X + OPEN_W),
        OPEN_H
    );

    //
    // Bright magenta proof border.
    //
    const XRenderColor magenta =
    {
        0xffff,
        0x0000,
        0xffff,
        0xffff
    };

    // Top
    fillRect(
        display,
        picture,
        magenta,
        OPEN_X - BORDER,
        OPEN_Y - BORDER,
        OPEN_W + (BORDER * 2),
        BORDER
    );

    // Bottom
    fillRect(
        display,
        picture,
        magenta,
        OPEN_X - BORDER,
        OPEN_Y + OPEN_H,
        OPEN_W + (BORDER * 2),
        BORDER
    );

    // Left
    fillRect(
        display,
        picture,
        magenta,
        OPEN_X - BORDER,
        OPEN_Y,
        BORDER,
        OPEN_H
    );

    // Right
    fillRect(
        display,
        picture,
        magenta,
        OPEN_X + OPEN_W,
        OPEN_Y,
        BORDER,
        OPEN_H
    );

    XSync(display, False);

    XWindowAttributes actual {};
    XGetWindowAttributes(
        display,
        window,
        &actual
    );

    std::cout
        << "BareFront overlay V2 running\n"
        << "Display: "
        << DisplayString(display)
        << "\n"
        << "Visual depth: "
        << chosenVisual->depth
        << "\n"
        << "Window requested: "
        << WIDTH
        << "x"
        << HEIGHT
        << "\n"
        << "Window actual: "
        << actual.width
        << "x"
        << actual.height
        << "\n"
        << "Opening: "
        << OPEN_W
        << "x"
        << OPEN_H
        << " at "
        << OPEN_X
        << ","
        << OPEN_Y
        << "\n";

    std::cout.flush();

    while (running)
    {
        while (XPending(display))
        {
            XEvent event {};
            XNextEvent(
                display,
                &event
            );
        }

        usleep(100000);
    }

    XRenderFreePicture(
        display,
        picture
    );

    XDestroyWindow(
        display,
        window
    );

    XFreeColormap(
        display,
        colormap
    );

    XFree(visuals);

    XCloseDisplay(display);

    return 0;
}
