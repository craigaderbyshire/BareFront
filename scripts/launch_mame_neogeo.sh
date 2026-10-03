#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"
MODE="${2:-}"

MAME="/usr/games/mame"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"
PRESENTATION_HELPER="$ROOT/c64_presentation_helper"
GUIDE_EXIT_HELPER="$ROOT/emulators/mame/mame_guide_exit_helper"

OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-neogeo.conf"

GAMESCOPE_PID=""
PANELS_HIDDEN=0


if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mame_neogeo.sh <rom-archive>" >&2
    exit 1
fi


if [[ -n "$MODE" && "$MODE" != "--dry-run" ]]; then
    echo "Invalid Neo Geo launch mode: $MODE" >&2
    exit 1
fi

if [[ "$ROM" != /* ]]; then
    ROM="$ROOT/${ROM#./}"
fi


if [[ ! -f "$ROM" ]]; then
    echo "Neo Geo ROM not found:" >&2
    echo "  $ROM" >&2
    exit 1
fi


for required in \
    "$MAME" \
    "$GAMESCOPE" \
    "$PRESENTATION_HELPER" \
    "$GUIDE_EXIT_HELPER"
do
    if [[ ! -x "$required" ]]; then
        echo "Required Neo Geo executable not found:" >&2
        echo "  $required" >&2
        exit 1
    fi
done





ROM_DIR="$(dirname "$ROM")"
ROM_FILE="$(basename "$ROM")"
SET_NAME="${ROM_FILE%.*}"

SAVE_ROOT="$ROOT/saves/neogeo/mame"

mkdir -p \
    "$SAVE_ROOT/cfg" \
    "$SAVE_ROOT/nvram" \
    "$SAVE_ROOT/states" \
    "$SAVE_ROOT/input"


# MAME accepts a semicolon-separated search path.
#
# The selected ROM directory comes first so curated local,
# removable or network-backed libraries work naturally.
# Standard BareFront Neo Geo locations remain available
# for parent and BIOS dependencies.
ROMPATH="$ROM_DIR;$ROOT/roms/neogeo;$ROOT/bios/neogeo"


# SSH shells normally have no graphical DISPLAY.
# Attach Neo Geo to the user's active local desktop when needed.
if [[ -z "${DISPLAY:-}" ]]; then

    SESSION_ID="$(
        loginctl show-user "$(id -un)" \
            --property=Display \
            --value \
            2>/dev/null || true
    )"

    LOCAL_DISPLAY="$(
        loginctl show-session "$SESSION_ID" \
            --property=Display \
            --value \
            2>/dev/null || true
    )"

    if [[ -z "$LOCAL_DISPLAY" ]]; then
        echo "No active local graphical session was found." >&2
        exit 1
    fi

    export DISPLAY="$LOCAL_DISPLAY"

    if [[ -f "$HOME/.Xauthority" ]]; then
        export XAUTHORITY="$HOME/.Xauthority"
    fi
fi


if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi


cleanup()
{
    local exit_code=$?

    trap - EXIT INT TERM

    if [[ -n "$GAMESCOPE_PID" ]]; then
        kill "$GAMESCOPE_PID" >/dev/null 2>&1 || true
        wait "$GAMESCOPE_PID" >/dev/null 2>&1 || true
    fi

    if [[ "$PANELS_HIDDEN" == "1" ]]; then
        "$PRESENTATION_HELPER" show-panels \
            >/dev/null 2>&1 || true
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM


PREFERENCES="${BAREFRONT_SHADER_PREFS:-$ROOT/saves/presentation/shaders.ini}"

SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r section value; do
        if [[ "$section" == "neogeo" ]]; then
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
        echo "STOP: Invalid Neo Geo shader preference: $SHADER" >&2
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
echo "BAREFRONT — NEO GEO"
echo "============================================================"
echo "Shader: $SHADER"
echo "Native: 320x224"
echo "Output: ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
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

# Release XFCE's reserved work area before Gamescope is created.
# This allows the 1920x1080 borderless Gamescope window to land
# at the true desktop origin rather than being displaced by the
# top panel.
"$PRESENTATION_HELPER" hide-panels
PANELS_HIDDEN=1

sleep 1


"${LAUNCH_ENV[@]}" \
    "$GAMESCOPE" \
        -b \
        -g \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        /bin/bash -c '
            guide="$1"
            shift

            BAREFRONT_MAME_GUIDE_SESSION=1 "$guide" &
            guide_pid=$!

            "$@" &
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
        "$MAME" \
            "$SET_NAME" \
            -rompath "$ROMPATH" \
            -cfg_directory "$SAVE_ROOT/cfg" \
            -nvram_directory "$SAVE_ROOT/nvram" \
            -state_directory "$SAVE_ROOT/states" \
            -input_directory "$SAVE_ROOT/input" \
            -skip_gameinfo \
            -window \
            -nomaximize \
            -video opengl \
            -nofilter \
            -prescale 1 \
            -nounevenstretch \
            -keepaspect \
            -view native &

GAMESCOPE_PID=$!


# Apply the invisible cursor once Gamescope's X11 window exists.
# No resident helper remains running during gameplay.
sleep 3

"$PRESENTATION_HELPER" hide-cursor || true


if wait "$GAMESCOPE_PID"; then
    GAME_EXIT=0
else
    GAME_EXIT=$?
fi

GAMESCOPE_PID=""

exit "$GAME_EXIT"
