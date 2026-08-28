#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_vice.sh <game-file>" >&2
    exit 1
fi

exec /usr/bin/x64sc \
    -basic "$ROOT/bios/c64/basic-901226-01.bin" \
    -kernal "$ROOT/bios/c64/kernal-901227-03.bin" \
    -chargen "$ROOT/bios/c64/chargen-901225-01.bin" \
    -dos1541 "$ROOT/bios/c64/dos1541-325302-01+901229-05.bin" \
    -drive8type 1541 \
    -autostart "$ROM"
