#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""

if [[ "${1:-}" == "--dry-run" ]]; then
    MODE="--dry-run"
    shift
fi

ROM="${1:-}"

AMIBERRY="/usr/bin/amiberry"
source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"

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
NESTED_HEIGHT=480


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
# Frontend-owned, per-system Amiga shader selection.
# NONE disables vkBasalt completely.
# ------------------------------------------------------------

PREFERENCES="${BAREFRONT_SHADER_PREFS:-$ROOT/saves/presentation/shaders.ini}"
SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r key value; do
        if [[ "$key" == "amiga" ]]; then
            SHADER="${value%$'\r'}"
        fi
    done < "$PREFERENCES"
fi

EFFECT=""
DECLARATION=""
INCLUDE_DIR=""
SHADER_FILE=""
SETTINGS=""

case "$SHADER" in
    NONE)
        ;;

    BARECRT)
        EFFECT="barecrt"
        SHADER_FILE="$BARECRT"
        INCLUDE_DIR="$ROOT/assets/shaders/barecrt"
        DECLARATION="barecrt = $SHADER_FILE"
        SETTINGS="$(printf '%s\n' \
            'BareFrontScale = 2.0' \
            'BareFrontSourceScaleX = 2.0' \
            'BareFrontSourceScaleY = 2.0')"
        ;;

    CRT-LITE)
        EFFECT="CRT_Lite"
        INCLUDE_DIR="$ROOT/assets/shaders/crt-lite"
        SHADER_FILE="$INCLUDE_DIR/CRT_Lite.fx"
        DECLARATION="CRT_Lite = $SHADER_FILE"
        SETTINGS="SCANLINE_COUNT = 0.0"
        ;;

    CRT-LOTTES)
        EFFECT="CRT_Lottes"
        INCLUDE_DIR="$ROOT/assets/shaders/crt-lottes"
        SHADER_FILE="$INCLUDE_DIR/CRT_Lottes.fx"
        DECLARATION="CRT_Lottes = $SHADER_FILE"
        SETTINGS="$(printf '%s\n' \
            'fDownscale = 2.0' \
            'fBlur = 2.6')"
        ;;

    *)
        echo "STOP: Invalid Amiga shader preference: $SHADER" >&2
        exit 1
        ;;
esac

if [[ "$SHADER" != "NONE" ]]; then
    if [[ ! -f "$SHADER_FILE" ||
          ! -f "$INCLUDE_DIR/ReShade.fxh" ]]; then
        echo "STOP: Selected Amiga shader dependency missing." >&2
        exit 1
    fi

    if [[ "$SHADER" == "CRT-LOTTES" &&
          ! -f "$INCLUDE_DIR/CRT_Lottes.fxh" ]]; then
        echo "STOP: CRT_Lottes.fxh missing." >&2
        exit 1
    fi
fi

echo "Amiga shader: $SHADER"
echo "Amiga effect: ${EFFECT:-DISABLED}"

if [[ -n "$SETTINGS" ]]; then
    printf '%s\n' "$SETTINGS"
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

# ------------------------------------------------------------
# Resolve BareFront Amiga media.
#
# WHDLoad archives use Amiberry's autoload path.
#
# BareFront's canonical Amiga multidisc format is .m3u.
# Amiberry does not launch .m3u directly, so BareFront:
#
#   1. validates the ordered relative floppy paths
#   2. inserts the first disk into DF0
#   3. preloads the complete ordered set into Amiberry's
#      native Disk Swapper
#
# Disk changes remain native Amiberry operations.
# ------------------------------------------------------------

AMIGA_DISK_COUNT=0

if [[ "${ROM,,}" == *.lha ]]; then

    MEDIA_ARGS=(--autoload "$ROM")

elif [[ "${ROM,,}" == *.m3u ]]; then

    PLAYLIST_OUTPUT="$(mktemp)"

    if ! python3 - "$ROM" > "$PLAYLIST_OUTPUT" <<'PY_M3U'
from pathlib import Path
import re
import sys

playlist = Path(sys.argv[1]).resolve()

if not playlist.is_file():
    raise SystemExit(
        f"STOP: Amiga playlist not found: {playlist}"
    )

base = playlist.parent.resolve()
media = []

for number, raw in enumerate(
    playlist.read_text(
        encoding="utf-8-sig"
    ).splitlines(),
    start=1
):
    entry = raw.strip()

    if not entry or entry.startswith("#"):
        continue

    def reject(reason):
        raise SystemExit(
            f"STOP: Invalid Amiga playlist line "
            f"{number}: {reason}: {raw!r}"
        )

    if "\x00" in entry:
        reject("NUL character")

    if "\\" in entry:
        reject("backslash path separator")

    if re.match(r"^[A-Za-z]:", entry):
        reject("Windows absolute path")

    path = Path(entry)

    if path.is_absolute():
        reject("absolute path")

    if ".." in path.parts:
        reject("parent-directory traversal")

    candidate = (base / path).resolve()

    try:
        candidate.relative_to(base)
    except ValueError:
        reject("media resolves outside game directory")

    if candidate == playlist:
        reject("playlist references itself")

    if not candidate.is_file():
        reject("referenced media does not exist")

    extension = candidate.suffix.lower()

    # Conservative floppy-only multidisc contract.
    if extension not in {
        ".adf",
        ".adz",
        ".dms",
        ".ipf",
    }:
        reject(
            f"unsupported floppy media type "
            f"{extension!r}"
        )

    media.append(candidate)

if len(media) < 2:
    raise SystemExit(
        "STOP: Amiga multidisc playlist must "
        "contain at least two disks"
    )

for candidate in media:
    print(candidate)
PY_M3U
    then
        rm -f -- "$PLAYLIST_OUTPUT"
        exit 1
    fi

    mapfile -t AMIGA_DISKS < "$PLAYLIST_OUTPUT"
    rm -f -- "$PLAYLIST_OUTPUT"

    AMIGA_DISK_COUNT="${#AMIGA_DISKS[@]}"

    if (( AMIGA_DISK_COUNT < 2 )); then
        echo \
            "STOP: Amiga playlist resolved fewer than two disks." \
            >&2
        exit 1
    fi

    DISKSWAPPER_LIST=""

    for disk in "${AMIGA_DISKS[@]}"; do

        entry="$disk"

        if [[ "$entry" == *'"'* ]]; then
            echo \
                "STOP: Double quote in Amiga floppy filename is unsupported." \
                >&2
            exit 1
        fi

        # Amiberry documents quoted individual paths when
        # filenames themselves contain commas.
        if [[ "$entry" == *,* ]]; then
            entry="\"$entry\""
        fi

        if [[ -n "$DISKSWAPPER_LIST" ]]; then
            DISKSWAPPER_LIST+=","
        fi

        DISKSWAPPER_LIST+="$entry"
    done

    MEDIA_ARGS=(
        -0 "${AMIGA_DISKS[0]}"
        "-diskswapper=$DISKSWAPPER_LIST"
    )

    echo "Amiga multidisc playlist:"
    echo "  Disks: $AMIGA_DISK_COUNT"
    echo "  DF0:   ${AMIGA_DISKS[0]}"

    for index in "${!AMIGA_DISKS[@]}"; do
        printf \
            '  Slot %d: %s\n' \
            "$index" \
            "${AMIGA_DISKS[$index]}"
    done

else

    MEDIA_ARGS=("$ROM")

fi

if [[ "$MODE" == "--dry-run" ]]; then
    echo "PASS: Dry run only — media resolved, no display changes or game launch."
    exit 0
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

LAUNCH_ENV=(
    env
    -u VKBASALT_CONFIG_FILE
    ENABLE_VKBASALT=0
)

if [[ "$SHADER" != "NONE" ]]; then
    cat > "$VKBASALT_CONFIG" <<EOF_VKBASALT
effects = $EFFECT
$DECLARATION
reshadeIncludePath = $INCLUDE_DIR
reshadeTexturePath = $INCLUDE_DIR
enableOnLaunch = True
$SETTINGS
EOF_VKBASALT

    LAUNCH_ENV=(
        env
        ENABLE_VKBASALT=1
        VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG"
    )
fi

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
#   automatic content crop
#   fixed 640x480 presentation canvas
#
# Gamescope:
#   1920x1080
#   exact 2x integer scaling to 1280x960
#   nearest neighbour
#
# vkBasalt:
#   external BareCRT
# ------------------------------------------------------------

"${LAUNCH_ENV[@]}" \
    "$GAMESCOPE" \
        -b \
        -g \
        -r 50 \
        -w "$NESTED_WIDTH" \
        -h "$NESTED_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        env \
            AMIBERRY_HOME_DIR="$PROFILE/home" \
            XDG_CONFIG_HOME="$PROFILE/xdg-config" \
            XDG_DATA_HOME="$PROFILE/xdg-data" \
            SDL_VIDEODRIVER=x11 \
            "$AMIBERRY" \
                -o "amiberry_config=$CONF" \
                -o "default_vkbd_enabled=yes" \
                -o "default_vkbd_toggle=F11" \
                --rescan-roms \
                "${MEDIA_ARGS[@]}" \
                -s "amiberry.gfx_correct_aspect=1" \
                -s "amiberry.gfx_auto_crop=true" \
                -s "amiberry.gfx_manual_crop=false" \
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
        "$IPC_SOCKET" \
        "$AMIGA_DISK_COUNT" &

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
    "640",
    "480"
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
