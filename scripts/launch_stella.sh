#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"
MODE="${2:-}"

STELLA="/usr/bin/stella"
GUIDE_EXIT_HELPER="$ROOT/emulators/stella/stella_guide_exit_helper"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"
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
    echo "Usage: launch_stella.sh <game-file> [--dry-run]" >&2
    exit 1
fi

if (( $# > 2 )) || [[ -n "$MODE" && "$MODE" != "--dry-run" ]]; then
    echo "Usage: launch_stella.sh <game-file> [--dry-run]" >&2
    exit 2
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

if [[ ! -x "$GUIDE_EXIT_HELPER" ]]; then
    echo "Stella Guide exit helper not found: $GUIDE_EXIT_HELPER" >&2
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

PREFERENCES="${BAREFRONT_SHADER_PREFS:-$ROOT/saves/presentation/shaders.ini}"

SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r section value; do
        if [[ "$section" == "atari2600" ]]; then
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
        echo "STOP: Invalid Atari 2600 shader preference: $SHADER" >&2
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
echo "BAREFRONT — ATARI 2600"
echo "============================================================"
echo "Shader: $SHADER"
echo "Stella surface: 640x456"
echo "Output: 1280x912"
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
    SESSION_DIR="$(mktemp -d /tmp/barefront-atari2600-shader.XXXXXX)"
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
        -g \
        -w "$STELLA_WIDTH" \
        -h "$STELLA_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        /bin/bash -c '
            guide="$1"
            shift

            BAREFRONT_STELLA_GUIDE_SESSION=1 "$guide" &
            guide_pid=$!

            "$@" &
            game_pid=$!

            cleanup() {
                kill -TERM "$guide_pid" 2>/dev/null || true
                sleep 0.2
                kill -KILL "$guide_pid" 2>/dev/null || true
                wait "$guide_pid" 2>/dev/null || true
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
        "$GUIDE_EXIT_HELPER" \
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
