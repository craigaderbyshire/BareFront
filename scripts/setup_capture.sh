#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "BareFront capture setup"
echo "Installing FFmpeg and X11 development libraries..."

sudo apt update
sudo apt install -y ffmpeg libx11-dev libxi-dev

echo
echo "Building capture helper..."
g++ -std=c++17 src/capture_helper.cpp -o capture_helper \
$(sdl2-config --cflags --libs) \
-lX11 -lXi

echo
echo "Capture helper built: $ROOT_DIR/capture_helper"
echo "P = snapshot"
echo "R = 5-second video"
echo "Select + Left = snapshot"
echo "Select + Right = 5-second video"
echo
echo "Capture v2 preserves game aspect ratio and orientation."
