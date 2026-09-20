#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

AMIBERRY="/usr/bin/amiberry"
GAMESCOPE="/usr/games/gamescope"

CONF="$ROOT/emulators/amiberry/amiberry.conf"
PROFILE="$ROOT/saves/amiga/amiberry"

ESC_HELPER="$ROOT/emulators/amiberry/amiberry_esc_helper"
PRESENTATION_HELPER="$ROOT/c64_presentation_helper"

BARECRT="$ROOT/assets/shaders/barecrt/BareCRT_v2.fx"

OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080

# Proven Amiga presentation geometry.
#
# Amiberry crops the native raster to 640x270.
# Gamescope maps that to 1920x1080 using exact integer-axis
# nearest-neighbour scaling:
#
#   horizontal: 640 x 3 = 1920
#   vertical:   270 x 4 = 1080
#
# This reproduces the presentation approved on:
#   IK+
#   Pinball Fantasies AGA
#   Sensible World of Soccer 96/97
NESTED_WIDTH=640
NESTED_HEIGHT=270

CROP_X=40
CROP_Y=9

GAMESCOPE_PID=""
AMIBERRY_PID=""
ESC_HELPER_PID=""

PANELS_HIDDEN=0

DISPLAY_OUTPUT=""
ORIGINAL_MODE=""
ORIGINAL_RATE=""

# ------------------------------------------------------------
# Validate launch input and required components
# ------------------------------------------------------------

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_amiberry.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "Amiga game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$AMIBERRY" ]]; then
    echo "Amiberry executable not found: $AMIBERRY" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    exit 1
fi

if [[ ! -f "$CONF" ]]; then
    echo "BareFront Amiberry configuration not found: $CONF" >&2
    exit 1
fi

if [[ ! -x "$ESC_HELPER" ]]; then
    echo "BareFront Amiberry Escape helper not found: $ESC_HELPER" >&2
    exit 1
fi

if [[ ! -x "$PRESENTATION_HELPER" ]]; then
    echo "BareFront presentation helper not found: $PRESENTATION_HELPER" >&2
    exit 1
fi

if [[ ! -f "$BARECRT" ]]; then
    echo "BareCRT shader not found: $BARECRT" >&2
    exit 1
fi

if ! command -v xrandr >/dev/null 2>&1; then
    echo "xrandr is required for Amiga presentation." >&2
    exit 1
fi

# ------------------------------------------------------------
# BareFront-isolated Amiberry profile
# ------------------------------------------------------------

mkdir -p \
    "$PROFILE/home" \
    "$PROFILE/xdg-config" \
    "$PROFILE/xdg-data"

export AMIBERRY_HOME_DIR="$PROFILE/home"
export XDG_CONFIG_HOME="$PROFILE/xdg-config"
export XDG_DATA_HOME="$PROFILE/xdg-data"

# WHDLoad archives use Amiberry's autoload path.
# Other supported media continues to use the normal media path.
if [[ "${ROM,,}" == *.lha ]]; then
    MEDIA_ARGS=(--autoload "$ROM")
else
    MEDIA_ARGS=("$ROM")
fi

# ------------------------------------------------------------
# Resolve the active desktop session when launched by BareFront
# without DISPLAY already exported.
# ------------------------------------------------------------

if [[ -z "${DISPLAY:-}" ]]; then

    SESSION_ID="$(
        loginctl show-user "$(id -un)" \
            --property=Display \
            --value 2>/dev/null || true
    )"

    if [[ -n "$SESSION_ID" ]]; then
        DISPLAY="$(
            loginctl show-session "$SESSION_ID" \
                --property=Display \
                --value 2>/dev/null || true
        )"
    fi

    if [[ -z "${DISPLAY:-}" ]]; then
        echo "Could not determine the active X display." >&2
        exit 1
    fi

    export DISPLAY

    if [[ -f "$HOME/.Xauthority" ]]; then
        export XAUTHORITY="$HOME/.Xauthority"
    fi
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

IPC_SOCKET="$XDG_RUNTIME_DIR/amiberry.sock"
VKBASALT_CONFIG="$XDG_RUNTIME_DIR/barefront-vkbasalt-amiga-$$.conf"
PROBE="$XDG_RUNTIME_DIR/barefront-amiga-probe-$$.png"

# ------------------------------------------------------------
# Capture the current physical display mode for exact restoration
# ------------------------------------------------------------

XRANDR_STATE="$(xrandr --query)"

DISPLAY_OUTPUT="$(
    awk '
        $2 == "connected" { output=$1 }
        /\*/ { print output; exit }
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
            for (i=2; i<=NF; i++) {
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
    echo "Could not determine the active display mode." >&2
    exit 1
fi

# ------------------------------------------------------------
# Cleanup must always restore the desktop
# ------------------------------------------------------------

cleanup()
{
    local status=$?

    trap - EXIT INT TERM

    if [[ -n "$ESC_HELPER_PID" ]] &&
       kill -0 "$ESC_HELPER_PID" 2>/dev/null
    then
        kill "$ESC_HELPER_PID" 2>/dev/null || true
    fi

    if [[ -n "$GAMESCOPE_PID" ]] &&
       kill -0 "$GAMESCOPE_PID" 2>/dev/null
    then
        kill "$GAMESCOPE_PID" 2>/dev/null || true
    fi

    if [[ -n "$ESC_HELPER_PID" ]]; then
        wait "$ESC_HELPER_PID" 2>/dev/null || true
    fi

    if [[ -n "$GAMESCOPE_PID" ]]; then
        wait "$GAMESCOPE_PID" 2>/dev/null || true
    fi

    if [[ -n "$DISPLAY_OUTPUT" &&
          -n "$ORIGINAL_MODE" &&
          -n "$ORIGINAL_RATE" ]]
    then
        xrandr \
            --output "$DISPLAY_OUTPUT" \
            --mode "$ORIGINAL_MODE" \
            --rate "$ORIGINAL_RATE" \
            >/dev/null 2>&1 || true
    fi

    if [[ "$PANELS_HIDDEN" == "1" ]]; then
        "$PRESENTATION_HELPER" show-panels \
            >/dev/null 2>&1 || true
    fi

    rm -f \
        "$IPC_SOCKET" \
        "$VKBASALT_CONFIG" \
        "$PROBE"

    exit "$status"
}

trap cleanup EXIT INT TERM

# ------------------------------------------------------------
# External BareCRT only
# ------------------------------------------------------------

cat > "$VKBASALT_CONFIG" <<EOF_VKBASALT
effects = barecrt
barecrt = $BARECRT
reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $ROOT/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
BareFrontScale = 4.0
BareFrontSourceScaleX = 3.0
BareFrontSourceScaleY = 4.0
EOF_VKBASALT

# ------------------------------------------------------------
# Physical PAL presentation
# ------------------------------------------------------------

"$PRESENTATION_HELPER" hide-panels
PANELS_HIDDEN=1

sleep 1

if ! xrandr \
    --output "$DISPLAY_OUTPUT" \
    --mode 1920x1080 \
    --rate 50.00
then
    echo "Unable to switch display to 1920x1080 @ 50 Hz." >&2
    exit 1
fi

sleep 3

rm -f "$IPC_SOCKET" "$PROBE"

# ------------------------------------------------------------
# Launch
#
# Amiberry:
#   native emulation
#   nearest
#   no auto crop
#   manual 640x270 crop
#
# Gamescope:
#   1920x1080
#   exact 3x horizontal / 4x vertical mapping
#   nearest neighbour
#
# vkBasalt:
#   external BareCRT
# ------------------------------------------------------------

env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -r 50 \
        -w "$NESTED_WIDTH" \
        -h "$NESTED_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S stretch \
        -F nearest \
        -- \
        env \
            AMIBERRY_HOME_DIR="$PROFILE/home" \
            XDG_CONFIG_HOME="$PROFILE/xdg-config" \
            XDG_DATA_HOME="$PROFILE/xdg-data" \
            SDL_VIDEODRIVER=x11 \
            "$AMIBERRY" \
                -o "amiberry_config=$CONF" \
                --rescan-roms \
                "${MEDIA_ARGS[@]}" \
                -s "amiberry.gfx_correct_aspect=0" \
                -s "amiberry.gfx_auto_crop=false" \
                -s "amiberry.gfx_manual_crop=true" \
                -s "amiberry.gfx_manual_crop_width=$NESTED_WIDTH" \
                -s "amiberry.gfx_manual_crop_height=$NESTED_HEIGHT" \
                -s "amiberry.gfx_horizontal_offset=$CROP_X" \
                -s "amiberry.gfx_vertical_offset=$CROP_Y" \
                -G &

GAMESCOPE_PID=$!

# ------------------------------------------------------------
# Discover Amiberry inside Gamescope
# ------------------------------------------------------------

for attempt in {1..120}; do

    REAPER_PID="$(
        pgrep -P "$GAMESCOPE_PID" -x gamescopereaper \
            2>/dev/null |
        head -1 || true
    )"

    if [[ -n "$REAPER_PID" ]]; then
        AMIBERRY_PID="$(
            pgrep -P "$REAPER_PID" -x amiberry \
                2>/dev/null |
            head -1 || true
        )"
    fi

    if [[ -n "$AMIBERRY_PID" ]]; then
        break
    fi

    sleep 0.05
done

if [[ -z "$AMIBERRY_PID" ]]; then
    echo "Could not discover Amiberry inside Gamescope." >&2
    exit 1
fi

# ------------------------------------------------------------
# Wait for Amiberry IPC
# ------------------------------------------------------------

for attempt in {1..120}; do
    if [[ -S "$IPC_SOCKET" ]]; then
        break
    fi

    if ! kill -0 "$AMIBERRY_PID" 2>/dev/null; then
        break
    fi

    sleep 0.05
done

if [[ ! -S "$IPC_SOCKET" ]]; then
    echo "Amiberry IPC socket did not appear." >&2
    exit 1
fi

# ------------------------------------------------------------
# Escape must return directly to BareFront
# ------------------------------------------------------------

AMIBERRY_DISPLAY="$(
    tr '\0' '\n' < "/proc/$AMIBERRY_PID/environ" |
        sed -n 's/^DISPLAY=//p' |
        head -1
)"

if [[ -z "$AMIBERRY_DISPLAY" ]]; then
    echo "Could not determine nested Amiberry DISPLAY." >&2
    exit 1
fi

env DISPLAY="$AMIBERRY_DISPLAY" \
    "$ESC_HELPER" \
        "$AMIBERRY_PID" \
        "$IPC_SOCKET" &

ESC_HELPER_PID=$!

# ------------------------------------------------------------
# Resize the Amiberry window to the actual cropped source
#
# This keeps the emulator presentation 1:1 before Gamescope owns
# the final scaling.
# ------------------------------------------------------------

sleep 5

python3 - "$IPC_SOCKET" "$PROBE" <<'PY'
import socket
import sys
import time

socket_path = sys.argv[1]
probe_path = sys.argv[2]

def send(*parts):
    message = "\t".join(parts) + "\n"

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(socket_path)
        sock.sendall(message.encode())

        data = b""

        while b"\n" not in data:
            chunk = sock.recv(4096)

            if not chunk:
                break

            data += chunk

    return data.decode().strip()

response = send(
    "SCREENSHOT",
    probe_path,
    "ACTIONABLE"
)

fields = {}

for field in response.split("\t"):
    if "=" in field:
        key, value = field.split("=", 1)
        fields[key] = value

source_width = int(fields["source_width"])
source_height = int(fields["source_height"])

send(
    "SET_WINDOW_SIZE",
    str(source_width),
    str(source_height)
)

time.sleep(1)
PY

rm -f "$PROBE"

"$PRESENTATION_HELPER" hide-cursor || true

# ------------------------------------------------------------
# Wait for the game
# ------------------------------------------------------------

GAMESCOPE_STATUS=0

wait "$GAMESCOPE_PID" || GAMESCOPE_STATUS=$?

GAMESCOPE_PID=""

ESC_HELPER_STATUS=0

if [[ -n "$ESC_HELPER_PID" ]]; then
    wait "$ESC_HELPER_PID" || ESC_HELPER_STATUS=$?
    ESC_HELPER_PID=""
fi

# Gamescope 3.16.22 may abort during teardown after Amiberry has
# already honoured a clean IPC QUIT request. Normalise that one
# observed shutdown case only when the Escape helper confirms
# that BareFront deliberately requested the exit.
if [[ "$GAMESCOPE_STATUS" -eq 134 &&
      "$ESC_HELPER_STATUS" -eq 10 ]]
then
    GAMESCOPE_STATUS=0
fi

exit "$GAMESCOPE_STATUS"
