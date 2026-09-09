#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MEDNAFEN="/usr/games/mednafen"
GAMESCOPE="/usr/games/gamescope"

PROFILE="$ROOT/saves/pcengine/mednafen"
CD_BIOS="$ROOT/bios/pcengine/syscard3.pce"

NATIVE_WIDTH=288
NATIVE_HEIGHT=232

INTEGER_SCALE=4

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))


if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mednafen_pce.sh <game-file>" >&2
    exit 1
fi


if [[ ! -f "$ROM" ]]; then
    echo "PC Engine game not found: $ROM" >&2
    exit 1
fi


if [[ ! -x "$MEDNAFEN" ]]; then
    echo "Mednafen executable not found: $MEDNAFEN" >&2
    exit 1
fi


if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi


if [[ ! -f "$PROFILE/mednafen.cfg" ]]; then
    echo "BareFront PC Engine profile not found:" >&2
    echo "  $PROFILE/mednafen.cfg" >&2
    echo "Run the BareFront installer before launching PC Engine." >&2
    exit 1
fi


case "${ROM,,}" in
    *.cue|*.ccd|*.toc|*.m3u)
        if [[ ! -f "$CD_BIOS" ]]; then
            echo "PC Engine CD System Card not found:" >&2
            echo "  $CD_BIOS" >&2
            exit 1
        fi
        ;;
esac


if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi


echo "Starting PC Engine through per-game Gamescope..."
echo "  Native:   ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:  ${INTEGER_SCALE}x"
echo "  Output:   ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:   nearest"


# --------------------------------------------------
# PC Engine display timing
#
# NTSC PC Engine presentation is noticeably smoother
# on the M7 display's 59.94 Hz mode.
#
# Preserve the current BareFront display rate, switch
# only for gameplay, then restore it when Gamescope
# exits normally.
# --------------------------------------------------

HOST_DISPLAY="${DISPLAY:-:0}"

HOST_OUTPUT="$(
    DISPLAY="$HOST_DISPLAY" xrandr --current 2>/dev/null |
    awk '$2 == "connected" { print $1; exit }'
)"

HOST_MODE="$(
    DISPLAY="$HOST_DISPLAY" xrandr --current 2>/dev/null |
    awk '/\*/ { print $1; exit }'
)"

HOST_RATE="$(
    DISPLAY="$HOST_DISPLAY" xrandr --current 2>/dev/null |
    awk '
        /\*/ {
            for (i = 2; i <= NF; ++i)
            {
                if ($i ~ /\*/)
                {
                    rate = $i
                    gsub(/[+*]/, "", rate)
                    print rate
                    exit
                }
            }
        }
    '
)"

DISPLAY_RATE_CHANGED=0


restore_display_rate()
{
    if [[
        "$DISPLAY_RATE_CHANGED" == "1" &&
        -n "$HOST_OUTPUT" &&
        -n "$HOST_MODE" &&
        -n "$HOST_RATE"
    ]]; then
        DISPLAY="$HOST_DISPLAY" \
            xrandr \
            --output "$HOST_OUTPUT" \
            --mode "$HOST_MODE" \
            --rate "$HOST_RATE" \
            >/dev/null 2>&1 || true
    fi
}


trap restore_display_rate EXIT


if [[
    -n "$HOST_OUTPUT" &&
    -n "$HOST_MODE" &&
    -n "$HOST_RATE"
]]; then
    if DISPLAY="$HOST_DISPLAY" \
        xrandr \
        --output "$HOST_OUTPUT" \
        --mode "$HOST_MODE" \
        --rate 59.94
    then
        DISPLAY_RATE_CHANGED=1
        echo \
            "PC Engine display: ${HOST_MODE} @ 59.94 Hz"
    else
        echo \
            "Warning: unable to select 59.94 Hz; continuing with ${HOST_RATE} Hz" \
            >&2
    fi
fi


VKBASALT_CONFIG="/tmp/barefront-vkbasalt-pcengine.conf"

cat > "$VKBASALT_CONFIG" <<EOF
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
EOF


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
    env \
        MEDNAFEN_HOME="$PROFILE" \
        "$MEDNAFEN" \
            -force_module pce_fast \
            -pce_fast.cdbios "$CD_BIOS" \
            -pce_fast.shader none \
            -pce_fast.special none \
            -pce_fast.videoip 0 \
            -pce_fast.scanlines 0 \
            -pce_fast.correct_aspect 0 \
            -pce_fast.xscale 1 \
            -pce_fast.yscale 1 \
            -sound.driver alsa \
            -sound.device sexyal-literal-default \
            -video.fs 0 \
            -command.exit "keyboard 0x0 41" \
            "$ROM"
