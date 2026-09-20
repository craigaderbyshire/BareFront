#!/usr/bin/env bash

# ============================================================
# BareFront shared audio resolver
#
# Policy:
#   - BareFront games use the currently selected HDMI output.
#   - Never hard-code ALSA card/device numbers.
#   - Resolve the desktop audio sink to its real ALSA hardware.
#
# Exports:
#   BAREFRONT_AUDIO_SINK
#   BAREFRONT_AUDIO_NAME
#   BAREFRONT_ALSA_CARD
#   BAREFRONT_ALSA_DEVICE
#   BAREFRONT_ALSA_HW
#   BAREFRONT_MEDNAFEN_DEVICE
# ============================================================

barefront_audio_resolve() {

    if ! command -v pactl >/dev/null 2>&1; then
        echo "BareFront audio: pactl not found." >&2
        return 1
    fi

    local sink
    local metadata
    local card
    local device
    local name
    local active_port
    local port_is_hdmi

    sink="$(pactl get-default-sink 2>/dev/null || true)"

    if [[ -z "$sink" ]]; then
        echo "BareFront audio: no default audio sink is available." >&2
        return 1
    fi

    metadata="$(
        pactl list sinks 2>/dev/null |
        awk -v sink="$sink" '
            $1 == "Name:" {
                found = ($2 == sink)
            }

            found {
                print
            }

            found && /^$/ {
                exit
            }
        '
    )"

    if [[ -z "$metadata" ]]; then
        echo "BareFront audio: could not inspect selected sink:" >&2
        echo "  $sink" >&2
        return 1
    fi

    active_port="$(
        printf '%s\n' "$metadata" |
        sed -n 's/^[[:space:]]*Active Port:[[:space:]]*//p' |
        head -1
    )"

    port_is_hdmi=0

    if printf '%s\n' "$metadata" |
        grep -qiE 'type:[[:space:]]*HDMI|Active Port:[[:space:]]*hdmi-|device\.string[[:space:]]*=[[:space:]]*"hdmi:'
    then
        port_is_hdmi=1
    fi

    if [[ "$port_is_hdmi" -ne 1 ]]; then
        echo "BareFront audio: selected output is not an HDMI device:" >&2
        echo "  $sink" >&2
        if [[ -n "$active_port" ]]; then
            echo "  Active port: $active_port" >&2
        fi
        return 1
    fi

    card="$(
        printf '%s\n' "$metadata" |
        sed -n 's/^[[:space:]]*alsa\.card = "\([^"]*\)".*/\1/p' |
        head -1
    )"

    device="$(
        printf '%s\n' "$metadata" |
        sed -n 's/^[[:space:]]*alsa\.device = "\([^"]*\)".*/\1/p' |
        head -1
    )"

    name="$(
        printf '%s\n' "$metadata" |
        sed -n 's/^[[:space:]]*alsa\.name = "\([^"]*\)".*/\1/p' |
        head -1
    )"

    if [[ -z "$card" || -z "$device" ]]; then
        echo "BareFront audio: selected HDMI sink has no ALSA hardware mapping:" >&2
        echo "  $sink" >&2
        return 1
    fi

    export BAREFRONT_AUDIO_SINK="$sink"
    export BAREFRONT_AUDIO_NAME="${name:-HDMI}"
    export BAREFRONT_ALSA_CARD="$card"
    export BAREFRONT_ALSA_DEVICE="$device"
    export BAREFRONT_ALSA_HW="hw:CARD=${card},DEV=${device}"
    export BAREFRONT_MEDNAFEN_DEVICE="sexyal-literal-${BAREFRONT_ALSA_HW}"
}


barefront_audio_log() {

    echo "  Audio sink:   $BAREFRONT_AUDIO_SINK"
    echo "  HDMI device:  $BAREFRONT_AUDIO_NAME"
    echo "  Direct ALSA:  $BAREFRONT_ALSA_HW"
}
