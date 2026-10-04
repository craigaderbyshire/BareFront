#!/usr/bin/env bash

# BareFront portable-content source preparation.
#
# This helper performs only best-effort acquisition:
#
#   External Media
#       Ask UDisks to mount eligible removable filesystems.
#
#   Network Share
#       Ask util-linux mount to mount the installer-configured
#       user-mountable CIFS location.
#
# It never selects a source and never writes to ROM/BIOS content.
# BareFront's content pre-flight performs validation and selection.

set -uo pipefail


NETWORK_MOUNTPOINT="${BAREFRONT_NETWORK_MOUNTPOINT:-/mnt/barefront-network}"
FSTAB_FILE="${BAREFRONT_FSTAB:-/etc/fstab}"

MOUNT_COMMAND="${BAREFRONT_MOUNT_COMMAND:-/usr/bin/mount}"
MOUNTPOINT_COMMAND="${BAREFRONT_MOUNTPOINT_COMMAND:-/usr/bin/mountpoint}"
UDISKSCTL_COMMAND="${BAREFRONT_UDISKSCTL_COMMAND:-/usr/bin/udisksctl}"
LSBLK_COMMAND="${BAREFRONT_LSBLK_COMMAND:-/usr/bin/lsblk}"
PYTHON_COMMAND="${BAREFRONT_PYTHON_COMMAND:-/usr/bin/python3}"
TIMEOUT_COMMAND="${BAREFRONT_TIMEOUT_COMMAND:-/usr/bin/timeout}"

CURRENT_USER="${USER:-$(id -un)}"

NETWORK_TIMEOUT_SECONDS="${BAREFRONT_NETWORK_TIMEOUT_SECONDS:-5}"
EXTERNAL_TIMEOUT_SECONDS="${BAREFRONT_EXTERNAL_TIMEOUT_SECONDS:-8}"


valid_source_root()
{
    local root="$1"

    [[ -d "$root/roms" ]] &&
    [[ -d "$root/bios" ]]
}


external_bases()
{
    if [[ -n "${BAREFRONT_EXTERNAL_BASES:-}" ]]; then
        tr ':' '\n' <<< "$BAREFRONT_EXTERNAL_BASES"
        return
    fi

    printf '%s\n' \
        "/media/$CURRENT_USER" \
        "/run/media/$CURRENT_USER"
}


find_valid_external_root()
{
    local base
    local mount
    local root

    while IFS= read -r base; do
        [[ -n "$base" ]] || continue
        [[ -d "$base" ]] || continue

        shopt -s nullglob

        for mount in "$base"/*; do
            [[ -d "$mount" ]] || continue

            root="$mount/barefront"

            if valid_source_root "$root"; then
                printf '%s\n' "$root"
                shopt -u nullglob
                return 0
            fi
        done

        shopt -u nullglob
    done < <(external_bases)

    return 1
}


external_devices()
{
    # A defined override, including an intentionally empty one,
    # is used by isolated regression tests.
    if [[ -n "${BAREFRONT_EXTERNAL_DEVICES+x}" ]]; then
        printf '%s' "$BAREFRONT_EXTERNAL_DEVICES"

        if [[ -n "$BAREFRONT_EXTERNAL_DEVICES" &&
              "${BAREFRONT_EXTERNAL_DEVICES: -1}" != $'\n' ]]; then
            printf '\n'
        fi

        return 0
    fi

    [[ -x "$LSBLK_COMMAND" ]] || return 0
    [[ -x "$PYTHON_COMMAND" ]] || return 0

    "$LSBLK_COMMAND" \
        --json \
        --paths \
        --output \
        PATH,TYPE,FSTYPE,MOUNTPOINTS,HOTPLUG,RM,TRAN \
        2>/dev/null |
    "$PYTHON_COMMAND" -c '
import json
import sys

try:
    document = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

excluded_fs = {
    "",
    "swap",
    "crypto_LUKS",
    "LVM2_member",
    "linux_raid_member",
}

def truthy(value):
    if isinstance(value, bool):
        return value

    if isinstance(value, int):
        return value != 0

    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes"}

    return False

def mounted(node):
    values = node.get("mountpoints")

    if values is None:
        value = node.get("mountpoint")
        return bool(value)

    if not isinstance(values, list):
        values = [values]

    return any(bool(value) for value in values)

def walk(node, inherited_external=False):
    transport = str(node.get("tran") or "").lower()

    here_external = (
        inherited_external
        or truthy(node.get("hotplug"))
        or truthy(node.get("rm"))
        or transport in {"usb", "mmc"}
    )

    device_type = str(node.get("type") or "")
    filesystem = str(node.get("fstype") or "")
    path = str(node.get("path") or "")

    if (
        here_external
        and device_type in {"disk", "part"}
        and filesystem not in excluded_fs
        and path
        and not mounted(node)
    ):
        print(path)

    for child in node.get("children") or []:
        walk(child, here_external)

for blockdevice in document.get("blockdevices") or []:
    walk(blockdevice)
'
}


network_is_configured()
{
    [[ -f "$FSTAB_FILE" ]] || return 1

    awk \
        -v mountpoint="$NETWORK_MOUNTPOINT" \
        '
        /^[[:space:]]*#/ {
            next
        }

        NF >= 3 &&
        $2 == mountpoint &&
        $3 == "cifs" {
            found = 1
        }

        END {
            exit(found ? 0 : 1)
        }
        ' \
        "$FSTAB_FILE"
}


network_is_mounted()
{
    [[ -x "$MOUNTPOINT_COMMAND" ]] || return 1

    "$MOUNTPOINT_COMMAND" \
        -q \
        "$NETWORK_MOUNTPOINT" \
        >/dev/null 2>&1
}


prepare_network()
{
    if ! network_is_configured; then
        echo "Network Share: not configured"
        return 0
    fi

    if network_is_mounted; then
        if valid_source_root "$NETWORK_MOUNTPOINT/barefront"; then
            echo "Network Share: ready"
        else
            echo "Network Share: mounted but invalid"
        fi

        return 0
    fi

    if [[ ! -d "$NETWORK_MOUNTPOINT" ]]; then
        echo "Network Share: configured but mountpoint missing"
        return 0
    fi

    if [[ ! -x "$MOUNT_COMMAND" ||
          ! -x "$TIMEOUT_COMMAND" ]]; then
        echo "Network Share: mount tooling unavailable"
        return 0
    fi

    "$TIMEOUT_COMMAND" \
        --kill-after=2 \
        "$NETWORK_TIMEOUT_SECONDS" \
        "$MOUNT_COMMAND" \
        "$NETWORK_MOUNTPOINT" \
        >/dev/null 2>&1 ||
        true

    if network_is_mounted &&
       valid_source_root "$NETWORK_MOUNTPOINT/barefront"; then
        echo "Network Share: ready"
    else
        echo "Network Share: unavailable"
    fi
}


prepare_external()
{
    local root
    local device

    root="$(
        find_valid_external_root \
            2>/dev/null ||
        true
    )"

    if [[ -n "$root" ]]; then
        echo "External Media: ready"
        return 0
    fi

    if [[ ! -x "$UDISKSCTL_COMMAND" ||
          ! -x "$TIMEOUT_COMMAND" ]]; then
        echo "External Media: mount tooling unavailable"
        return 0
    fi

    while IFS= read -r device; do
        [[ -n "$device" ]] || continue

        "$TIMEOUT_COMMAND" \
            --kill-after=2 \
            "$EXTERNAL_TIMEOUT_SECONDS" \
            "$UDISKSCTL_COMMAND" \
            mount \
            --block-device "$device" \
            --no-user-interaction \
            >/dev/null 2>&1 ||
            true

        root="$(
            find_valid_external_root \
                2>/dev/null ||
            true
        )"

        if [[ -n "$root" ]]; then
            echo "External Media: ready"
            return 0
        fi
    done < <(external_devices)

    echo "External Media: unavailable"
}


prepare_external
prepare_network

# Optional sources being absent is not an error. BareFront itself
# decides whether Local/External/Network content is actually valid.
exit 0
