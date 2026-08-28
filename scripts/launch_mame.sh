#!/bin/bash

ROM="$1"

if [ -z "$ROM" ]; then
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROMDIR="$(dirname "$ROM")"
ROMFILE="$(basename "$ROM")"
ROMSET="${ROMFILE%.*}"

exec /usr/games/mame \
    -rompath "$ROMDIR;$ROOT/bios/arcade;$ROOT/bios/neogeo" \
    "$ROMSET"
