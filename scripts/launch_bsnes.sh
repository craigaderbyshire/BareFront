#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

BSNES="$ROOT/emulators/bsnes/bsnes"
GAMESCOPE="/usr/games/gamescope"

NATIVE_WIDTH=256
NATIVE_HEIGHT=224

INTEGER_SCALE=4

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_bsnes.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "SNES game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$BSNES" ]]; then
    echo "bsnes executable not found: $BSNES" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
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

export PULSE_SINK="$BAREFRONT_AUDIO_SINK"

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-snes.conf"

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
EOF2

echo "Starting SNES through per-game Gamescope..."
echo "  Native:   ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:  ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
barefront_audio_log

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
    "$BSNES" \
        --pseudo-fullscreen \
        "$ROM"
