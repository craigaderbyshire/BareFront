#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MAME="/usr/games/mame"
GAMESCOPE="/usr/games/gamescope"
PRESENTATION_HELPER="$ROOT/c64_presentation_helper"
BARECRT="$ROOT/assets/shaders/barecrt/BareCRT_v2.fx"

OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-neogeo.conf"

GAMESCOPE_PID=""
PANELS_HIDDEN=0


if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mame_neogeo.sh <rom-archive>" >&2
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
    "$PRESENTATION_HELPER"
do
    if [[ ! -x "$required" ]]; then
        echo "Required Neo Geo executable not found:" >&2
        echo "  $required" >&2
        exit 1
    fi
done


if [[ ! -f "$BARECRT" ]]; then
    echo "BareCRT shader not found:" >&2
    echo "  $BARECRT" >&2
    exit 1
fi


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


cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $BARECRT
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
BareFrontScale = 4.0
EOF2


echo "Starting Neo Geo through BareFront..."
echo "  Set:          $SET_NAME"
echo "  MAME:         Neo Geo native raster / native rotation"
echo "  Source:       native 320x224 pixels"
echo "  Filtering:    disabled"
echo "  Gamescope:    dynamic integer scale into ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Scale filter: nearest"
echo "  CRT:          BareCRT"


# Release XFCE's reserved work area before Gamescope is created.
# This allows the 1920x1080 borderless Gamescope window to land
# at the true desktop origin rather than being displaced by the
# top panel.
"$PRESENTATION_HELPER" hide-panels
PANELS_HIDDEN=1

sleep 1


env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
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
