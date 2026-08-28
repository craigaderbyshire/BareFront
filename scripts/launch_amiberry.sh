#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_amiberry.sh <game-file>" >&2
    exit 1
fi

CONF="$ROOT/emulators/amiberry/amiberry.conf"

exec /usr/bin/amiberry \
    -o "amiberry_config=$CONF" \
    -G \
    "$ROM"
