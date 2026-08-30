#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mame.sh <rom-archive>" >&2
    exit 1
fi

ROM_DIR="$(dirname "$ROM")"
ROM_FILE="$(basename "$ROM")"
SET_NAME="${ROM_FILE%.*}"

# MAME accepts a semicolon-separated ROM search path.
#
# Include the selected game's own directory first, then both
# BareFront MAME-backed system libraries and BIOS directories.
ROMPATH="$ROM_DIR;$ROOT/roms/arcade;$ROOT/roms/neogeo;$ROOT/bios/arcade;$ROOT/bios/neogeo"

case "$ROM" in
    "$ROOT"/roms/neogeo/*|roms/neogeo/*|./roms/neogeo/*)
        SAVE_ROOT="$ROOT/saves/neogeo/mame"
        ;;
    *)
        SAVE_ROOT="$ROOT/saves/arcade/mame"
        ;;
esac

mkdir -p \
    "$SAVE_ROOT/cfg" \
    "$SAVE_ROOT/nvram" \
    "$SAVE_ROOT/states" \
    "$SAVE_ROOT/input"

exec /usr/games/mame \
    "$SET_NAME" \
    -rompath "$ROMPATH" \
    -cfg_directory "$SAVE_ROOT/cfg" \
    -nvram_directory "$SAVE_ROOT/nvram" \
    -state_directory "$SAVE_ROOT/states" \
    -input_directory "$SAVE_ROOT/input"
