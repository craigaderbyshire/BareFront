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
