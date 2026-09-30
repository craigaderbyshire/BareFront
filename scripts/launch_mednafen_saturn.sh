#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MEDNAFEN="/usr/games/mednafen"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"
PROFILE="$ROOT/saves/saturn/mednafen"
PREFERENCES="$ROOT/saves/presentation/shaders.ini"
CONTROL_HELPER="$ROOT/emulators/mednafen/saturn_controller_helper"

NA_EU_BIOS="$ROOT/bios/saturn/mpr-17933.bin"
JP_BIOS="$ROOT/bios/saturn/sega_101.bin"

NATIVE_WIDTH=352
NATIVE_HEIGHT=240
INTEGER_SCALE=4

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mednafen_saturn.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "Saturn game not found: $ROM" >&2
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

if [[ ! -x "$CONTROL_HELPER" ]]; then
    echo "Saturn controller helper not found: $CONTROL_HELPER" >&2
    exit 1
fi

if ! command -v pasuspender >/dev/null 2>&1; then
    echo "pasuspender not found." >&2
    exit 1
fi

if [[ ! -f "$PROFILE/mednafen.cfg" ]]; then
    echo "BareFront Saturn profile not found:" >&2
    echo "  $PROFILE/mednafen.cfg" >&2
    exit 1
fi

if [[ ! -f "$NA_EU_BIOS" && ! -f "$JP_BIOS" ]]; then
    echo "No Saturn BIOS files found in:" >&2
    echo "  $ROOT/bios/saturn" >&2
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

AUDIO_DEVICE="$BAREFRONT_MEDNAFEN_DEVICE"

SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r section value; do
        if [[ "$section" == "saturn" ]]; then
            SHADER="$value"
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
        SETTINGS="$(printf 'fDownscale = 2.0\nfBlur = 2.6')"
        ;;

    *)
        echo "STOP: Invalid Saturn shader preference: $SHADER" >&2
        exit 1
        ;;
esac

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-saturn.conf"

if [[ "$SHADER" == "NONE" ]]; then
    LAUNCH_ENV=(
        env
        -u VKBASALT_CONFIG_FILE
        ENABLE_VKBASALT=0
    )
else
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

echo "Starting Saturn through per-game Gamescope..."
echo "  Native:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
echo "  Shader:      $SHADER"
barefront_audio_log

SESSION_DIR="$(mktemp -d /tmp/barefront-saturn.XXXXXX)"
GAME_LOG="$SESSION_DIR/gamescope.log"
CONTROL_LOG="$SESSION_DIR/controller.log"

CONTROL_HELPER_PID=""

cleanup()
{
    if [[ -n "$CONTROL_HELPER_PID" ]]; then
        if kill -0 "$CONTROL_HELPER_PID" 2>/dev/null; then
            kill "$CONTROL_HELPER_PID" 2>/dev/null || true
        fi

        wait "$CONTROL_HELPER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo "  Session logs: $SESSION_DIR"

pasuspender -- \
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
            env \
                MEDNAFEN_HOME="$PROFILE" \
                "$MEDNAFEN" \
                    -loadcd ss \
                    -ss.bios_na_eu "$NA_EU_BIOS" \
                    -ss.bios_jp "$JP_BIOS" \
                    -ss.correct_aspect 0 \
                    -ss.stretch 0 \
                    -ss.shader none \
                    -ss.special none \
                    -ss.videoip 0 \
                    -ss.scanlines 0 \
                    -ss.xscale 1 \
                    -ss.yscale 1 \
                    -cd.image_memcache 1 \
                    -sound.driver alsa \
                    -sound.device "$AUDIO_DEVICE" \
                    -sound.rate 48000 \
                    -sound.buffer_time 20 \
                    -video.fs 0 \
                    -command.exit "keyboard 0x0 41" \
                    "$ROM" > "$GAME_LOG" 2>&1 &

GAME_PID=$!

BAREFRONT_SATURN_CONTROL_SESSION=1 \
    "$CONTROL_HELPER" > "$CONTROL_LOG" 2>&1 &

CONTROL_HELPER_PID=$!

STATUS=0
wait "$GAME_PID" || STATUS=$?

cleanup
CONTROL_HELPER_PID=""

echo
echo "=== SATURN CONTROLLER RESULT ==="
cat "$CONTROL_LOG" 2>/dev/null || true

echo
echo "=== SATURN GAME EXIT STATUS ==="
echo "$STATUS"

exit "$STATUS"
