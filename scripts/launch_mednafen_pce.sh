#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MEDNAFEN="/usr/games/mednafen"
PROFILE="$ROOT/saves/pcengine/mednafen"
CD_BIOS="$ROOT/bios/pcengine/syscard3.pce"

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

exec env \
    MEDNAFEN_HOME="$PROFILE" \
    "$MEDNAFEN" \
        -force_module pce_fast \
        -pce_fast.cdbios "$CD_BIOS" \
        -pce_fast.shader none \
        -pce_fast.special none \
        -pce_fast.videoip 0 \
        -pce_fast.scanlines 0 \
        -sound.driver alsa \
        -sound.device sexyal-literal-default \
        -video.fs 0 \
        -command.exit "keyboard 0x0 41" \
        "$ROM"
