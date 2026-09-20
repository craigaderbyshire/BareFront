#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

DOLPHIN="/usr/games/dolphin-emu"
GAMESCOPE="/usr/games/gamescope"
DOLPHIN_USER_DIR="$ROOT/saves/gamecube/dolphin"

NATIVE_WIDTH=640
NATIVE_HEIGHT=480
INTEGER_SCALE=2

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_dolphin.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "GameCube game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$DOLPHIN" ]]; then
    echo "Dolphin executable not found: $DOLPHIN" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi

if [[ ! -d "$DOLPHIN_USER_DIR" ]]; then
    echo "BareFront Dolphin profile not found:" >&2
    echo "  $DOLPHIN_USER_DIR" >&2
    echo "Run the BareFront installer before launching GameCube." >&2
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-gamecube.conf"

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT_v2.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
BareFrontScale = 2.0
EOF2

echo "Starting GameCube through per-game Gamescope..."
echo "  Native:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"

exec env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -w "$NATIVE_WIDTH" \
        -h "$NATIVE_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        "$DOLPHIN" \
            -u "$DOLPHIN_USER_DIR" \
            -C Dolphin.Analytics.PermissionAsked=True \
            -C Dolphin.Analytics.Enabled=False \
            -C Dolphin.Core.SkipIPL=False \
            -C Dolphin.Interface.ConfirmStop=False \
            -C GFX.Settings.InternalResolution=1 \
            -C GFX.Settings.MSAA=1 \
            -C GFX.Settings.SSAA=False \
            -C GFX.Settings.AspectRatio=0 \
            -C GFX.Settings.Crop=False \
            -C GFX.Settings.wideScreenHack=False \
            -C GFX.Enhancements.ForceTextureFiltering=0 \
            -C GFX.Enhancements.MaxAnisotropy=0 \
            -b \
            -e "$ROM"
