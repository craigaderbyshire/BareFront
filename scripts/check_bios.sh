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

echo "This checker verifies firmware in BareFront's standard folders."
echo
echo "Where verified signatures are available, BareFront also"
echo "recognises user-supplied firmware by checksum."
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


# ------------------------------------------------------------
# GameCube
#
# Dolphin can boot without an external IPL, but BareFront uses
# a real regional IPL to preserve the authentic startup screen.
# ------------------------------------------------------------

GC_IPL_REGIONS=()

for REGION in EUR USA JAP; do
    if [[ -f "$ROOT/bios/gamecube/$REGION/IPL.bin" ]]; then
        GC_IPL_REGIONS+=("$REGION")
    fi
done

if [[ "${#GC_IPL_REGIONS[@]}" -gt 0 ]]; then
    pass "GameCube" "IPL present for: ${GC_IPL_REGIONS[*]}"
else
    fail "GameCube" "IPL missing - add bios/gamecube/<region>/IPL.bin"
fi


# ------------------------------------------------------------
# PlayStation
#
# DuckStation needs a real PlayStation BIOS supplied by the user.
# Legitimate BIOS filenames vary, so BareFront recognises the
# file contents rather than requiring one particular filename.
#
# BareFront does not provide or install BIOS files.
# ------------------------------------------------------------

PS1_DIR="$ROOT/bios/ps1"

ps1_bios_identity()
{
    local path="$1"

    local actual_size
    local actual_crc32
    local actual_sha256

    actual_size="$(stat -Lc '%s' "$path")"

    actual_crc32="$(
        python3 - "$path" <<'PYCRC'
import sys
import zlib

with open(sys.argv[1], "rb") as handle:
    crc = 0

    while True:
        chunk = handle.read(1024 * 1024)

        if not chunk:
            break

        crc = zlib.crc32(chunk, crc)

print(f"{crc & 0xffffffff:08x}")
PYCRC
    )"

    actual_sha256="$(
        sha256sum "$path" |
        awk '{print $1}'
    )"

    case \
        "${actual_size}:${actual_crc32,,}:${actual_sha256,,}" \
    in

        524288:37157331:71af94d1e47a68c11e8fdb9f8368040601514a42a5a399cda48c7d3bff1e99d3)
            printf '%s\n' "SCPH-1001 v2.2 NTSC-U/C"
            return 0
            ;;

        524288:ff3eeb8c:9c0421858e217805f4abe18698afea8d5aa36ff0727eb8484944e00eb5e7eadb)
            printf '%s\n' "SCPH-5500 v3.0 NTSC-J"
            return 0
            ;;

        524288:8d8cb7e4:11052b6499e466bbf0a709b1f9cb6834a9418e66680387912451e971cf8a1fef)
            printf '%s\n' "SCPH-5501/5503/7003 v3.0 NTSC-U/C"
            return 0
            ;;

        524288:318178bf:5e84a94818cf5282f4217591fefd88be36b9b174b3cc7cb0bcd75199beb450f1)
            printf '%s\n' "SCPH-7002/7502/9002 v4.1 PAL"
            return 0
            ;;

    esac

    return 1
}


PS1_FILES=0
PS1_RECOGNISED=0
PS1_UNKNOWN=0

if [[ -d "$PS1_DIR" ]]; then

    while IFS= read -r -d '' file; do

        PS1_FILES=$((PS1_FILES + 1))

        if identity="$(ps1_bios_identity "$file")"; then
            PS1_RECOGNISED=$((PS1_RECOGNISED + 1))
        else
            PS1_UNKNOWN=$((PS1_UNKNOWN + 1))
        fi

    done < <(
        find -L "$PS1_DIR" \
            -maxdepth 1 \
            -type f \
            -print0 \
            2>/dev/null
    )

fi


if [[ "$PS1_RECOGNISED" -gt 0 ]]; then

    if [[ "$PS1_UNKNOWN" -gt 0 ]]; then
        pass "PlayStation" \
            "$PS1_RECOGNISED recognised BIOS file(s); $PS1_UNKNOWN unrecognised file(s) ignored"
    else
        pass "PlayStation" \
            "$PS1_RECOGNISED recognised BIOS file(s)"
    fi

elif [[ "$PS1_FILES" -gt 0 ]]; then

    fail "PlayStation" \
        "BIOS file(s) present but none recognised"

else

    fail "PlayStation" \
        "BIOS missing - add a supported dump to bios/ps1/"

fi


# ------------------------------------------------------------
# PlayStation 2
#
# PCSX2 accepts many legitimate console BIOS revisions/regions.
# BareFront uses the same ROMVER structure validation as the
# launcher, then recognises verified BIOS payloads by size,
# CRC32 and SHA-256.
#
# Companion files such as NVM, MEC, ROM1, ROM2 and EROM do not
# count as a main PS2 BIOS.
#
# BareFront does not provide or install BIOS files.
# ------------------------------------------------------------

PS2_DIR="$ROOT/bios/ps2"

PS2_SCAN="$(
    python3 - "$PS2_DIR" <<'PYPS2'
from pathlib import Path
import hashlib
import struct
import sys
import zlib

bios_dir = Path(sys.argv[1])

REGION_CODES = {
    "A": "USA",
    "E": "Europe",
    "J": "Japan",
    "H": "Asia",
    "C": "China",
    "P": "Free",
    "X": "Test",
}

KNOWN = {
    (
        4194304,
        "9386a740",
        "ee7ae4cc152588b7da1dab17494a321ceafafaf799769baea4e8a28afa5044b1",
    ): "Europe",

    (
        4194304,
        "6f8e3c29",
        "d6653f4e93be2f6f9e9d690a934f26cf0f6ad4e348b69f41ef736732c3a6685b",
    ): "Europe",

    (
        4194304,
        "b7ef81a9",
        "c4dad3b5c6ad58bce70a47fc332602880f041c0338ac6be89061c928f6919ab1",
    ): "Japan",

    (
        4194304,
        "a19e0bf5",
        "f4c948e61a291d4b3f92a141e550cf8357204287a31ff784caccbedaef910c9d",
    ): "USA",
}


def identify_bios(path):
    size = path.stat().st_size

    if not (4 * 1024 * 1024 <= size <= 8 * 1024 * 1024):
        return None

    data = path.read_bytes()

    romdir_pos = None

    for pos in range(0, min(len(data), 512 * 1024), 16):
        entry = data[pos:pos + 16]

        if len(entry) < 16:
            break

        if entry[:10].split(b"\0", 1)[0] == b"RESET":
            romdir_pos = pos
            break

    if romdir_pos is None:
        return None

    file_offset = 0
    pos = romdir_pos

    while pos + 16 <= len(data):
        entry = data[pos:pos + 16]

        name = (
            entry[:10]
            .split(b"\0", 1)[0]
            .decode("ascii", "ignore")
        )

        if not name:
            break

        _, file_size = struct.unpack_from("<HI", entry, 10)

        if name == "ROMVER":
            romver = data[file_offset:file_offset + 14].decode(
                "ascii", "replace"
            )

            if len(romver) != 14:
                return None

            try:
                int(romver[0:4])
                int(romver[6:14])
            except ValueError:
                return None

            region = REGION_CODES.get(romver[4])

            if region is None:
                return None

            return {
                "region": region,
                "size": len(data),
                "crc32": f"{zlib.crc32(data) & 0xffffffff:08x}",
                "sha256": hashlib.sha256(data).hexdigest(),
            }

        file_offset += (file_size + 0x0F) & ~0x0F
        pos += 16

    return None


files = 0
valid = 0
recognised = 0
unknown_valid = 0
regions = set()

if bios_dir.is_dir():
    for path in bios_dir.iterdir():
        if not path.is_file():
            continue

        files += 1

        info = identify_bios(path)

        if info is None:
            continue

        valid += 1
        regions.add(info["region"])

        identity = (
            info["size"],
            info["crc32"],
            info["sha256"],
        )

        if identity in KNOWN:
            recognised += 1
        else:
            unknown_valid += 1

print(f"FILES={files}")
print(f"VALID={valid}")
print(f"RECOGNISED={recognised}")
print(f"UNKNOWN_VALID={unknown_valid}")
print(f"REGIONS={' '.join(sorted(regions))}")
PYPS2
)"

PS2_FILES=0
PS2_VALID=0
PS2_RECOGNISED=0
PS2_UNKNOWN_VALID=0
PS2_REGIONS=""

while IFS='=' read -r key value; do
    case "$key" in
        FILES)
            PS2_FILES="$value"
            ;;
        VALID)
            PS2_VALID="$value"
            ;;
        RECOGNISED)
            PS2_RECOGNISED="$value"
            ;;
        UNKNOWN_VALID)
            PS2_UNKNOWN_VALID="$value"
            ;;
        REGIONS)
            PS2_REGIONS="$value"
            ;;
    esac
done <<< "$PS2_SCAN"


if [[ "$PS2_RECOGNISED" -gt 0 ]]; then

    message="$PS2_RECOGNISED recognised BIOS image(s)"

    if [[ -n "$PS2_REGIONS" ]]; then
        message="$message - regions: $PS2_REGIONS"
    fi

    if [[ "$PS2_UNKNOWN_VALID" -gt 0 ]]; then
        message="$message; $PS2_UNKNOWN_VALID additional valid unrecognised image(s)"
    fi

    pass "PlayStation 2" "$message"

elif [[ "$PS2_UNKNOWN_VALID" -gt 0 ]]; then

    warn "PlayStation 2" \
        "$PS2_UNKNOWN_VALID valid ROMVER BIOS image(s), but checksum not recognised"

elif [[ "$PS2_FILES" -gt 0 ]]; then

    fail "PlayStation 2" \
        "Files present but no valid main PS2 BIOS found"

else

    fail "PlayStation 2" \
        "BIOS missing - add a dumped BIOS to bios/ps2/"

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
# MAME owns the Neo Geo BIOS/device-set definition. BareFront
# therefore asks the installed MAME build to verify neogeo.zip
# rather than maintaining a duplicate ROM-member database.
#
# The archive may live in either bios/neogeo/ or roms/neogeo/.
# BareFront never downloads, creates or repairs this archive.
# ------------------------------------------------------------

NEOGEO_BIOS_ARCHIVE="$ROOT/bios/neogeo/neogeo.zip"
NEOGEO_ROM_ARCHIVE="$ROOT/roms/neogeo/neogeo.zip"
NEOGEO_MAME="$(command -v mame || true)"

if [[ ! -f "$NEOGEO_BIOS_ARCHIVE" &&
      ! -f "$NEOGEO_ROM_ARCHIVE" ]]
then

    warn "Neo Geo" \
        "neogeo.zip not found in bios/neogeo/ or roms/neogeo/"

elif [[ -z "$NEOGEO_MAME" ]]; then

    warn "Neo Geo" \
        "neogeo.zip present but MAME is unavailable for verification"

else

    NEOGEO_ROMPATH="$ROOT/bios/neogeo;$ROOT/roms/neogeo"

    if "$NEOGEO_MAME" \
        -rompath "$NEOGEO_ROMPATH" \
        -verifyroms neogeo \
        >/tmp/barefront-neogeo-verify.log 2>&1
    then

        pass "Neo Geo" \
            "neogeo.zip verified by MAME"

    else

        warn "Neo Geo" \
            "neogeo.zip present but failed MAME verification"

    fi

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
# Mednafen uses separate BIOS files for Japan and for
# North America/Europe.
#
# BareFront does not provide or install these files. It only
# recognises user-supplied dumps by filename, size, CRC32 and
# SHA-256.
# ------------------------------------------------------------

SATURN_DIR="$ROOT/bios/saturn"
SATURN_JP="$SATURN_DIR/sega_101.bin"
SATURN_NA_EU="$SATURN_DIR/mpr-17933.bin"

saturn_bios_matches()
{
    local path="$1"
    local expected_size="$2"
    local expected_crc32="$3"
    local expected_sha256="$4"

    if [[ ! -f "$path" ]]; then
        return 2
    fi

    local actual_size
    local actual_crc32
    local actual_sha256

    actual_size="$(stat -Lc '%s' "$path")"

    actual_crc32="$(
        python3 - "$path" <<'PYCRC'
import sys
import zlib

with open(sys.argv[1], "rb") as handle:
    crc = 0

    while True:
        chunk = handle.read(1024 * 1024)

        if not chunk:
            break

        crc = zlib.crc32(chunk, crc)

print(f"{crc & 0xffffffff:08x}")
PYCRC
    )"

    actual_sha256="$(
        sha256sum "$path" |
        awk '{print $1}'
    )"

    [[ "$actual_size" == "$expected_size" ]] &&
    [[ "${actual_crc32,,}" == "${expected_crc32,,}" ]] &&
    [[ "${actual_sha256,,}" == "${expected_sha256,,}" ]]
}


SATURN_JP_STATUS=2

if saturn_bios_matches \
    "$SATURN_JP" \
    "524288" \
    "224b752c" \
    "dcfef4b99605f872b6c3b6d05c045385cdea3d1b702906a0ed930df7bcb7deac"
then
    SATURN_JP_STATUS=0
else
    SATURN_JP_STATUS=$?
fi


SATURN_NA_EU_STATUS=2

if saturn_bios_matches \
    "$SATURN_NA_EU" \
    "524288" \
    "4afcf0fa" \
    "96e106f740ab448cf89f0dd49dfbac7fe5391cb6bd6e14ad5e3061c13330266f"
then
    SATURN_NA_EU_STATUS=0
else
    SATURN_NA_EU_STATUS=$?
fi


if [[ "$SATURN_JP_STATUS" -eq 0 &&
      "$SATURN_NA_EU_STATUS" -eq 0 ]]
then

    pass "Saturn" "Recognised sega_101.bin and mpr-17933.bin"

elif [[ "$SATURN_JP_STATUS" -eq 0 ]]; then

    if [[ "$SATURN_NA_EU_STATUS" -eq 2 ]]; then
        warn "Saturn" "sega_101.bin recognised; add mpr-17933.bin"
    else
        warn "Saturn" "sega_101.bin recognised; mpr-17933.bin is not recognised"
    fi

elif [[ "$SATURN_NA_EU_STATUS" -eq 0 ]]; then

    if [[ "$SATURN_JP_STATUS" -eq 2 ]]; then
        warn "Saturn" "mpr-17933.bin recognised; add sega_101.bin"
    else
        warn "Saturn" "mpr-17933.bin recognised; sega_101.bin is not recognised"
    fi

else

    SATURN_PROBLEMS=()

    if [[ "$SATURN_JP_STATUS" -eq 2 ]]; then
        SATURN_PROBLEMS+=("missing sega_101.bin")
    else
        SATURN_PROBLEMS+=("unrecognised sega_101.bin")
    fi

    if [[ "$SATURN_NA_EU_STATUS" -eq 2 ]]; then
        SATURN_PROBLEMS+=("missing mpr-17933.bin")
    else
        SATURN_PROBLEMS+=("unrecognised mpr-17933.bin")
    fi

    fail "Saturn" "${SATURN_PROBLEMS[*]}"

fi


# ------------------------------------------------------------
# PC Engine
#
# Base PC Engine HuCard emulation does not require BIOS firmware.
# CD titles need System Card firmware, but not every BareFront
# PC Engine user will use CD games.
# ------------------------------------------------------------

PCENGINE_DIR="$ROOT/bios/pcengine"

if [[ -f "$PCENGINE_DIR/syscard3.pce" ]]; then
    pass "PC Engine" "System Card 3 present for CD games"
else
    warn "PC Engine" "HuCards ready; add syscard3.pce for CD games"
fi


# ------------------------------------------------------------
# Amiga
#
# Amiberry identifies Kickstart ROMs by content rather than
# requiring one particular filename.
#
# BareFront treats the A500 1.3, A600 2.05 and A1200 3.1
# Kickstarts as the complete WHDLoad firmware set. Additional
# recognised Kickstarts are optional.
#
# AROS remains a fallback and does not count as a Commodore
# Kickstart.
#
# BareFront does not provide or install Kickstart ROMs.
# ------------------------------------------------------------

AMIGA_DIR="$ROOT/bios/amiga"

AMIGA_SCAN="$(
    python3 - "$AMIGA_DIR" <<'PYAMIGA'
from pathlib import Path
import hashlib
import sys
import zlib

bios_dir = Path(sys.argv[1])

KNOWN = {
    (
        262144,
        "c4f0f55f",
        "ee05862d8102a08436ac4056da7d549db31625c7d47b24dfb7b3c9a5c113ca53",
    ): ("A500_1.3", True),

    (
        524288,
        "43b0df7b",
        "8d57d6e9d976df42d91ff9d10a5eedaede1a00e3b4b34cad750ca5ff7229f28a",
    ): ("A600_2.05", True),

    (
        524288,
        "fc24ae0d",
        "8c8a0cf04f91b88eaf0c4f1126041987067e2286a8ee590bdbae447a8000c5ee",
    ): ("A600_3.1", False),

    (
        524288,
        "1483a091",
        "6d43840d4099a74170ea0f0425b6257c3891ebcaa39c4d1840075a9ab22b5707",
    ): ("A1200_3.1", True),
}

AROS = {
    (
        524288,
        "20ca1219",
        "874a9275ff7b39723921eac223a5f461f4eb03bd9ba1976b228ad0f4cfa74505",
    ),
    (
        524288,
        "7fe47845",
        "d583ff8f40c73b1584a1395bb0869a909a96d2366a4ae9f4c15ab6a3d868ea62",
    ),
}

required_ids = {
    ident
    for ident, required in KNOWN.values()
    if required
}

recognised_ids = set()
optional = 0
aros = 0
files = 0

if bios_dir.is_dir():
    for path in bios_dir.iterdir():
        if not path.is_file():
            continue

        files += 1

        data = path.read_bytes()

        identity = (
            len(data),
            f"{zlib.crc32(data) & 0xffffffff:08x}",
            hashlib.sha256(data).hexdigest(),
        )

        if identity in KNOWN:
            ident, required = KNOWN[identity]
            recognised_ids.add(ident)

            if not required:
                optional += 1

        elif identity in AROS:
            aros += 1

missing = sorted(required_ids - recognised_ids)

print(f"FILES={files}")
print(f"REQUIRED_FOUND={len(required_ids) - len(missing)}")
print(f"MISSING={len(missing)}")
print(f"MISSING_IDS={' '.join(missing)}")
print(f"OPTIONAL={optional}")
print(f"AROS={aros}")
PYAMIGA
)"

AMIGA_FILES=0
AMIGA_REQUIRED_FOUND=0
AMIGA_MISSING=0
AMIGA_MISSING_IDS=""
AMIGA_OPTIONAL=0
AMIGA_AROS=0

while IFS='=' read -r key value; do
    case "$key" in
        FILES)
            AMIGA_FILES="$value"
            ;;
        REQUIRED_FOUND)
            AMIGA_REQUIRED_FOUND="$value"
            ;;
        MISSING)
            AMIGA_MISSING="$value"
            ;;
        MISSING_IDS)
            AMIGA_MISSING_IDS="$value"
            ;;
        OPTIONAL)
            AMIGA_OPTIONAL="$value"
            ;;
        AROS)
            AMIGA_AROS="$value"
            ;;
    esac
done <<< "$AMIGA_SCAN"


if [[ "$AMIGA_MISSING" -eq 0 ]]; then

    message="All 3 WHDLoad-required Kickstarts recognised"

    if [[ "$AMIGA_OPTIONAL" -gt 0 ]]; then
        message="$message; $AMIGA_OPTIONAL additional recognised"
    fi

    pass "Amiga" "$message"

elif [[ "$AMIGA_REQUIRED_FOUND" -gt 0 ]]; then

    warn "Amiga" \
        "$AMIGA_MISSING WHDLoad-required Kickstart(s) missing: $AMIGA_MISSING_IDS"

elif [[ "$AMIGA_AROS" -gt 0 ]]; then

    warn "Amiga" \
        "AROS fallback present; no recognised Commodore Kickstarts"

else

    warn "Amiga" \
        "No recognised Kickstarts - Amiberry can use built-in AROS fallback"

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
