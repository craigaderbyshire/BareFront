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

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-arcade.conf"

GAMESCOPE_PID=""
PANELS_HIDDEN=0


if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mame_arcade.sh <rom-archive>" >&2
    exit 1
fi


if [[ "$ROM" != /* ]]; then
    ROM="$ROOT/${ROM#./}"
fi


if [[ ! -f "$ROM" ]]; then
    echo "Arcade ROM not found:" >&2
    echo "  $ROM" >&2
    exit 1
fi


for required in \
    "$MAME" \
    "$GAMESCOPE" \
    "$PRESENTATION_HELPER"
do
    if [[ ! -x "$required" ]]; then
        echo "Required Arcade executable not found:" >&2
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


# ------------------------------------------------------------
# Arcade raster geometry policy
#
# BareFront never permits arbitrary fractional raster scaling.
# Normal ROM-backed raster games remain at their native pixel
# geometry. Exact transformations are allowed only where they
# have been specifically proven lossless.
#
# MAME metadata is used to identify parent/clone families so a
# validated rule applies automatically to the whole family.
# ------------------------------------------------------------

MAME_XML="$(
    "$MAME" -listxml "$SET_NAME" 2>/dev/null || true
)"

MACHINE_LINE="$(
    printf '%s\n' "$MAME_XML" |
        grep -m1 '<machine ' || true
)"

DISPLAY_LINE="$(
    printf '%s\n' "$MAME_XML" |
        grep -m1 '<display ' || true
)"

CLONE_OF="$(
    printf '%s\n' "$MACHINE_LINE" |
        sed -n 's/.* cloneof="\([^"]*\)".*/\1/p'
)"

SOURCE_FILE="$(
    printf '%s\n' "$MACHINE_LINE" |
        sed -n 's/.* sourcefile="\([^"]*\)".*/\1/p'
)"

NATIVE_WIDTH="$(
    printf '%s\n' "$DISPLAY_LINE" |
        sed -n 's/.* width="\([^"]*\)".*/\1/p'
)"

NATIVE_HEIGHT="$(
    printf '%s\n' "$DISPLAY_LINE" |
        sed -n 's/.* height="\([^"]*\)".*/\1/p'
)"

NATIVE_ROTATE="$(
    printf '%s\n' "$DISPLAY_LINE" |
        sed -n 's/.* rotate="\([^"]*\)".*/\1/p'
)"

FAMILY_ROOT="${CLONE_OF:-$SET_NAME}"

GEOMETRY_MODE="native raster / integer pixels"

PRESENTATION_WIDTH="$NATIVE_WIDTH"
PRESENTATION_HEIGHT="$NATIVE_HEIGHT"

MAME_GEOMETRY_ARGS=(
    -nounevenstretch
    -nounevenstretchx
    -nounevenstretchy
    -noautostretchxy
    -keepaspect
)


case "$FAMILY_ROOT" in

    wboy)
        # Wonder Boy hardware exposes a 512x224 raster in MAME,
        # but direct frame analysis proved every adjacent pair
        # of horizontal columns is identical (100.0000%).
        #
        # Collapse those duplicate columns exactly 2:1:
        #
        #     512x224 -> 256x224
        #
        # This is lossless and introduces no periodic sampling.
        if [[ "$NATIVE_WIDTH" == "512" &&
              "$NATIVE_HEIGHT" == "224" &&
              "$NATIVE_ROTATE" == "0" ]]; then

            GEOMETRY_MODE="lossless Wonder Boy X/2: 512x224 -> 256x224"

            PRESENTATION_WIDTH=256
            PRESENTATION_HEIGHT=224

            MAME_GEOMETRY_ARGS=(
                -resolution 256x224
                -nounevenstretch
                -unevenstretchx
                -nounevenstretchy
                -noautostretchxy
                -nokeepaspect
            )
        fi
        ;;

esac


# ------------------------------------------------------------
# BareCRT presentation geometry
#
# MAME rotates vertical games before Gamescope receives them.
# Therefore rotate=90/270 swaps the presented width/height.
#
# BareCRTScale describes the final output pixels occupied by one
# emulated source pixel. BeamAxis follows the physical CRT:
#
#   0 = horizontal scanlines
#   1 = vertical scanlines for a rotated/TATE monitor
#
# Phase aligns the beam pattern with the centred integer-scaled
# image rather than the top-left corner of the 1080p backbuffer.
# ------------------------------------------------------------

if [[ ! "$PRESENTATION_WIDTH" =~ ^[0-9]+$ ||
      ! "$PRESENTATION_HEIGHT" =~ ^[0-9]+$ ||
      "$PRESENTATION_WIDTH" -le 0 ||
      "$PRESENTATION_HEIGHT" -le 0 ]]; then

    echo "Unable to determine valid Arcade raster geometry." >&2
    exit 1
fi


case "$NATIVE_ROTATE" in

    0|180)
        DISPLAY_WIDTH="$PRESENTATION_WIDTH"
        DISPLAY_HEIGHT="$PRESENTATION_HEIGHT"
        BAREFRONT_BEAM_AXIS=0
        ;;

    90|270)
        DISPLAY_WIDTH="$PRESENTATION_HEIGHT"
        DISPLAY_HEIGHT="$PRESENTATION_WIDTH"
        BAREFRONT_BEAM_AXIS=1
        ;;

    *)
        echo "Unsupported MAME rotation: ${NATIVE_ROTATE:-unknown}" >&2
        exit 1
        ;;

esac


SCALE_X=$((OUTPUT_WIDTH / DISPLAY_WIDTH))
SCALE_Y=$((OUTPUT_HEIGHT / DISPLAY_HEIGHT))

if (( SCALE_X < SCALE_Y )); then
    BAREFRONT_SCALE=$SCALE_X
else
    BAREFRONT_SCALE=$SCALE_Y
fi


if (( BAREFRONT_SCALE < 1 )); then
    echo "Arcade raster does not fit the configured output." >&2
    exit 1
fi


LEFT_MARGIN=$((
    (OUTPUT_WIDTH -
     (DISPLAY_WIDTH * BAREFRONT_SCALE)) / 2
))

TOP_MARGIN=$((
    (OUTPUT_HEIGHT -
     (DISPLAY_HEIGHT * BAREFRONT_SCALE)) / 2
))


BAREFRONT_PHASE_X=0
BAREFRONT_PHASE_Y=0

if (( BAREFRONT_BEAM_AXIS == 1 )); then
    BAREFRONT_PHASE_X=$((
        LEFT_MARGIN % BAREFRONT_SCALE
    ))
else
    BAREFRONT_PHASE_Y=$((
        TOP_MARGIN % BAREFRONT_SCALE
    ))
fi


SAVE_ROOT="$ROOT/saves/arcade/mame"

mkdir -p \
    "$SAVE_ROOT/cfg" \
    "$SAVE_ROOT/nvram" \
    "$SAVE_ROOT/states" \
    "$SAVE_ROOT/input"


# MAME accepts a semicolon-separated search path.
#
# The selected ROM directory comes first so curated local,
# removable or network-backed libraries work naturally.
# Standard BareFront Arcade / Neo Geo locations remain available
# for parent, device and BIOS dependencies.
ROMPATH="$ROM_DIR;$ROOT/roms/arcade;$ROOT/roms/neogeo;$ROOT/bios/arcade;$ROOT/bios/neogeo"


# SSH shells normally have no graphical DISPLAY.
# Attach Arcade to the user's active local desktop when needed.
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
toggleKey = F8
BareFrontScale = ${BAREFRONT_SCALE}.0
BareFrontBeamAxis = ${BAREFRONT_BEAM_AXIS}.0
BareFrontPhaseX = ${BAREFRONT_PHASE_X}.0
BareFrontPhaseY = ${BAREFRONT_PHASE_Y}.0
EOF2


echo "Starting Arcade through BareFront..."
echo "  Set:          $SET_NAME"
echo "  MAME:         native raster / native rotation"
echo "  Driver:       ${SOURCE_FILE:-unknown}"
echo "  Family:       $FAMILY_ROOT"
echo "  Raster:       ${NATIVE_WIDTH:-?}x${NATIVE_HEIGHT:-?} rotate=${NATIVE_ROTATE:-?}"
echo "  Geometry:     $GEOMETRY_MODE"
echo "  Filtering:    disabled"
echo "  Gamescope:    dynamic integer scale into ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Scale filter: nearest"
echo "  CRT:          BareCRT v2"
echo "  CRT raster:   ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"
echo "  CRT scale:    ${BAREFRONT_SCALE}x"
echo "  CRT axis:     $([[ "$BAREFRONT_BEAM_AXIS" == "1" ]] && echo vertical || echo horizontal)"
echo "  CRT phase:    X=${BAREFRONT_PHASE_X} Y=${BAREFRONT_PHASE_Y}"


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
            "${MAME_GEOMETRY_ARGS[@]}" \
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
