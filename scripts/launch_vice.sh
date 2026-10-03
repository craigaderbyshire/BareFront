#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""
if [[ "${1:-}" == "--dry-run" ]]; then
    MODE="--dry-run"
    shift
fi
ROM="${1:-}"

VICE="/usr/bin/x64sc"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"
PRESENTATION_HELPER="$ROOT/c64_presentation_helper"
GUIDE_HELPER="$ROOT/emulators/vice/vice_guide_exit_helper"

NATIVE_WIDTH=408
NATIVE_HEIGHT=293

OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080

C64_PAL_MODE="1920x1080_C64PAL"

BEZEL="$ROOT/assets/overlays/plain/c64.png"
BEZEL_SHADER="$ROOT/assets/shaders/c64/BareFront_C64_Bezel.fx"
BARECRT_SHADER="$ROOT/assets/shaders/barecrt/BareCRT_v2.fx"

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-c64.conf"

GAMESCOPE_PID=""
PANELS_HIDDEN=0
C64_TEXTURE_DIR=""

DISPLAY_OUTPUT=""
ORIGINAL_MODE=""
ORIGINAL_RATE=""


if [[ -z "$ROM" ]]; then
    echo "Usage: launch_vice.sh <game-file>" >&2
    exit 1
fi


# BareFront normally supplies a path relative to its root.
# Convert it to an absolute path so VICE fliplist entries can
# be resolved reliably regardless of the caller's directory.
if [[ "$ROM" != /* ]]; then
    ROM="$ROOT/${ROM#./}"
fi


if [[ ! -f "$ROM" ]]; then
    echo "C64 game not found:" >&2
    echo "  $ROM" >&2
    exit 1
fi



for required in \
    "$VICE" \
    "$GAMESCOPE" \
    "$PRESENTATION_HELPER" \
    "$GUIDE_HELPER"
do
    if [[ ! -x "$required" ]]; then
        echo "Required C64 executable not found:" >&2
        echo "  $required" >&2
        exit 1
    fi
done


for required in \
    "$ROOT/bios/c64/basic-901226-01.bin" \
    "$ROOT/bios/c64/kernal-901227-03.bin" \
    "$ROOT/bios/c64/chargen-901225-01.bin" \
    "$ROOT/bios/c64/dos1541-325302-01+901229-05.bin" \
    "$BARECRT_SHADER" \
    "$BEZEL_SHADER" \
    "$BEZEL"
do
    if [[ ! -f "$required" ]]; then
        echo "Required C64 file not found:" >&2
        echo "  $required" >&2
        exit 1
    fi
done


export DISPLAY="${DISPLAY:-:0}"

if [[ -z "${XAUTHORITY:-}" &&
      -f "$HOME/.Xauthority" ]]
then
    export XAUTHORITY="$HOME/.Xauthority"
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi


# ------------------------------------------------------------
# Capture the current physical display state.
#
# The original mode/rate is restored when VICE exits.
# ------------------------------------------------------------

# ------------------------------------------------------------
# Per-system CRT selection.
#
# The C64 bezel is always the final effect, including NONE.
# NONE disables CRT treatment, not the selected C64 artwork.
# ------------------------------------------------------------

PREFERENCES="${BAREFRONT_SHADER_PREFS:-$ROOT/saves/presentation/shaders.ini}"
SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r key value; do
        if [[ "$key" == "c64" ]]; then
            SHADER="${value%$'\\r'}"
        fi
    done < "$PREFERENCES"
fi

EFFECTS="c64bezel"
CRT_DECLARATION=""
CRT_INCLUDE_DIR="$ROOT/assets/shaders/barecrt"
CRT_SETTINGS=""
CRT_SHADER_FILE=""

case "$SHADER" in
    NONE)
        ;;

    BARECRT)
        EFFECTS="barecrt:c64bezel"
        CRT_SHADER_FILE="$BARECRT_SHADER"
        CRT_DECLARATION="barecrt = $CRT_SHADER_FILE"
        CRT_SETTINGS="$(printf '%s\n' 'BareFrontScale = 3.0' 'BareFrontPhaseY = 1.0')"
        ;;

    CRT-LITE)
        EFFECTS="CRT_Lite:c64bezel"
        CRT_INCLUDE_DIR="$ROOT/assets/shaders/crt-lite"
        CRT_SHADER_FILE="$CRT_INCLUDE_DIR/CRT_Lite.fx"
        CRT_DECLARATION="CRT_Lite = $CRT_SHADER_FILE"
        CRT_SETTINGS="SCANLINE_COUNT = 0.0"
        ;;

    CRT-LOTTES)
        EFFECTS="CRT_Lottes:c64bezel"
        CRT_INCLUDE_DIR="$ROOT/assets/shaders/crt-lottes"
        CRT_SHADER_FILE="$CRT_INCLUDE_DIR/CRT_Lottes.fx"
        CRT_DECLARATION="CRT_Lottes = $CRT_SHADER_FILE"
        CRT_SETTINGS="$(printf '%s\n' 'fDownscale = 3.0' 'fBlur = 2.6')"
        ;;

    *)
        echo "STOP: Invalid C64 shader preference: $SHADER" >&2
        exit 1
        ;;
esac

if [[ ! -f "$CRT_INCLUDE_DIR/ReShade.fxh" ]]; then
    echo "STOP: Missing C64 shader include dependency." >&2
    exit 1
fi

if [[ -n "$CRT_SHADER_FILE" &&
      ! -f "$CRT_SHADER_FILE" ]]; then
    echo "STOP: Missing selected C64 shader: $CRT_SHADER_FILE" >&2
    exit 1
fi

if [[ "$SHADER" == "CRT-LOTTES" &&
      ! -f "$CRT_INCLUDE_DIR/CRT_Lottes.fxh" ]]; then
    echo "STOP: Missing CRT_Lottes.fxh" >&2
    exit 1
fi

echo "Shader: $SHADER"
echo "Effects: $EFFECTS"
echo "CRT include: $CRT_INCLUDE_DIR"

if [[ -n "$CRT_SETTINGS" ]]; then
    printf '%s\n' "$CRT_SETTINGS"
fi

if [[ "$MODE" == "--dry-run" ]]; then
    echo "PASS: Dry run only — no display changes or game launch."
    exit 0
fi

XRANDR_STATE="$(xrandr --query)"

DISPLAY_OUTPUT="$(
    awk '
        $2 == "connected" {
            output = $1
        }

        /\*/ {
            print output
            exit
        }
    ' <<< "$XRANDR_STATE"
)"

ORIGINAL_MODE="$(
    awk '
        /\*/ {
            print $1
            exit
        }
    ' <<< "$XRANDR_STATE"
)"

ORIGINAL_RATE="$(
    awk '
        /\*/ {
            for (i = 2; i <= NF; ++i) {
                if ($i ~ /\*/) {
                    gsub(/[\*\+]/, "", $i)
                    print $i
                    exit
                }
            }
        }
    ' <<< "$XRANDR_STATE"
)"


if [[ -z "$DISPLAY_OUTPUT" ||
      -z "$ORIGINAL_MODE" ||
      -z "$ORIGINAL_RATE" ]]
then
    echo "Unable to determine the active X11 display mode." >&2
    exit 1
fi


cleanup()
{
    local exit_code=$?

    trap - EXIT INT TERM

    if [[ -n "$GAMESCOPE_PID" ]]; then
        kill "$GAMESCOPE_PID" \
            >/dev/null 2>&1 || true

        wait "$GAMESCOPE_PID" \
            >/dev/null 2>&1 || true
    fi

    echo
    echo "Restoring display:"
    echo "  Output: $DISPLAY_OUTPUT"
    echo "  Mode:   $ORIGINAL_MODE"
    echo "  Rate:   $ORIGINAL_RATE"

    xrandr \
        --output "$DISPLAY_OUTPUT" \
        --mode "$ORIGINAL_MODE" \
        --rate "$ORIGINAL_RATE" \
        >/dev/null 2>&1 || true

    if [[ "$PANELS_HIDDEN" == "1" ]]; then
        "$PRESENTATION_HELPER" show-panels \
            >/dev/null 2>&1 || true
    fi


    if [[ -n "$C64_TEXTURE_DIR" ]]; then
        rm -rf -- "$C64_TEXTURE_DIR"
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# Select C64 artwork without opening a separate X11 overlay.
OVERLAY_ROOT="$ROOT/assets/overlays"
OVERLAY_MAP="$OVERLAY_ROOT/overlays.ini"
DEFAULT_C64="$OVERLAY_ROOT/plain/c64.png"
C64_SELECTION="plain/c64.png"

if [[ ! -f "$OVERLAY_MAP" ]]; then
    OVERLAY_MAP="$OVERLAY_ROOT/overlays.ini.example"
fi

if [[ -f "$OVERLAY_MAP" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"

        if [[ "$key" == "c64" ]]; then
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            C64_SELECTION="$value"
        fi
    done < "$OVERLAY_MAP"
fi

case "$C64_SELECTION" in
    /*|*..*|*\\*|!*.png)
        echo "Invalid C64 overlay selection: $C64_SELECTION"
        C64_SELECTION="plain/c64.png"
        ;;
esac

C64_SELECTED="$OVERLAY_ROOT/$C64_SELECTION"
C64_VALIDATOR="$ROOT/overlay_helper"

# The reference mask must itself be valid and available.
if [[ ! -f "$DEFAULT_C64" ]] ||
   ! "$C64_VALIDATOR" --validate-c64 \
       "$DEFAULT_C64" "$DEFAULT_C64"; then
    echo "Required plain C64 texture or validator unavailable." >&2
    exit 1
fi

if [[ ! -f "$C64_SELECTED" ]] ||
   ! "$C64_VALIDATOR" --validate-c64 \
       "$C64_SELECTED" "$DEFAULT_C64"; then
    echo "Invalid or missing C64 artwork: $C64_SELECTED"
    C64_SELECTED="$DEFAULT_C64"
fi

C64_TEXTURE_DIR="$(mktemp -d /tmp/barefront-c64-texture.XXXXXX)"
cp -- "$C64_SELECTED" "$C64_TEXTURE_DIR/c64.png"

echo "C64 overlay: $C64_SELECTED"
echo "C64 texture directory: $C64_TEXTURE_DIR"



# ------------------------------------------------------------
# Determine whether this output advertises 1080p50.
#
# BareFront only attempts the PAL-matched custom mode on a
# display which already reports 1920x1080 at approximately
# 50 Hz. Otherwise the existing display mode is retained.
# ------------------------------------------------------------

SUPPORTS_1080P50="$(
    awk -v target="$DISPLAY_OUTPUT" '
        $1 == target && $2 == "connected" {
            inside = 1
            next
        }

        inside && /^[^[:space:]]/ {
            inside = 0
        }

        inside && $1 == "1920x1080" {
            for (i = 2; i <= NF; ++i) {
                rate = $i
                gsub(/[\*\+]/, "", rate)

                if (rate ~ /^50(\.0+)?$/) {
                    print "yes"
                    exit
                }
            }
        }
    ' <<< "$XRANDR_STATE"
)"


echo "Starting Commodore 64 through BareFront..."
echo "  VICE:        PAL"
echo "  Surface:     ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Gamescope:   ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Scaling:     integer / nearest"
echo "  Borders:     full"
echo "  Shader:      $SHADER"
echo "  Bezel:       black"


# ------------------------------------------------------------
# Release XFCE's panel work area BEFORE Gamescope is created.
#
# This allows the borderless 1920x1080 Gamescope window to be
# placed at the real desktop origin instead of y=27.
# ------------------------------------------------------------

"$PRESENTATION_HELPER" hide-panels
PANELS_HIDDEN=1

sleep 1


# ------------------------------------------------------------
# PAL display timing.
#
# A real PAL C64 runs at approximately 50.12 Hz. The M7 display
# accepts this custom 1080p mode and it removes the periodic
# cadence judder visible at ordinary 50.000 Hz.
#
# If the display cannot use it, fall back to its advertised
# 1080p50 mode. If even that fails, retain the original mode.
# ------------------------------------------------------------

if [[ "$SUPPORTS_1080P50" == "yes" ]]; then

    xrandr --newmode \
        "$C64_PAL_MODE" \
        148.87 \
        1920 2448 2492 2640 \
        1080 1084 1089 1125 \
        +HSync +VSync \
        >/dev/null 2>&1 || true

    xrandr --addmode \
        "$DISPLAY_OUTPUT" \
        "$C64_PAL_MODE" \
        >/dev/null 2>&1 || true

    if xrandr \
        --output "$DISPLAY_OUTPUT" \
        --mode "$C64_PAL_MODE"
    then
        echo "  Display:     PAL matched ~50.12 Hz"
    elif xrandr \
        --output "$DISPLAY_OUTPUT" \
        --mode 1920x1080 \
        --rate 50.00
    then
        echo "  Display:     50.00 Hz fallback"
    else
        echo "  Display:     original mode retained"
    fi

else
    echo "  Display:     no advertised 1080p50; original mode retained"
fi

# Give the physical display and X11 stack time to settle on the
# new refresh timing before Gamescope establishes its pacing.
sleep 3


# ------------------------------------------------------------
# vkBasalt / ReShade presentation.
#
# BareCRT runs first. The C64 bezel is then composited inside
# the same shader path, avoiding the separate X11 overlay
# window which caused visible scrolling judder.
# ------------------------------------------------------------

cat > "$VKBASALT_CONFIG" <<EOF2
effects = $EFFECTS

$CRT_DECLARATION
c64bezel = $BEZEL_SHADER

reshadeIncludePath = $CRT_INCLUDE_DIR
reshadeTexturePath = $C64_TEXTURE_DIR

enableOnLaunch = True
$CRT_SETTINGS
EOF2


VICE_ARGS=(
    -hotkeyfile "$ROOT/emulators/vice/barefront.vhk"
    +confirmonexit

    -pal

    -VICIIborders 1
    -VICIIfilter 0
    -VICIIglfilter 0
    -VICIIaspectmode 0

    -VICIIfull
    +fullscreen-decorations
    +VICIIshowstatusbar

    +VICIIdsize
    +VICIIdscan
    +VICIIvsync

    -basic "$ROOT/bios/c64/basic-901226-01.bin"
    -kernal "$ROOT/bios/c64/kernal-901227-03.bin"
    -chargen "$ROOT/bios/c64/chargen-901225-01.bin"
    -dos1541 "$ROOT/bios/c64/dos1541-325302-01+901229-05.bin"

    -drive8type 1541
)


# ------------------------------------------------------------
# Native VICE multi-disk support.
#
# A .vfl file is presented to BareFront as one game. The first
# non-comment entry is autostarted and VICE receives the whole
# fliplist so its normal disk-next / disk-previous controls
# remain available.
# ------------------------------------------------------------

ROM_EXTENSION="${ROM##*.}"
ROM_EXTENSION="${ROM_EXTENSION,,}"

if [[ "$ROM_EXTENSION" == "vfl" ]]; then

    FIRST_DISK="$(
        awk '
            {
                line = $0
                sub(/\r$/, "", line)
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)

                if (line != "" &&
                    substr(line, 1, 1) != ";")
                {
                    print line
                    exit
                }
            }
        ' "$ROM"
    )"

    if [[ -z "$FIRST_DISK" ]]; then
        echo "VICE fliplist contains no disk images:" >&2
        echo "  $ROM" >&2
        exit 1
    fi

    if [[ "$FIRST_DISK" == /* ]]; then
        AUTOSTART_DISK="$FIRST_DISK"
    else
        AUTOSTART_DISK="$(dirname "$ROM")/$FIRST_DISK"
    fi

    if [[ ! -f "$AUTOSTART_DISK" ]]; then
        echo "First VICE fliplist disk not found:" >&2
        echo "  $AUTOSTART_DISK" >&2
        exit 1
    fi

    echo "  Fliplist:    $(basename "$ROM")"
    echo "  First disk:  $(basename "$AUTOSTART_DISK")"

    VICE_ARGS+=(
        -flipname "$ROM"
        -autostart "$AUTOSTART_DISK"
    )

else

    VICE_ARGS+=(
        -autostart "$ROM"
    )

fi


env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -r 50.12 \
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

              BAREFRONT_C64_GUIDE_SESSION=1 "$guide" &
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
        "$GUIDE_HELPER" \
        "$VICE" \
        "${VICE_ARGS[@]}" &

GAMESCOPE_PID=$!


# Gamescope exists as a normal borderless X11 window. Apply an
# invisible cursor once, then leave no resident X11 helper
# running during gameplay.
sleep 3

"$PRESENTATION_HELPER" hide-cursor || true


if wait "$GAMESCOPE_PID"; then
    GAME_EXIT=0
else
    GAME_EXIT=$?
fi

GAMESCOPE_PID=""

exit "$GAME_EXIT"
