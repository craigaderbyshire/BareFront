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

exec /usr/games/mame \
    "$SET_NAME" \
    -rompath "$ROMPATH"
