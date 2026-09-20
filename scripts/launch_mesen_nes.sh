#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MESEN="$ROOT/emulators/mesen/Mesen"
GAMESCOPE="/usr/games/gamescope"

NATIVE_WIDTH=256
NATIVE_HEIGHT=240
INTEGER_SCALE=4

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: $0 <rom>"
    exit 2
fi

if [[ ! -f "$ROM" ]]; then
    echo "ROM not found: $ROM"
    exit 1
fi

if [[ ! -x "$MESEN" ]]; then
    echo "Mesen executable not found: $MESEN"
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE"
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-nes.conf"

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT_v2.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
BareFrontScale = 4.0
EOF2

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
        "$MESEN" \
        /fullscreen \
        "$ROM"
