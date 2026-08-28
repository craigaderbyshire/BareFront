#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# BareFront Emulator Installer
# v0.2 - BlastEm + MesenCE
#
# BareFront launches. Emulators emulate.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAREFRONT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${BAREFRONT_ROOT}/barefront.ini"

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_CYAN="\033[36m"

say() {
    printf "%b\n" "$*"
}

die() {
    say "${C_RED}ERROR:${C_RESET} $*"
    exit 1
}

pause() {
    echo
    read -r -p "Press Enter to continue..." _
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    else
        OS_ID="unknown"
        OS_NAME="unknown"
    fi
}

backup_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local stamp
        stamp="$(date +%Y%m%d-%H%M%S)"
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-${stamp}"
        say "${C_GREEN}✓${C_RESET} Backed up barefront.ini"
    fi
}

write_system_config() {
    local section="$1"
    local roms="$2"
    local screenshots="$3"
    local emulator="$4"
    local arguments="$5"

    python3 - \
        "$CONFIG_FILE" \
        "$section" \
        "$roms" \
        "$screenshots" \
        "$emulator" \
        "$arguments" <<'PY'
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
section = sys.argv[2].lower()
wanted = {
    "roms": sys.argv[3],
    "screenshots": sys.argv[4],
    "emulator": sys.argv[5],
    "arguments": sys.argv[6],
}

if config_path.exists():
    lines = config_path.read_text().splitlines()
else:
    lines = []

out = []
found_section = False
inside_target = False
written_keys = set()

def emit_missing():
    for key, value in wanted.items():
        if key not in written_keys:
            out.append(f"{key}={value}")

for line in lines:
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        if inside_target:
            emit_missing()

        name = stripped[1:-1].strip().lower()
        inside_target = (name == section)

        if inside_target:
            found_section = True
            written_keys = set()

        out.append(line)
        continue

    if inside_target and "=" in line and not stripped.startswith(("#", ";")):
        key = line.split("=", 1)[0].strip().lower()
        if key in wanted:
            out.append(f"{key}={wanted[key]}")
            written_keys.add(key)
            continue

    out.append(line)

if inside_target:
    emit_missing()

if not found_section:
    if out and out[-1].strip():
        out.append("")
    out.extend([
        f"[{section}]",
        f"roms={wanted['roms']}",
        f"screenshots={wanted['screenshots']}",
        f"emulator={wanted['emulator']}",
        f"arguments={wanted['arguments']}",
    ])

config_path.write_text("\n".join(out).rstrip() + "\n")
PY
}

# ============================================================
# Mega Drive - BlastEm
# ============================================================

ensure_megadrive_dirs() {
    mkdir -p \
        "${BAREFRONT_ROOT}/testroms/megadrive" \
        "${BAREFRONT_ROOT}/assets/games/megadrive" \
        "${BAREFRONT_ROOT}/assets/videos/megadrive" \
        "${BAREFRONT_ROOT}/saves/megadrive"
}

install_blastem_debian() {
    if command -v blastem >/dev/null 2>&1 || [[ -x /usr/games/blastem ]]; then
        return
    fi

    say "${C_CYAN}Installing BlastEm from Debian repositories...${C_RESET}"
    sudo apt-get update
    sudo apt-get install -y blastem
}

find_blastem() {
    local found=""

    found="$(command -v blastem 2>/dev/null || true)"

    if [[ -z "$found" && -x /usr/games/blastem ]]; then
        found="/usr/games/blastem"
    fi

    if [[ -z "$found" && -x /usr/bin/blastem ]]; then
        found="/usr/bin/blastem"
    fi

    if [[ -z "$found" ]] && command -v dpkg >/dev/null 2>&1; then
        found="$(
            dpkg -L blastem 2>/dev/null |
            awk '/\/blastem$/ { print; exit }'
        )"
    fi

    if [[ -n "$found" && -x "$found" ]]; then
        printf "%s" "$found"
        return 0
    fi

    return 1
}

install_blastem() {
    detect_os

    say
    say "${C_BOLD}Mega Drive - BlastEm${C_RESET}"
    say "Detected OS: ${OS_NAME}"
    say

    case "$OS_ID" in
        debian)
            install_blastem_debian
            ;;
        *)
            say "${C_YELLOW}This build currently automates BlastEm on Debian only.${C_RESET}"
            return 1
            ;;
    esac

    local emulator_path
    emulator_path="$(find_blastem)" ||
        die "BlastEm was installed but its executable could not be located."

    ensure_megadrive_dirs
    backup_config

    write_system_config \
        "megadrive" \
        "testroms/megadrive" \
        "assets/games/megadrive" \
        "$emulator_path" \
        "{rom}"

    say "${C_GREEN}✓${C_RESET} BlastEm executable: ${emulator_path}"
    say "${C_GREEN}✓${C_RESET} Mega Drive folders ready"
    say "${C_GREEN}✓${C_RESET} barefront.ini updated"
    say
    say "${C_GREEN}${C_BOLD}Mega Drive is BareFront-ready.${C_RESET}"
}

# ============================================================
# NES - MesenCE
# ============================================================

ensure_nes_dirs() {
    mkdir -p \
        "${BAREFRONT_ROOT}/testroms/nes" \
        "${BAREFRONT_ROOT}/assets/games/nes" \
        "${BAREFRONT_ROOT}/assets/videos/nes" \
        "${BAREFRONT_ROOT}/saves/nes" \
        "${BAREFRONT_ROOT}/emulators/mesen"
}

install_mesen_dependencies_debian() {
    say "${C_CYAN}Checking MesenCE dependencies...${C_RESET}"
    sudo apt-get update
    sudo apt-get install -y \
        curl \
        ca-certificates \
        unzip \
        libsdl2-2.0-0
}

find_installed_mesen() {
    local candidate="${BAREFRONT_ROOT}/emulators/mesen/Mesen"

    if [[ -x "$candidate" ]]; then
        printf "%s" "$candidate"
        return 0
    fi

    return 1
}

download_mesen_linux_x64() {
    local install_dir="${BAREFRONT_ROOT}/emulators/mesen"
    local temp_dir
    temp_dir="$(mktemp -d)"

    trap 'rm -rf "$temp_dir"' RETURN

    say "${C_CYAN}Finding latest official MesenCE Linux x64 release...${C_RESET}"

    local asset_url
    local asset_name

    read -r asset_url asset_name < <(
        python3 - <<'PY'
import json
import urllib.request

api = "https://api.github.com/repos/nesdev-org/MesenCE/releases/latest"

request = urllib.request.Request(
    api,
    headers={
        "User-Agent": "BareFront-Installer",
        "Accept": "application/vnd.github+json",
    },
)

with urllib.request.urlopen(request, timeout=30) as response:
    release = json.load(response)

assets = release.get("assets", [])

# Prefer the normal native x64 Linux build rather than ARM or AppImage.
preferred = []
fallback = []

for asset in assets:
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    lower = name.lower()

    if not url or "linux" not in lower or not lower.endswith(".zip"):
        continue

    if "arm" in lower:
        continue

    if "ubuntu-22.04" in lower and "clang_aot" in lower:
        preferred.append((url, name))
    elif "x64" in lower and "appimage" not in lower:
        fallback.append((url, name))

choices = preferred or fallback

if not choices:
    raise SystemExit(
        "Could not find a suitable official MesenCE Linux x64 release asset."
    )

url, name = choices[0]
print(url, name.replace(" ", "__SPACE__"))
PY
    )

    asset_name="${asset_name//__SPACE__/ }"

    [[ -n "$asset_url" ]] ||
        die "Could not determine the MesenCE download URL."

    say "Downloading: ${asset_name}"

    curl \
        --fail \
        --location \
        --retry 3 \
        --output "${temp_dir}/mesen.zip" \
        "$asset_url"

    unzip -q \
        "${temp_dir}/mesen.zip" \
        -d "${temp_dir}/mesen"

    local found_binary
    found_binary="$(
        find "${temp_dir}/mesen" \
            -type f \
            \( -name 'Mesen' -o -name 'mesen' \) \
            | head -n 1
    )"

    [[ -n "$found_binary" ]] ||
        die "MesenCE archive downloaded, but the Mesen executable was not found."

    rm -rf "${install_dir:?}/"*
    cp -a "${temp_dir}/mesen/." "$install_dir/"

    local installed_binary="$(
        find "$install_dir" \
            -type f \
            \( -name 'Mesen' -o -name 'mesen' \) \
            | head -n 1
    )"

    [[ -n "$installed_binary" ]] ||
        die "MesenCE was extracted, but its executable could not be located."

    chmod +x "$installed_binary"

    # BareFront expects one stable launcher path even if a future archive
    # changes its internal directory layout.
    if [[ "$installed_binary" != "${install_dir}/Mesen" ]]; then
        ln -sf \
            "$installed_binary" \
            "${install_dir}/Mesen"
    fi
}

install_mesen() {
    detect_os

    say
    say "${C_BOLD}NES - MesenCE${C_RESET}"
    say "Detected OS: ${OS_NAME}"
    say

    case "$OS_ID" in
        debian)
            install_mesen_dependencies_debian
            ;;
        *)
            say "${C_YELLOW}This first MesenCE installer path is tested for Debian.${C_RESET}"
            return 1
            ;;
    esac

    ensure_nes_dirs

    local emulator_path=""

    if emulator_path="$(find_installed_mesen 2>/dev/null)"; then
        say "${C_GREEN}✓${C_RESET} Existing MesenCE found"
    else
        download_mesen_linux_x64
        emulator_path="$(find_installed_mesen)" ||
            die "MesenCE install completed but BareFront could not find it."
    fi

    backup_config

    write_system_config \
        "nes" \
        "testroms/nes" \
        "assets/games/nes" \
        "$emulator_path" \
        "{rom}"

    say "${C_GREEN}✓${C_RESET} MesenCE executable: ${emulator_path}"
    say "${C_GREEN}✓${C_RESET} NES ROM folder: testroms/nes"
    say "${C_GREEN}✓${C_RESET} Screenshot folder: assets/games/nes"
    say "${C_GREEN}✓${C_RESET} Video folder: assets/videos/nes"
    say "${C_GREEN}✓${C_RESET} barefront.ini updated"
    say
    say "${C_GREEN}${C_BOLD}NES is BareFront-ready.${C_RESET}"
}

# ============================================================
# Menu
# ============================================================

show_menu() {
    clear
    say "${C_BOLD}======================================${C_RESET}"
    say "${C_BOLD}     BAREFRONT EMULATOR INSTALLER${C_RESET}"
    say "${C_BOLD}======================================${C_RESET}"
    say
    say "     SYSTEM          EMULATOR"
    say "     --------------  --------------"
    say "  1  Mega Drive      BlastEm"
    say "  2  NES             MesenCE"
    say
    say "  A  Install all currently supported"
    say "  Q  Quit"
    say
}

main() {
    cd "$BAREFRONT_ROOT"

    while true; do
        show_menu
        read -r -p "> " choice

        case "${choice,,}" in
            1)
                install_blastem
                pause
                ;;
            2)
                install_mesen
                pause
                ;;
            a)
                install_blastem
                install_mesen
                pause
                ;;
            q)
                exit 0
                ;;
            *)
                say "${C_YELLOW}Unknown option.${C_RESET}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
