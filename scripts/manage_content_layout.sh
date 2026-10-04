#!/usr/bin/env bash

set -euo pipefail


die()
{
    echo "ERROR: $*" >&2
    exit 1
}


state_of_canonical()
{
    local path="$1"
    local expected="$2"

    if [[ -L "$path" ]]; then
        if [[ "$(readlink "$path")" == "$expected" ]]; then
            printf '%s\n' "managed"
        else
            printf '%s\n' "other"
        fi

        return
    fi

    if [[ -d "$path" ]]; then
        printf '%s\n' "legacy"
        return
    fi

    if [[ -e "$path" ]]; then
        printf '%s\n' "other"
        return
    fi

    printf '%s\n' "missing"
}


managed_link_matches()
{
    local path="$1"
    local expected="$2"

    [[ -L "$path" ]] &&
    [[ "$(readlink "$path")" == "$expected" ]]
}


remove_our_link_if_present()
{
    local path="$1"
    local expected="$2"

    if managed_link_matches "$path" "$expected"; then
        rm -- "$path"
    fi
}


ROOT="${1:-}"

[[ -n "$ROOT" ]] ||
    die "Usage: manage_content_layout.sh <BareFront root>"

ROOT="$(
    cd "$ROOT" 2>/dev/null &&
    pwd -P
)" || die "BareFront root does not exist: $1"


CONTENT="$ROOT/content"
LOCAL_PARENT="$CONTENT/local"
LOCAL_ROOT="$LOCAL_PARENT/barefront"

LOCAL_ROMS="$LOCAL_ROOT/roms"
LOCAL_BIOS="$LOCAL_ROOT/bios"

ACTIVE="$CONTENT/active"

CANONICAL_ROMS="$ROOT/roms"
CANONICAL_BIOS="$ROOT/bios"

ROMS_TARGET="content/active/roms"
BIOS_TARGET="content/active/bios"
ACTIVE_LOCAL_TARGET="local/barefront"


ROM_STATE="$(
    state_of_canonical \
        "$CANONICAL_ROMS" \
        "$ROMS_TARGET"
)"

BIOS_STATE="$(
    state_of_canonical \
        "$CANONICAL_BIOS" \
        "$BIOS_TARGET"
)"


echo "ROM state:  $ROM_STATE"
echo "BIOS state: $BIOS_STATE"


# ------------------------------------------------------------
# Existing fully managed installation
# ------------------------------------------------------------

if [[ "$ROM_STATE" == "managed" &&
      "$BIOS_STATE" == "managed" ]]
then
    [[ -d "$LOCAL_ROMS" ]] ||
        die "Managed layout is missing Local ROM directory"

    [[ -d "$LOCAL_BIOS" ]] ||
        die "Managed layout is missing Local BIOS directory"

    if [[ -e "$ACTIVE" && ! -L "$ACTIVE" ]]; then
        die "Managed content/active is not a symlink"
    fi

    if [[ -L "$ACTIVE" ]]; then
        TEMP="$CONTENT/.active.install"

        if [[ -e "$TEMP" && ! -L "$TEMP" ]] ||
           [[ -L "$TEMP" ]]
        then
            die "Installer temporary selector already exists: $TEMP"
        fi

        ln -s \
            "$ACTIVE_LOCAL_TARGET" \
            "$TEMP"

        mv -Tf \
            "$TEMP" \
            "$ACTIVE"
    else
        ln -s \
            "$ACTIVE_LOCAL_TARGET" \
            "$ACTIVE"
    fi

    echo "PASS: existing managed layout accepted"
    echo "PASS: installer selected Local source"
    exit 0
fi


# ------------------------------------------------------------
# Reject every mixed / unknown canonical state
# ------------------------------------------------------------

if [[ "$ROM_STATE" != "$BIOS_STATE" ]]; then
    die "Partially managed or inconsistent canonical layout"
fi

if [[ "$ROM_STATE" == "other" ]]; then
    die "Unexpected canonical ROM/BIOS filesystem objects"
fi


# ------------------------------------------------------------
# Fresh installation
# ------------------------------------------------------------

if [[ "$ROM_STATE" == "missing" &&
      "$BIOS_STATE" == "missing" ]]
then
    [[ ! -e "$LOCAL_ROMS" && ! -L "$LOCAL_ROMS" ]] ||
        die "Local ROM destination already exists"

    [[ ! -e "$LOCAL_BIOS" && ! -L "$LOCAL_BIOS" ]] ||
        die "Local BIOS destination already exists"

    [[ ! -e "$ACTIVE" && ! -L "$ACTIVE" ]] ||
        die "content/active already exists"

    mkdir -p "$LOCAL_ROOT"

    ROLLBACK=1

    rollback_fresh()
    {
        local status=$?

        if [[ "$ROLLBACK" -eq 1 ]]; then
            remove_our_link_if_present \
                "$CANONICAL_ROMS" \
                "$ROMS_TARGET"

            remove_our_link_if_present \
                "$CANONICAL_BIOS" \
                "$BIOS_TARGET"

            remove_our_link_if_present \
                "$ACTIVE" \
                "$ACTIVE_LOCAL_TARGET"

            rmdir "$LOCAL_ROMS" 2>/dev/null || true
            rmdir "$LOCAL_BIOS" 2>/dev/null || true
            rmdir "$LOCAL_ROOT" 2>/dev/null || true
            rmdir "$LOCAL_PARENT" 2>/dev/null || true
            rmdir "$CONTENT" 2>/dev/null || true
        fi

        exit "$status"
    }

    trap rollback_fresh EXIT INT TERM

    mkdir \
        "$LOCAL_ROMS" \
        "$LOCAL_BIOS"

    ln -s \
        "$ACTIVE_LOCAL_TARGET" \
        "$ACTIVE"

    ln -s \
        "$ROMS_TARGET" \
        "$CANONICAL_ROMS"

    ln -s \
        "$BIOS_TARGET" \
        "$CANONICAL_BIOS"

    ROLLBACK=0
    trap - EXIT INT TERM

    echo "PASS: fresh managed Local layout created"
    exit 0
fi


# ------------------------------------------------------------
# Legacy installation
#
# Both canonical paths are ordinary directories. They are
# migrated by same-filesystem rename; content is not copied.
# ------------------------------------------------------------

[[ "$ROM_STATE" == "legacy" &&
   "$BIOS_STATE" == "legacy" ]] ||
    die "Unsupported canonical layout state"


# Never attempt to rename a live mountpoint. This specifically
# protects installations temporarily presenting USB/NAS directly
# on the historical canonical paths.

if mountpoint -q "$CANONICAL_ROMS"; then
    die "Legacy ROM path is a mountpoint; unmount it before migration"
fi

if mountpoint -q "$CANONICAL_BIOS"; then
    die "Legacy BIOS path is a mountpoint; unmount it before migration"
fi


[[ ! -e "$LOCAL_ROMS" && ! -L "$LOCAL_ROMS" ]] ||
    die "Local ROM migration destination already exists"

[[ ! -e "$LOCAL_BIOS" && ! -L "$LOCAL_BIOS" ]] ||
    die "Local BIOS migration destination already exists"

[[ ! -e "$ACTIVE" && ! -L "$ACTIVE" ]] ||
    die "content/active already exists"


mkdir -p "$LOCAL_ROOT"


SOURCE_ROM_DEVICE="$(
    stat -c '%d' "$CANONICAL_ROMS"
)"

SOURCE_BIOS_DEVICE="$(
    stat -c '%d' "$CANONICAL_BIOS"
)"

DESTINATION_DEVICE="$(
    stat -c '%d' "$LOCAL_ROOT"
)"


[[ "$SOURCE_ROM_DEVICE" == "$DESTINATION_DEVICE" ]] ||
    die "ROM migration would cross filesystems"

[[ "$SOURCE_BIOS_DEVICE" == "$DESTINATION_DEVICE" ]] ||
    die "BIOS migration would cross filesystems"


echo "PASS: migration is same-filesystem rename"


ROM_MOVED=0
BIOS_MOVED=0
ACTIVE_CREATED=0
ROMS_LINK_CREATED=0
BIOS_LINK_CREATED=0
ROLLBACK=1


rollback_legacy()
{
    local status=$?

    if [[ "$ROLLBACK" -eq 1 ]]; then
        if [[ "$BIOS_LINK_CREATED" -eq 1 ]]; then
            remove_our_link_if_present \
                "$CANONICAL_BIOS" \
                "$BIOS_TARGET"
        fi

        if [[ "$ROMS_LINK_CREATED" -eq 1 ]]; then
            remove_our_link_if_present \
                "$CANONICAL_ROMS" \
                "$ROMS_TARGET"
        fi

        if [[ "$ACTIVE_CREATED" -eq 1 ]]; then
            remove_our_link_if_present \
                "$ACTIVE" \
                "$ACTIVE_LOCAL_TARGET"
        fi

        if [[ "$BIOS_MOVED" -eq 1 &&
              -d "$LOCAL_BIOS" &&
              ! -e "$CANONICAL_BIOS" &&
              ! -L "$CANONICAL_BIOS" ]]
        then
            mv \
                "$LOCAL_BIOS" \
                "$CANONICAL_BIOS"
        fi

        if [[ "$ROM_MOVED" -eq 1 &&
              -d "$LOCAL_ROMS" &&
              ! -e "$CANONICAL_ROMS" &&
              ! -L "$CANONICAL_ROMS" ]]
        then
            mv \
                "$LOCAL_ROMS" \
                "$CANONICAL_ROMS"
        fi

        rmdir "$LOCAL_ROOT" 2>/dev/null || true
        rmdir "$LOCAL_PARENT" 2>/dev/null || true
        rmdir "$CONTENT" 2>/dev/null || true
    fi

    exit "$status"
}


trap rollback_legacy EXIT INT TERM


mv \
    "$CANONICAL_ROMS" \
    "$LOCAL_ROMS"

ROM_MOVED=1


mv \
    "$CANONICAL_BIOS" \
    "$LOCAL_BIOS"

BIOS_MOVED=1


ln -s \
    "$ACTIVE_LOCAL_TARGET" \
    "$ACTIVE"

ACTIVE_CREATED=1


ln -s \
    "$ROMS_TARGET" \
    "$CANONICAL_ROMS"

ROMS_LINK_CREATED=1


ln -s \
    "$BIOS_TARGET" \
    "$CANONICAL_BIOS"

BIOS_LINK_CREATED=1


ROLLBACK=0
trap - EXIT INT TERM


echo "PASS: legacy Local content migrated"
echo "PASS: canonical ROM/BIOS links installed"
echo "PASS: Local source selected"
