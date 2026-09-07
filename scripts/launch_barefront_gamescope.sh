#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BAREFRONT="$ROOT/barefront"
GAMESCOPE="/usr/games/gamescope"

INTERNAL_WIDTH=1280
INTERNAL_HEIGHT=720

if [[ ! -x "$BAREFRONT" ]]; then
    echo "BareFront executable not found: $BAREFRONT" >&2
    echo "Run the BareFront installer first." >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "Gamescope executable not found: $GAMESCOPE" >&2
    echo "Run the BareFront installer first." >&2
    exit 1
fi

# An SSH shell normally has no graphical display variables.
# Attach to this user's active local desktop when necessary.
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
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

DETECTED_SIZE="$(
    xrandr --current 2>/dev/null |
    sed -n \
        's/^Screen .* current \([0-9][0-9]*\) x \([0-9][0-9]*\),.*/\1 \2/p' |
    head -1
)"

read -r DETECTED_WIDTH DETECTED_HEIGHT <<< "$DETECTED_SIZE"

OUTPUT_WIDTH="${BAREFRONT_GAMESCOPE_WIDTH:-${DETECTED_WIDTH:-1920}}"
OUTPUT_HEIGHT="${BAREFRONT_GAMESCOPE_HEIGHT:-${DETECTED_HEIGHT:-1080}}"

if [[ ! "$OUTPUT_WIDTH" =~ ^[0-9]+$ ]] || \
   [[ ! "$OUTPUT_HEIGHT" =~ ^[0-9]+$ ]]
then
    echo "Invalid Gamescope output resolution:" >&2
    echo "  ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}" >&2
    exit 1
fi

echo "Starting BareFront through Gamescope..."
echo "  Internal: ${INTERNAL_WIDTH}x${INTERNAL_HEIGHT}"
echo "  Output:   ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Scaling:  fit"

exec "$GAMESCOPE" \
    -f \
    -w "$INTERNAL_WIDTH" \
    -h "$INTERNAL_HEIGHT" \
    -W "$OUTPUT_WIDTH" \
    -H "$OUTPUT_HEIGHT" \
    -S fit \
    -- \
    "$BAREFRONT"
