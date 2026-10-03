#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""
if [[ "${1:-}" == "--dry-run" ]]; then
    MODE="--dry-run"
    shift
fi
ROM="${1:-}"

BIGPEMU="$ROOT/emulators/bigpemu/BigPEmu"
ESC_HELPER="$ROOT/emulators/bigpemu/bigpemu_esc_helper"
GUIDE_HELPER="$ROOT/emulators/bigpemu/bigpemu_guide_exit_helper"

source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"

NATIVE_WIDTH=320
NATIVE_HEIGHT=240
INTEGER_SCALE=4
OUTPUT_WIDTH=1280
OUTPUT_HEIGHT=960

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_bigpemu.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "Jaguar ROM not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$BIGPEMU" ]]; then
    echo "BigPEmu executable not found: $BIGPEMU" >&2
    exit 1
fi

if [[ ! -x "$ESC_HELPER" ]]; then
    echo "BigPEmu Esc helper not found: $ESC_HELPER" >&2
    exit 1
fi

if [[ ! -x "$GUIDE_HELPER" ]]; then
    echo "BigPEmu Guide helper not found: $GUIDE_HELPER" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi

PREFERENCES="${BAREFRONT_SHADER_PREFS:-$ROOT/saves/presentation/shaders.ini}"

SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r section value; do
        if [[ "$section" == "jaguar" ]]; then
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
        echo "STOP: Invalid Jaguar shader preference: $SHADER" >&2
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

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-jaguar.conf"

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

echo "Starting Atari Jaguar through per-game Gamescope..."
echo "  Native:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
echo "  Shader:      $SHADER"

"${LAUNCH_ENV[@]}" \
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
        "$BIGPEMU" \
            "$ROM" \
            -localdata \
            -forcewidth "$NATIVE_WIDTH" \
            -forceheight "$NATIVE_HEIGHT" \
            -noborder &

gamescope_pid=$!
esc_pid=""
guide_pid=""

cleanup()
{
    if [[ -n "$guide_pid" ]]; then
        kill "$guide_pid" 2>/dev/null || true
        wait "$guide_pid" 2>/dev/null || true
    fi

    if [[ -n "$esc_pid" ]]; then
        kill "$esc_pid" 2>/dev/null || true
        wait "$esc_pid" 2>/dev/null || true
    fi
}

trap cleanup EXIT

#
# Gamescope launches the game through gamescopereaper:
#
#   gamescope
#     └─ gamescopereaper
#          └─ BigPEmu
#
# BigPEmu runs on Gamescope's nested Xwayland display rather than the
# host X display. Discover both the emulator PID and that DISPLAY before
# starting BareFront's Esc helper.
#
emu_pid=""

for _ in {1..100}; do
    if ! kill -0 "$gamescope_pid" 2>/dev/null; then
        break
    fi

    reaper_pid="$(
        pgrep -P "$gamescope_pid" -x gamescopereaper 2>/dev/null |
        head -1 || true
    )"

    if [[ -n "$reaper_pid" ]]; then
        emu_pid="$(
            pgrep -P "$reaper_pid" -x BigPEmu 2>/dev/null |
            head -1 || true
        )"
    fi

    if [[ -n "$emu_pid" ]]; then
        break
    fi

    sleep 0.05
done

if [[ -z "$emu_pid" ]]; then
    echo "Could not discover BigPEmu inside Gamescope." >&2
    kill "$gamescope_pid" 2>/dev/null || true
    wait "$gamescope_pid" 2>/dev/null || true
    exit 1
fi

emu_display="$(
    tr '\0' '\n' < "/proc/$emu_pid/environ" |
    sed -n 's/^DISPLAY=//p' |
    head -1
)"

if [[ -z "$emu_display" ]]; then
    echo "Could not determine BigPEmu X display." >&2
    kill "$gamescope_pid" 2>/dev/null || true
    wait "$gamescope_pid" 2>/dev/null || true
    exit 1
fi

env DISPLAY="$emu_display" \
    "$ESC_HELPER" "$emu_pid" &

esc_pid=$!

env DISPLAY="$emu_display" \
    BAREFRONT_JAGUAR_GUIDE_SESSION=1 \
    "$GUIDE_HELPER" "$emu_pid" &

guide_pid=$!

status=0
wait "$gamescope_pid" || status=$?

exit "$status"
