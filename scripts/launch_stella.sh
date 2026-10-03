#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

STELLA="/usr/bin/stella"
GAMESCOPE="/usr/games/gamescope"
PROFILE="$ROOT/saves/atari2600/stella"

# Stella 7.0's pixel-exact TIA buffer is 320x228, but Stella's
# minimum crisp presentation surface is an exact 2x: 640x456.
#
# Gamescope therefore receives Stella's unfiltered 640x456 surface
# and performs the remaining exact 2x nearest-neighbour enlargement.
STELLA_WIDTH=640
STELLA_HEIGHT=456

INTEGER_SCALE=2

OUTPUT_WIDTH=$((STELLA_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((STELLA_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_stella.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "Atari 2600 game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$STELLA" ]]; then
    echo "Stella executable not found: $STELLA" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi

if [[ ! -d "$PROFILE" ]]; then
    echo "BareFront Stella profile not found:" >&2
    echo "  $PROFILE" >&2
    echo "Run the BareFront installer before launching Atari 2600." >&2
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-atari2600.conf"

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT_v2.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
BareFrontScale = 4.0
EOF2

echo "Starting Atari 2600 through per-game Gamescope..."
echo "  Stella surface: ${STELLA_WIDTH}x${STELLA_HEIGHT}"
echo "  Gamescope:      ${INTEGER_SCALE}x nearest"
echo "  Output:         ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  TIA filtering:  off"
echo "  BareCRT:        enabled"

env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -w "$STELLA_WIDTH" \
        -h "$STELLA_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        "$STELLA" \
            -basedir "$PROFILE" \
            -video opengl \
            -fullscreen 0 \
            -hidpi 0 \
            -tia.zoom 1 \
            -tia.inter 0 \
            -tia.correct_aspect 0 \
            -tv.filter 0 \
            -tv.phosblend 0 \
            -tv.scanlines 0 \
            -pp No \
            -exitlauncher 0 \
            -confirmexit 0 \
            "$ROM"
