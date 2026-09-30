#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"
MODE="${2:-}"

source "$ROOT/scripts/barefront_presentation_runtime.sh"
barefront_resolve_presentation_runtime "$ROOT"
GAMESCOPE="$BAREFRONT_GAMESCOPE"
export VK_IMPLICIT_LAYER_PATH="$BAREFRONT_VKBASALT_LAYER_DIR"
FLYCAST="$ROOT/emulators/flycast/Flycast.AppImage"
SHADER_HELPER="$ROOT/scripts/flycast_shader_activate.py"
CONTROL_HELPER="$ROOT/emulators/flycast/flycast_controller_helper"
PREFERENCES="$ROOT/saves/presentation/shaders.ini"

if [[ ! -f "$ROM" || ! -x "$FLYCAST" ||
      ! -x "$GAMESCOPE" || ! -f "$SHADER_HELPER" ||
      ! -x "$CONTROL_HELPER" ]]; then
    echo "STOP: Dreamcast runtime dependency is missing." >&2
    exit 1
fi

if [[ -n "$MODE" && "$MODE" != "--dry-run" ]]; then
    echo "Usage: $0 <rom> [--dry-run]" >&2
    exit 1
fi

SHADER="NONE"

if [[ -f "$PREFERENCES" ]]; then
    while IFS='=' read -r section value; do
        if [[ "$section" == "dreamcast" ]]; then
            SHADER="$value"
        fi
    done < "$PREFERENCES"
fi

EFFECT=""
SHADER_FILE=""
INCLUDE_DIR=""
SETTINGS=""

case "$SHADER" in
    NONE)
        ;;

    BARECRT)
        EFFECT="barecrt"
        INCLUDE_DIR="$ROOT/assets/shaders/barecrt"
        SHADER_FILE="$INCLUDE_DIR/BareCRT_v2.fx"
        SETTINGS="BareFrontScale = 2.0"
        ;;

    CRT-LITE)
        EFFECT="CRT_Lite"
        INCLUDE_DIR="$ROOT/assets/shaders/crt-lite"
        SHADER_FILE="$INCLUDE_DIR/CRT_Lite.fx"
        SETTINGS="SCANLINE_COUNT = 0.0"
        ;;

    CRT-LOTTES)
        EFFECT="CRT_Lottes"
        INCLUDE_DIR="$ROOT/assets/shaders/crt-lottes"
        SHADER_FILE="$INCLUDE_DIR/CRT_Lottes.fx"
        SETTINGS="$(printf 'fDownscale = 2.0\nfBlur = 2.6')"
        ;;

    *)
        echo "STOP: Invalid Dreamcast shader preference: $SHADER" >&2
        exit 1
        ;;
esac

if [[ "$SHADER" != "NONE" ]]; then
    for required in "$SHADER_FILE" "$INCLUDE_DIR/ReShade.fxh"; do
        if [[ ! -f "$required" ]]; then
            echo "STOP: Missing shader dependency: $required" >&2
            exit 1
        fi
    done

    if [[ "$SHADER" == "CRT-LOTTES" &&
          ! -f "$INCLUDE_DIR/CRT_Lottes.fxh" ]]; then
        echo "STOP: CRT_Lottes.fxh is missing." >&2
        exit 1
    fi
fi

echo "============================================================"
echo "BAREFRONT — DREAMCAST"
echo "============================================================"
echo "Shader:       $SHADER"
echo "Native:       640x480"
echo "Output:       1280x960"
echo "Scaling:      integer / nearest"
echo "ROM:          $ROM"

if [[ "$SHADER" == "NONE" ]]; then
    echo "vkBasalt:     disabled"
else
    echo "Shader file:  $SHADER_FILE"
    echo "Activation:   disabled at startup; delayed F8"
fi

if [[ "$MODE" == "--dry-run" ]]; then
    echo "PASS: Dry run only — no game launched."
    exit 0
fi

mkdir -p "$ROOT/saves/dreamcast"

export XDG_DATA_HOME="$ROOT/saves/dreamcast"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SESSION_DIR="$(mktemp -d /tmp/barefront-flycast-shader.XXXXXX)"
LOG="$SESSION_DIR/gamescope.log"
ACTIVATION_LOG="$SESSION_DIR/activation.log"
CONTROL_LOG="$SESSION_DIR/controller.log"
CONFIG="$SESSION_DIR/vkbasalt.conf"

echo "Session logs: $SESSION_DIR"

if [[ "$SHADER" == "NONE" ]]; then
    LAUNCH_ENV=(env -u VKBASALT_CONFIG_FILE ENABLE_VKBASALT=0)
else
    cat > "$CONFIG" <<CONF
effects = $EFFECT
$EFFECT = $SHADER_FILE
reshadeIncludePath = $INCLUDE_DIR
reshadeTexturePath = $INCLUDE_DIR
enableOnLaunch = False
toggleKey = F8
$SETTINGS
CONF

    LAUNCH_ENV=(
        env
        ENABLE_VKBASALT=1
        VKBASALT_CONFIG_FILE="$CONFIG"
    )
fi

SHADER_HELPER_PID=""
CONTROL_HELPER_PID=""

cleanup() {
    if [[ -n "$SHADER_HELPER_PID" ]]; then
        if kill -0 "$SHADER_HELPER_PID" 2>/dev/null; then
            kill "$SHADER_HELPER_PID" 2>/dev/null || true
        fi
        wait "$SHADER_HELPER_PID" 2>/dev/null || true
    fi

    if [[ -n "$CONTROL_HELPER_PID" ]]; then
        if kill -0 "$CONTROL_HELPER_PID" 2>/dev/null; then
            kill "$CONTROL_HELPER_PID" 2>/dev/null || true
        fi
        wait "$CONTROL_HELPER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

echo
echo "=== LAUNCHING GAME ==="

"${LAUNCH_ENV[@]}" \
    "$GAMESCOPE" \
        -b -g \
        -w 640 -h 480 \
        -W 1280 -H 960 \
        -S integer \
        -F nearest \
        -- "$FLYCAST" "$ROM" > "$LOG" 2>&1 &

GAME_PID=$!

BAREFRONT_DREAMCAST_CONTROL_SESSION=1 \
    "$CONTROL_HELPER" > "$CONTROL_LOG" 2>&1 &
CONTROL_HELPER_PID=$!

if [[ "$SHADER" != "NONE" ]]; then
    BAREFRONT_FLYCAST_LOG="$LOG" \
        python3 "$SHADER_HELPER" > "$ACTIVATION_LOG" 2>&1 &
    SHADER_HELPER_PID=$!
fi

STATUS=0
wait "$GAME_PID" || STATUS=$?

cleanup
SHADER_HELPER_PID=""
CONTROL_HELPER_PID=""

echo
echo "=== CONTROLLER RESULT ==="
cat "$CONTROL_LOG" 2>/dev/null || true

echo
echo "=== ACTIVATION RESULT ==="

if [[ "$SHADER" == "NONE" ]]; then
    echo "Not applicable — vkBasalt disabled."
else
    cat "$ACTIVATION_LOG"
fi

echo
echo "=== GAME EXIT STATUS ==="
echo "$STATUS"

echo
echo "=== LAST GAME LOG LINES ==="
tail -n 16 "$LOG"

echo
echo "=== SESSION LOG DIRECTORY ==="
echo "$SESSION_DIR"

exit "$STATUS"
