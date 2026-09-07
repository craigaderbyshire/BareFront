#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CAPTURE_RECORDER="$ROOT_DIR/scripts/capture_gamescope_video.sh"

cd "$ROOT_DIR"

echo "BareFront capture setup"
echo "Installing capture dependencies..."

sudo apt-get update
sudo apt-get install -y \
    ffmpeg \
    gstreamer1.0-tools \
    gstreamer1.0-pipewire \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-ugly \
    pipewire-bin \
    libx11-dev \
    libxi-dev

if [[ ! -f "$CAPTURE_RECORDER" ]]; then
    echo "Gamescope capture recorder is missing: $CAPTURE_RECORDER" >&2
    exit 1
fi

chmod +x "$CAPTURE_RECORDER"

if [[ ! -x "$CAPTURE_RECORDER" ]]; then
    echo "Gamescope capture recorder is not executable: $CAPTURE_RECORDER" >&2
    exit 1
fi

REQUIRED_COMMANDS=(
    ffmpeg
    gst-launch-1.0
    gst-inspect-1.0
    pw-dump
    pw-link
    python3
    timeout
)

for REQUIRED_COMMAND in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        echo "Capture command is unavailable: $REQUIRED_COMMAND" >&2
        exit 1
    fi
done

REQUIRED_GSTREAMER_ELEMENTS=(
    pipewiresrc
    queue
    videoconvert
    videorate
    videoscale
    identity
    x264enc
    h264parse
    mp4mux
    filesink
)

for REQUIRED_ELEMENT in "${REQUIRED_GSTREAMER_ELEMENTS[@]}"; do
    if ! gst-inspect-1.0 "$REQUIRED_ELEMENT" >/dev/null 2>&1; then
        echo "Required GStreamer element is unavailable: $REQUIRED_ELEMENT" >&2
        exit 1
    fi
done

echo
echo "Capture commands and GStreamer elements verified."
echo "Gamescope recorder: $CAPTURE_RECORDER"

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
