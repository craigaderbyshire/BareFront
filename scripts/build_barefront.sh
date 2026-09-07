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

for package in x11 xfixes xrender; do
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
    $(pkg-config --cflags --libs x11 xfixes xrender)

echo
echo "Built: $ROOT_DIR/overlay_helper"
