#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

AMIBERRY="/usr/bin/amiberry"
CONF="$ROOT/emulators/amiberry/amiberry.conf"
PROFILE="$ROOT/saves/amiga/amiberry"
ESC_HELPER="$ROOT/emulators/amiberry/amiberry_esc_helper"
IPC_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/amiberry.sock"

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

if [[ ! -f "$CONF" ]]; then
    echo "BareFront Amiberry configuration not found: $CONF" >&2
    exit 1
fi

if [[ ! -x "$ESC_HELPER" ]]; then
    echo "BareFront Amiberry Escape helper not found: $ESC_HELPER" >&2
    exit 1
fi

mkdir -p \
    "$PROFILE/home" \
    "$PROFILE/xdg-config" \
    "$PROFILE/xdg-data"

export AMIBERRY_HOME_DIR="$PROFILE/home"
export XDG_CONFIG_HOME="$PROFILE/xdg-config"
export XDG_DATA_HOME="$PROFILE/xdg-data"

if [[ "${ROM,,}" == *.lha ]]; then
    MEDIA_ARGS=(--autoload "$ROM")
else
    MEDIA_ARGS=("$ROM")
fi

"$AMIBERRY" \
    -o "amiberry_config=$CONF" \
    "${MEDIA_ARGS[@]}" \
    -G &

AMIBERRY_PID=$!
ESC_HELPER_PID=""

cleanup()
{
    if [[ -n "$ESC_HELPER_PID" ]] &&
       kill -0 "$ESC_HELPER_PID" 2>/dev/null; then
        kill "$ESC_HELPER_PID" 2>/dev/null || true
        wait "$ESC_HELPER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

for attempt in {1..100}; do
    if [[ -S "$IPC_SOCKET" ]]; then
        break
    fi

    if ! kill -0 "$AMIBERRY_PID" 2>/dev/null; then
        break
    fi

    sleep 0.1
done

if [[ -S "$IPC_SOCKET" ]] &&
   kill -0 "$AMIBERRY_PID" 2>/dev/null; then
    "$ESC_HELPER" "$AMIBERRY_PID" "$IPC_SOCKET" &
    ESC_HELPER_PID=$!
else
    echo "Amiberry IPC socket did not become ready." >&2
    kill "$AMIBERRY_PID" 2>/dev/null || true
fi

set +e
wait "$AMIBERRY_PID"
AMIBERRY_STATUS=$?
set -e

exit "$AMIBERRY_STATUS"
