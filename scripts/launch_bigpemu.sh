#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

BIGPEMU="$ROOT/emulators/bigpemu/BigPEmu"
ESC_HELPER="$ROOT/emulators/bigpemu/bigpemu_esc_helper"
GAMESCOPE="/usr/games/gamescope"

NATIVE_WIDTH=320
NATIVE_HEIGHT=240
INTEGER_SCALE=4
OUTPUT_WIDTH=1280
OUTPUT_HEIGHT=960

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_bigpemu.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "Jaguar ROM not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$BIGPEMU" ]]; then
    echo "BigPEmu executable not found: $BIGPEMU" >&2
    exit 1
fi

if [[ ! -x "$ESC_HELPER" ]]; then
    echo "BigPEmu Esc helper not found: $ESC_HELPER" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi

if [[ ! -f "$ROOT/assets/shaders/barecrt/BareCRT_v2.fx" ]]; then
    echo "BareCRT shader not found." >&2
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-jaguar.conf"

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT_v2.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
BareFrontScale = 4.0
EOF2

echo "Starting Atari Jaguar through per-game Gamescope..."
echo "  Native:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
echo "  BareCRT:     enabled"

env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -w "$NATIVE_WIDTH" \
        -h "$NATIVE_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        "$BIGPEMU" \
            "$ROM" \
            -localdata \
            -forcewidth "$NATIVE_WIDTH" \
            -forceheight "$NATIVE_HEIGHT" \
            -noborder &

gamescope_pid=$!
esc_pid=""

cleanup()
{
    if [[ -n "$esc_pid" ]]; then
        kill "$esc_pid" 2>/dev/null || true
        wait "$esc_pid" 2>/dev/null || true
    fi
}

trap cleanup EXIT

#
# Gamescope launches the game through gamescopereaper:
#
#   gamescope
#     └─ gamescopereaper
#          └─ BigPEmu
#
# BigPEmu runs on Gamescope's nested Xwayland display rather than the
# host X display. Discover both the emulator PID and that DISPLAY before
# starting BareFront's Esc helper.
#
emu_pid=""

for _ in {1..100}; do
    if ! kill -0 "$gamescope_pid" 2>/dev/null; then
        break
    fi

    reaper_pid="$(
        pgrep -P "$gamescope_pid" -x gamescopereaper 2>/dev/null |
        head -1 || true
    )"

    if [[ -n "$reaper_pid" ]]; then
        emu_pid="$(
            pgrep -P "$reaper_pid" -x BigPEmu 2>/dev/null |
            head -1 || true
        )"
    fi

    if [[ -n "$emu_pid" ]]; then
        break
    fi

    sleep 0.05
done

if [[ -z "$emu_pid" ]]; then
    echo "Could not discover BigPEmu inside Gamescope." >&2
    kill "$gamescope_pid" 2>/dev/null || true
    wait "$gamescope_pid" 2>/dev/null || true
    exit 1
fi

emu_display="$(
    tr '\0' '\n' < "/proc/$emu_pid/environ" |
    sed -n 's/^DISPLAY=//p' |
    head -1
)"

if [[ -z "$emu_display" ]]; then
    echo "Could not determine BigPEmu X display." >&2
    kill "$gamescope_pid" 2>/dev/null || true
    wait "$gamescope_pid" 2>/dev/null || true
    exit 1
fi

env DISPLAY="$emu_display" \
    "$ESC_HELPER" "$emu_pid" &

esc_pid=$!

status=0
wait "$gamescope_pid" || status=$?

exit "$status"
