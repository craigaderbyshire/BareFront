#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--dry-run" ]]; then
    MODE="--dry-run"
    ROM="${2:-}"
else
    MODE="launch"
    ROM="${1:-}"
fi

DUCKSTATION="$ROOT/emulators/duckstation/DuckStation.AppImage"
GUIDE_EXIT_HELPER="$ROOT/emulators/duckstation/duckstation_guide_exit_helper"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"

GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"

NATIVE_WIDTH=640
NATIVE_HEIGHT=480
INTEGER_SCALE=2

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_duckstation.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "PlayStation game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$DUCKSTATION" ]]; then
    echo "DuckStation executable not found: $DUCKSTATION" >&2
    exit 1
fi

if [[ ! -x "$GUIDE_EXIT_HELPER" ]]; then
    echo "DuckStation Guide helper missing: $GUIDE_EXIT_HELPER" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-ps1.conf"

PREFERENCES="${BAREFRONT_SHADER_PREFS:-$ROOT/saves/presentation/shaders.ini}"
SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r section value; do
        if [[ "$section" == "ps1" ]]; then
            SHADER="${value%$'\r'}"
        fi
    done < "$PREFERENCES"
fi

EFFECT=""
SHADER_FILE=""
INCLUDE_DIR=""
SETTINGS=""

case "$SHADER" in
    NONE)
        ;;
    BARECRT)
        EFFECT="barecrt"
        INCLUDE_DIR="$ROOT/assets/shaders/barecrt"
        SHADER_FILE="$INCLUDE_DIR/BareCRT_v2.fx"
        SETTINGS="BareFrontScale = 2.0"
        ;;
    CRT-LITE)
        EFFECT="CRT_Lite"
        INCLUDE_DIR="$ROOT/assets/shaders/crt-lite"
        SHADER_FILE="$INCLUDE_DIR/CRT_Lite.fx"
        SETTINGS="SCANLINE_COUNT = 0.0"
        ;;
    CRT-LOTTES)
        EFFECT="CRT_Lottes"
        INCLUDE_DIR="$ROOT/assets/shaders/crt-lottes"
        SHADER_FILE="$INCLUDE_DIR/CRT_Lottes_PS1_TIMED.fx"
        SETTINGS="fBlur = 2.6"
        ;;
    *)
        echo "STOP: Invalid PS1 shader preference: $SHADER" >&2
        exit 1
        ;;
esac

if [[ "$SHADER" != "NONE" ]]; then
    for required in "$SHADER_FILE" "$INCLUDE_DIR/ReShade.fxh"; do
        if [[ ! -f "$required" ]]; then
            echo "STOP: Missing shader dependency: $required" >&2
            exit 1
        fi
    done

    if [[ "$SHADER" == "CRT-LOTTES" &&
          ! -f "$INCLUDE_DIR/CRT_Lottes.fxh" ]]; then
        echo "STOP: CRT_Lottes.fxh is missing." >&2
        exit 1
    fi
fi

echo "Shader: $SHADER"

if [[ "$MODE" == "--dry-run" ]]; then
    echo "PASS: Dry run only — no game launched."
    exit 0
fi

if [[ "$SHADER" == "NONE" ]]; then
    LAUNCH_ENV=(env -u VKBASALT_CONFIG_FILE ENABLE_VKBASALT=0)
else
    cat > "$VKBASALT_CONFIG" <<EOF2
effects = $EFFECT
$EFFECT = $SHADER_FILE
reshadeIncludePath = $INCLUDE_DIR
reshadeTexturePath = $INCLUDE_DIR
enableOnLaunch = True
$SETTINGS
EOF2

    LAUNCH_ENV=(
        env
        ENABLE_VKBASALT=1
        VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG"
    )
fi

echo "Starting PlayStation through per-game Gamescope..."
echo "  Canvas:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"

exec "${LAUNCH_ENV[@]}" \
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
        /bin/bash -c '
            guide="$1"
            shift

            BAREFRONT_PS1_GUIDE_SESSION=1 \
            BAREFRONT_PS1_DISC_CONTROL=1 \
                "$guide" &
            guide_pid=$!

            QT_QPA_PLATFORM=xcb "$@" &
            game_pid=$!

            cleanup() {
                kill -TERM "$guide_pid" 2>/dev/null || true
                wait "$guide_pid" 2>/dev/null || true
            }

            trap cleanup EXIT

            if wait "$game_pid"; then
                status=0
            else
                status=$?
            fi

            exit "$status"
        ' _ \
        "$GUIDE_EXIT_HELPER" \
        "$DUCKSTATION" \
            -batch \
            -fullscreen \
            -slowboot \
            -- \
            "$ROM"
