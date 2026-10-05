#include <SDL2/SDL.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <algorithm>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace
{
volatile std::sig_atomic_t stopRequested = 0;

void stop(int)
{
    stopRequested = 1;
}

enum class KeyKind
{
    Normal,
    Modifier
};

struct Key
{
    const char* shortLabel;
    const char* name;
    KeySym keysym;
    KeyKind kind = KeyKind::Normal;
};

using Row = std::vector<Key>;

const std::vector<Row> rows = {
    {
        {"<-",  "ARROW LEFT", XK_End},
        {"1",   "1 !",        XK_1},
        {"2",   "2 \"",       XK_2},
        {"3",   "3 #",        XK_3},
        {"4",   "4 $",        XK_4},
        {"5",   "5 %",        XK_5},
        {"6",   "6 &",        XK_6},
        {"7",   "7 '",        XK_7},
        {"8",   "8 (",        XK_8},
        {"9",   "9 )",        XK_9},
        {"0",   "0",          XK_0},
        {"+",   "+",          XK_plus},
        {"-",   "-",          XK_minus},
        {"£",   "POUND",      XK_backslash},
        {"HM",  "HOME",       XK_Home},
        {"DEL", "DELETE",     XK_BackSpace},
        {"F1",  "F1",         XK_F1},
        {"F2",  "F2",         XK_F2}
    },

    {
        {"CTL", "CTRL",       XK_Control_L, KeyKind::Modifier},
        {"Q",   "Q",          XK_q},
        {"W",   "W",          XK_w},
        {"E",   "E",          XK_e},
        {"R",   "R",          XK_r},
        {"T",   "T",          XK_t},
        {"Y",   "Y",          XK_y},
        {"U",   "U",          XK_u},
        {"I",   "I",          XK_i},
        {"O",   "O",          XK_o},
        {"P",   "P",          XK_p},
        {"@",   "@",          XK_at},
        {"*",   "*",          XK_asterisk},
        {"UP",  "ARROW UP",   XK_Page_Down},
        {"RST", "RESTORE",    XK_Page_Up},
        {"F3",  "F3",         XK_F3},
        {"F4",  "F4",         XK_F4}
    },

    {
        {"R/S", "RUN/STOP",   XK_F9},
        {"SH",  "LEFT SHIFT", XK_Shift_L, KeyKind::Modifier},
        {"A",   "A",          XK_a},
        {"S",   "S",          XK_s},
        {"D",   "D",          XK_d},
        {"F",   "F",          XK_f},
        {"G",   "G",          XK_g},
        {"H",   "H",          XK_h},
        {"J",   "J",          XK_j},
        {"K",   "K",          XK_k},
        {"L",   "L",          XK_l},
        {":",   "COLON",      XK_colon},
        {";",   "SEMICOLON",  XK_semicolon},
        {"=",   "=",          XK_equal},
        {"RET", "RETURN",     XK_Return},
        {"F5",  "F5",         XK_F5},
        {"F6",  "F6",         XK_F6}
    },

    {
        {"C=",  "COMMODORE",  XK_Tab, KeyKind::Modifier},
        {"RSH", "RIGHT SHIFT",XK_Shift_R, KeyKind::Modifier},
        {"Z",   "Z",          XK_z},
        {"X",   "X",          XK_x},
        {"C",   "C",          XK_c},
        {"V",   "V",          XK_v},
        {"B",   "B",          XK_b},
        {"N",   "N",          XK_n},
        {"M",   "M",          XK_m},
        {",",   "COMMA",      XK_comma},
        {".",   "PERIOD",     XK_period},
        {"/",   "SLASH",      XK_slash},
        {"DN",  "CURSOR DOWN",XK_Down},
        {"RT",  "CURSOR RIGHT",XK_Right},
        {"F7",  "F7",         XK_F7},
        {"F8",  "F8",         XK_F8}
    },

    {
        {"SPC", "SPACE",      XK_space}
    }
};

struct HostKey
{
    KeyCode code = 0;
    bool needsShift = false;
};

HostKey resolveHostKey(Display* display, KeySym target)
{
    HostKey result{};

    int minCode = 0;
    int maxCode = 0;

    XDisplayKeycodes(
        display,
        &minCode,
        &maxCode
    );

    int symsPerCode = 0;

    KeySym* mapping =
        XGetKeyboardMapping(
            display,
            static_cast<KeyCode>(minCode),
            maxCode - minCode + 1,
            &symsPerCode
        );

    if (mapping)
    {
        for (int code = minCode;
             code <= maxCode && !result.code;
             ++code)
        {
            const int base =
                (code - minCode) * symsPerCode;

            if (symsPerCode > 0 &&
                mapping[base] == target)
            {
                result.code =
                    static_cast<KeyCode>(code);

                result.needsShift = false;
                break;
            }

            if (symsPerCode > 1 &&
                mapping[base + 1] == target)
            {
                result.code =
                    static_cast<KeyCode>(code);

                result.needsShift = true;
                break;
            }
        }

        XFree(mapping);
    }

    if (!result.code)
    {
        result.code =
            XKeysymToKeycode(display, target);

        result.needsShift = false;
    }

    return result;
}

bool isViceWindow(Display* display, Window window)
{
    XWindowAttributes attributes{};

    if (!XGetWindowAttributes(
            display,
            window,
            &attributes))
    {
        return false;
    }

    if (attributes.map_state != IsViewable ||
        attributes.width < 100 ||
        attributes.height < 100)
    {
        return false;
    }

    char* title = nullptr;

    if (!XFetchName(display, window, &title) ||
        !title)
    {
        return false;
    }

    const std::string name(title);
    XFree(title);

    return name.find("VICE") != std::string::npos;
}

Window findViceWindow(
    Display* display,
    Window parent)
{
    Window root = None;
    Window parentReturned = None;
    Window* children = nullptr;
    unsigned int count = 0;

    if (!XQueryTree(
            display,
            parent,
            &root,
            &parentReturned,
            &children,
            &count))
    {
        return None;
    }

    Window found = None;

    for (unsigned int i = 0;
         i < count && found == None;
         ++i)
    {
        if (isViceWindow(display, children[i]))
            found = children[i];
    }

    for (unsigned int i = 0;
         i < count && found == None;
         ++i)
    {
        found =
            findViceWindow(
                display,
                children[i]
            );
    }

    if (children)
        XFree(children);

    return found;
}

bool keyIsActive(
    const Key& key,
    bool leftShift,
    bool rightShift,
    bool control,
    bool commodore)
{
    if (key.keysym == XK_Shift_L)
        return leftShift;

    if (key.keysym == XK_Shift_R)
        return rightShift;

    if (key.keysym == XK_Control_L)
        return control;

    if (key.keysym == XK_Tab)
        return commodore;

    return false;
}

void drawKeyboard(
    Display* display,
    Window window,
    GC gc,
    XFontStruct* font,
    int width,
    int height,
    int selectedRow,
    int selectedColumn,
    bool leftShift,
    bool rightShift,
    bool control,
    bool commodore)
{
    const int screen =
        DefaultScreen(display);

    const unsigned long black =
        BlackPixel(display, screen);

    const unsigned long white =
        WhitePixel(display, screen);

    const Colormap colormap =
        DefaultColormap(display, screen);

    auto colour =
        [&](const char* value,
            unsigned long fallback)
        {
            XColor screenColour{};
            XColor exactColour{};

            if (XAllocNamedColor(
                    display,
                    colormap,
                    value,
                    &screenColour,
                    &exactColour))
            {
                return screenColour.pixel;
            }

            return fallback;
        };

    const unsigned long caseBrown =
        colour("#70513A", black);

    const unsigned long caseEdge =
        colour("#3E2D22", white);

    const unsigned long keyDark =
        colour("#292725", black);

    const unsigned long keyLegend =
        colour("#E8D8B3", white);

    const unsigned long selectedKey =
        colour("#D6A04A", white);

    const unsigned long functionKey =
        colour("#B58A57", white);

    const unsigned long selectedText =
        colour("#221B16", black);

    XSetForeground(display, gc, caseBrown);

    XFillRectangle(
        display,
        window,
        gc,
        0,
        0,
        static_cast<unsigned int>(width),
        static_cast<unsigned int>(height)
    );

    XSetForeground(display, gc, caseEdge);

    XDrawRectangle(
        display,
        window,
        gc,
        0,
        0,
        static_cast<unsigned int>(width - 1),
        static_cast<unsigned int>(height - 1)
    );

    XSetForeground(display, gc, keyLegend);

    const Key& selected =
        rows[selectedRow][selectedColumn];

    std::string header =
        std::string("SEL: ") + selected.name;

    XDrawString(
        display,
        window,
        gc,
        6,
        12,
        header.c_str(),
        static_cast<int>(header.size())
    );

    std::string controls =
        "RS MOVE  X PRESS  B CLOSE";

    XDrawString(
        display,
        window,
        gc,
        6,
        25,
        controls.c_str(),
        static_cast<int>(controls.size())
    );

    std::string modifiers = "MOD:";

    if (leftShift)
        modifiers += " LSHIFT";

    if (rightShift)
        modifiers += " RSHIFT";

    if (control)
        modifiers += " CTRL";

    if (commodore)
        modifiers += " C=";

    if (!leftShift &&
        !rightShift &&
        !control &&
        !commodore)
    {
        modifiers += " NONE";
    }

    XDrawString(
        display,
        window,
        gc,
        220,
        25,
        modifiers.c_str(),
        static_cast<int>(modifiers.size())
    );

    const int keyboardTop = 42;
    const int bottomMargin = 10;

    // Breadbin proportions:
    // main keyboard body on the left,
    // four physical function keys in a narrow strip on the right.
    const int sideMargin = 8;
    const int functionGap = 6;
    const int functionWidth = 52;

    const int mainLeft = sideMargin;
    const int mainRight =
        width -
        sideMargin -
        functionWidth -
        functionGap;

    const int functionLeft =
        mainRight +
        functionGap;

    const int mainWidth =
        mainRight -
        mainLeft;

    const int usableHeight =
        height -
        keyboardTop -
        bottomMargin;

    const int keyAreaHeight =
        std::min(
            usableHeight,
            150
        );

    const int rowHeight =
        keyAreaHeight /
        static_cast<int>(rows.size());

    const int mainKeyHeight =
        std::max(
            1,
            rowHeight - 7
        );

    for (std::size_t r = 0;
         r < rows.size();
         ++r)
    {
        const Row& row = rows[r];

        const int y =
            keyboardTop +
            static_cast<int>(r) * rowHeight;

        if (row.size() == 1)
        {
            // Real C64-style bottom row:
            // wide space bar on the left, then the two
            // physical cursor keys to its right.
            const int gap = 6;
            const int cursorWidth = 66;

            const int spaceWidth =
                std::max(
                    120,
                    mainWidth -
                        (cursorWidth * 2) -
                        (gap * 2)
                );

            const int x =
                mainLeft;

            const bool selectedNow =
                static_cast<int>(r) == selectedRow &&
                selectedColumn == 0;

            const int spaceY =
                y + 7;

            XSetForeground(
                display,
                gc,
                selectedNow ? selectedKey : keyDark
            );

            XFillRectangle(
                display,
                window,
                gc,
                x,
                spaceY,
                static_cast<unsigned int>(spaceWidth),
                static_cast<unsigned int>(mainKeyHeight)
            );

            XSetForeground(
                display,
                gc,
                selectedNow ? selectedText : keyLegend
            );

            XDrawRectangle(
                display,
                window,
                gc,
                x,
                spaceY,
                static_cast<unsigned int>(spaceWidth),
                static_cast<unsigned int>(mainKeyHeight)
            );

            const std::string spaceLabel = "SPACE";

            const int spaceTextWidth =
                font
                ? XTextWidth(
                    font,
                    spaceLabel.c_str(),
                    static_cast<int>(spaceLabel.size()))
                : static_cast<int>(spaceLabel.size()) * 6;

            XDrawString(
                display,
                window,
                gc,
                x + std::max(
                        2,
                        (spaceWidth - spaceTextWidth) / 2),
                spaceY + mainKeyHeight / 2 + 5,
                spaceLabel.c_str(),
                static_cast<int>(spaceLabel.size())
            );

            // Existing logical cursor keys live in row 3,
            // columns 12 and 13. Only their drawing moves.
            const bool cursorUDSelected =
                selectedRow == 3 &&
                selectedColumn == 12;

            const bool cursorLRSelected =
                selectedRow == 3 &&
                selectedColumn == 13;

            auto drawCursorKey =
                [&](int keyX,
                    const char* label,
                    bool isSelected)
                {
                    const int cursorY =
                        y + 7;

                    XSetForeground(
                        display,
                        gc,
                        isSelected
                            ? selectedKey
                            : keyDark
                    );

                    XFillRectangle(
                        display,
                        window,
                        gc,
                        keyX,
                        cursorY,
                        static_cast<unsigned int>(
                            cursorWidth),
                        static_cast<unsigned int>(
                            mainKeyHeight)
                    );

                    XSetForeground(
                        display,
                        gc,
                        isSelected
                            ? selectedText
                            : keyLegend
                    );

                    XDrawRectangle(
                        display,
                        window,
                        gc,
                        keyX,
                        cursorY,
                        static_cast<unsigned int>(
                            cursorWidth),
                        static_cast<unsigned int>(
                            mainKeyHeight)
                    );

                    const std::string text(label);

                    const int textWidth =
                        font
                        ? XTextWidth(
                            font,
                            text.c_str(),
                            static_cast<int>(
                                text.size()))
                        : static_cast<int>(
                            text.size()) * 6;

                    XDrawString(
                        display,
                        window,
                        gc,
                        keyX +
                            std::max(
                                2,
                                (cursorWidth -
                                 textWidth) / 2),
                        cursorY + mainKeyHeight / 2 + 5,
                        text.c_str(),
                        static_cast<int>(
                            text.size())
                    );
                };

            const int cursorUDX =
                x + spaceWidth + gap;

            const int cursorLRX =
                cursorUDX + cursorWidth + gap;

            drawCursorKey(
                cursorUDX,
                "CSR U/D",
                cursorUDSelected
            );

            drawCursorKey(
                cursorLRX,
                "CSR L/R",
                cursorLRSelected
            );

            continue;
        }

        const int count =
            static_cast<int>(row.size());

        // First four rows contain two logical function-key
        // entries at the end. Visually they belong to one
        // physical C64 function key in the right-hand strip.
        const bool hasFunctionPair =
            static_cast<int>(r) < 4 &&
            count >= 2;

        const int mainCount =
            hasFunctionPair
                ? count - 2
                : count;

        const int keyWidth =
            std::max(
                1,
                mainWidth /
                    std::max(1, mainCount)
            );

        for (int c = 0;
             c < count;
             ++c)
        {
            // Cursor keys are now drawn beside SPACE
            // on the bottom row.
            if (static_cast<int>(r) == 3 &&
                (c == 12 || c == 13))
            {
                continue;
            }

            if (hasFunctionPair &&
                c >= mainCount)
            {
                // Draw the physical F-key once for the pair.
                if (c == mainCount + 1)
                    continue;

                const int fx =
                    functionLeft;

                const int fy =
                    keyboardTop +
                    static_cast<int>(r) *
                        rowHeight +
                    2;

                const int fh =
                    std::max(
                        1,
                        rowHeight - 5
                    );

                const bool firstSelected =
                    static_cast<int>(r) ==
                        selectedRow &&
                    selectedColumn ==
                        mainCount;

                const bool secondSelected =
                    static_cast<int>(r) ==
                        selectedRow &&
                    selectedColumn ==
                        mainCount + 1;

                XSetForeground(
                    display,
                    gc,
                    functionKey
                );

                XFillRectangle(
                    display,
                    window,
                    gc,
                    fx,
                    fy,
                    static_cast<unsigned int>(
                        functionWidth),
                    static_cast<unsigned int>(
                        fh)
                );

                const int halfWidth =
                    functionWidth / 2;

                if (firstSelected)
                {
                    XSetForeground(
                        display,
                        gc,
                        selectedKey
                    );

                    XFillRectangle(
                        display,
                        window,
                        gc,
                        fx,
                        fy,
                        static_cast<unsigned int>(
                            halfWidth),
                        static_cast<unsigned int>(
                            fh)
                    );
                }

                if (secondSelected)
                {
                    XSetForeground(
                        display,
                        gc,
                        selectedKey
                    );

                    XFillRectangle(
                        display,
                        window,
                        gc,
                        fx + halfWidth,
                        fy,
                        static_cast<unsigned int>(
                            functionWidth -
                            halfWidth),
                        static_cast<unsigned int>(
                            fh)
                    );
                }

                XSetForeground(
                    display,
                    gc,
                    caseEdge
                );

                XDrawRectangle(
                    display,
                    window,
                    gc,
                    fx,
                    fy,
                    static_cast<unsigned int>(
                        functionWidth),
                    static_cast<unsigned int>(
                        fh)
                );

                XDrawLine(
                    display,
                    window,
                    gc,
                    fx + halfWidth,
                    fy + 2,
                    fx + halfWidth,
                    fy + fh - 2
                );

                const Key& first =
                    row[mainCount];

                const Key& second =
                    row[mainCount + 1];

                auto drawFunctionLabel =
                    [&](const Key& key,
                        int left,
                        int areaWidth,
                        bool selectedHalf)
                    {
                        XSetForeground(
                            display,
                            gc,
                            selectedHalf
                                ? selectedText
                                : selectedText
                        );

                        const std::string label =
                            key.shortLabel;

                        const int textWidth =
                            font
                            ? XTextWidth(
                                font,
                                label.c_str(),
                                static_cast<int>(
                                    label.size()))
                            : static_cast<int>(
                                label.size()) * 6;

                        XDrawString(
                            display,
                            window,
                            gc,
                            left +
                                std::max(
                                    2,
                                    (areaWidth -
                                     textWidth) / 2),
                            fy + fh / 2 + 5,
                            label.c_str(),
                            static_cast<int>(
                                label.size())
                        );
                    };

                drawFunctionLabel(
                    first,
                    fx,
                    halfWidth,
                    firstSelected
                );

                drawFunctionLabel(
                    second,
                    fx + halfWidth,
                    functionWidth - halfWidth,
                    secondSelected
                );

                continue;
            }

            const int x =
                mainLeft +
                c * keyWidth;

            const bool selectedNow =
                static_cast<int>(r) == selectedRow &&
                c == selectedColumn;

            const bool active =
                keyIsActive(
                    row[c],
                    leftShift,
                    rightShift,
                    control,
                    commodore
                );

            const bool isFunctionKey =
                row[c].keysym >= XK_F1 &&
                row[c].keysym <= XK_F8;

            XSetForeground(
                display,
                gc,
                selectedNow
                    ? selectedKey
                    : (isFunctionKey
                        ? functionKey
                        : keyDark)
            );

            XFillRectangle(
                display,
                window,
                gc,
                x + 1,
                y + 1,
                static_cast<unsigned int>(
                    std::max(1, keyWidth - 2)),
                static_cast<unsigned int>(
                    std::max(1, rowHeight - 3))
            );

            XSetForeground(
                display,
                gc,
                selectedNow
                    ? selectedText
                    : (isFunctionKey
                        ? selectedText
                        : keyLegend)
            );

            XDrawRectangle(
                display,
                window,
                gc,
                x + 1,
                y + 1,
                static_cast<unsigned int>(
                    std::max(1, keyWidth - 2)),
                static_cast<unsigned int>(
                    std::max(1, rowHeight - 3))
            );

            std::string label =
                active
                ? std::string("*") +
                    row[c].shortLabel
                : row[c].shortLabel;

            const int textWidth =
                font
                ? XTextWidth(
                    font,
                    label.c_str(),
                    static_cast<int>(label.size()))
                : static_cast<int>(label.size()) * 6;

            XDrawString(
                display,
                window,
                gc,
                x + std::max(
                        2,
                        (keyWidth - textWidth) / 2),
                y + rowHeight / 2 + 5,
                label.c_str(),
                static_cast<int>(label.size())
            );
        }
    }

    XFlush(display);
}

void setModifier(
    Display* display,
    KeySym keysym,
    bool down)
{
    const KeyCode code =
        XKeysymToKeycode(
            display,
            keysym
        );

    if (!code)
        return;

    XTestFakeKeyEvent(
        display,
        code,
        down ? True : False,
        CurrentTime
    );

    XSync(display, False);
}

void releaseModifiers(
    Display* display,
    bool& leftShift,
    bool& rightShift,
    bool& control,
    bool& commodore)
{
    if (leftShift)
        setModifier(display, XK_Shift_L, false);

    if (rightShift)
        setModifier(display, XK_Shift_R, false);

    if (control)
        setModifier(display, XK_Control_L, false);

    if (commodore)
        setModifier(display, XK_Tab, false);

    leftShift = false;
    rightShift = false;
    control = false;
    commodore = false;
}

bool sendNormalKey(
    Display* display,
    Window viceWindow,
    Window keyboardWindow,
    const Key& key,
    bool leftShift,
    bool rightShift)
{
    HostKey host =
        resolveHostKey(
            display,
            key.keysym
        );

    if (!host.code)
    {
        std::cerr
            << "No host keycode for "
            << key.name
            << "\n";

        return false;
    }

    XSetInputFocus(
        display,
        viceWindow,
        RevertToParent,
        CurrentTime
    );

    XSync(display, False);

    bool temporaryShift = false;

    if (host.needsShift &&
        !leftShift &&
        !rightShift)
    {
        const KeyCode shift =
            XKeysymToKeycode(
                display,
                XK_Shift_L
            );

        if (shift)
        {
            XTestFakeKeyEvent(
                display,
                shift,
                True,
                CurrentTime
            );

            XSync(display, False);
            temporaryShift = true;
        }
    }

    XTestFakeKeyEvent(
        display,
        host.code,
        True,
        CurrentTime
    );

    XSync(display, False);
    SDL_Delay(60);

    XTestFakeKeyEvent(
        display,
        host.code,
        False,
        CurrentTime
    );

    XSync(display, False);

    if (temporaryShift)
    {
        const KeyCode shift =
            XKeysymToKeycode(
                display,
                XK_Shift_L
            );

        if (shift)
        {
            XTestFakeKeyEvent(
                display,
                shift,
                False,
                CurrentTime
            );

            XSync(display, False);
        }
    }

    XRaiseWindow(
        display,
        keyboardWindow
    );

    XFlush(display);

    std::cout
        << "C64 key sent: "
        << key.name
        << "\n";

    std::cout.flush();

    return true;
}

int mappedColumn(
    int oldColumn,
    int oldCount,
    int newCount)
{
    if (newCount <= 1)
        return 0;

    if (oldCount <= 1)
        return newCount / 2;

    const double position =
        static_cast<double>(oldColumn) /
        static_cast<double>(oldCount - 1);

    return std::clamp(
        static_cast<int>(
            std::lround(
                position *
                static_cast<double>(newCount - 1)
            )
        ),
        0,
        newCount - 1
    );
}
}

int main()
{
    std::signal(SIGINT, stop);
    std::signal(SIGTERM, stop);

    const char* session =
        std::getenv(
            "BAREFRONT_C64_KEYBOARD_SESSION"
        );

    if (!session ||
        std::string(session) != "1")
    {
        std::cerr
            << "Not a BareFront C64 keyboard session\n";

        return 1;
    }

    SDL_SetHint(
        SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS,
        "1"
    );

    if (SDL_Init(
            SDL_INIT_GAMECONTROLLER) != 0)
    {
        std::cerr
            << SDL_GetError()
            << "\n";

        return 1;
    }

    std::vector<SDL_GameController*> controllers;

    for (int i = 0;
         i < SDL_NumJoysticks();
         ++i)
    {
        if (!SDL_IsGameController(i))
            continue;

        SDL_GameController* controller =
            SDL_GameControllerOpen(i);

        if (!controller)
            continue;

        controllers.push_back(controller);

        std::cout
            << "Keyboard controller: "
            << SDL_GameControllerName(
                   controller)
            << "\n";
    }

    if (controllers.empty())
    {
        std::cerr
            << "No SDL controller available\n";

        SDL_Quit();
        return 1;
    }

    Display* display =
        XOpenDisplay(nullptr);

    if (!display)
    {
        std::cerr
            << "Cannot open nested X display\n";

        for (auto* controller : controllers)
            SDL_GameControllerClose(controller);

        SDL_Quit();
        return 1;
    }

    const Window root =
        DefaultRootWindow(display);

    Window viceWindow = None;

    for (int attempt = 0;
         attempt < 100 &&
         viceWindow == None;
         ++attempt)
    {
        viceWindow =
            findViceWindow(
                display,
                root
            );

        if (viceWindow == None)
            SDL_Delay(100);
    }

    if (viceWindow == None)
    {
        std::cerr
            << "Could not locate VICE window\n";

        XCloseDisplay(display);

        for (auto* controller : controllers)
            SDL_GameControllerClose(controller);

        SDL_Quit();
        return 1;
    }

    XWindowAttributes rootAttributes{};

    if (!XGetWindowAttributes(
            display,
            root,
            &rootAttributes))
    {
        std::cerr
            << "Could not inspect nested display\n";

        XCloseDisplay(display);

        for (auto* controller : controllers)
            SDL_GameControllerClose(controller);

        SDL_Quit();
        return 1;
    }

    const int width =
        std::max(
            200,
            rootAttributes.width - 4
        );

    const int height =
        std::min(
            300,
            std::max(
                240,
                rootAttributes.height - 70
            )
        );

    const int x =
        std::max(
            0,
            (rootAttributes.width - width) / 2
        );

    const int y =
        std::max(
            0,
            rootAttributes.height -
                height -
                2
        );

    const int screen =
        DefaultScreen(display);

    XSetWindowAttributes attributes{};
    attributes.override_redirect = True;
    attributes.background_pixel =
        BlackPixel(display, screen);
    attributes.border_pixel =
        WhitePixel(display, screen);

    const Window keyboardWindow =
        XCreateWindow(
            display,
            root,
            x,
            y,
            static_cast<unsigned int>(width),
            static_cast<unsigned int>(height),
            0,
            DefaultDepth(display, screen),
            InputOutput,
            DefaultVisual(display, screen),
            CWOverrideRedirect |
                CWBackPixel |
                CWBorderPixel,
            &attributes
        );

    if (!keyboardWindow)
    {
        std::cerr
            << "Could not create keyboard window\n";

        XCloseDisplay(display);

        for (auto* controller : controllers)
            SDL_GameControllerClose(controller);

        SDL_Quit();
        return 1;
    }

    XStoreName(
        display,
        keyboardWindow,
        "BareFront C64 Full Keyboard Candidate"
    );

    XWMHints hints{};
    hints.flags = InputHint;
    hints.input = False;

    XSetWMHints(
        display,
        keyboardWindow,
        &hints
    );

    XSelectInput(
        display,
        keyboardWindow,
        ExposureMask
    );

    GC gc =
        XCreateGC(
            display,
            keyboardWindow,
            0,
            nullptr
        );

    XFontStruct* font =
        XLoadQueryFont(
            display,
            "6x13"
        );

    if (!font)
    {
        font =
            XLoadQueryFont(
                display,
                "fixed"
            );
    }

    if (font)
        XSetFont(display, gc, font->fid);

    bool visible = false;

    bool axisXLatched = false;
    bool axisYLatched = false;

    bool leftShift = false;
    bool rightShift = false;
    bool control = false;
    bool commodore = false;

    int selectedRow = 0;
    int selectedColumn = 1; // Start on "1"

    auto redraw = [&]()
    {
        if (!visible)
            return;

        drawKeyboard(
            display,
            keyboardWindow,
            gc,
            font,
            width,
            height,
            selectedRow,
            selectedColumn,
            leftShift,
            rightShift,
            control,
            commodore
        );
    };

    std::cout
        << "BareFront C64 full keyboard candidate active\n"
        << "LB+RB+B -> open/close\n"
        << "Right stick -> navigate\n"
        << "X -> press/toggle selected key\n"
        << "B -> close\n"
        << "RUN/STOP uses private F9 transport\n";

    std::cout.flush();

    SDL_Event event;

    while (!stopRequested)
    {
        while (XPending(display))
        {
            XEvent xevent{};
            XNextEvent(display, &xevent);

            if (visible &&
                xevent.type == Expose)
            {
                redraw();
            }
        }

        if (!SDL_WaitEventTimeout(
                &event,
                20))
        {
            continue;
        }

        if (event.type == SDL_QUIT)
            break;

        if (event.type ==
            SDL_CONTROLLERAXISMOTION)
        {
            if (!visible)
                continue;

            if (event.caxis.axis ==
                SDL_CONTROLLER_AXIS_RIGHTX)
            {
                const int value =
                    static_cast<int>(
                        event.caxis.value
                    );

                if (std::abs(value) < 8000)
                {
                    axisXLatched = false;
                    continue;
                }

                if (axisXLatched ||
                    std::abs(value) < 16000)
                {
                    continue;
                }

                const int count =
                    static_cast<int>(
                        rows[selectedRow].size()
                    );

                if (value > 0)
                {
                    selectedColumn =
                        (selectedColumn + 1) %
                        count;
                }
                else
                {
                    selectedColumn =
                        (selectedColumn +
                         count - 1) %
                        count;
                }

                axisXLatched = true;

                std::cout
                    << "Selected: "
                    << rows[selectedRow]
                           [selectedColumn].name
                    << "\n";

                std::cout.flush();

                redraw();
                continue;
            }

            if (event.caxis.axis ==
                SDL_CONTROLLER_AXIS_RIGHTY)
            {
                const int value =
                    static_cast<int>(
                        event.caxis.value
                    );

                if (std::abs(value) < 8000)
                {
                    axisYLatched = false;
                    continue;
                }

                if (axisYLatched ||
                    std::abs(value) < 16000)
                {
                    continue;
                }

                const int oldRow =
                    selectedRow;

                const int oldCount =
                    static_cast<int>(
                        rows[oldRow].size()
                    );

                if (value > 0)
                {
                    selectedRow =
                        (selectedRow + 1) %
                        static_cast<int>(
                            rows.size()
                        );
                }
                else
                {
                    selectedRow =
                        (selectedRow +
                         static_cast<int>(
                             rows.size()) -
                         1) %
                        static_cast<int>(
                            rows.size()
                        );
                }

                const int newCount =
                    static_cast<int>(
                        rows[selectedRow].size()
                    );

                selectedColumn =
                    mappedColumn(
                        selectedColumn,
                        oldCount,
                        newCount
                    );

                axisYLatched = true;

                std::cout
                    << "Selected: "
                    << rows[selectedRow]
                           [selectedColumn].name
                    << "\n";

                std::cout.flush();

                redraw();
                continue;
            }

            continue;
        }

        if (event.type !=
            SDL_CONTROLLERBUTTONDOWN)
        {
            continue;
        }

        SDL_GameController* controller =
            SDL_GameControllerFromInstanceID(
                event.cbutton.which
            );

        if (!controller)
            continue;

        const bool lb =
            SDL_GameControllerGetButton(
                controller,
                SDL_CONTROLLER_BUTTON_LEFTSHOULDER
            );

        const bool rb =
            SDL_GameControllerGetButton(
                controller,
                SDL_CONTROLLER_BUTTON_RIGHTSHOULDER
            );

        if (event.cbutton.button ==
                SDL_CONTROLLER_BUTTON_B &&
            lb && rb)
        {
            visible = !visible;

            axisXLatched = false;
            axisYLatched = false;

            if (visible)
            {
                selectedRow = 0;
                selectedColumn = 1;

                XMapRaised(
                    display,
                    keyboardWindow
                );

                redraw();

                std::cout
                    << "C64 keyboard opened\n";
            }
            else
            {
                releaseModifiers(
                    display,
                    leftShift,
                    rightShift,
                    control,
                    commodore
                );

                XUnmapWindow(
                    display,
                    keyboardWindow
                );

                XFlush(display);

                std::cout
                    << "C64 keyboard closed\n";
            }

            std::cout.flush();
            continue;
        }

        if (!visible)
            continue;

        if (event.cbutton.button ==
            SDL_CONTROLLER_BUTTON_B)
        {
            releaseModifiers(
                display,
                leftShift,
                rightShift,
                control,
                commodore
            );

            XUnmapWindow(
                display,
                keyboardWindow
            );

            XFlush(display);

            visible = false;

            std::cout
                << "C64 keyboard closed\n";

            std::cout.flush();
            continue;
        }

        if (event.cbutton.button !=
            SDL_CONTROLLER_BUTTON_X)
        {
            continue;
        }

        // Never steal the proven disc-previous chord.
        if (lb || rb)
            continue;

        const Key& selected =
            rows[selectedRow][selectedColumn];

        if (selected.kind ==
            KeyKind::Modifier)
        {
            bool* state = nullptr;

            if (selected.keysym == XK_Shift_L)
                state = &leftShift;

            else if (selected.keysym == XK_Shift_R)
                state = &rightShift;

            else if (selected.keysym == XK_Control_L)
                state = &control;

            else if (selected.keysym == XK_Tab)
                state = &commodore;

            if (state)
            {
                *state = !*state;

                setModifier(
                    display,
                    selected.keysym,
                    *state
                );

                std::cout
                    << selected.name
                    << (*state ? " ON\n" : " OFF\n");

                std::cout.flush();

                redraw();
            }

            continue;
        }

        sendNormalKey(
            display,
            viceWindow,
            keyboardWindow,
            selected,
            leftShift,
            rightShift
        );
    }

    releaseModifiers(
        display,
        leftShift,
        rightShift,
        control,
        commodore
    );

    if (font)
        XFreeFont(display, font);

    XFreeGC(display, gc);

    XDestroyWindow(
        display,
        keyboardWindow
    );

    XCloseDisplay(display);

    for (auto* controller : controllers)
        SDL_GameControllerClose(controller);

    SDL_Quit();

    std::cout
        << "BareFront C64 full keyboard candidate quitting\n";

    return 0;
}
