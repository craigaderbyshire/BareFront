#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building BareFront with video preview support..."

g++ -std=c++17 src/main.cpp -o barefront \
$(sdl2-config --cflags --libs) \
-lSDL2_ttf -lSDL2_image -pthread

echo
echo "Built: $ROOT_DIR/barefront"

echo
echo "Building BareFront presentation overlay helper..."

for package in x11 xfixes xrender SDL2_image; do
    if ! pkg-config --exists "$package"; then
        echo "Missing overlay build dependency: $package" >&2
        exit 1
    fi
done

g++ \
    -std=c++17 \
    -Wall \
    -Wextra \
    -Wpedantic \
    -Werror \
    src/overlay_helper.cpp \
    -o overlay_helper \
    $(pkg-config --cflags --libs x11 xfixes xrender SDL2_image)

echo
echo "Built: $ROOT_DIR/overlay_helper"

echo
echo "Checking BareFront capture helper..."

CAPTURE_SOURCE="$ROOT_DIR/src/capture_helper.cpp"
CAPTURE_BINARY="$ROOT_DIR/capture_helper"

if [[ ! -x "$CAPTURE_BINARY" ||
      "$CAPTURE_SOURCE" -nt "$CAPTURE_BINARY" ]]; then

    echo "Building BareFront capture helper..."

    g++ -std=c++17 "$CAPTURE_SOURCE" -o "$CAPTURE_BINARY" \
        $(sdl2-config --cflags --libs) \
        -lX11 -lXi

    echo
    echo "Built: $CAPTURE_BINARY"

else

    echo "Capture helper is already built and current."

fi
