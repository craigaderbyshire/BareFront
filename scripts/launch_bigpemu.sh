#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

BIGPEMU="$ROOT/emulators/bigpemu/BigPEmu"
ESC_HELPER="$ROOT/emulators/bigpemu/bigpemu_esc_helper"

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

# BigPEmu requires the ROM before -localdata.
"$BIGPEMU" "$ROM" -localdata &
emu_pid=$!

"$ESC_HELPER" "$emu_pid" &
esc_pid=$!

cleanup()
{
    kill "$esc_pid" 2>/dev/null || true
    wait "$esc_pid" 2>/dev/null || true
}

trap cleanup EXIT

status=0
wait "$emu_pid" || status=$?

exit "$status"
