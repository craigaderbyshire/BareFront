#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MEDNAFEN="/usr/games/mednafen"
PROFILE="$ROOT/saves/saturn/mednafen"
NA_EU_BIOS="$ROOT/bios/saturn/mpr-17933.bin"
JP_BIOS="$ROOT/bios/saturn/sega_101.bin"

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mednafen_saturn.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "Saturn game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$MEDNAFEN" ]]; then
    echo "Mednafen executable not found: $MEDNAFEN" >&2
    exit 1
fi

if [[ ! -f "$PROFILE/mednafen.cfg" ]]; then
    echo "BareFront Saturn profile not found:" >&2
    echo "  $PROFILE/mednafen.cfg" >&2
    echo "Run the BareFront installer before launching Saturn." >&2
    exit 1
fi

if [[ ! -f "$NA_EU_BIOS" && ! -f "$JP_BIOS" ]]; then
    echo "No Saturn BIOS files found in:" >&2
    echo "  $ROOT/bios/saturn" >&2
    exit 1
fi

exec env \
    MEDNAFEN_HOME="$PROFILE" \
    "$MEDNAFEN" \
        -loadcd ss \
        -ss.bios_na_eu "$NA_EU_BIOS" \
        -ss.bios_jp "$JP_BIOS" \
        -ss.shader none \
        -ss.special none \
        -ss.videoip 0 \
        -ss.scanlines 0 \
        -cd.image_memcache 1 \
        -sound.driver alsa \
        -sound.device sexyal-literal-default \
        -video.fs 0 \
        -command.exit "keyboard 0x0 41" \
        "$ROM"
