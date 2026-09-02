#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

DOLPHIN="/usr/games/dolphin-emu"
DOLPHIN_USER_DIR="$ROOT/saves/gamecube/dolphin"

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_dolphin.sh <game-file>" >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "GameCube game not found: $ROM" >&2
    exit 1
fi

if [[ ! -x "$DOLPHIN" ]]; then
    echo "Dolphin executable not found: $DOLPHIN" >&2
    exit 1
fi

if [[ ! -d "$DOLPHIN_USER_DIR" ]]; then
    echo "BareFront Dolphin profile not found:" >&2
    echo "  $DOLPHIN_USER_DIR" >&2
    echo "Run the BareFront installer before launching GameCube." >&2
    exit 1
fi

exec "$DOLPHIN" \
    -u "$DOLPHIN_USER_DIR" \
    -C Dolphin.Analytics.PermissionAsked=True \
    -C Dolphin.Analytics.Enabled=False \
    -C Dolphin.Core.SkipIPL=False \
    -C Dolphin.Interface.ConfirmStop=False \
    -b \
    -e "$ROM"
