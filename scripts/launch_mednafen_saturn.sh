#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

MEDNAFEN="/usr/games/mednafen"
GAMESCOPE="/usr/games/gamescope"
PROFILE="$ROOT/saves/saturn/mednafen"

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

if ! command -v pactl >/dev/null 2>&1; then
    echo "pactl not found." >&2
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

PULSE_SINK="$(pactl info | sed -n 's/^Default Sink: //p')"

read -r ALSA_CARD ALSA_DEVICE < <(
    pactl list sinks | awk -v sink="$PULSE_SINK" '
        $1 == "Name:" && $2 == sink { found=1 }
        found && /alsa\.card =/ {
            gsub(/"/, "", $3)
            card=$3
        }
        found && /alsa\.device =/ {
            gsub(/"/, "", $3)
            device=$3
        }
        found && card != "" && device != "" {
            print card, device
            exit
        }
    '
) || true

if [[ -z "${ALSA_CARD:-}" || -z "${ALSA_DEVICE:-}" ]]; then
    echo "Could not resolve ALSA device for PulseAudio sink:" >&2
    echo "  $PULSE_SINK" >&2
    exit 1
fi

AUDIO_DEVICE="sexyal-literal-hw:CARD=${ALSA_CARD},DEV=${ALSA_DEVICE}"

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-saturn.conf"

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt
barecrt = $ROOT/assets/shaders/barecrt/BareCRT.fx
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
EOF2

echo "Starting Saturn through per-game Gamescope..."
echo "  Native:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
echo "  Pulse sink:  $PULSE_SINK"
echo "  Direct ALSA: hw:CARD=${ALSA_CARD},DEV=${ALSA_DEVICE}"

exec pasuspender -- \
    env \
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
                    "$ROM"
