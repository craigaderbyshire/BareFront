#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MEDNAFEN="/usr/games/mednafen"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"
PROFILE="$ROOT/saves/megadrive/mednafen"
CONTROL_HELPER="$ROOT/emulators/mednafen/megadrive_controller_helper"

NATIVE_WIDTH=320
NATIVE_HEIGHT=224
INTEGER_SCALE=4

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mednafen_md.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "Mega Drive game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$MEDNAFEN" ]]; then
    echo "Mednafen executable not found: $MEDNAFEN" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi

if [[ ! -x "$CONTROL_HELPER" ]]; then
    echo "Mega Drive controller helper not found: $CONTROL_HELPER" >&2
    exit 1
fi

if ! command -v pasuspender >/dev/null 2>&1; then
    echo "pasuspender not found." >&2
    exit 1
fi

if [[ ! -f "$PROFILE/mednafen.cfg" ]]; then
    echo "BareFront Mega Drive Mednafen profile not found:" >&2
    echo "  $PROFILE/mednafen.cfg" >&2
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

AUDIO_HELPER="$ROOT/scripts/barefront_audio.sh"

if [[ ! -f "$AUDIO_HELPER" ]]; then
    echo "BareFront audio helper not found:" >&2
    echo "  $AUDIO_HELPER" >&2
    exit 1
fi

source "$AUDIO_HELPER"

if ! barefront_audio_resolve; then
    exit 1
fi

AUDIO_DEVICE="$BAREFRONT_MEDNAFEN_DEVICE"

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-megadrive.conf"

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT_v2.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
BareFrontScale = 4.0
EOF2

echo "Starting Mega Drive through per-game Gamescope..."
echo "  Native:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
barefront_audio_log

SESSION_DIR="$(mktemp -d /tmp/barefront-megadrive.XXXXXX)"
GAME_LOG="$SESSION_DIR/gamescope.log"
CONTROL_LOG="$SESSION_DIR/controller.log"

CONTROL_HELPER_PID=""

cleanup()
{
    if [[ -n "$CONTROL_HELPER_PID" ]]; then
        if kill -0 "$CONTROL_HELPER_PID" 2>/dev/null; then
            kill "$CONTROL_HELPER_PID" 2>/dev/null || true
        fi

        wait "$CONTROL_HELPER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo "  Session logs: $SESSION_DIR"

pasuspender -- \
    env \
        ENABLE_VKBASALT=1 \
        VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
        "$GAMESCOPE" \
            -b \
            -w "$NATIVE_WIDTH" \
            -h "$NATIVE_HEIGHT" \
            -W "$OUTPUT_WIDTH" \
            -H "$OUTPUT_HEIGHT" \
            -S integer \
            -F nearest \
            -- \
            env \
                MEDNAFEN_HOME="$PROFILE" \
                "$MEDNAFEN" \
                    -force_module md \
                    -sound.driver alsa \
                    -sound.device "$AUDIO_DEVICE" \
                    -sound.rate 48000 \
                    -sound.buffer_time 20 \
                    -md.correct_aspect 0 \
                    -md.scanlines 0 \
                    -md.shader none \
                    -md.stretch 0 \
                    -md.videoip 0 \
                    -md.xscale 1 \
                    -md.yscale 1 \
                    -video.fs 0 \
                    -command.exit "keyboard 0x0 41" \
                    "$ROM" > "$GAME_LOG" 2>&1 &

GAME_PID=$!

BAREFRONT_MEGADRIVE_CONTROL_SESSION=1 \
    "$CONTROL_HELPER" > "$CONTROL_LOG" 2>&1 &

CONTROL_HELPER_PID=$!

STATUS=0
wait "$GAME_PID" || STATUS=$?

cleanup
CONTROL_HELPER_PID=""

echo
echo "=== MEGA DRIVE CONTROLLER RESULT ==="
cat "$CONTROL_LOG" 2>/dev/null || true

echo
echo "=== MEGA DRIVE GAME EXIT STATUS ==="
echo "$STATUS"

exit "$STATUS"
