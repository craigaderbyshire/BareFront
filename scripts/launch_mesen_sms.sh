#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"
MODE="${2:-}"

MESEN="$ROOT/emulators/mesen/Mesen"
MENU_NUDGE_HELPER="$ROOT/emulators/mesen/mesen_menu_nudge_helper"
GUIDE_EXIT_HELPER="$ROOT/emulators/mesen/mesen_guide_exit_helper"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"

NATIVE_WIDTH=256
NATIVE_HEIGHT=192
INTEGER_SCALE=4

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: $0 <rom> [--dry-run]"
    exit 2
fi

if (( $# > 2 )) || [[ -n "$MODE" && "$MODE" != "--dry-run" ]]; then
    echo "Usage: $0 <rom> [--dry-run]"
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

if [[ ! -x "$MENU_NUDGE_HELPER" ]]; then
    echo "Mesen menu nudge helper not found: $MENU_NUDGE_HELPER"
    exit 1
fi

if [[ ! -x "$GUIDE_EXIT_HELPER" ]]; then
    echo "Mesen Guide exit helper not found: $GUIDE_EXIT_HELPER"
    exit 1
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

PREFERENCES="${BAREFRONT_SHADER_PREFS:-$ROOT/saves/presentation/shaders.ini}"

SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r section value; do
        if [[ "$section" == "mastersystem" ]]; then
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
        SETTINGS="BareFrontScale = 4.0"
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
        SHADER_FILE="$INCLUDE_DIR/CRT_Lottes.fx"
        SETTINGS="$(printf 'fDownscale = 4.0\nfBlur = 2.6')"
        ;;

    *)
        echo "STOP: Invalid Master System shader preference: $SHADER" >&2
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

echo "============================================================"
echo "BAREFRONT — MASTER SYSTEM"
echo "============================================================"
echo "Shader: $SHADER"
echo "Native: 256x192"
echo "Output: 1024x768"
echo "Scaling: integer / nearest"

if [[ "$SHADER" == "NONE" ]]; then
    echo "vkBasalt: disabled"
else
    echo "vkBasalt: enabled"
    echo "Shader file: $SHADER_FILE"
fi

if [[ "$MODE" == "--dry-run" ]]; then
    echo "PASS: Dry run only — no game launched."
    exit 0
fi

if [[ "$SHADER" == "NONE" ]]; then
    LAUNCH_ENV=(env -u VKBASALT_CONFIG_FILE ENABLE_VKBASALT=0)
else
    SESSION_DIR="$(mktemp -d /tmp/barefront-mastersystem-shader.XXXXXX)"
    trap 'rm -rf -- "$SESSION_DIR"' EXIT

    VKBASALT_CONFIG="$SESSION_DIR/vkbasalt.conf"

    cat > "$VKBASALT_CONFIG" <<CONF
effects = $EFFECT
$EFFECT = $SHADER_FILE
reshadeIncludePath = $INCLUDE_DIR
reshadeTexturePath = $INCLUDE_DIR
enableOnLaunch = True
$SETTINGS
CONF

    LAUNCH_ENV=(
        env
        ENABLE_VKBASALT=1
        VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG"
    )
fi

"${LAUNCH_ENV[@]}" \
    "$GAMESCOPE" \
        -b \
        -w "$NATIVE_WIDTH" \
        -h "$NATIVE_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        /bin/bash -c '
            menu="$1"
            guide="$2"
            shift 2

            "$menu" &
            menu_pid=$!

            BAREFRONT_MESEN_GUIDE_SESSION=1 "$guide" &
            guide_pid=$!

            "$@" &
            game_pid=$!

            cleanup() {
                kill -TERM "$guide_pid" "$menu_pid" 2>/dev/null || true
                sleep 0.2
                kill -KILL "$guide_pid" "$menu_pid" 2>/dev/null || true
                wait "$guide_pid" "$menu_pid" 2>/dev/null || true
            }

            trap cleanup EXIT

            if wait "$game_pid"; then
                game_status=0
            else
                game_status=$?
            fi

            cleanup
            trap - EXIT

            exit "$game_status"
        ' _ \
        "$MENU_NUDGE_HELPER" \
        "$GUIDE_EXIT_HELPER" \
        "$MESEN" \
        "$ROM" \
        --fullscreen
