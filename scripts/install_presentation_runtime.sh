#!/usr/bin/env bash
# Install the pinned BareFront presentation release privately.
# Usage: install_presentation_runtime.sh ARCHIVE EXPECTED_SHA256 BAREFRONT_ROOT

set -Eeuo pipefail

die() {
    echo "STOP: $*" >&2
    exit 1
}

[[ $# -eq 3 ]] || die "Expected ARCHIVE SHA256 BAREFRONT_ROOT."

ARCHIVE="$1"
EXPECTED="$2"
ROOT="$3"

[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || die "Invalid SHA-256 argument."
[[ -f "$ARCHIVE" ]] || die "Release archive is missing."
[[ -d "$ROOT" ]] || die "BareFront installation directory is missing."

ROOT="$(cd -- "$ROOT" && pwd -P)"
ARCHIVE="$(realpath -- "$ARCHIVE")"
DEST="$ROOT/runtime/presentation"

source /etc/os-release

[[ "$ID" == debian && "$VERSION_ID" == 13 ]] ||
    die "This release requires Debian 13."

[[ "$(dpkg --print-architecture)" == amd64 ]] ||
    die "This release requires amd64."

SYSTEM_MANIFEST="/usr/share/vulkan/implicit_layer.d/vkBasalt.json"
[[ -s "$SYSTEM_MANIFEST" ]] ||
    die "Debian vkBasalt manifest is missing."

echo "=== VERIFY PINNED RELEASE ARCHIVE ==="

ACTUAL="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
[[ "$ACTUAL" == "$EXPECTED" ]] ||
    die "Release archive checksum mismatch."

echo "PASS: Archive SHA-256 verified."

mkdir -p "$ROOT/runtime"

STAGE="$(mktemp -d "$ROOT/runtime/.presentation-v1.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT

tar -xJf "$ARCHIVE" -C "$STAGE" \
    --no-same-owner --no-same-permissions

GS="$STAGE/runtime/gamescope/gamescope"
VK="$STAGE/runtime/vkbasalt/libvkbasalt.so"

[[ -s "$GS" && -s "$VK" ]] ||
    die "Release archive is incomplete."

GS_SHA="a0951ce8f20d0f9fc893b64c3e9d1a82e8b16b0bf61bb915c39a3901970b1346"
VK_SHA="246ad9a372cca8d0387235e36437e87e55fba0594283fd1bc6906a10cc25c331"

[[ "$(sha256sum "$GS" | cut -d' ' -f1)" == "$GS_SHA" ]] ||
    die "Unexpected Gamescope binary."

[[ "$(sha256sum "$VK" | cut -d' ' -f1)" == "$VK_SHA" ]] ||
    die "Unexpected vkBasalt binary."

echo "PASS: Both tested executables verified."

NEW="$STAGE/presentation"

mkdir -p \
    "$NEW/gamescope" \
    "$NEW/vkbasalt" \
    "$NEW/vulkan/implicit_layer.d" \
    "$NEW/LICENSES"

install -m 0755 "$GS" "$NEW/gamescope/gamescope"
install -m 0755 "$VK" "$NEW/vkbasalt/libvkbasalt.so"

cp -a "$STAGE/LICENSES/." "$NEW/LICENSES/"
cp "$STAGE/README.txt" "$NEW/README.txt"

echo "=== GENERATE INSTALLATION-SPECIFIC VULKAN MANIFEST ==="

python3 - \
    "$SYSTEM_MANIFEST" \
    "$DEST/vkbasalt/libvkbasalt.so" \
    "$NEW/vulkan/implicit_layer.d/vkBasalt.json" <<'PY'
import json
import sys
from pathlib import Path

template = Path(sys.argv[1])
final_library = sys.argv[2]
output = Path(sys.argv[3])

data = json.loads(template.read_text())

if data["layer"]["name"] != "VK_LAYER_VKBASALT_post_processing":
    raise SystemExit("STOP: Unexpected Vulkan layer template.")

data["layer"]["library_path"] = final_library
output.write_text(json.dumps(data, indent=2) + "\n")
PY

if [[ -L "$DEST" ]]; then
    die "Existing runtime directory is a symlink."
fi

if [[ -e "$DEST" ]]; then
    echo "=== VERIFY EXISTING INSTALLATION ==="

    cmp "$NEW/gamescope/gamescope" \
        "$DEST/gamescope/gamescope" ||
        die "Existing Gamescope differs; refusing to overwrite."

    cmp "$NEW/vkbasalt/libvkbasalt.so" \
        "$DEST/vkbasalt/libvkbasalt.so" ||
        die "Existing vkBasalt differs; refusing to overwrite."

    cmp "$NEW/vulkan/implicit_layer.d/vkBasalt.json" \
        "$DEST/vulkan/implicit_layer.d/vkBasalt.json" ||
        die "Existing Vulkan manifest differs; refusing to overwrite."

    echo "PASS: Matching runtime already installed."
else
    echo "=== INSTALL PRIVATE RUNTIME ==="
    mv -T "$NEW" "$DEST"
    echo "PASS: Private runtime installed."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

source "$SCRIPT_DIR/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"

[[ "$BAREFRONT_GAMESCOPE" == "$DEST/gamescope/gamescope" ]] ||
    die "Gamescope resolver returned an unexpected path."

[[ "$BAREFRONT_VKBASALT_LAYER_DIR" == \
   "$DEST/vulkan/implicit_layer.d" ]] ||
    die "Vulkan resolver returned an unexpected path."

echo "PASS: BareFront runtime resolver verified."
echo "Runtime: $DEST"
