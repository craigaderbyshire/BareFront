#!/usr/bin/env bash
# BareFront-owned presentation runtime.
# Source this file from a launcher, then call:
#   barefront_resolve_presentation_runtime "$ROOT"
#
# Returns:
#   BAREFRONT_GAMESCOPE
#   BAREFRONT_VKBASALT_LAYER_DIR
#
# Does not modify system binaries or enable shaders itself.

barefront_resolve_presentation_runtime() {
    local root="${1:-}"
    local runtime gamescope library layer_dir manifest

    if [[ -z "$root" || ! -d "$root" ]]; then
        echo "STOP: BareFront runtime root is missing." >&2
        return 1
    fi

    root="$(cd -- "$root" && pwd -P)" || return 1
    runtime="$root/runtime/presentation"

    gamescope="$runtime/gamescope/gamescope"
    library="$runtime/vkbasalt/libvkbasalt.so"
    layer_dir="$runtime/vulkan/implicit_layer.d"
    manifest="$layer_dir/vkBasalt.json"

    if [[ ! -x "$gamescope" ]]; then
        echo "STOP: BareFront Gamescope runtime missing: $gamescope" >&2
        return 1
    fi

    if [[ ! -s "$library" || ! -s "$manifest" ]]; then
        echo "STOP: BareFront vkBasalt runtime is incomplete." >&2
        return 1
    fi

    # Reject a stale manifest pointing to a developer's temporary build
    # or the system-wide Debian vkBasalt library.
    if ! python3 - "$manifest" "$library" <<'PY'
import json
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
expected_library = sys.argv[2]

try:
    data = json.loads(manifest.read_text())
    actual_library = data["layer"]["library_path"]
except (OSError, ValueError, KeyError, TypeError):
    sys.exit("STOP: Invalid BareFront Vulkan manifest.")

if actual_library != expected_library:
    sys.exit("STOP: Vulkan manifest points outside the selected runtime.")
PY
    then
        return 1
    fi

    BAREFRONT_GAMESCOPE="$gamescope"
    BAREFRONT_VKBASALT_LAYER_DIR="$layer_dir"

    export BAREFRONT_GAMESCOPE
    export BAREFRONT_VKBASALT_LAYER_DIR
}
