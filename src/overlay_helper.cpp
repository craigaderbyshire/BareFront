#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/shape.h>
#include <X11/extensions/Xrender.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h>
#include "c64_mask_validator.h"

#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <unistd.h>


static volatile sig_atomic_t running = 1;


static void handleSignal(int)
{
    running = 0;
}


static void compositeArtwork(
    Display* display,
    Picture source,
    Picture destination,
    int width,
    int height)
{
    XRenderComposite(
        display,
        PictOpSrc,
        source,
        None,
        destination,
        0,
        0,
        0,
        0,
        0,
        0,
        width,
        height
    );
}


int main(
    int argc,
    char* argv[])
{
    constexpr int WIDTH = 1920;
    constexpr int HEIGHT = 1080;

    if (argc == 4 &&
        std::strcmp(argv[1], "--validate-c64") == 0)
    {
        return validateC64Mask(argv[2], argv[3]);
    }



    if (argc != 2)
    {
        std::cerr
            << "Usage: overlay_helper <overlay.png>\n";

        return 1;
    }


    const char* artworkPath =
        argv[1];


    std::signal(
        SIGINT,
        handleSignal
    );

    std::signal(
        SIGTERM,
        handleSignal
    );


    if (SDL_Init(0) != 0)
    {
        std::cerr
            << "SDL_Init failed: "
            << SDL_GetError()
            << "\n";

        return 1;
    }


    if ((IMG_Init(IMG_INIT_PNG) & IMG_INIT_PNG) == 0)
    {
        std::cerr
            << "SDL_image PNG support failed: "
            << IMG_GetError()
            << "\n";

        SDL_Quit();
        return 1;
    }


    SDL_Surface* loaded =
        IMG_Load(
            artworkPath
        );


    if (!loaded)
    {
        std::cerr
            << "Unable to load overlay artwork: "
            << artworkPath
            << ": "
            << IMG_GetError()
            << "\n";

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    if (
        loaded->w != WIDTH ||
        loaded->h != HEIGHT
    )
    {
        std::cerr
            << "Overlay artwork must be "
            << WIDTH
            << "x"
            << HEIGHT
            << ", got "
            << loaded->w
            << "x"
            << loaded->h
            << "\n";

        SDL_FreeSurface(
            loaded
        );

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    SDL_Surface* artwork =
        SDL_ConvertSurfaceFormat(
            loaded,
            SDL_PIXELFORMAT_ARGB8888,
            0
        );


    SDL_FreeSurface(
        loaded
    );


    if (!artwork)
    {
        std::cerr
            << "Unable to convert overlay artwork: "
            << SDL_GetError()
            << "\n";

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    //
    // XRender expects premultiplied ARGB.
    //
    if (SDL_MUSTLOCK(artwork))
    {
        if (SDL_LockSurface(artwork) != 0)
        {
            std::cerr
                << "Unable to lock overlay artwork: "
                << SDL_GetError()
                << "\n";

            SDL_FreeSurface(
                artwork
            );

            IMG_Quit();
            SDL_Quit();

            return 1;
        }
    }


    for (int y = 0; y < HEIGHT; ++y)
    {
        auto* row =
            reinterpret_cast<std::uint32_t*>(
                static_cast<unsigned char*>(artwork->pixels) +
                (y * artwork->pitch)
            );


        for (int x = 0; x < WIDTH; ++x)
        {
            const std::uint32_t pixel =
                row[x];


            const std::uint32_t alpha =
                (pixel >> 24) & 0xff;


            std::uint32_t red =
                (pixel >> 16) & 0xff;

            std::uint32_t green =
                (pixel >> 8) & 0xff;

            std::uint32_t blue =
                pixel & 0xff;


            red =
                (red * alpha + 127) / 255;

            green =
                (green * alpha + 127) / 255;

            blue =
                (blue * alpha + 127) / 255;


            row[x] =
                (alpha << 24) |
                (red << 16) |
                (green << 8) |
                blue;
        }
    }


    if (SDL_MUSTLOCK(artwork))
    {
        SDL_UnlockSurface(
            artwork
        );
    }


    Display* display =
        XOpenDisplay(
            nullptr
        );


    if (!display)
    {
        std::cerr
            << "Unable to open X11 display.\n";

        SDL_FreeSurface(
            artwork
        );

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    const int screen =
        DefaultScreen(
            display
        );


    Window root =
        RootWindow(
            display,
            screen
        );


    //
    // Find the same 32-bit ARGB visual already proven with
    // Gamescope's GAMESCOPE_EXTERNAL_OVERLAY path.
    //
    XVisualInfo visualTemplate {};
    visualTemplate.screen =
        screen;


    int visualCount =
        0;


    XVisualInfo* visuals =
        XGetVisualInfo(
            display,
            VisualScreenMask,
            &visualTemplate,
            &visualCount
        );


    if (!visuals)
    {
        std::cerr
            << "Unable to enumerate X11 visuals.\n";

        XCloseDisplay(
            display
        );

        SDL_FreeSurface(
            artwork
        );

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    XVisualInfo* chosenVisual =
        nullptr;

    XRenderPictFormat* chosenFormat =
        nullptr;


    for (int i = 0; i < visualCount; ++i)
    {
        if (visuals[i].depth != 32)
        {
            continue;
        }


        XRenderPictFormat* format =
            XRenderFindVisualFormat(
                display,
                visuals[i].visual
            );


        if (!format)
        {
            continue;
        }


        if (format->type != PictTypeDirect)
        {
            continue;
        }


        if (format->direct.alphaMask == 0)
        {
            continue;
        }


        chosenVisual =
            &visuals[i];

        chosenFormat =
            format;

        break;
    }


    if (
        !chosenVisual ||
        !chosenFormat
    )
    {
        std::cerr
            << "No 32-bit ARGB X11 visual found.\n";

        XFree(
            visuals
        );

        XCloseDisplay(
            display
        );

        SDL_FreeSurface(
            artwork
        );

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    //
    // The Gamescope Xwayland ARGB visual used by our proven
    // prototype has this standard AARRGGBB layout.
    //
    if (
        chosenFormat->direct.red != 16 ||
        chosenFormat->direct.green != 8 ||
        chosenFormat->direct.blue != 0 ||
        chosenFormat->direct.alpha != 24 ||
        chosenFormat->direct.redMask != 0xff ||
        chosenFormat->direct.greenMask != 0xff ||
        chosenFormat->direct.blueMask != 0xff ||
        chosenFormat->direct.alphaMask != 0xff
    )
    {
        std::cerr
            << "Unsupported X11 ARGB visual layout.\n";

        XFree(
            visuals
        );

        XCloseDisplay(
            display
        );

        SDL_FreeSurface(
            artwork
        );

        IMG_Quit();
        SDL_Quit();

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
    attributes.colormap =
        colormap;

    attributes.border_pixel =
        0;

    attributes.background_pixel =
        0;

    attributes.override_redirect =
        True;

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
        std::cerr
            << "Unable to create overlay window.\n";

        XFreeColormap(
            display,
            colormap
        );

        XFree(
            visuals
        );

        XCloseDisplay(
            display
        );

        SDL_FreeSurface(
            artwork
        );

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    XStoreName(
        display,
        window,
        "BareFront Presentation Overlay"
    );


    Atom externalOverlay =
        XInternAtom(
            display,
            "GAMESCOPE_EXTERNAL_OVERLAY",
            False
        );


    unsigned long enabled =
        1;


    XChangeProperty(
        display,
        window,
        externalOverlay,
        XA_CARDINAL,
        32,
        PropModeReplace,
        reinterpret_cast<unsigned char*>(
            &enabled
        ),
        1
    );


    Atom opacityAtom =
        XInternAtom(
            display,
            "_NET_WM_WINDOW_OPACITY",
            False
        );


    unsigned long fullOpacity =
        0xffffffffUL;


    XChangeProperty(
        display,
        window,
        opacityAtom,
        XA_CARDINAL,
        32,
        PropModeReplace,
        reinterpret_cast<unsigned char*>(
            &fullOpacity
        ),
        1
    );


    //
    // Overlay must never receive mouse input.
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


    Pixmap artworkPixmap =
        XCreatePixmap(
            display,
            root,
            WIDTH,
            HEIGHT,
            chosenVisual->depth
        );


    GC graphicsContext =
        XCreateGC(
            display,
            artworkPixmap,
            0,
            nullptr
        );


    const std::size_t imageBytes =
        static_cast<std::size_t>(
            artwork->pitch
        ) *
        HEIGHT;


    char* imageData =
        static_cast<char*>(
            std::malloc(
                imageBytes
            )
        );


    if (!imageData)
    {
        std::cerr
            << "Unable to allocate X11 overlay image.\n";

        XFreeGC(
            display,
            graphicsContext
        );

        XFreePixmap(
            display,
            artworkPixmap
        );

        XDestroyWindow(
            display,
            window
        );

        XFreeColormap(
            display,
            colormap
        );

        XFree(
            visuals
        );

        XCloseDisplay(
            display
        );

        SDL_FreeSurface(
            artwork
        );

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    std::memcpy(
        imageData,
        artwork->pixels,
        imageBytes
    );


    XImage* image =
        XCreateImage(
            display,
            chosenVisual->visual,
            chosenVisual->depth,
            ZPixmap,
            0,
            imageData,
            WIDTH,
            HEIGHT,
            32,
            artwork->pitch
        );


    if (!image)
    {
        std::cerr
            << "Unable to create X11 overlay image.\n";

        std::free(
            imageData
        );

        XFreeGC(
            display,
            graphicsContext
        );

        XFreePixmap(
            display,
            artworkPixmap
        );

        XDestroyWindow(
            display,
            window
        );

        XFreeColormap(
            display,
            colormap
        );

        XFree(
            visuals
        );

        XCloseDisplay(
            display
        );

        SDL_FreeSurface(
            artwork
        );

        IMG_Quit();
        SDL_Quit();

        return 1;
    }


    XPutImage(
        display,
        artworkPixmap,
        graphicsContext,
        image,
        0,
        0,
        0,
        0,
        WIDTH,
        HEIGHT
    );


    //
    // XDestroyImage also frees imageData.
    //
    XDestroyImage(
        image
    );


    XFreeGC(
        display,
        graphicsContext
    );


    SDL_FreeSurface(
        artwork
    );


    Picture artworkPicture =
        XRenderCreatePicture(
            display,
            artworkPixmap,
            chosenFormat,
            0,
            nullptr
        );


    Picture windowPicture =
        XRenderCreatePicture(
            display,
            window,
            chosenFormat,
            0,
            nullptr
        );


    // BareFront owns presentation while gameplay is active.
    // Hide the host X11 pointer so it cannot appear over the
    // nested Gamescope/emulator window.
    XFixesHideCursor(
        display,
        root
    );

    XFlush(
        display
    );


    XMapRaised(
        display,
        window
    );


    compositeArtwork(
        display,
        artworkPicture,
        windowPicture,
        WIDTH,
        HEIGHT
    );


    XSync(
        display,
        False
    );


    XWindowAttributes actual {};


    XGetWindowAttributes(
        display,
        window,
        &actual
    );


    std::cout
        << "BareFront presentation overlay running\n"
        << "Display: "
        << DisplayString(display)
        << "\n"
        << "Artwork: "
        << artworkPath
        << "\n"
        << "Window: "
        << actual.width
        << "x"
        << actual.height
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


            if (event.type == Expose)
            {
                compositeArtwork(
                    display,
                    artworkPicture,
                    windowPicture,
                    WIDTH,
                    HEIGHT
                );
            }
        }


        XFlush(
            display
        );


        usleep(
            100000
        );
    }


    XRenderFreePicture(
        display,
        windowPicture
    );


    XRenderFreePicture(
        display,
        artworkPicture
    );


    XFreePixmap(
        display,
        artworkPixmap
    );


    XDestroyWindow(
        display,
        window
    );


    XFreeColormap(
        display,
        colormap
    );


    XFree(
        visuals
    );


    // Restore the host pointer before returning control
    // to BareFront.
    XFixesShowCursor(
        display,
        root
    );

    XFlush(
        display
    );


    XCloseDisplay(
        display
    );


    IMG_Quit();
    SDL_Quit();

    return 0;
}
