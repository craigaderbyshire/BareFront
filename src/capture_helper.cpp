#include <SDL2/SDL.h>

#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <X11/extensions/XInput2.h>

#include <algorithm>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;


// --------------------------------------------------
// BareFront capture helper
//
// Runs only while an emulator is open.
//
// Keyboard:
//   P = picture
//   R = five-second recording
//
// Controller:
//   VIEW + Left  = picture
//   VIEW + Right = five-second recording
//
// The helper captures the currently active X11 window,
// detects solid black presentation bars around the game,
// and scales the remaining picture to fit within the
// requested preview size WITHOUT changing its aspect ratio.
//
// Typical limits:
//   240p-era systems : 320x240
//   480-line systems : 640x480
//
// Portrait sources remain portrait. Widescreen sources
// remain widescreen. Nothing is stretched to 4:3.
// --------------------------------------------------

volatile std::sig_atomic_t keepRunning = 1;


void handleSignal(int)
{
    keepRunning = 0;
}


struct CaptureRect
{
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
};


// --------------------------------------------------
// Find the currently active X11 window.
// --------------------------------------------------

bool getActiveWindowRect(
    Display* display,
    Window& captureWindow,
    CaptureRect& rect)
{
    if (!display)
        return false;


    Window root =
        DefaultRootWindow(display);

    Window active =
        None;


    Atom activeWindowAtom =
        XInternAtom(
            display,
            "_NET_ACTIVE_WINDOW",
            True
        );


    if (activeWindowAtom != None)
    {
        Atom actualType;
        int actualFormat = 0;
        unsigned long itemCount = 0;
        unsigned long bytesAfter = 0;
        unsigned char* data = nullptr;


        int status =
            XGetWindowProperty(
                display,
                root,
                activeWindowAtom,
                0,
                1,
                False,
                AnyPropertyType,
                &actualType,
                &actualFormat,
                &itemCount,
                &bytesAfter,
                &data
            );


        if (status == Success &&
            data &&
            itemCount == 1)
        {
            active =
                *reinterpret_cast<Window*>(data);
        }


        if (data)
        {
            XFree(data);
        }
    }


    // Fallback for a WM that does not expose _NET_ACTIVE_WINDOW.
    if (active == None)
    {
        int revertTo = 0;

        XGetInputFocus(
            display,
            &active,
            &revertTo
        );
    }


    if (active == None ||
        active == PointerRoot)
    {
        active =
            root;
    }


    XWindowAttributes attributes;

    if (!XGetWindowAttributes(
            display,
            active,
            &attributes))
    {
        return false;
    }


    // Capture coordinates are relative to this window.
    captureWindow =
        active;

    rect.x =
        0;

    rect.y =
        0;

    rect.w =
        attributes.width;

    rect.h =
        attributes.height;


    return rect.w > 0 &&
           rect.h > 0;
}


// --------------------------------------------------
// Work with X11 pixels.
//
// Used only when a capture is requested, so this small
// amount of sampling has no effect on normal gameplay.
// --------------------------------------------------

int maskShift(
    unsigned long mask)
{
    int shift = 0;

    if (mask == 0)
        return 0;

    while ((mask & 1UL) == 0)
    {
        mask >>= 1;
        ++shift;
    }

    return shift;
}


unsigned long maskMaximum(
    unsigned long mask)
{
    if (mask == 0)
        return 1;

    int shift =
        maskShift(mask);

    return
        mask >>
        shift;
}


int pixelChannel(
    unsigned long pixel,
    unsigned long mask)
{
    if (mask == 0)
        return 0;

    int shift =
        maskShift(mask);

    unsigned long maximum =
        maskMaximum(mask);

    unsigned long value =
        (pixel & mask) >>
        shift;

    return static_cast<int>(
        (value * 255UL) /
        maximum
    );
}


bool pixelIsBlack(
    XImage* image,
    int x,
    int y)
{
    unsigned long pixel =
        XGetPixel(
            image,
            x,
            y
        );

    const int red =
        pixelChannel(
            pixel,
            image->red_mask
        );

    const int green =
        pixelChannel(
            pixel,
            image->green_mask
        );

    const int blue =
        pixelChannel(
            pixel,
            image->blue_mask
        );

    // Presentation bars are normally true black.
    // Keep this threshold deliberately low so dark game
    // artwork is not mistaken for a border.
    const int threshold =
        10;

    return
        red <= threshold &&
        green <= threshold &&
        blue <= threshold;
}


// --------------------------------------------------
// Decide whether a sampled row/column is effectively
// a solid black presentation bar.
//
// We sample rather than inspect every pixel to keep this
// cheap even on a 4K desktop.
// --------------------------------------------------

bool columnIsBlack(
    XImage* image,
    int x)
{
    const int sampleStep =
        std::max(
            2,
            image->height / 180
        );

    int samples = 0;
    int blackSamples = 0;

    for (int y = 0;
         y < image->height;
         y += sampleStep)
    {
        ++samples;

        if (pixelIsBlack(
                image,
                x,
                y))
        {
            ++blackSamples;
        }
    }

    return
        samples > 0 &&
        blackSamples * 100 >=
            samples * 99;
}


bool rowIsBlack(
    XImage* image,
    int y)
{
    const int sampleStep =
        std::max(
            2,
            image->width / 240
        );

    int samples = 0;
    int blackSamples = 0;

    for (int x = 0;
         x < image->width;
         x += sampleStep)
    {
        ++samples;

        if (pixelIsBlack(
                image,
                x,
                y))
        {
            ++blackSamples;
        }
    }

    return
        samples > 0 &&
        blackSamples * 100 >=
            samples * 99;
}


// --------------------------------------------------
// Remove only OUTER solid-black presentation bars.
//
// This is what lets one capture path handle:
//
//   4:3 game on a 16:9 fullscreen desktop
//   widescreen GameCube/PS2
//   vertical/TATE arcade games
//
// The actual game image is never forced to 4:3.
//
// Safety limits stop a dark game scene being cropped
// aggressively by mistake.
// --------------------------------------------------

CaptureRect detectGameContentRect(
    Display* display,
    Window captureWindow,
    const CaptureRect& windowRect)
{
    CaptureRect result =
        windowRect;

    if (!display)
        return result;


    // Gamescope's nested Xwayland server can reject a root-window
    // XGetImage request. Trap that X11 error and retain the full
    // active-window rectangle instead of terminating the helper.
    static bool imageGrabFailed =
        false;

    imageGrabFailed =
        false;


    // Flush earlier requests so the temporary handler applies only
    // to this image grab.
    XSync(
        display,
        False
    );


    XErrorHandler previousErrorHandler =
        XSetErrorHandler(
            [](Display*, XErrorEvent*)
            {
                imageGrabFailed =
                    true;

                return 0;
            }
        );


    XImage* image =
        XGetImage(
            display,
            captureWindow,
            windowRect.x,
            windowRect.y,
            static_cast<unsigned int>(
                windowRect.w
            ),
            static_cast<unsigned int>(
                windowRect.h
            ),
            AllPlanes,
            ZPixmap
        );


    XSync(
        display,
        False
    );


    XSetErrorHandler(
        previousErrorHandler
    );


    if (imageGrabFailed ||
        !image)
    {
        if (image)
        {
            XDestroyImage(
                image
            );
        }

        return result;
    }


    int left = 0;
    int right =
        image->width - 1;

    int top = 0;
    int bottom =
        image->height - 1;


    // Step inward in small groups so a single unusual
    // row/column does not stop border detection.
    const int xStep =
        std::max(
            1,
            image->width / 640
        );

    const int yStep =
        std::max(
            1,
            image->height / 480
        );


    while (left < right &&
           columnIsBlack(
               image,
               left))
    {
        left +=
            xStep;
    }


    while (right > left &&
           columnIsBlack(
               image,
               right))
    {
        right -=
            xStep;
    }


    while (top < bottom &&
           rowIsBlack(
               image,
               top))
    {
        top +=
            yStep;
    }


    while (bottom > top &&
           rowIsBlack(
               image,
               bottom))
    {
        bottom -=
            yStep;
    }


    XDestroyImage(
        image
    );


    int detectedWidth =
        right - left + 1;

    int detectedHeight =
        bottom - top + 1;


    // Do not accept an almost-empty result.
    // Portrait/TATE games can legitimately use much less
    // than half of a widescreen desktop, so keep this limit
    // deliberately permissive.
    if (detectedWidth <
            windowRect.w / 5 ||
        detectedHeight <
            windowRect.h / 5)
    {
        return result;
    }


    int leftBar =
        left;

    int rightBar =
        windowRect.w - 1 - right;

    int topBar =
        top;

    int bottomBar =
        windowRect.h - 1 - bottom;


    // Real fullscreen presentation bars are normally
    // approximately symmetrical. If only one side looks
    // black, it is more likely to be dark game artwork than
    // an actual border, so keep that axis untouched.
    const int horizontalTolerance =
        std::max(
            16,
            windowRect.w / 20
        );

    const int verticalTolerance =
        std::max(
            16,
            windowRect.h / 20
        );


    if (std::abs(
            leftBar - rightBar) >
        horizontalTolerance)
    {
        left = 0;
        right =
            windowRect.w - 1;

        leftBar = 0;
        rightBar = 0;
    }


    if (std::abs(
            topBar - bottomBar) >
        verticalTolerance)
    {
        top = 0;
        bottom =
            windowRect.h - 1;

        topBar = 0;
        bottomBar = 0;
    }


    // Ignore tiny edge trims. We only want genuine
    // presentation bars, not a handful of dark pixels.
    const int minHorizontalBar =
        std::max(
            8,
            windowRect.w / 100
        );

    const int minVerticalBar =
        std::max(
            8,
            windowRect.h / 100
        );


    if (leftBar < minHorizontalBar &&
        rightBar <
            minHorizontalBar)
    {
        left = 0;
        right =
            windowRect.w - 1;
    }


    if (topBar < minVerticalBar &&
        bottomBar <
            minVerticalBar)
    {
        top = 0;
        bottom =
            windowRect.h - 1;
    }


    result.x =
        windowRect.x +
        left;

    result.y =
        windowRect.y +
        top;

    result.w =
        right - left + 1;

    result.h =
        bottom - top + 1;


    // FFmpeg/H.264 prefer even sizes.
    result.w -=
        result.w % 2;

    result.h -=
        result.h % 2;


    if (result.w <= 0 ||
        result.h <= 0)
    {
        return windowRect;
    }


    return result;
}


// --------------------------------------------------
// Scale to FIT inside the system's preview limit.
//
// There is deliberately NO crop and NO pad here.
// The stored media keeps its natural orientation:
//
//   4:3      -> 320x240 (or 640x480)
//   16:9     -> 320x180 (or 640x360)
//   portrait -> about 180x240 (or 360x480)
//
// This also makes portrait arcade previews easy to detect
// later when BareFront rotates the CRT into TATE mode.
// --------------------------------------------------

std::string makeVideoFilter(
    int maxWidth,
    int maxHeight)
{
    return
        "scale=" +
        std::to_string(maxWidth) +
        ":" +
        std::to_string(maxHeight) +
        ":force_original_aspect_ratio=decrease"
        ":force_divisible_by=2"
        ":flags=lanczos,"
        "setsar=1";
}


// --------------------------------------------------
// Run FFmpeg for one still image.
// --------------------------------------------------

void takeSnapshot(
    Display* display,
    const fs::path& outputPath,
    int maxWidth,
    int maxHeight)
{
    CaptureRect rect;

    Window captureWindow =
        None;


    if (!getActiveWindowRect(
            display,
            captureWindow,
            rect))
    {
        std::cerr
            << "BareFront capture: could not locate active window.\n";

        return;
    }


    rect =
        detectGameContentRect(
            display,
            captureWindow,
            rect
        );


    fs::create_directories(
        outputPath.parent_path()
    );


    std::string size =
        std::to_string(rect.w) +
        "x" +
        std::to_string(rect.h);


    std::string windowId =
        std::to_string(
            static_cast<unsigned long long>(
                captureWindow
            )
        );


    const char* displayEnvironment =
        std::getenv("DISPLAY");

    std::string displayName =
        displayEnvironment
            ? displayEnvironment
            : ":0";


    std::string input =
        displayName +
        "+" +
        std::to_string(rect.x) +
        "," +
        std::to_string(rect.y);


    std::string filter =
        makeVideoFilter(
            maxWidth,
            maxHeight
        );


    pid_t pid =
        fork();


    if (pid == 0)
    {
        execlp(
            "ffmpeg",
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "x11grab",
            "-window_id",
            windowId.c_str(),
            "-video_size",
            size.c_str(),
            "-draw_mouse",
            "0",
            "-i",
            input.c_str(),
            "-frames:v",
            "1",
            "-vf",
            filter.c_str(),
            outputPath.c_str(),
            static_cast<char*>(nullptr)
        );

        _exit(127);
    }


    if (pid > 0)
    {
        int status = 0;

        waitpid(
            pid,
            &status,
            0
        );


        if (WIFEXITED(status) &&
            WEXITSTATUS(status) == 0)
        {
            std::cout
                << "Snapshot saved: "
                << outputPath
                << "\n";
        }
        else
        {
            std::cerr
                << "BareFront snapshot failed. Is ffmpeg installed?\n";
        }
    }
}


// --------------------------------------------------
// Start one five-second silent MP4 capture.
//
// Returns the FFmpeg child PID so the helper can keep
// listening to input while the recording is happening.
// --------------------------------------------------

pid_t startRecording(
    Display* display,
    const fs::path& outputPath,
    int maxWidth,
    int maxHeight)
{
    CaptureRect rect;

    Window captureWindow =
        None;


    if (!getActiveWindowRect(
            display,
            captureWindow,
            rect))
    {
        std::cerr
            << "BareFront capture: could not locate active window.\n";

        return -1;
    }


    const CaptureRect windowRect =
        rect;

    rect =
        detectGameContentRect(
            display,
            captureWindow,
            rect
        );


    fs::create_directories(
        outputPath.parent_path()
    );


    const char* gamescopeCaptureEnvironment =
        std::getenv(
            "BAREFRONT_GAMESCOPE_CAPTURE"
        );


    if (gamescopeCaptureEnvironment &&
        std::string(
            gamescopeCaptureEnvironment
        ) == "1")
    {
        fs::path recorderPath =
            "scripts/capture_gamescope_video.sh";


        if (access(
                recorderPath.c_str(),
                X_OK) != 0)
        {
            std::cerr
                << "BareFront recording script is unavailable: "
                << recorderPath
                << "\n";

            return -1;
        }


        int outputWidth =
            maxWidth;

        int outputHeight =
            static_cast<int>(
                (
                    static_cast<long long>(
                        rect.h
                    ) *
                    maxWidth
                ) /
                rect.w
            );


        if (outputHeight > maxHeight)
        {
            outputHeight =
                maxHeight;

            outputWidth =
                static_cast<int>(
                    (
                        static_cast<long long>(
                            rect.w
                        ) *
                        maxHeight
                    ) /
                    rect.h
                );
        }


        outputWidth =
            std::max(
                2,
                outputWidth -
                    outputWidth % 2
            );

        outputHeight =
            std::max(
                2,
                outputHeight -
                    outputHeight % 2
            );


        std::string sourceWidth =
            std::to_string(
                windowRect.w
            );

        std::string sourceHeight =
            std::to_string(
                windowRect.h
            );

        std::string cropX =
            std::to_string(
                rect.x
            );

        std::string cropY =
            std::to_string(
                rect.y
            );

        std::string cropWidth =
            std::to_string(
                rect.w
            );

        std::string cropHeight =
            std::to_string(
                rect.h
            );

        std::string scaledWidth =
            std::to_string(
                outputWidth
            );

        std::string scaledHeight =
            std::to_string(
                outputHeight
            );


        pid_t gamescopePid =
            fork();


        if (gamescopePid == 0)
        {
            execl(
                recorderPath.c_str(),
                recorderPath.c_str(),
                outputPath.c_str(),
                sourceWidth.c_str(),
                sourceHeight.c_str(),
                cropX.c_str(),
                cropY.c_str(),
                cropWidth.c_str(),
                cropHeight.c_str(),
                scaledWidth.c_str(),
                scaledHeight.c_str(),
                static_cast<char*>(
                    nullptr
                )
            );

            _exit(127);
        }


        if (gamescopePid > 0)
        {
            std::cout
                << "Recording 5 seconds through Gamescope: "
                << outputPath
                << "\n";
        }


        return gamescopePid;
    }


    std::string size =
        std::to_string(rect.w) +
        "x" +
        std::to_string(rect.h);


    std::string windowId =
        std::to_string(
            static_cast<unsigned long long>(
                captureWindow
            )
        );


    const char* displayEnvironment =
        std::getenv("DISPLAY");

    std::string displayName =
        displayEnvironment
            ? displayEnvironment
            : ":0";


    std::string input =
        displayName +
        "+" +
        std::to_string(rect.x) +
        "," +
        std::to_string(rect.y);


    std::string filter =
        makeVideoFilter(
            maxWidth,
            maxHeight
        );


    pid_t pid =
        fork();


    if (pid == 0)
    {
        execlp(
            "ffmpeg",
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "x11grab",
            "-window_id",
            windowId.c_str(),
            "-framerate",
            "30",
            "-video_size",
            size.c_str(),
            "-draw_mouse",
            "0",
            "-i",
            input.c_str(),
            "-t",
            "5",
            "-an",
            "-vf",
            filter.c_str(),
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
            outputPath.c_str(),
            static_cast<char*>(nullptr)
        );

        _exit(127);
    }


    if (pid > 0)
    {
        std::cout
            << "Recording 5 seconds: "
            << outputPath
            << "\n";
    }


    return pid;
}


// --------------------------------------------------
// Open every SDL GameController currently connected.
// SDL filters out VirtualBox mouse/tablet devices here.
// --------------------------------------------------

void openControllers(
    std::vector<SDL_GameController*>& controllers)
{
    for (int index = 0;
         index < SDL_NumJoysticks();
         ++index)
    {
        if (!SDL_IsGameController(index))
        {
            continue;
        }


        SDL_GameController* controller =
            SDL_GameControllerOpen(index);


        if (controller)
        {
            controllers.push_back(
                controller
            );
        }
    }
}


int main(
    int argc,
    char* argv[])
{
    if (argc != 5)
    {
        std::cerr
            << "Usage: capture_helper <screenshot.png> <video.mp4> "
            << "<max-width> <max-height>\n";

        return 1;
    }


    fs::path screenshotPath =
        argv[1];

    fs::path videoPath =
        argv[2];


    int maxWidth =
        std::max(
            2,
            std::atoi(argv[3])
        );

    int maxHeight =
        std::max(
            2,
            std::atoi(argv[4])
        );


    // Keep video dimensions friendly to H.264.
    maxWidth -=
        maxWidth % 2;

    maxHeight -=
        maxHeight % 2;


    std::signal(
        SIGTERM,
        handleSignal
    );

    std::signal(
        SIGINT,
        handleSignal
    );


    Display* display =
        XOpenDisplay(nullptr);


    if (!display)
    {
        std::cerr
            << "BareFront capture helper: X11 display unavailable.\n";

        return 1;
    }


    // --------------------------------------------------
    // Global keyboard P/R using XInput2 raw key events.
    // --------------------------------------------------

    int xiOpcode = 0;
    int xiEvent = 0;
    int xiError = 0;


    bool xInputAvailable =
        XQueryExtension(
            display,
            "XInputExtension",
            &xiOpcode,
            &xiEvent,
            &xiError
        );


    if (xInputAvailable)
    {
        unsigned char maskData[
            XIMaskLen(XI_LASTEVENT)
        ] = {};


        XIEventMask mask;
        mask.deviceid =
            XIAllMasterDevices;

        mask.mask_len =
            sizeof(maskData);

        mask.mask =
            maskData;


        XISetMask(
            mask.mask,
            XI_RawKeyPress
        );


        XISelectEvents(
            display,
            DefaultRootWindow(display),
            &mask,
            1
        );


        XFlush(display);
    }


    // XInput2 raw key events are not always forwarded by
    // nested Xwayland compositors such as Gamescope.
    //
    // Keep the raw-event path above and also track the current
    // P/R key state as a non-grabbing fallback.
    KeyCode pictureKeycode =
        XKeysymToKeycode(
            display,
            XK_p
        );

    KeyCode recordKeycode =
        XKeysymToKeycode(
            display,
            XK_r
        );

    bool pictureKeyWasDown =
        false;

    bool recordKeyWasDown =
        false;


    // --------------------------------------------------
    // Background gamepad events.
    // --------------------------------------------------

    SDL_SetHint(
        SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS,
        "1"
    );


    if (SDL_Init(
            SDL_INIT_GAMECONTROLLER |
            SDL_INIT_EVENTS) != 0)
    {
        std::cerr
            << "Capture helper SDL error: "
            << SDL_GetError()
            << "\n";
    }


    SDL_GameControllerEventState(
        SDL_ENABLE
    );


    std::vector<SDL_GameController*> controllers;

    openControllers(
        controllers
    );


    Uint32 pictureChordStarted =
        0;

    Uint32 recordChordStarted =
        0;

    bool pictureChordTriggered =
        false;

    bool recordChordTriggered =
        false;

    const Uint32 captureChordHoldMs =
        250;

    pid_t recordingPid =
        -1;

    const Uint32 debounceMs =
        500;

    Uint32 lastPictureTrigger =
        SDL_GetTicks() - debounceMs;

    Uint32 lastRecordTrigger =
        SDL_GetTicks() - debounceMs;


    auto picture =
        [&]()
        {
            Uint32 now =
                SDL_GetTicks();


            if (now - lastPictureTrigger <
                debounceMs)
            {
                return;
            }


            lastPictureTrigger =
                now;


            takeSnapshot(
                display,
                screenshotPath,
                maxWidth,
                maxHeight
            );
        };


    auto record =
        [&]()
        {
            Uint32 now =
                SDL_GetTicks();


            if (now - lastRecordTrigger <
                debounceMs)
            {
                return;
            }


            lastRecordTrigger =
                now;


            if (recordingPid > 0)
            {
                std::cout
                    << "Recording already in progress.\n";

                return;
            }


            recordingPid =
                startRecording(
                    display,
                    videoPath,
                    maxWidth,
                    maxHeight
                );
        };


    std::cout
        << "BareFront capture ready: "
        << "P=picture, R=record, "
        << "VIEW+Left=picture, VIEW+Right=record "
        << "(max "
        << maxWidth
        << "x"
        << maxHeight
        << ", aspect preserved)\n";


    while (keepRunning)
    {
        // --------------------------------------------------
        // Check whether an asynchronous 5-second recording
        // has finished.
        // --------------------------------------------------

        if (recordingPid > 0)
        {
            int status = 0;

            pid_t result =
                waitpid(
                    recordingPid,
                    &status,
                    WNOHANG
                );


            if (result == recordingPid)
            {
                if (WIFEXITED(status) &&
                    WEXITSTATUS(status) == 0)
                {
                    std::cout
                        << "Video saved: "
                        << videoPath
                        << "\n";
                }
                else
                {
                    std::cerr
                        << "BareFront recording failed. Is ffmpeg/libx264 available?\n";
                }


                recordingPid =
                    -1;
            }
        }


        // --------------------------------------------------
        // Global keyboard events from XInput2.
        // --------------------------------------------------

        while (xInputAvailable &&
               XPending(display) > 0)
        {
            XEvent event;

            XNextEvent(
                display,
                &event
            );


            if (event.xcookie.type != GenericEvent ||
                event.xcookie.extension != xiOpcode)
            {
                continue;
            }


            if (!XGetEventData(
                    display,
                    &event.xcookie))
            {
                continue;
            }


            if (event.xcookie.evtype ==
                XI_RawKeyPress)
            {
                auto* rawEvent =
                    static_cast<XIRawEvent*>(
                        event.xcookie.data
                    );


                KeySym key =
                    XkbKeycodeToKeysym(
                        display,
                        rawEvent->detail,
                        0,
                        0
                    );


                if (key == XK_p ||
                    key == XK_P)
                {
                    if (!pictureKeyWasDown)
                    {
                        picture();
                    }

                    pictureKeyWasDown =
                        true;
                }
                else if (
                    key == XK_r ||
                    key == XK_R)
                {
                    if (!recordKeyWasDown)
                    {
                        record();
                    }

                    recordKeyWasDown =
                        true;
                }
            }


            XFreeEventData(
                display,
                &event.xcookie
            );
        }


        // Polling fallback for nested Xwayland.
        //
        // This does not grab the keys. Edge detection ensures
        // that holding P or R triggers only one capture.
        char keyState[32] = {};

        XQueryKeymap(
            display,
            keyState
        );

        auto keyIsDown =
            [&keyState](KeyCode keycode)
            {
                if (keycode == 0)
                {
                    return false;
                }

                const unsigned int byteIndex =
                    keycode / 8;

                const unsigned int bitIndex =
                    keycode % 8;

                return
                    (
                        static_cast<unsigned char>(
                            keyState[byteIndex]
                        ) &
                        (1u << bitIndex)
                    ) != 0;
            };

        bool pictureKeyIsDown =
            keyIsDown(
                pictureKeycode
            );

        bool recordKeyIsDown =
            keyIsDown(
                recordKeycode
            );

        if (pictureKeyIsDown &&
            !pictureKeyWasDown)
        {
            picture();
        }

        if (recordKeyIsDown &&
            !recordKeyWasDown)
        {
            record();
        }

        pictureKeyWasDown =
            pictureKeyIsDown;

        recordKeyWasDown =
            recordKeyIsDown;


        // --------------------------------------------------
        // SDL controller events.
        // --------------------------------------------------

        SDL_Event event;


        while (SDL_PollEvent(
            &event))
        {
            if (event.type ==
                SDL_CONTROLLERDEVICEADDED)
            {
                int index =
                    event.cdevice.which;


                if (SDL_IsGameController(index))
                {
                    SDL_GameController* controller =
                        SDL_GameControllerOpen(index);


                    if (controller)
                    {
                        controllers.push_back(
                            controller
                        );
                    }
                }
            }
            else if (event.type ==
                     SDL_CONTROLLERDEVICEREMOVED)
            {
                SDL_JoystickID removedId =
                    event.cdevice.which;


                for (auto it = controllers.begin();
                     it != controllers.end();)
                {
                    SDL_Joystick* joystick =
                        SDL_GameControllerGetJoystick(
                            *it
                        );


                    if (SDL_JoystickInstanceID(
                            joystick) == removedId)
                    {
                        SDL_GameControllerClose(
                            *it
                        );

                        it =
                            controllers.erase(it);
                    }
                    else
                    {
                        ++it;
                    }
                }
            }
        }


        // Poll live controller state rather than relying on
        // button event ordering. Either half of the chord may
        // be pressed first.
        bool pictureChordHeld =
            false;

        bool recordChordHeld =
            false;


        for (SDL_GameController* controller :
             controllers)
        {
            if (!controller ||
                !SDL_GameControllerGetAttached(
                    controller))
            {
                continue;
            }


            const bool viewHeld =
                SDL_GameControllerGetButton(
                    controller,
                    SDL_CONTROLLER_BUTTON_BACK
                ) != 0;


            if (viewHeld &&
                SDL_GameControllerGetButton(
                    controller,
                    SDL_CONTROLLER_BUTTON_DPAD_LEFT
                ))
            {
                pictureChordHeld =
                    true;
            }


            if (viewHeld &&
                SDL_GameControllerGetButton(
                    controller,
                    SDL_CONTROLLER_BUTTON_DPAD_RIGHT
                ))
            {
                recordChordHeld =
                    true;
            }
        }


        Uint32 chordNow =
            SDL_GetTicks();


        if (pictureChordHeld)
        {
            if (pictureChordStarted == 0)
            {
                pictureChordStarted =
                    chordNow;
            }

            if (!pictureChordTriggered &&
                chordNow - pictureChordStarted >=
                    captureChordHoldMs)
            {
                picture();

                pictureChordTriggered =
                    true;
            }
        }
        else
        {
            pictureChordStarted =
                0;

            pictureChordTriggered =
                false;
        }


        if (recordChordHeld)
        {
            if (recordChordStarted == 0)
            {
                recordChordStarted =
                    chordNow;
            }

            if (!recordChordTriggered &&
                chordNow - recordChordStarted >=
                    captureChordHoldMs)
            {
                record();

                recordChordTriggered =
                    true;
            }
        }
        else
        {
            recordChordStarted =
                0;

            recordChordTriggered =
                false;
        }


        SDL_Delay(10);
    }


    // If the emulator closes during an active recording,
    // stop FFmpeg rather than leaving an orphan process.
    if (recordingPid > 0)
    {
        kill(
            recordingPid,
            SIGTERM
        );

        waitpid(
            recordingPid,
            nullptr,
            0
        );
    }


    for (SDL_GameController* controller :
         controllers)
    {
        if (controller)
        {
            SDL_GameControllerClose(
                controller
            );
        }
    }


    SDL_Quit();

    XCloseDisplay(
        display
    );


    return 0;
}
