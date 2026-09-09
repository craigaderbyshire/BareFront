#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BAREFRONT="$ROOT/barefront"

if [[ ! -x "$BAREFRONT" ]]; then
    echo "BareFront executable not found: $BAREFRONT" >&2
    echo "Run the BareFront installer first." >&2
    exit 1
fi


# ------------------------------------------------------------
# SSH shells normally have no graphical DISPLAY.
# Attach BareFront to the active local desktop.
# ------------------------------------------------------------

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


# BareFront itself is direct.
# Gamescope is now created only for gameplay sessions.
#
# Keep this existing environment flag enabled so BareFront's
# capture and overlay lifecycle remain active.
export BAREFRONT_GAMESCOPE_CAPTURE=1


echo "Starting BareFront directly..."
echo "  Display: ${DISPLAY}"
echo "  Gameplay presentation: per-game Gamescope"

exec "$BAREFRONT"
