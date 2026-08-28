#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OK=0
WARN=0
FAIL=0

green()
{
    printf '\033[1;32m%s\033[0m' "$1"
}

yellow()
{
    printf '\033[1;33m%s\033[0m' "$1"
}

red()
{
    printf '\033[1;31m%s\033[0m' "$1"
}

heading()
{
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo
}

pass()
{
    local system="$1"
    local message="$2"

    printf "%-18s " "$system"
    green "✅"
    printf " %s\n" "$message"

    OK=$((OK + 1))
}

warn()
{
    local system="$1"
    local message="$2"

    printf "%-18s " "$system"
    yellow "⚠"
    printf " %s\n" "$message"

    WARN=$((WARN + 1))
}

fail()
{
    local system="$1"
    local message="$2"

    printf "%-18s " "$system"
    red "❌"
    printf " %s\n" "$message"

    FAIL=$((FAIL + 1))
}

has_any_file()
{
    local dir="$1"

    [[ -d "$dir" ]] &&
    find "$dir" -maxdepth 1 -type f -print -quit 2>/dev/null \
        | grep -q .
}


heading "BAREFRONT FIRMWARE CHECK"

echo "This first checker verifies whether the expected firmware"
echo "is present in BareFront's standard folders."
echo
echo "Checksum recognition will be added in the next firmware"
echo "database stage."
echo


# ------------------------------------------------------------
# Systems which require no external firmware for ordinary use
# ------------------------------------------------------------

pass "Mega Drive"    "No firmware required"
pass "NES"           "No firmware required"
pass "Super NES"     "No firmware required"
pass "Master System" "No firmware required"
pass "Atari 2600"    "No firmware required"
pass "Atari Jaguar"  "No mandatory firmware required"
pass "GameCube"      "No external BIOS required"


# ------------------------------------------------------------
# PlayStation
#
# DuckStation needs a real PlayStation BIOS supplied by the user.
# Several legitimate regional BIOS variants exist, so Stage 5A
# checks for presence only. Stage 5B will recognise known files
# by size, CRC32 and SHA-256.
# ------------------------------------------------------------

PS1_DIR="$ROOT/bios/ps1"

if has_any_file "$PS1_DIR"; then
    pass "PlayStation" "BIOS file present - checksum check pending"
else
    fail "PlayStation" "BIOS missing - add dumped BIOS to bios/ps1/"
fi


# ------------------------------------------------------------
# PlayStation 2
#
# PCSX2 accepts many legitimate console BIOS revisions/regions.
# Do not require one particular filename.
# ------------------------------------------------------------

PS2_DIR="$ROOT/bios/ps2"

if has_any_file "$PS2_DIR"; then
    pass "PlayStation 2" "BIOS file present - recognition pending"
else
    fail "PlayStation 2" "BIOS missing - add dumped BIOS to bios/ps2/"
fi


# ------------------------------------------------------------
# Commodore 64
#
# These exact files match BareFront's VICE launcher adapter.
# ------------------------------------------------------------

C64_DIR="$ROOT/bios/c64"

C64_REQUIRED=(
    "basic-901226-01.bin"
    "kernal-901227-03.bin"
    "chargen-901225-01.bin"
    "dos1541-325302-01+901229-05.bin"
)

C64_MISSING=0

for file in "${C64_REQUIRED[@]}"; do
    if [[ ! -f "$C64_DIR/$file" ]]; then
        C64_MISSING=$((C64_MISSING + 1))
    fi
done

if [[ "$C64_MISSING" -eq 0 ]]; then
    pass "Commodore 64" "All four VICE firmware files present"
else
    fail "Commodore 64" "$C64_MISSING required firmware file(s) missing"
fi


# ------------------------------------------------------------
# Arcade
#
# Ordinary MAME arcade sets contain their own required ROM
# components or reference parent/device sets. There is no single
# universal external BIOS file for the entire Arcade platform.
# ------------------------------------------------------------

pass "Arcade" "No single global BIOS requirement"


# ------------------------------------------------------------
# Neo Geo
#
# Standard MAME Neo Geo sets normally rely on neogeo.zip.
# Stage 5B will inspect archive members rather than hashing the
# complete ZIP, because ZIP metadata can change without the ROM
# payload changing.
# ------------------------------------------------------------

if [[ -f "$ROOT/bios/neogeo/neogeo.zip" ]] || \
   [[ -f "$ROOT/roms/neogeo/neogeo.zip" ]]
then
    pass "Neo Geo" "neogeo.zip present - archive verification pending"
else
    warn "Neo Geo" "neogeo.zip not found in bios/neogeo/ or roms/neogeo/"
fi


# ------------------------------------------------------------
# Dreamcast
#
# BareFront keeps the user's original firmware in bios/dreamcast.
# Flycast uses a writable copy of dc_flash.bin under saves/.
# ------------------------------------------------------------

DC_DIR="$ROOT/bios/dreamcast"
DC_BOOT="$DC_DIR/dc_boot.bin"
DC_FLASH="$DC_DIR/dc_flash.bin"
DC_FLASH_WORK="$ROOT/saves/dreamcast/dc_flash.bin"

if [[ -f "$DC_BOOT" && -f "$DC_FLASH" ]]; then

    if [[ ! -f "$DC_FLASH_WORK" ]]; then

        # Stage 5A may seed the working flash copy only when it
        # does not already exist. It never overwrites a modified
        # runtime flash file.
        cp "$DC_FLASH" "$DC_FLASH_WORK"

        pass "Dreamcast" "Firmware present; writable flash copy created"

    else

        pass "Dreamcast" "Boot ROM and source flash present"

    fi

else

    missing=""

    [[ -f "$DC_BOOT" ]] || missing="${missing} dc_boot.bin"
    [[ -f "$DC_FLASH" ]] || missing="${missing} dc_flash.bin"

    fail "Dreamcast" "Missing:${missing}"

fi


# ------------------------------------------------------------
# Sega Saturn
#
# Mednafen's exact accepted BIOS variants will be validated in
# Stage 5B. For now, presence of at least one Saturn firmware file
# is enough to tell the user whether the folder is empty.
# ------------------------------------------------------------

SATURN_DIR="$ROOT/bios/saturn"

if has_any_file "$SATURN_DIR"; then
    pass "Saturn" "Firmware present - recognition pending"
else
    fail "Saturn" "BIOS missing - add firmware to bios/saturn/"
fi


# ------------------------------------------------------------
# PC Engine
#
# Base PC Engine HuCard emulation does not require BIOS firmware.
# CD titles need System Card firmware, but not every BareFront
# PC Engine user will use CD games.
# ------------------------------------------------------------

PCENGINE_DIR="$ROOT/bios/pcengine"

if has_any_file "$PCENGINE_DIR"; then
    pass "PC Engine" "Optional CD/System Card firmware present"
else
    warn "PC Engine" "HuCards ready; CD games may need System Card firmware"
fi


# ------------------------------------------------------------
# Amiga
#
# Amiberry supports numerous legitimate Kickstart versions.
# Stage 5B will recognise known Kickstarts by checksum.
# ------------------------------------------------------------

AMIGA_DIR="$ROOT/bios/amiga"

if has_any_file "$AMIGA_DIR"; then
    pass "Amiga" "Kickstart/firmware file present - recognition pending"
else
    warn "Amiga" "No Kickstart found in bios/amiga/"
fi


# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

TOTAL=$((OK + WARN + FAIL))

echo
echo "------------------------------------------------------------"
echo "SUMMARY"
echo "------------------------------------------------------------"
echo

printf "Ready / present : %d\n" "$OK"
printf "Optional/warning: %d\n" "$WARN"
printf "Missing required: %d\n" "$FAIL"
printf "Systems checked : %d\n" "$TOTAL"

echo

if [[ "$FAIL" -eq 0 ]]; then

    green "No required firmware is currently missing."
    echo

else

    red "$FAIL required firmware check(s) need attention."
    echo
    echo
    echo "Add legally obtained/dumped firmware to the folder shown"
    echo "above, then simply run this checker again:"
    echo
    echo "  ./scripts/check_bios.sh"

fi

echo
echo "BareFront never downloads copyrighted BIOS or firmware."
echo

# Missing required firmware is reported to the user, but the
# checker itself exits normally so the installer can continue
# and provide a complete readiness report.
exit 0
