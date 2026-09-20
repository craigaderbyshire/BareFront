#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MEDNAFEN="/usr/games/mednafen"
GAMESCOPE="/usr/games/gamescope"

PROFILE="$ROOT/saves/pcengine/mednafen"
CD_BIOS="$ROOT/bios/pcengine/syscard3.pce"

NATIVE_WIDTH=288
NATIVE_HEIGHT=232

INTEGER_SCALE=4

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))


if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mednafen_pce.sh <game-file>" >&2
    exit 1
fi


if [[ ! -f "$ROM" ]]; then
    echo "PC Engine game not found: $ROM" >&2
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


if ! command -v pasuspender >/dev/null 2>&1; then
    echo "pasuspender not found." >&2
    exit 1
fi


if [[ ! -f "$PROFILE/mednafen.cfg" ]]; then
    echo "BareFront PC Engine profile not found:" >&2
    echo "  $PROFILE/mednafen.cfg" >&2
    echo "Run the BareFront installer before launching PC Engine." >&2
    exit 1
fi


case "${ROM,,}" in
    *.cue|*.ccd|*.toc|*.m3u)
        if [[ ! -f "$CD_BIOS" ]]; then
            echo "PC Engine CD System Card not found:" >&2
            echo "  $CD_BIOS" >&2
            exit 1
        fi
        ;;
esac


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


echo "Starting PC Engine through per-game Gamescope..."
echo "  Native:   ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:  ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
barefront_audio_log


VKBASALT_CONFIG="/tmp/barefront-vkbasalt-pcengine.conf"

cat > "$VKBASALT_CONFIG" <<EOF
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT_v2.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
BareFrontScale = 4.0
EOF


exec pasuspender -- \
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
            -force_module pce_fast \
            -pce_fast.cdbios "$CD_BIOS" \
            -pce_fast.shader none \
            -pce_fast.special none \
            -pce_fast.videoip 0 \
            -pce_fast.scanlines 0 \
            -pce_fast.correct_aspect 0 \
            -pce_fast.xscale 1 \
            -pce_fast.yscale 1 \
            -sound.driver alsa \
            -sound.device "$AUDIO_DEVICE" \
            -sound.rate 48000 \
            -sound.buffer_time 20 \
            -video.fs 0 \
            -command.exit "keyboard 0x0 41" \
            "$ROM"
