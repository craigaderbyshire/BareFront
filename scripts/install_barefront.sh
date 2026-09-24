#!/bin/bash

# ============================================================
# BareFront Installer
# v0.12
#
# Stage 1: Pre-flight checks
# Stage 2: Common Debian dependencies
# Stage 3A: Debian/package-managed emulators
# Stage 2B: Production BareFront directory structure
# Stage 3B: Locally managed emulators
# Stage 4: Production launcher adapters + barefront.ini
# ============================================================

set -Eeuo pipefail

BAREFRONT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$BAREFRONT_DIR/logs"
LOG_FILE="$LOG_DIR/install.log"

mkdir -p "$LOG_DIR"

# Write terminal output and errors to both the screen and log.
exec > >(tee -a "$LOG_FILE") 2>&1


# ============================================================
# Helper functions
# ============================================================

heading()
{
    echo
    echo "================================================"
    echo "$1"
    echo "================================================"
    echo
}

die()
{
    echo
    echo "ERROR: $1"
    echo
    echo "See:"
    echo "  $LOG_FILE"
    exit 1
}

package_is_installed()
{
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null \
        | grep -q '^install ok installed$'
}

install_debian_emulator()
{
    local display_name="$1"
    local package_name="$2"
    local executable="$3"

    echo
    echo "------------------------------------------------"
    echo "$display_name"
    echo "------------------------------------------------"

    if package_is_installed "$package_name"; then
        echo "Package '$package_name' is already installed."
        echo "  Action: SKIP"
    else
        echo "Installing Debian package:"
        echo "  $package_name"

        if sudo apt-get install -y "$package_name"; then
            echo "Package installation completed."
        else
            echo
            echo "FAILED: Debian could not install '$package_name'."
            return 1
        fi
    fi

    if [[ -x "$executable" ]]; then
        echo "Executable verified:"
        echo "  $executable"
        return 0
    else
        echo
        echo "FAILED: Expected executable was not found:"
        echo "  $executable"
        return 1
    fi
}


# ============================================================
# Opening screen
# ============================================================

clear 2>/dev/null || true

echo
echo "================================================"
echo "                B A R E F R O N T"
echo "================================================"
echo
echo "BareFront Installer v0.12"
echo
echo "BareFront launches."
echo "Emulators emulate."
echo "Gamescope presents."
echo


# ============================================================
# Stage 1 - Pre-flight
# ============================================================

heading "STAGE 1 / PRE-FLIGHT CHECKS"

if [[ ! -f /etc/os-release ]]; then
    die "Cannot identify this Linux distribution."
fi

source /etc/os-release

echo "Operating system:"
echo "  ${PRETTY_NAME:-Unknown}"

if [[ "${ID:-}" != "debian" ]]; then
    die "BareFront v1.0 currently supports Debian only."
fi

if [[ "${VERSION_ID:-}" != "13" ]]; then
    die "BareFront v1.0 currently supports Debian 13 (Trixie)."
fi

echo "  Debian 13 check: OK"

ARCH="$(dpkg --print-architecture)"

echo
echo "Architecture:"
echo "  $ARCH"

if [[ "$ARCH" != "amd64" ]]; then
    die "BareFront v1.0 currently supports amd64/x86-64 only."
fi

echo "  Architecture check: OK"

if [[ "$EUID" -eq 0 ]]; then
    die "Do not run the whole installer with sudo. Run it as your normal user."
fi

echo
echo "User:"
echo "  $USER"
echo "  Normal-user check: OK"

echo
echo "Checking sudo access..."

if ! sudo -v; then
    die "sudo authentication failed."
fi

echo "  sudo check: OK"

# ============================================================
# Stage 2 - Common Debian dependencies
# ============================================================

heading "STAGE 2 / DEBIAN DEPENDENCIES"

echo "Refreshing Debian package catalogue..."
echo
echo "This also acts as our first real network/repository check."
echo

# We deliberately use apt-get update as the network check.
# A fresh Debian installation may not have curl or wget yet,
# but apt-get is guaranteed to be present on our supported target.
if ! sudo apt-get update; then
    die "Debian could not refresh its package catalogue. Check the network connection and repository configuration."
fi

echo
echo "  Network/repository check: OK"

BASE_PACKAGES=(
    build-essential
    pkg-config
    git
    curl
    wget
    ca-certificates
    unzip
    zip
    p7zip-full
    xz-utils
    file
    rsync
    jq
    python3
    pulseaudio-utils
)

BAREFRONT_PACKAGES=(
    libsdl2-dev
    libsdl2-image-dev
    libsdl2-ttf-dev
    libsdl2-mixer-dev
    ffmpeg
)

CAPTURE_PACKAGES=(
    gstreamer1.0-tools
    gstreamer1.0-pipewire
    gstreamer1.0-plugins-base
    gstreamer1.0-plugins-good
    gstreamer1.0-plugins-ugly
)

GRAPHICS_PACKAGES=(
    libgl1-mesa-dev
    libopengl0
    libvulkan1
    mesa-vulkan-drivers
    vulkan-tools
    vkbasalt
    x11-xserver-utils
    libfuse2t64
    libx11-dev
    libxtst-dev
    libxi-dev
    libxfixes-dev
    libxrender-dev
)

ALL_PACKAGES=(
    "${BASE_PACKAGES[@]}"
    "${BAREFRONT_PACKAGES[@]}"
    "${CAPTURE_PACKAGES[@]}"
    "${GRAPHICS_PACKAGES[@]}"
)

echo
echo "Installing/verifying common dependencies..."

sudo apt-get install -y "${ALL_PACKAGES[@]}"

echo
echo "Common dependency stage complete."


# ============================================================
# Stage 2A - Gamescope presentation layer
# ============================================================

heading "STAGE 2A / GAMESCOPE PRESENTATION"

GAMESCOPE_EXE="/usr/games/gamescope"
GAMESCOPE_LAUNCHER="$BAREFRONT_DIR/scripts/launch_barefront_gamescope.sh"
GAMESCOPE_BACKPORTS_SOURCE="/etc/apt/sources.list.d/barefront-backports.sources"

echo "Installing/verifying PipeWire support for Gamescope..."

if package_is_installed "pipewire" && \
   package_is_installed "pipewire-bin"
then
    echo "PipeWire packages are already installed."
    echo "  Action: SKIP"
else
    # BareFront deliberately retains the desktop's existing audio
    # server. pipewire-pulse and a separate session manager are not
    # needed for Gamescope's capture connection.
    if ! sudo apt-get install -y \
        --no-install-recommends \
        pipewire \
        pipewire-bin
    then
        die "Could not install Gamescope's PipeWire support."
    fi
fi

echo
echo "Starting/verifying the PipeWire user service..."

if ! systemctl --user enable --now \
    pipewire.socket \
    pipewire.service
then
    die "Could not enable the PipeWire user service."
fi

if ! systemctl --user is-active --quiet pipewire.service; then
    die "PipeWire user service is not active."
fi

if ! pw-cli info 0 >/dev/null 2>&1; then
    die "PipeWire connection verification failed."
fi

echo "  PipeWire connection: OK"

echo
echo "Installing/verifying Gamescope..."

if package_is_installed "gamescope"; then
    echo "Gamescope is already installed."
    echo "  Action: SKIP"
else
    echo "Gamescope is supplied by Debian 13 backports."
    echo "Creating BareFront-owned repository file:"
    echo "  $GAMESCOPE_BACKPORTS_SOURCE"

    sudo tee "$GAMESCOPE_BACKPORTS_SOURCE" >/dev/null <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    echo
    echo "Refreshing APT after enabling backports..."

    if ! sudo apt-get update; then
        die "APT update failed after enabling Debian backports."
    fi

    if ! sudo apt-get install -y \
        -t trixie-backports \
        gamescope
    then
        die "Could not install Gamescope from Debian backports."
    fi
fi

if [[ ! -x "$GAMESCOPE_EXE" ]]; then
    die "Gamescope executable not found: $GAMESCOPE_EXE"
fi

if [[ ! -f "$GAMESCOPE_LAUNCHER" ]]; then
    die "Tracked Gamescope launcher missing: $GAMESCOPE_LAUNCHER"
fi

chmod +x "$GAMESCOPE_LAUNCHER"

if [[ ! -x "$GAMESCOPE_LAUNCHER" ]]; then
    die "BareFront Gamescope launcher is not executable."
fi

GAMESCOPE_PACKAGE_VERSION="$(
    dpkg-query -W -f='${Version}' gamescope 2>/dev/null || true
)"

echo
echo "Gamescope presentation dependencies verified."
echo "  Executable: $GAMESCOPE_EXE"
echo "  Package version: ${GAMESCOPE_PACKAGE_VERSION:-Unknown}"
echo "  BareFront launcher: $GAMESCOPE_LAUNCHER"
echo "  PipeWire service: active"
echo

# ============================================================
# Stage 2B - Production BareFront directory structure
# ============================================================

heading "STAGE 2B / BAREFRONT DIRECTORIES"

echo "Creating the standard production directory structure."
echo
echo "Official game-library path:"
echo "  $BAREFRONT_DIR/roms"
echo
echo "'testroms' is development-only and is NOT used by the"
echo "production installer."
echo

SYSTEM_KEYS=(
    megadrive
    nes
    snes
    ps1
    ps2
    mastersystem
    atari2600
    c64
    arcade
    neogeo
    dreamcast
    saturn
    pcengine
    jaguar
    gamecube
    amiga
)

# mkdir -p:
#   mkdir = make directory
#   -p    = also make missing parent directories and do not
#           complain if the directory already exists.
mkdir -p \
    "$BAREFRONT_DIR/emulators" \
    "$BAREFRONT_DIR/logs"

for system in "${SYSTEM_KEYS[@]}"; do
    mkdir -p \
        "$BAREFRONT_DIR/roms/$system" \
        "$BAREFRONT_DIR/bios/$system" \
        "$BAREFRONT_DIR/saves/$system" \
        "$BAREFRONT_DIR/assets/games/$system" \
        "$BAREFRONT_DIR/assets/videos/$system"
done

echo "Created/verified:"
echo "  roms/<system>/"
echo "  bios/<system>/"
echo "  saves/<system>/"
echo "  assets/games/<system>/"
echo "  assets/videos/<system>/"
echo
echo "Directory stage complete."


# ============================================================
# Stage 3A - Debian-managed emulators
# ============================================================

heading "STAGE 3A / DEBIAN EMULATORS"

echo "These emulators come directly from Debian 13 packages."
echo
echo "For each emulator BareFront will:"
echo "  1. check whether its Debian package is already installed"
echo "  2. install it only if necessary"
echo "  3. verify the executable exists"
echo

SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_SPECIAL=0


# ------------------------------------------------------------
# Stella - Atari 2600
# ------------------------------------------------------------

if install_debian_emulator \
    "Atari 2600 / Stella" \
    "stella" \
    "/usr/bin/stella"
then
    ((SUCCESS_COUNT+=1))
else
    ((FAILED_COUNT+=1))
fi

STELLA_BASE_DIR="$BAREFRONT_DIR/saves/atari2600/stella"
STELLA_CONFIG="$STELLA_BASE_DIR/stella.sqlite3"
STELLA_LAUNCHER="$BAREFRONT_DIR/scripts/launch_stella.sh"
STELLA_OVERLAY="$BAREFRONT_DIR/assets/overlays/atari2600.png"

mkdir -p "$STELLA_BASE_DIR"

echo
echo "Creating/verifying BareFront Stella baseline..."

if [[ -f "$STELLA_CONFIG" ]]; then

    echo "Existing Stella configuration found."
    echo "BareFront will not overwrite it:"
    echo "  $STELLA_CONFIG"
    echo "Action: PRESERVE USER CONFIG"

else

    python3 - "$STELLA_CONFIG" <<'PYSTELLA'
import sqlite3
import sys
from pathlib import Path

db = Path(sys.argv[1])

con = sqlite3.connect(db)
con.execute(
    "CREATE TABLE settings "
    "(setting TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID"
)
con.execute(
    "INSERT INTO settings(setting, value) VALUES (?, ?)",
    ("stella.version", "7.0")
)
con.commit()
con.close()
PYSTELLA

    echo "BareFront Stella baseline created:"
    echo "  $STELLA_CONFIG"
    echo
    echo "  What's New popup: suppressed"
    echo "  Save states: $STELLA_BASE_DIR/state"
    echo "  Action: CREATE BASELINE"

fi


if [[ ! -f "$STELLA_LAUNCHER" ]]; then
    die "Tracked Atari 2600 launcher missing: $STELLA_LAUNCHER"
fi

chmod +x "$STELLA_LAUNCHER"

if [[ ! -x "$STELLA_LAUNCHER" ]]; then
    die "Atari 2600 launcher is not executable: $STELLA_LAUNCHER"
fi

if [[ ! -s "$STELLA_OVERLAY" ]]; then
    die "Atari 2600 overlay is missing: $STELLA_OVERLAY"
fi


# ------------------------------------------------------------
# Mednafen - Mega Drive + Saturn + PC Engine
# One emulator package services three BareFront systems.
# ------------------------------------------------------------

if install_debian_emulator \
    "Mega Drive + Saturn + PC Engine / Mednafen" \
    "mednafen" \
    "/usr/games/mednafen"
then
    ((SUCCESS_COUNT+=1))
else
    ((FAILED_COUNT+=1))
fi


# ------------------------------------------------------------
# MAME - Arcade + Neo Geo
# One emulator package services two BareFront systems.
# ------------------------------------------------------------

if install_debian_emulator \
    "Arcade + Neo Geo / MAME" \
    "mame" \
    "/usr/games/mame"
then
    ((SUCCESS_COUNT+=1))
else
    ((FAILED_COUNT+=1))
fi


# ------------------------------------------------------------
# Dolphin - GameCube
# ------------------------------------------------------------

if install_debian_emulator \
    "GameCube / Dolphin" \
    "dolphin-emu" \
    "/usr/games/dolphin-emu"
then
    ((SUCCESS_COUNT+=1))
else
    ((FAILED_COUNT+=1))
fi


# ============================================================
# VICE special case
#
# Debian 13 places VICE in the "contrib" component.
#
# Rather than modifying the user's existing Debian repository
# file, BareFront can create its own small supplemental source:
#
#   /etc/apt/sources.list.d/barefront-contrib.sources
#
# This is easy to identify and easy to reverse later.
# ============================================================

enable_barefront_contrib()
{
    local source_file="/etc/apt/sources.list.d/barefront-contrib.sources"

    echo
    echo "VICE needs Debian's 'contrib' repository component."
    echo
    echo "BareFront can enable contrib by creating:"
    echo "  $source_file"
    echo
    echo "Your existing Debian source files will NOT be edited."
    echo
    echo "To reverse this later you can remove that one file and run:"
    echo "  sudo apt-get update"
    echo

    read -r -p "Enable Debian contrib for BareFront? [Y/n] " reply
    reply="${reply:-Y}"

    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "User chose not to enable contrib."
        return 1
    fi

    # tee reads text from standard input and writes it to a file.
    # sudo is attached to tee because /etc/apt belongs to root.
    sudo tee "$source_file" >/dev/null <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    echo
    echo "Created:"
    echo "  $source_file"
    echo
    echo "Refreshing APT after enabling contrib..."

    if ! sudo apt-get update; then
        echo "APT update failed after enabling contrib."
        return 1
    fi

    return 0
}


echo
echo "------------------------------------------------"
echo "Commodore 64 / VICE"
echo "------------------------------------------------"

if package_is_installed "vice"; then

    echo "VICE is already installed."
    echo "  Action: SKIP"

    if [[ -x /usr/bin/x64sc ]]; then
        echo "Executable verified:"
        echo "  /usr/bin/x64sc"
        ((SUCCESS_COUNT+=1))
    else
        echo "FAILED: VICE package exists but /usr/bin/x64sc is missing."
        ((FAILED_COUNT+=1))
    fi

else

    # apt-cache policy asks APT which version it would install.
    # Candidate: (none) means none of the configured repositories
    # currently provides the package.
    VICE_CANDIDATE="$(
        apt-cache policy vice 2>/dev/null \
        | awk '/Candidate:/ {print $2}'
    )"

    if [[ -z "$VICE_CANDIDATE" || "$VICE_CANDIDATE" == "(none)" ]]; then

        echo "VICE is not currently visible to APT."

        if enable_barefront_contrib; then

            # Ask APT again now that contrib has been added.
            VICE_CANDIDATE="$(
                apt-cache policy vice 2>/dev/null \
                | awk '/Candidate:/ {print $2}'
            )"

        else
            VICE_CANDIDATE="(none)"
        fi
    fi

    if [[ -n "$VICE_CANDIDATE" && "$VICE_CANDIDATE" != "(none)" ]]; then

        echo
        echo "VICE is available."
        echo "Candidate version:"
        echo "  $VICE_CANDIDATE"

        if sudo apt-get install -y vice; then

            if [[ -x /usr/bin/x64sc ]]; then
                echo "VICE installed and verified:"
                echo "  /usr/bin/x64sc"
                ((SUCCESS_COUNT+=1))
            else
                echo "FAILED: VICE installed but x64sc was not found."
                ((FAILED_COUNT+=1))
            fi

        else
            echo "FAILED: APT could see VICE but installation failed."
            ((FAILED_COUNT+=1))
        fi

    else
        echo
        echo "VICE was not installed."
        echo "BareFront can continue, but Commodore 64 support"
        echo "will remain incomplete until contrib/VICE is available."
        ((SKIPPED_SPECIAL+=1))
    fi
fi


# ============================================================
# Stage 3A summary
# ============================================================

heading "STAGE 3A SUMMARY"

echo "Debian emulator packages:"
echo
echo "  Successful / verified : $SUCCESS_COUNT"
echo "  Failed                : $FAILED_COUNT"
echo "  Deferred special case : $SKIPPED_SPECIAL"
echo

echo "Expected executable paths:"
echo
echo "  Stella    /usr/bin/stella"
echo "  Mednafen  /usr/games/mednafen"
echo "  MAME      /usr/games/mame"
echo "  VICE      /usr/bin/x64sc"
echo "  Dolphin   /usr/games/dolphin-emu"
echo

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    echo "One or more package-managed emulator installs failed."
    echo "Review:"
    echo "  $LOG_FILE"
    exit 1
fi

if [[ "$SKIPPED_SPECIAL" -gt 0 ]]; then
    echo "Stage 3A completed with one expected special case."
    echo "VICE remains incomplete because contrib was not enabled or available."
else
    echo "Stage 3A completed successfully."
fi

echo
echo "Nothing in Stage 3A installs ROMs or copyrighted BIOS files."
echo


# ============================================================
# Stage 3B - Mega Drive
# Mednafen
# ============================================================

heading "STAGE 3B / MEGA DRIVE / MEDNAFEN"

MEDNAFEN_MD_EXE="/usr/games/mednafen"
MEDNAFEN_MD_LOCAL_DIR="$BAREFRONT_DIR/emulators/mednafen"
MEDNAFEN_MD_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mednafen_md.sh"
MEDNAFEN_MD_PROFILE="$BAREFRONT_DIR/saves/megadrive/mednafen"
MEDNAFEN_MD_CONFIG="$MEDNAFEN_MD_PROFILE/mednafen.cfg"

BAREFRONT_AUDIO_HELPER="$BAREFRONT_DIR/scripts/barefront_audio.sh"

MEDNAFEN_MD_BARECRT_DIR="$BAREFRONT_DIR/assets/shaders/barecrt"
MEDNAFEN_MD_BARECRT_SHADER="$MEDNAFEN_MD_BARECRT_DIR/BareCRT_v2.fx"
MEDNAFEN_MD_RESHADE_INCLUDE="$MEDNAFEN_MD_BARECRT_DIR/ReShade.fxh"
MEDNAFEN_MD_OVERLAY="$BAREFRONT_DIR/assets/overlays/megadrive.png"

VKBASALT_LAYER="/usr/share/vulkan/implicit_layer.d/vkBasalt.json"

echo "Configuring BareFront Mega Drive integration..."
echo

if [[ ! -x "$MEDNAFEN_MD_EXE" ]]; then
    die "Mednafen executable not found: $MEDNAFEN_MD_EXE"
fi

if [[ ! -f "$MEDNAFEN_MD_LAUNCHER" ]]; then
    die "Tracked Mega Drive launcher missing: $MEDNAFEN_MD_LAUNCHER"
fi

chmod +x "$MEDNAFEN_MD_LAUNCHER"

if [[ ! -x "$MEDNAFEN_MD_LAUNCHER" ]]; then
    die "Mega Drive launcher is not executable."
fi

if [[ ! -f "$BAREFRONT_AUDIO_HELPER" ]]; then
    die "BareFront shared audio helper is missing: $BAREFRONT_AUDIO_HELPER"
fi

if ! bash -n "$BAREFRONT_AUDIO_HELPER"; then
    die "BareFront shared audio helper failed syntax validation."
fi

echo "BareFront shared audio helper: OK"

if ! command -v pactl >/dev/null 2>&1; then
    die "Mega Drive direct-HDMI audio requires pactl."
fi

if ! command -v pasuspender >/dev/null 2>&1; then
    die "Mega Drive direct-HDMI audio requires pasuspender."
fi

if [[ ! -x "$GAMESCOPE_EXE" ]]; then
    die "Mega Drive presentation requires Gamescope: $GAMESCOPE_EXE"
fi

if [[ ! -f "$VKBASALT_LAYER" ]]; then
    die "vkBasalt Vulkan layer is missing: $VKBASALT_LAYER"
fi

if [[ ! -s "$MEDNAFEN_MD_BARECRT_SHADER" ]]; then
    die "BareCRT shader is missing: $MEDNAFEN_MD_BARECRT_SHADER"
fi

if [[ ! -s "$MEDNAFEN_MD_RESHADE_INCLUDE" ]]; then
    die "BareCRT ReShade include is missing: $MEDNAFEN_MD_RESHADE_INCLUDE"
fi

if [[ ! -s "$MEDNAFEN_MD_OVERLAY" ]]; then
    die "Mega Drive overlay artwork is missing: $MEDNAFEN_MD_OVERLAY"
fi

mkdir -p \
    "$MEDNAFEN_MD_LOCAL_DIR" \
    "$MEDNAFEN_MD_PROFILE" \
    "$BAREFRONT_DIR/roms/megadrive" \
    "$BAREFRONT_DIR/saves/megadrive" \
    "$BAREFRONT_DIR/assets/games/megadrive" \
    "$BAREFRONT_DIR/assets/videos/megadrive"

if [[ ! -f "$MEDNAFEN_MD_CONFIG" ]]; then
    echo "Creating isolated Mednafen Mega Drive profile..."

    MEDNAFEN_HOME="$MEDNAFEN_MD_PROFILE" \
        "$MEDNAFEN_MD_EXE" -help \
        > "$LOG_DIR/mednafen-megadrive-profile.log" \
        2>&1 || true

    echo "  Action: CREATE"
else
    echo "Isolated Mednafen Mega Drive profile already exists."
    echo "  Action: PRESERVE"
fi

if [[ ! -f "$MEDNAFEN_MD_CONFIG" ]]; then
    die "Mednafen did not create the Mega Drive profile."
fi

MEDNAFEN_MD_CONFIG_PATH="$MEDNAFEN_MD_CONFIG" python3 - <<'PYMEDNAFEN_MD'
import os
from pathlib import Path

path = Path(os.environ["MEDNAFEN_MD_CONFIG_PATH"])
original = path.read_text()
lines = original.splitlines()

enforced = {
    "command.exit": "keyboard 0x0 41",
    "md.correct_aspect": "0",
    "md.scanlines": "0",
    "md.shader": "none",
    "md.stretch": "0",
    "md.videoip": "0",
    "md.xscale": "1.000000",
    "md.yscale": "1.000000",
}

seen = set()

for index, line in enumerate(lines):
    parts = line.split(None, 1)

    if not parts:
        continue

    key = parts[0]

    if key in enforced:
        lines[index] = f"{key} {enforced[key]}"
        seen.add(key)

for key, value in enforced.items():
    if key not in seen:
        lines.append(f"{key} {value}")

updated = "\n".join(lines) + "\n"

if updated != original:
    path.write_text(updated)

resolved = {}

for line in lines:
    parts = line.split(None, 1)

    if len(parts) == 2:
        resolved[parts[0]] = parts[1].strip()

for key, value in enforced.items():
    if resolved.get(key) != value:
        raise SystemExit(
            f"Could not enforce Mega Drive Mednafen setting: {key}"
        )

print("  Raw 1x video profile: OK")
print("  Esc exit binding: OK")
PYMEDNAFEN_MD

MEDNAFEN_MD_PACKAGE_VERSION="$(
    dpkg-query -W -f='${Version}' mednafen 2>/dev/null || true
)"

cat > "$MEDNAFEN_MD_LOCAL_DIR/MEGADRIVE_VERSION.txt" <<EOF
BareFront managed emulator integration
System: Mega Drive / Genesis
Emulator: Mednafen
Package version: ${MEDNAFEN_MD_PACKAGE_VERSION:-Unknown}
Executable: $MEDNAFEN_MD_EXE
BareFront launcher: $MEDNAFEN_MD_LAUNCHER
BareFront profile: $MEDNAFEN_MD_PROFILE
Presentation: Gamescope integer scaling + external BareCRT
EOF

echo
echo "Mega Drive integration:"
echo "  Emulator: Mednafen"
echo "  Raw H40:  320x224"
echo "  Raw H32:  256x224 within the 320x224 presentation surface"
echo "  Gamescope output: 1280x896"
echo "  Audio: BareFront-selected HDMI -> direct ALSA / 48 kHz / 20 ms"
echo "  Esc: direct return to BareFront"
echo
echo "Mega Drive stage complete."


# ============================================================
# Stage 3B - Locally managed emulators
# Mesen Community Edition
# ============================================================

heading "STAGE 3B / MESEN"

MESEN_DIR="$BAREFRONT_DIR/emulators/mesen"
MESEN_EXE="$MESEN_DIR/Mesen"
MESEN_NES_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mesen_nes.sh"
MESEN_SMS_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mesen_sms.sh"
MESEN_SMS_OVERLAY="$BAREFRONT_DIR/assets/overlays/mastersystem.png"
MESEN_MENU_NUDGE_SOURCE="$BAREFRONT_DIR/src/mesen_menu_nudge_helper.cpp"
MESEN_MENU_NUDGE_HELPER="$MESEN_DIR/mesen_menu_nudge_helper"
MESEN_GUIDE_EXIT_SOURCE="$BAREFRONT_DIR/src/mesen_guide_exit_helper.cpp"
MESEN_GUIDE_EXIT_HELPER="$MESEN_DIR/mesen_guide_exit_helper"

# BareFront-tested MesenCE release.
MESEN_VERSION="2.2.1"
MESEN_CONFIG_UPGRADE="5"
MESEN_ASSET_NAME_EXPECTED="Mesen_2.2.1_Linux_x64.zip"
MESEN_EXPECTED_SHA256="c88ff4d251b407515c43d3332d641927655cd69fb538996b6a21da4509dbb58f"

MESEN_API="https://api.github.com/repos/nesdev-org/MesenCE/releases/tags/$MESEN_VERSION"

MESEN_CONFIG_DIR="$HOME/.config/MesenCE"
MESEN_CONFIG="$MESEN_CONFIG_DIR/settings.json"
MESEN_SAVE_DIR="$BAREFRONT_DIR/saves/mesen"

echo "BareFront uses Mesen for:"
echo "  NES"
echo "  Master System"
echo
echo "Install location:"
echo "  $MESEN_DIR"
echo

MESEN_INSTALLED_RELEASE="$(
    sed -n 's/^Release: //p' "$MESEN_DIR/VERSION.txt" 2>/dev/null         | head -1 || true
)"

if [[ -x "$MESEN_EXE" &&
      "$MESEN_INSTALLED_RELEASE" == "$MESEN_VERSION" ]]; then

    echo "Pinned MesenCE release is already installed."
    echo "Release:"
    echo "  $MESEN_INSTALLED_RELEASE"
    echo "Executable:"
    echo "  $MESEN_EXE"
    echo "Action: SKIP"

else

    if [[ -x "$MESEN_EXE" ]]; then
        echo "Existing Mesen installation is not the BareFront-pinned release."
        echo "Action: INSTALL PINNED RELEASE"
        echo
    fi

    mkdir -p "$MESEN_DIR"

    echo "Requesting BareFront-pinned MesenCE release from GitHub..."
    echo

    # curl:
    #   -f = fail if the web server returns an HTTP error
    #   -s = silent progress meter
    #   -S = still show an error if something fails
    #   -L = follow redirects
    #
    # BareFront requests the exact tested release tag rather than
    # following MesenCE's latest release automatically.
    if ! MESEN_RELEASE_JSON="$(curl -fsSL "$MESEN_API")"; then
        die "Could not retrieve the latest stable MesenCE release information."
    fi

    MESEN_RELEASE_TAG="$(
        printf '%s' "$MESEN_RELEASE_JSON" \
        | jq -r '.tag_name // empty'
    )"

    if [[ "$MESEN_RELEASE_TAG" != "$MESEN_VERSION" ]]; then
        die "GitHub did not return the pinned MesenCE release."
    fi

    echo "Pinned stable release:"
    echo "  $MESEN_VERSION"
    echo

    # --------------------------------------------------------
    # Select the exact BareFront-tested Linux x64 archive.
    # --------------------------------------------------------

    MESEN_ASSET_JSON="$(
        printf '%s' "$MESEN_RELEASE_JSON" \
        | jq -c --arg asset "$MESEN_ASSET_NAME_EXPECTED" '
            [
              .assets[]
              | select(.name == $asset)
            ][0] // empty
          '
    )"

    if [[ -z "$MESEN_ASSET_JSON" ]]; then
        die "Could not find the BareFront-tested MesenCE Linux x64 archive."
    fi

    MESEN_ASSET_NAME="$(
        printf '%s' "$MESEN_ASSET_JSON" \
        | jq -r '.name'
    )"

    MESEN_DOWNLOAD_URL="$(
        printf '%s' "$MESEN_ASSET_JSON" \
        | jq -r '.browser_download_url'
    )"

    MESEN_DIGEST="$(
        printf '%s' "$MESEN_ASSET_JSON" \
        | jq -r '.digest // empty'
    )"

    echo
    echo "Selected release asset:"
    echo "  $MESEN_ASSET_NAME"

    if [[ "$MESEN_ASSET_NAME" != "$MESEN_ASSET_NAME_EXPECTED" ]]; then
        die "GitHub did not return the expected BareFront-tested MesenCE asset."
    fi

    TEMP_DIR="$(mktemp -d)"
    TEMP_DOWNLOAD="$TEMP_DIR/mesen-download"

    echo
    echo "Downloading..."

    if ! curl -fL --progress-bar \
        "$MESEN_DOWNLOAD_URL" \
        -o "$TEMP_DOWNLOAD"
    then
        rm -rf "$TEMP_DIR"
        die "MesenCE download failed."
    fi

    # --------------------------------------------------------
    # BareFront pinned SHA-256 verification.
    #
    # This is the exact Linux x64 archive accepted during
    # BareFront integration testing.
    # --------------------------------------------------------

    ACTUAL_PINNED_SHA256="$(sha256sum "$TEMP_DOWNLOAD" | awk '{print $1}')"

    echo
    echo "Checking BareFront pinned SHA-256..."

    if [[ "$ACTUAL_PINNED_SHA256" != "$MESEN_EXPECTED_SHA256" ]]; then
        rm -rf "$TEMP_DIR"
        die "MesenCE does not match the BareFront-tested SHA-256."
    fi

    echo "  SHA-256: OK"

    # --------------------------------------------------------
    # Verify SHA-256 when GitHub publishes one for the asset.
    # --------------------------------------------------------

    if [[ "$MESEN_DIGEST" == sha256:* ]]; then

        EXPECTED_SHA256="${MESEN_DIGEST#sha256:}"
        ACTUAL_SHA256="$(sha256sum "$TEMP_DOWNLOAD" | awk '{print $1}')"

        echo
        echo "Checking download SHA-256..."

        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            rm -rf "$TEMP_DIR"
            die "MesenCE SHA-256 verification failed."
        fi

        echo "  SHA-256: OK"

    else

        echo
        echo "GitHub did not publish an asset SHA-256 digest."
        echo "Download came directly from the official MesenCE release."
    fi

    # --------------------------------------------------------
    # Work out what kind of file GitHub gave us.
    #
    # `file` examines the CONTENTS of a file rather than trusting
    # its filename extension.
    # --------------------------------------------------------

    DOWNLOAD_TYPE="$(file -b "$TEMP_DOWNLOAD")"

    echo
    echo "Downloaded file type:"
    echo "  $DOWNLOAD_TYPE"

    EXTRACT_DIR="$TEMP_DIR/extracted"
    mkdir -p "$EXTRACT_DIR"

    if grep -qi "Zip archive" <<< "$DOWNLOAD_TYPE"; then

        echo "Extracting ZIP archive..."
        unzip -q "$TEMP_DOWNLOAD" -d "$EXTRACT_DIR"

        FOUND_MESEN="$(
            find "$EXTRACT_DIR" \
                -type f \
                -name 'Mesen' \
                -print \
                -quit
        )"

        if [[ -z "$FOUND_MESEN" ]]; then
            rm -rf "$TEMP_DIR"
            die "Mesen executable was not found inside the downloaded ZIP."
        fi

        cp "$FOUND_MESEN" "$MESEN_EXE"

    elif grep -qiE "ELF .* executable|AppImage|executable" <<< "$DOWNLOAD_TYPE"; then

        echo "Downloaded asset is directly executable."
        cp "$TEMP_DOWNLOAD" "$MESEN_EXE"

    else

        echo
        echo "Unexpected download format:"
        echo "  $DOWNLOAD_TYPE"
        rm -rf "$TEMP_DIR"
        die "BareFront does not yet know how to unpack this MesenCE release asset."
    fi

    chmod +x "$MESEN_EXE"

    # Keep a small human-readable record of what BareFront installed.
    cat > "$MESEN_DIR/VERSION.txt" <<EOF
BareFront managed emulator
Emulator: Mesen Community Edition
Release: $MESEN_VERSION
Source: https://github.com/nesdev-org/MesenCE
Asset: $MESEN_ASSET_NAME
EOF

    rm -rf "$TEMP_DIR"

    echo
    echo "Mesen installed."
fi


# ------------------------------------------------------------
# Final Mesen verification
# ------------------------------------------------------------

echo
echo "Verifying Mesen..."

if [[ -x "$MESEN_EXE" ]]; then
    echo "  Executable: OK"
    echo "  $MESEN_EXE"
else
    die "Mesen installation verification failed."
fi

if [[ -f "$MESEN_DIR/VERSION.txt" ]]; then
    echo
    echo "BareFront install record:"
    sed 's/^/  /' "$MESEN_DIR/VERSION.txt"
fi

if [[ ! -x "$MESEN_NES_LAUNCHER" ]]; then
    die "Mesen NES BareFront wrapper is missing or not executable."
fi

if [[ ! -x "$MESEN_SMS_LAUNCHER" ]]; then
    die "Mesen Master System BareFront wrapper is missing or not executable."
fi

if [[ ! -s "$MESEN_SMS_OVERLAY" ]]; then
    die "Master System overlay artwork is missing: $MESEN_SMS_OVERLAY"
fi

if [[ ! -f "$MESEN_MENU_NUDGE_SOURCE" ]]; then
    die "Mesen menu nudge helper source is missing."
fi

if [[ ! -x "$MESEN_MENU_NUDGE_HELPER" ]] || \
   [[ "$MESEN_MENU_NUDGE_SOURCE" -nt "$MESEN_MENU_NUDGE_HELPER" ]]
then
    echo
    echo "Building Mesen menu nudge helper..."

    g++ -std=c++17 -O2 \
        "$MESEN_MENU_NUDGE_SOURCE" \
        -o "$MESEN_MENU_NUDGE_HELPER" \
        -lX11

    echo "Action: BUILD"
else
    echo
    echo "Mesen menu nudge helper is already current."
    echo "Action: SKIP"
fi

if [[ ! -x "$MESEN_MENU_NUDGE_HELPER" ]]; then
    die "Mesen menu nudge helper build failed."
fi

if [[ ! -f "$MESEN_GUIDE_EXIT_SOURCE" ]]; then
    die "Mesen Guide exit helper source is missing."
fi

if [[ ! -x "$MESEN_GUIDE_EXIT_HELPER" ]] || \
   [[ "$MESEN_GUIDE_EXIT_SOURCE" -nt "$MESEN_GUIDE_EXIT_HELPER" ]]
then
    echo
    echo "Building Mesen Guide exit helper..."

    g++ -std=c++17 -O2 \
        "$MESEN_GUIDE_EXIT_SOURCE" \
        -o "$MESEN_GUIDE_EXIT_HELPER" \
        $(sdl2-config --cflags --libs) \
        -lX11 -lXtst

    echo "Action: BUILD"
else
    echo
    echo "Mesen Guide exit helper is already current."
    echo "Action: SKIP"
fi

if [[ ! -x "$MESEN_GUIDE_EXIT_HELPER" ]]; then
    die "Mesen Guide exit helper build failed."
fi

echo
echo "Creating/verifying BareFront MesenCE baseline..."

mkdir -p "$MESEN_SAVE_DIR"

if [[ -f "$MESEN_CONFIG" ]]; then

    echo "Existing MesenCE user configuration found."
    echo "Preserving emulator-owned settings:"
    echo "  $MESEN_CONFIG"
    echo
    echo "Enforcing BareFront-owned integration:"
    echo "  Esc = exit directly to BareFront"
    echo "  Emulator screenshot hotkey = unassigned"

    python3 - "$MESEN_CONFIG" <<'PYMESENPRESERVE'
import json
import sys
from pathlib import Path

config = Path(sys.argv[1])

with config.open("r", encoding="utf-8-sig") as f:
    data = json.load(f)

preferences = data.setdefault("Preferences", {})
preferences["AutoHideMenu"] = True
shortcuts = preferences.setdefault("ShortcutKeys", [])

def set_shortcut(name, key1):
    for item in shortcuts:
        if item.get("Shortcut") == name:
            item["KeyCombination"] = {
                "Key1": key1,
                "Key2": 0,
                "Key3": 0,
            }
            item["KeyCombination2"] = {
                "Key1": 0,
                "Key2": 0,
                "Key3": 0,
            }
            return

    shortcuts.append({
        "Shortcut": name,
        "KeyCombination": {
            "Key1": key1,
            "Key2": 0,
            "Key3": 0,
        },
        "KeyCombination2": {
            "Key1": 0,
            "Key2": 0,
            "Key3": 0,
        },
    })

set_shortcut("Exit", 13)
set_shortcut("Pause", 0)
set_shortcut("TakeScreenshot", 0)

# --------------------------------------------------------
# BareFront Xbox-compatible controller baseline
#
# MesenCE stores controller inputs as numeric host-key codes.
# These values were generated by MesenCE 2.2.1 itself using
# an Xbox Series controller.
#
# Only seed Port 1 when ALL normal gameplay controls are
# unassigned. Any existing/user-customised mapping is left
# completely untouched.
# --------------------------------------------------------

def seed_xbox_port(system_name, controller_type, mapping):
    system = data.setdefault(system_name, {})
    port = system.setdefault("Port1", {})
    current = port.setdefault("Mapping1", {})

    gameplay_keys = (
        "A", "B",
        "Up", "Down", "Left", "Right",
        "Start", "Select",
    )

    if all((current.get(key, 0) or 0) == 0 for key in gameplay_keys):
        port["Type"] = controller_type

        for key, value in mapping.items():
            current[key] = value


seed_xbox_port(
    "Nes",
    "NesController",
    {
        "A": 4096,
        "B": 4097,
        "Up": 4125,
        "Down": 4124,
        "Left": 4123,
        "Right": 4122,
        "Start": 4107,
        "Select": 4106,
    },
)

seed_xbox_port(
    "Sms",
    "SmsController",
    {
        "A": 4097,
        "B": 4096,
        "Up": 4125,
        "Down": 4124,
        "Left": 4123,
        "Right": 4122,
        "Start": 4107,
        "Select": 0,
    },
)

with config.open("w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYMESENPRESERVE

    echo "Action: REPAIR BAREFRONT INTEGRATION"

else

    mkdir -p "$MESEN_CONFIG_DIR"

    python3 - "$MESEN_CONFIG" "$MESEN_SAVE_DIR" "$MESEN_VERSION" "$MESEN_CONFIG_UPGRADE" <<'PYMESEN'
import json
import sys
from pathlib import Path

config = Path(sys.argv[1])
save_dir = sys.argv[2]
version = sys.argv[3]
config_upgrade = int(sys.argv[4])

data = {
    "Version": version,
    "ConfigUpgrade": config_upgrade,
    "Preferences": {
        "AutomaticallyCheckForUpdates": False,
        "AutoHideMenu": True,

        "OverrideSaveDataFolder": True,
        "SaveDataFolder": save_dir,

        "OverrideSaveStateFolder": True,
        "SaveStateFolder": save_dir,

        "ShortcutKeys": [
            {
                "Shortcut": "TakeScreenshot",
                "KeyCombination": {
                    "Key1": 0,
                    "Key2": 0,
                    "Key3": 0
                },
                "KeyCombination2": {
                    "Key1": 0,
                    "Key2": 0,
                    "Key3": 0
                }
            },
            {
                "Shortcut": "Exit",
                "KeyCombination": {
                    "Key1": 13,
                    "Key2": 0,
                    "Key3": 0
                },
                "KeyCombination2": {
                    "Key1": 0,
                    "Key2": 0,
                    "Key3": 0
                }
            },
            {
                "Shortcut": "Pause",
                "KeyCombination": {
                    "Key1": 0,
                    "Key2": 0,
                    "Key3": 0
                },
                "KeyCombination2": {
                    "Key1": 0,
                    "Key2": 0,
                    "Key3": 0
                }
            }
        ]
    }
}

# --------------------------------------------------------
# BareFront Xbox-compatible controller baseline
#
# MesenCE stores controller inputs as numeric host-key codes.
# These values were generated by MesenCE 2.2.1 itself using
# an Xbox Series controller.
#
# Only seed Port 1 when ALL normal gameplay controls are
# unassigned. Any existing/user-customised mapping is left
# completely untouched.
# --------------------------------------------------------

def seed_xbox_port(system_name, controller_type, mapping):
    system = data.setdefault(system_name, {})
    port = system.setdefault("Port1", {})
    current = port.setdefault("Mapping1", {})

    gameplay_keys = (
        "A", "B",
        "Up", "Down", "Left", "Right",
        "Start", "Select",
    )

    if all((current.get(key, 0) or 0) == 0 for key in gameplay_keys):
        port["Type"] = controller_type

        for key, value in mapping.items():
            current[key] = value


seed_xbox_port(
    "Nes",
    "NesController",
    {
        "A": 4096,
        "B": 4097,
        "Up": 4125,
        "Down": 4124,
        "Left": 4123,
        "Right": 4122,
        "Start": 4107,
        "Select": 4106,
    },
)

seed_xbox_port(
    "Sms",
    "SmsController",
    {
        "A": 4097,
        "B": 4096,
        "Up": 4125,
        "Down": 4124,
        "Left": 4123,
        "Right": 4122,
        "Start": 4107,
        "Select": 0,
    },
)

config.write_text(
    json.dumps(data, indent=2),
    encoding="utf-8-sig"
)
PYMESEN

    echo "BareFront MesenCE baseline created:"
    echo "  $MESEN_CONFIG"
    echo
    echo "  First-run wizard: suppressed"
    echo "  Automatic updates: OFF"
    echo "  Esc: exit to BareFront"
    echo "  Mesen screenshot hotkey: unassigned"
    echo "  Save directory: $MESEN_SAVE_DIR"
    echo "  Action: CREATE BASELINE"

fi

echo
echo "Mesen stage complete."


# ============================================================
# Stage 3B - Locally managed emulators
# Part 2: DuckStation
# ============================================================

heading "STAGE 3B / DUCKSTATION"

DUCKSTATION_DIR="$BAREFRONT_DIR/emulators/duckstation"
DUCKSTATION_EXE="$DUCKSTATION_DIR/DuckStation.AppImage"
DUCKSTATION_SETTINGS="$DUCKSTATION_DIR/settings.ini"
DUCKSTATION_GAMESCOPE="/usr/games/gamescope"
DUCKSTATION_WRAPPER="$BAREFRONT_DIR/scripts/launch_duckstation.sh"
DUCKSTATION_OVERLAY="$BAREFRONT_DIR/assets/overlays/ps1.png"

# BareFront deliberately pins DuckStation to a known-good build.
#
# Do NOT change this to GitHub's moving "latest" tag.
# Emulator updates must be tested before BareFront adopts them.
DUCKSTATION_VERSION="v0.1-11752"
DUCKSTATION_ASSET_NAME="DuckStation-x64.AppImage"
DUCKSTATION_DOWNLOAD_URL="https://github.com/stenzek/duckstation/releases/download/$DUCKSTATION_VERSION/$DUCKSTATION_ASSET_NAME"
DUCKSTATION_SHA256="169a7dd2c37731780eb3729cbe16f048fff3e3b6ef9c9f499869dc1174899a54"

echo "BareFront uses DuckStation for:"
echo "  PlayStation"
echo
echo "Pinned version:"
echo "  $DUCKSTATION_VERSION"
echo
echo "Install location:"
echo "  $DUCKSTATION_DIR"
echo

mkdir -p "$DUCKSTATION_DIR"

if [[ ! -x "$DUCKSTATION_GAMESCOPE" ]]; then
    die "Gamescope executable not found: $DUCKSTATION_GAMESCOPE"
fi

if [[ ! -x "$DUCKSTATION_WRAPPER" ]]; then
    die "DuckStation BareFront wrapper is missing or not executable."
fi

if [[ ! -s "$DUCKSTATION_OVERLAY" ]]; then
    die "Tracked PlayStation overlay missing: $DUCKSTATION_OVERLAY"
fi

# ------------------------------------------------------------
# Install / verify the pinned DuckStation build
# ------------------------------------------------------------

NEED_DUCKSTATION_INSTALL=1

if [[ -f "$DUCKSTATION_EXE" ]]; then

    ACTUAL_SHA256="$(sha256sum "$DUCKSTATION_EXE" | awk '{print $1}')"

    if [[ "$ACTUAL_SHA256" == "$DUCKSTATION_SHA256" ]]; then

        echo "DuckStation already matches BareFront's pinned build."
        echo "  SHA-256: OK"

        chmod +x "$DUCKSTATION_EXE"
        NEED_DUCKSTATION_INSTALL=0

    else

        echo "Existing DuckStation does not match the pinned build."
        echo "Existing SHA-256:"
        echo "  $ACTUAL_SHA256"
        echo "Expected SHA-256:"
        echo "  $DUCKSTATION_SHA256"
        echo

        # BareFront may replace a binary which it previously installed,
        # but must never silently overwrite an unmanaged/user-supplied one.
        if [[ -f "$DUCKSTATION_DIR/VERSION.txt" ]] &&
           grep -q '^BareFront managed emulator$' "$DUCKSTATION_DIR/VERSION.txt"
        then
            echo "Existing DuckStation is BareFront-managed."
            echo "Action: replace with pinned build."
        else
            echo "WARNING: Existing DuckStation is not marked as BareFront-managed."
            echo "BareFront will not overwrite it."
            die "Remove or relocate the unmanaged DuckStation binary before continuing."
        fi
    fi
fi


if [[ "$NEED_DUCKSTATION_INSTALL" -eq 1 ]]; then

    TEMP_DIR="$(mktemp -d)"
    TEMP_DOWNLOAD="$TEMP_DIR/DuckStation.AppImage"

    echo "Downloading DuckStation $DUCKSTATION_VERSION..."

    if ! curl -fL --progress-bar \
        "$DUCKSTATION_DOWNLOAD_URL" \
        -o "$TEMP_DOWNLOAD"
    then
        rm -rf "$TEMP_DIR"
        die "DuckStation download failed."
    fi

    echo
    echo "Checking DuckStation SHA-256..."

    ACTUAL_SHA256="$(sha256sum "$TEMP_DOWNLOAD" | awk '{print $1}')"

    if [[ "$ACTUAL_SHA256" != "$DUCKSTATION_SHA256" ]]; then
        echo "Expected:"
        echo "  $DUCKSTATION_SHA256"
        echo "Received:"
        echo "  $ACTUAL_SHA256"

        rm -rf "$TEMP_DIR"
        die "DuckStation SHA-256 verification failed."
    fi

    echo "  SHA-256: OK"

    # Inspect the downloaded contents rather than trusting the filename.
    DOWNLOAD_TYPE="$(file -b "$TEMP_DOWNLOAD")"

    echo
    echo "Downloaded file type:"
    echo "  $DOWNLOAD_TYPE"

    if ! grep -qiE 'ELF|AppImage|executable' <<< "$DOWNLOAD_TYPE"; then
        rm -rf "$TEMP_DIR"
        die "Downloaded DuckStation file does not look executable."
    fi

    install -m 0755 "$TEMP_DOWNLOAD" "$DUCKSTATION_EXE"

    rm -rf "$TEMP_DIR"

    echo
    echo "DuckStation $DUCKSTATION_VERSION installed."
fi


# ------------------------------------------------------------
# DuckStation portable user-data mode
#
# portable.txt makes DuckStation use this directory as its
# data root rather than ~/.local/share/duckstation.
# ------------------------------------------------------------

touch "$DUCKSTATION_DIR/portable.txt"

echo
echo "DuckStation portable mode:"
echo "  ENABLED"


# ------------------------------------------------------------
# BareFront PS1 save location
#
# DuckStation resolves relative folder settings from its data
# root. In portable mode that is emulators/duckstation/.
#
# ../../saves/ps1 therefore resolves to:
#
#   BareFront/saves/ps1
# ------------------------------------------------------------

mkdir -p "$BAREFRONT_DIR/saves/ps1"


# ------------------------------------------------------------
# BareFront first-run DuckStation baseline
#
# IMPORTANT:
# Create this file ONLY when no DuckStation settings already
# exist. Once created, the settings belong to the user.
#
# Re-running the installer must never overwrite customised
# emulator settings.
# ------------------------------------------------------------

if [[ -f "$DUCKSTATION_SETTINGS" ]]; then

    echo
    echo "DuckStation settings:"
    echo "  Existing settings.ini preserved."

else

    cat > "$DUCKSTATION_SETTINGS" <<'EOF'
[Main]
SetupWizardIncomplete = false
ConfirmPowerOff = false
SaveStateOnExit = false
NoDesktopFile = true

[AutoUpdater]
CheckAtStartup = false

[MemoryCards]
Directory = ../../saves/ps1

[Folders]
SaveStates = ../../saves/ps1

[Hotkeys]
OpenPauseMenu =
PowerOff = Keyboard/Escape
LoadSelectedSaveState = Keyboard/F1
SaveSelectedSaveState = Keyboard/F2
SelectPreviousSaveStateSlot = Keyboard/F3
SelectNextSaveStateSlot = Keyboard/F4

[GPU]
ResolutionScale = 1
Multisamples = 1
TextureFilter = Nearest
SpriteTextureFilter = Nearest
DownsampleMode = Disabled
WidescreenHack = false
ChromaSmoothing24Bit = false
DitheringMode = Unscaled
PGXPEnable = false

[Display]
Scaling = Nearest
Scaling24Bit = Nearest
AspectRatio = Auto
CropMode = None
EOF

    echo
    echo "DuckStation settings:"
    echo "  BareFront first-run baseline created."
fi


# ------------------------------------------------------------
# DuckStation BIOS
#
# DuckStation expects BIOS images inside <user directory>/bios.
# BareFront's firmware location is bios/ps1/.
#
# A symbolic link lets both conventions refer to the same folder.
# ------------------------------------------------------------

DUCK_BIOS_LINK="$DUCKSTATION_DIR/bios"
BAREFRONT_PS1_BIOS="$BAREFRONT_DIR/bios/ps1"

if [[ -L "$DUCK_BIOS_LINK" ]]; then

    CURRENT_TARGET="$(readlink "$DUCK_BIOS_LINK")"

    if [[ "$CURRENT_TARGET" != "$BAREFRONT_PS1_BIOS" ]]; then
        echo
        echo "WARNING: Existing DuckStation BIOS symbolic link points to:"
        echo "  $CURRENT_TARGET"
        echo "Expected:"
        echo "  $BAREFRONT_PS1_BIOS"
        echo "Leaving the existing link untouched."
    fi

elif [[ -e "$DUCK_BIOS_LINK" ]]; then

    echo
    echo "WARNING: DuckStation already has a real 'bios' directory."
    echo "BareFront will not overwrite it."
    echo "Expected BareFront BIOS directory:"
    echo "  $BAREFRONT_PS1_BIOS"

else

    ln -s "$BAREFRONT_PS1_BIOS" "$DUCK_BIOS_LINK"

    echo
    echo "Created DuckStation BIOS link:"
    echo "  $DUCK_BIOS_LINK"
    echo "       -> $BAREFRONT_PS1_BIOS"
fi


# ------------------------------------------------------------
# Record the BareFront-managed build
# ------------------------------------------------------------

if [[ ! -f "$DUCKSTATION_DIR/VERSION.txt" ]] ||
   grep -q '^BareFront managed emulator$' "$DUCKSTATION_DIR/VERSION.txt"
then

    cat > "$DUCKSTATION_DIR/VERSION.txt" <<EOF
BareFront managed emulator
Emulator: DuckStation
Version: $DUCKSTATION_VERSION
Source: https://github.com/stenzek/duckstation
Asset: $DUCKSTATION_ASSET_NAME
SHA256: $DUCKSTATION_SHA256
EOF

else

    echo
    echo "WARNING: Existing DuckStation VERSION.txt is not BareFront-managed."
    echo "Leaving it untouched."
fi


# ------------------------------------------------------------
# Final DuckStation verification
# ------------------------------------------------------------

echo
echo "Verifying DuckStation..."

if [[ ! -x "$DUCKSTATION_EXE" ]]; then
    die "DuckStation installation verification failed."
fi

ACTUAL_SHA256="$(sha256sum "$DUCKSTATION_EXE" | awk '{print $1}')"

if [[ "$ACTUAL_SHA256" != "$DUCKSTATION_SHA256" ]]; then
    die "Installed DuckStation does not match the pinned SHA-256."
fi

echo "  Executable: OK"
echo "  Version:    $DUCKSTATION_VERSION"
echo "  SHA-256:    OK"
echo "  Gamescope:  OK"
echo "  BareFront launcher: OK"
echo "  Presentation overlay: OK"

if [[ -f "$DUCKSTATION_DIR/portable.txt" ]]; then
    echo "  Portable mode marker: OK"
else
    die "DuckStation portable mode marker is missing."
fi

if [[ -f "$DUCKSTATION_SETTINGS" ]]; then
    echo "  settings.ini: OK"
else
    die "DuckStation settings.ini is missing."
fi

if [[ -d "$BAREFRONT_DIR/saves/ps1" ]]; then
    echo "  PS1 save directory: OK"
else
    die "BareFront PS1 save directory is missing."
fi

echo
echo "DuckStation stage complete."


# ============================================================
# Stage 3B - Locally managed emulators
# Part 3: PCSX2
# ============================================================

heading "STAGE 3B / PCSX2"

PCSX2_DIR="$BAREFRONT_DIR/emulators/pcsx2"
PCSX2_EXE="$PCSX2_DIR/PCSX2.AppImage"
PCSX2_LAUNCHER="$PCSX2_DIR/launch_pcsx2.sh"
PCSX2_GAMESCOPE="/usr/games/gamescope"
PCSX2_BARECRT="$BAREFRONT_DIR/assets/shaders/barecrt/BareCRT_v2.fx"
PCSX2_OVERLAY="$BAREFRONT_DIR/assets/overlays/ps2.png"

# BareFront deliberately pins PCSX2 to a known build.
#
# Do NOT change this to GitHub's moving "latest" release.
# Emulator updates must be tested before BareFront adopts them.
PCSX2_VERSION="v2.6.3"
PCSX2_ASSET_NAME="pcsx2-v2.6.3-linux-appimage-x64-Qt.AppImage"
PCSX2_DOWNLOAD_URL="https://github.com/PCSX2/pcsx2/releases/download/$PCSX2_VERSION/$PCSX2_ASSET_NAME"
PCSX2_SHA256="8ce7de8613c17b00b01028a512dd1b81998b6626ebbe93a067e0eb20aeedd5bf"

echo "BareFront uses PCSX2 for:"
echo "  PlayStation 2"
echo
echo "Pinned version:"
echo "  $PCSX2_VERSION"
echo
echo "Install location:"
echo "  $PCSX2_DIR"
echo

mkdir -p "$PCSX2_DIR"

NEED_PCSX2_INSTALL=1

if [[ -f "$PCSX2_EXE" ]]; then

    ACTUAL_SHA256="$(sha256sum "$PCSX2_EXE" | awk '{print $1}')"

    if [[ "$ACTUAL_SHA256" == "$PCSX2_SHA256" ]]; then

        echo "PCSX2 already matches BareFront's pinned build."
        echo "  SHA-256: OK"

        chmod +x "$PCSX2_EXE"
        NEED_PCSX2_INSTALL=0

    else

        echo "Existing PCSX2 does not match the pinned build."
        echo "Existing SHA-256:"
        echo "  $ACTUAL_SHA256"
        echo "Expected SHA-256:"
        echo "  $PCSX2_SHA256"
        echo

        # BareFront may replace a binary which it previously installed,
        # but must never silently overwrite an unmanaged/user-supplied one.
        if [[ -f "$PCSX2_DIR/VERSION.txt" ]] &&
           grep -q '^BareFront managed emulator$' "$PCSX2_DIR/VERSION.txt"
        then
            echo "Existing PCSX2 is BareFront-managed."
            echo "Action: replace with pinned build."
        else
            echo "WARNING: Existing PCSX2 is not marked as BareFront-managed."
            echo "BareFront will not overwrite it."
            die "Remove or relocate the unmanaged PCSX2 binary before continuing."
        fi
    fi
fi


if [[ "$NEED_PCSX2_INSTALL" -eq 1 ]]; then

    TEMP_DIR="$(mktemp -d)"
    TEMP_DOWNLOAD="$TEMP_DIR/PCSX2.AppImage"

    echo "Downloading PCSX2 $PCSX2_VERSION..."

    if ! curl -fL --progress-bar \
        "$PCSX2_DOWNLOAD_URL" \
        -o "$TEMP_DOWNLOAD"
    then
        rm -rf "$TEMP_DIR"
        die "PCSX2 download failed."
    fi

    echo
    echo "Checking PCSX2 SHA-256..."

    ACTUAL_SHA256="$(sha256sum "$TEMP_DOWNLOAD" | awk '{print $1}')"

    if [[ "$ACTUAL_SHA256" != "$PCSX2_SHA256" ]]; then
        echo "Expected:"
        echo "  $PCSX2_SHA256"
        echo "Received:"
        echo "  $ACTUAL_SHA256"

        rm -rf "$TEMP_DIR"
        die "PCSX2 SHA-256 verification failed."
    fi

    echo "  SHA-256: OK"

    DOWNLOAD_TYPE="$(file -b "$TEMP_DOWNLOAD")"

    echo
    echo "Downloaded file type:"
    echo "  $DOWNLOAD_TYPE"

    if ! grep -qiE 'ELF|AppImage|executable' <<< "$DOWNLOAD_TYPE"; then
        rm -rf "$TEMP_DIR"
        die "Downloaded PCSX2 file does not look executable."
    fi

    install -m 0755 "$TEMP_DOWNLOAD" "$PCSX2_EXE"

    rm -rf "$TEMP_DIR"

    echo
    echo "PCSX2 $PCSX2_VERSION installed."
fi


# Record the BareFront-managed build.
#
# A missing VERSION.txt is safe to create when the installed
# binary already matches the exact BareFront pin.
if [[ ! -f "$PCSX2_DIR/VERSION.txt" ]] ||
   grep -q '^BareFront managed emulator$' "$PCSX2_DIR/VERSION.txt"
then

    cat > "$PCSX2_DIR/VERSION.txt" <<EOF
BareFront managed emulator
Emulator: PCSX2
Version: $PCSX2_VERSION
Source: https://github.com/PCSX2/pcsx2
Asset: $PCSX2_ASSET_NAME
SHA256: $PCSX2_SHA256
EOF

else

    echo
    echo "WARNING: Existing PCSX2 VERSION.txt is not BareFront-managed."
    echo "Leaving it untouched."
fi


# ------------------------------------------------------------
# PCSX2 portable data root
# ------------------------------------------------------------

# With the Linux AppImage, PCSX2 -portable stores its data in a
# sibling "PCSX2" directory beside the AppImage.
#
# BareFront therefore always launches PCSX2 with -portable and
# manages this directory as PCSX2's portable data root.
PCSX2_DATA_DIR="$PCSX2_DIR/PCSX2"
PCSX2_INI="$PCSX2_DATA_DIR/inis/PCSX2.ini"

mkdir -p "$PCSX2_DATA_DIR"

echo
echo "PCSX2 portable data root:"
echo "  $PCSX2_DATA_DIR"


# ------------------------------------------------------------
# BareFront-owned PS2 BIOS and save folders
# ------------------------------------------------------------

mkdir -p \
    "$BAREFRONT_DIR/bios/ps2" \
    "$BAREFRONT_DIR/saves/ps2/memcards" \
    "$BAREFRONT_DIR/saves/ps2/sstates"


ensure_symlink()
{
    local target="$1"
    local link_path="$2"
    local description="$3"

    if [[ -L "$link_path" ]]; then

        local current_target
        current_target="$(readlink "$link_path")"

        if [[ "$current_target" == "$target" ]]; then
            echo "  $description: OK"
        else
            echo
            echo "WARNING: Existing symbolic link:"
            echo "  $link_path"
            echo "currently points to:"
            echo "  $current_target"
            echo "Expected:"
            echo "  $target"
            echo "Leaving it untouched."
        fi

    elif [[ -e "$link_path" ]]; then

        echo
        echo "WARNING: A real file/directory already exists at:"
        echo "  $link_path"
        echo "BareFront will not overwrite it."

    else

        ln -s "$target" "$link_path"

        echo "  $description: linked"
        echo "    $link_path"
        echo "      -> $target"

    fi
}


echo
echo "Connecting PCSX2 portable data folders to BareFront..."

ensure_symlink \
    "$BAREFRONT_DIR/bios/ps2" \
    "$PCSX2_DATA_DIR/bios" \
    "BIOS"

ensure_symlink \
    "$BAREFRONT_DIR/saves/ps2/memcards" \
    "$PCSX2_DATA_DIR/memcards" \
    "Memory cards"

ensure_symlink \
    "$BAREFRONT_DIR/saves/ps2/sstates" \
    "$PCSX2_DATA_DIR/sstates" \
    "Save states"


# ------------------------------------------------------------
# First-run PCSX2 configuration
# ------------------------------------------------------------

# Do not manufacture PCSX2's full configuration ourselves.
#
# On a genuinely fresh profile, the pinned PCSX2 build creates
# its own default configuration, including its normal controller
# and hotkey mappings. BareFront then changes only the small
# appliance-facing settings it deliberately owns.
#
# Existing profiles retain their user-managed settings.
# BareFront-owned appliance/presentation values are normalised
# idempotently below after the profile exists.
if [[ ! -f "$PCSX2_INI" ]]; then

    echo
    echo "Creating initial PCSX2 portable configuration..."

    PCSX2_CONFIG_ENV=()

    # A remote SSH shell has no graphical-session variables,
    # even when the same user has an active local desktop.
    #
    # PCSX2 still needs that desktop while generating its initial
    # Qt configuration. Discover the user's primary local session
    # without changing the environment used by the rest of the
    # installer.
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then

        PCSX2_SESSION_ID="$(
            loginctl show-user "$(id -un)" --property=Display --value 2>/dev/null || true
        )"

        PCSX2_LOCAL_DISPLAY="$(
            loginctl show-session "$PCSX2_SESSION_ID" --property=Display --value 2>/dev/null || true
        )"

        if [[ -z "$PCSX2_LOCAL_DISPLAY" ]]; then
            die "PCSX2 initial configuration needs an active graphical desktop."
        fi

        PCSX2_CONFIG_ENV+=(
            "DISPLAY=$PCSX2_LOCAL_DISPLAY"
        )

        if [[ -f "$HOME/.Xauthority" ]]; then
            PCSX2_CONFIG_ENV+=(
                "XAUTHORITY=$HOME/.Xauthority"
            )
        fi

        echo "  Using local graphical session: $PCSX2_LOCAL_DISPLAY"

    fi

    if ! env "${PCSX2_CONFIG_ENV[@]}"         "$PCSX2_EXE" -portable -testconfig
    then
        die "PCSX2 failed to create its initial portable configuration."
    fi

    if [[ ! -f "$PCSX2_INI" ]]; then
        die "PCSX2 did not create the expected portable PCSX2.ini."
    fi

    python3 - "$PCSX2_INI" <<'PYCONFIG'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()


def set_value(section, key, value):
    header = f"[{section}]"

    try:
        section_start = lines.index(header)
    except ValueError:
        if lines and lines[-1] != "":
            lines.append("")
        lines.append(header)
        lines.append(f"{key} = {value}")
        lines.append("")
        return

    section_end = len(lines)

    for i in range(section_start + 1, len(lines)):
        if lines[i].startswith("[") and lines[i].endswith("]"):
            section_end = i
            break

    for i in range(section_start + 1, section_end):
        stripped = lines[i].lstrip()

        if stripped.startswith(f"{key} =") or stripped.startswith(f"{key}="):
            lines[i] = f"{key} = {value}"
            return

    lines.insert(section_end, f"{key} = {value}")


# BareFront appliance behaviour.
set_value("UI", "SetupWizardIncomplete", "false")
set_value("UI", "ConfirmShutdown", "false")

# BareFront pins the emulator build, so PCSX2 must not self-update.
set_value("AutoUpdater", "CheckAtStartup", "false")

# Escape must return directly to BareFront rather than opening
# PCSX2's pause menu.
set_value("Hotkeys", "OpenPauseMenu", "")
set_value("Hotkeys", "ShutdownVM", "Keyboard/Escape")

# Do not hard-code a user's BIOS filename. BareFront's PS2
# launcher selects a region-matching BIOS immediately before
# each game starts.
set_value("Filenames", "BIOS", "")

path.write_text("\n".join(lines) + "\n")
PYCONFIG

    echo "Initial PCSX2 configuration created."
    echo "  Setup wizard: disabled"
    echo "  Automatic updates: disabled"
    echo "  Escape: return to BareFront"
    echo "  BIOS selection: mixed-region launcher"

else

    echo
    echo "Existing PCSX2 configuration found."
    echo "Preserving user-managed PCSX2 settings:"
    echo "  $PCSX2_INI"

fi


# ------------------------------------------------------------
# BareFront-owned PCSX2 appliance / presentation settings
# ------------------------------------------------------------
#
# These values are part of BareFront's PS2 contract rather than
# user preference:
#
# - emulator renders at native 1x
# - no emulator-side final smoothing / enhancement
# - original 4:3/3:2 aspect behaviour retained
# - PCSX2 handles deinterlacing automatically per title
# - Escape exits directly to BareFront
# - Gamescope owns final integer scaling
#
# Apply these on every installer run while leaving controller,
# memory-card, game-fix and other user-managed settings untouched.

python3 - "$PCSX2_INI" <<'PYCONFIG_OWNED'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()


def set_value(section, key, value):
    header = f"[{section}]"

    try:
        section_start = lines.index(header)
    except ValueError:
        if lines and lines[-1] != "":
            lines.append("")

        lines.extend([
            header,
            f"{key} = {value}",
            "",
        ])
        return

    section_end = len(lines)

    for i in range(section_start + 1, len(lines)):
        if lines[i].startswith("[") and lines[i].endswith("]"):
            section_end = i
            break

    for i in range(section_start + 1, section_end):
        stripped = lines[i].lstrip()

        if stripped.startswith(f"{key} =") or stripped.startswith(f"{key}="):
            lines[i] = f"{key} = {value}"
            return

    lines.insert(section_end, f"{key} = {value}")


# BareFront appliance behaviour.
set_value("UI", "SetupWizardIncomplete", "false")
set_value("UI", "ConfirmShutdown", "false")

set_value("AutoUpdater", "CheckAtStartup", "false")

set_value("Hotkeys", "OpenPauseMenu", "")
set_value("Hotkeys", "ShutdownVM", "Keyboard/Escape")

# The launcher chooses the matching BIOS immediately before launch.
set_value("Filenames", "BIOS", "")

# Neutral emulator-side presentation.
set_value("EmuCore", "EnableWideScreenPatches", "false")
set_value("EmuCore", "EnableNoInterlacingPatches", "false")

set_value("EmuCore/GS", "AspectRatio", "Auto 4:3/3:2")
set_value("EmuCore/GS", "IntegerScaling", "false")
set_value("EmuCore/GS", "fxaa", "false")
set_value("EmuCore/GS", "linear_present_mode", "0")
set_value("EmuCore/GS", "deinterlace_mode", "0")
set_value("EmuCore/GS", "upscale_multiplier", "1")
set_value("EmuCore/GS", "TVShader", "0")

path.write_text("\n".join(lines) + "\n")
PYCONFIG_OWNED

echo
echo "BareFront PCSX2 presentation settings:"
echo "  Internal resolution: 1x"
echo "  Aspect:              Auto 4:3/3:2"
echo "  Bilinear present:    disabled"
echo "  Deinterlace:         automatic"
echo "  Emulator FXAA:       disabled"
echo "  Emulator TV shader:  disabled"
echo "  Escape:              return to BareFront"


# ------------------------------------------------------------
# BareFront mixed-region PS2 launcher
# ------------------------------------------------------------

# BareFront owns this launcher. It determines the game's
# region from the curated ROM filename, identifies real PS2
# BIOS images from their ROMVER data, selects the newest
# matching BIOS, then starts PCSX2 with an authentic slow boot.
cat > "$PCSX2_LAUNCHER" <<'BAREFRONT_PCSX2_LAUNCHER_EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAREFRONT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PCSX2_EXE="$SCRIPT_DIR/PCSX2.AppImage"
PCSX2_DATA_DIR="$SCRIPT_DIR/PCSX2"
PCSX2_INI="$PCSX2_DATA_DIR/inis/PCSX2.ini"
BIOS_DIR="$PCSX2_DATA_DIR/bios"

GAMESCOPE="/usr/games/gamescope"
BARECRT="$BAREFRONT_DIR/assets/shaders/barecrt/BareCRT_v2.fx"

NATIVE_WIDTH=640
NATIVE_HEIGHT=480
INTEGER_SCALE=2

OUTPUT_WIDTH=$((NATIVE_WIDTH * INTEGER_SCALE))
OUTPUT_HEIGHT=$((NATIVE_HEIGHT * INTEGER_SCALE))

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-ps2.conf"

ROM="${1:-}"

if [[ -z "$ROM" ]]; then
    echo "ERROR: No PS2 game supplied." >&2
    exit 1
fi

if [[ ! -f "$ROM" ]]; then
    echo "ERROR: PS2 game not found:" >&2
    echo "  $ROM" >&2
    exit 1
fi

if [[ ! -x "$PCSX2_EXE" ]]; then
    echo "ERROR: PCSX2 executable not found:" >&2
    echo "  $PCSX2_EXE" >&2
    exit 1
fi

if [[ ! -x "$GAMESCOPE" ]]; then
    echo "ERROR: Gamescope executable not found:" >&2
    echo "  $GAMESCOPE" >&2
    exit 1
fi

if [[ ! -f "$BARECRT" ]]; then
    echo "ERROR: BareCRT shader not found:" >&2
    echo "  $BARECRT" >&2
    exit 1
fi

if [[ ! -f "$PCSX2_INI" ]]; then
    echo "ERROR: PCSX2 portable configuration not found:" >&2
    echo "  $PCSX2_INI" >&2
    exit 1
fi


python3 - "$ROM" "$BIOS_DIR" "$PCSX2_INI" <<'PY'
from pathlib import Path
import re
import struct
import sys

rom = Path(sys.argv[1])
bios_dir = Path(sys.argv[2])
ini = Path(sys.argv[3])

REGION_CODES = {
    "A": "USA",
    "E": "Europe",
    "J": "Japan",
    "H": "Asia",
    "C": "China",
    "P": "Free",
    "X": "Test",
}


def game_region(name):
    rules = [
        (r"\((?:USA|United States|Canada)\)|NTSC[- _]?U", "USA"),
        (r"\((?:Europe|PAL|Australia|New Zealand)\)|\bPAL\b", "Europe"),
        (r"\((?:Japan)\)|NTSC[- _]?J", "Japan"),
        (r"\((?:Asia)\)", "Asia"),
        (r"\((?:China)\)", "China"),
    ]

    matches = {
        region
        for pattern, region in rules
        if re.search(pattern, name, re.IGNORECASE)
    }

    if len(matches) == 1:
        return next(iter(matches))

    if not matches:
        raise SystemExit(
            f"ERROR: Cannot determine PS2 game region from filename:\n  {name}"
        )

    raise SystemExit(
        f"ERROR: Ambiguous PS2 game region in filename:\n"
        f"  {name}\n"
        f"Matches: {', '.join(sorted(matches))}"
    )


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

            region = REGION_CODES.get(romver[4])

            if region is None:
                return None

            return {
                "region": region,
                "version": int(romver[0:4]),
                "date": int(romver[6:14]),
                "romver": romver,
            }

        file_offset += (file_size + 0x0F) & ~0x0F
        pos += 16

    return None


region = game_region(rom.name)

candidates = []

for path in bios_dir.iterdir():
    if not path.is_file():
        continue

    info = identify_bios(path)

    if info and info["region"] == region:
        candidates.append(
            (info["date"], info["version"], path.name.lower(), path, info)
        )

if not candidates:
    raise SystemExit(
        f"ERROR: No valid {region} PS2 BIOS found in:\n  {bios_dir}"
    )

# Newest BIOS date first, then highest version.
candidates.sort(reverse=True)

_, _, _, selected, info = candidates[0]

print(f"BareFront PS2 region: {region}")
print(f"BareFront PS2 BIOS:   {selected.name}")

lines = ini.read_text().splitlines()

header = "[Filenames]"

try:
    start = lines.index(header)
except ValueError:
    if lines and lines[-1] != "":
        lines.append("")

    lines.extend([
        header,
        f"BIOS = {selected.name}",
        "",
    ])
else:
    end = len(lines)

    for i in range(start + 1, len(lines)):
        if lines[i].startswith("[") and lines[i].endswith("]"):
            end = i
            break

    for i in range(start + 1, end):
        if lines[i].lstrip().startswith("BIOS ="):
            lines[i] = f"BIOS = {selected.name}"
            break
    else:
        lines.insert(end, f"BIOS = {selected.name}")

ini.write_text("\n".join(lines) + "\n")
PY


if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

cat > "$VKBASALT_CONFIG" <<EOF
effects = barecrt
barecrt = $BARECRT
reshadeIncludePath = $BAREFRONT_DIR/assets/shaders/barecrt
reshadeTexturePath = $BAREFRONT_DIR/assets/shaders/barecrt
enableOnLaunch = True
toggleKey = F8
BareFrontScale = 2.0
EOF

echo "Starting PlayStation 2 through per-game Gamescope..."
echo "  Canvas:      ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Integer:     ${INTEGER_SCALE}x"
echo "  Output:      ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Filter:      nearest"
echo "  BareCRT:     enabled"

exec env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -w "$NATIVE_WIDTH" \
        -h "$NATIVE_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        "$PCSX2_EXE" \
            -portable \
            -batch \
            -slowboot \
            -fullscreen \
            "$ROM"
BAREFRONT_PCSX2_LAUNCHER_EOF

chmod +x "$PCSX2_LAUNCHER"

echo
echo "Mixed-region PS2 launcher installed:"
echo "  $PCSX2_LAUNCHER"


# ------------------------------------------------------------
# Final PCSX2 verification
# ------------------------------------------------------------

echo
echo "Verifying PCSX2..."

if [[ -x "$PCSX2_EXE" ]]; then
    echo "  Executable: OK"
    echo "  $PCSX2_EXE"
else
    die "PCSX2 installation verification failed."
fi

if [[ -x "$PCSX2_LAUNCHER" ]]; then
    echo "  Mixed-region launcher: OK"
    echo "  $PCSX2_LAUNCHER"
else
    die "PCSX2 mixed-region launcher verification failed."
fi

if ! bash -n "$PCSX2_LAUNCHER"; then
    die "PCSX2 launcher shell syntax verification failed."
fi

echo "  Launcher syntax: OK"

if [[ -x "$PCSX2_GAMESCOPE" ]]; then
    echo "  Gamescope: OK"
else
    die "PCSX2 presentation requires Gamescope."
fi

if [[ -f "$PCSX2_BARECRT" ]]; then
    echo "  BareCRT: OK"
else
    die "PCSX2 presentation requires the shared BareCRT shader."
fi

if [[ -f "$PCSX2_OVERLAY" ]]; then
    echo "  PS2 overlay: OK"
else
    die "PCSX2 presentation overlay is missing."
fi

if [[ -d "$PCSX2_DATA_DIR" ]]; then
    echo "  Portable data root: OK"
else
    die "PCSX2 portable data root is missing."
fi

if [[ "$(readlink "$PCSX2_DATA_DIR/bios" 2>/dev/null || true)" == "$BAREFRONT_DIR/bios/ps2" ]]; then
    echo "  BIOS link: OK"
else
    die "PCSX2 BIOS link verification failed."
fi

if [[ "$(readlink "$PCSX2_DATA_DIR/memcards" 2>/dev/null || true)" == "$BAREFRONT_DIR/saves/ps2/memcards" ]]; then
    echo "  Memory-card link: OK"
else
    die "PCSX2 memory-card link verification failed."
fi

if [[ "$(readlink "$PCSX2_DATA_DIR/sstates" 2>/dev/null || true)" == "$BAREFRONT_DIR/saves/ps2/sstates" ]]; then
    echo "  Save-state link: OK"
else
    die "PCSX2 save-state link verification failed."
fi

if [[ -f "$PCSX2_INI" ]]; then
    echo "  Portable configuration: OK"
else
    die "PCSX2 portable configuration is missing."
fi

echo
echo "BareFront PS2 launch path:"
echo "  $PCSX2_LAUNCHER {rom}"
echo
echo "The launcher:"
echo "  - detects the game's region from its curated filename"
echo "  - identifies installed PS2 BIOS images from ROMVER data"
echo "  - selects a matching BIOS for each game"
echo "  - starts PCSX2 with -portable -batch -slowboot -fullscreen"
echo "  - presents a 640x480 canvas through Gamescope"
echo "  - scales 2x nearest to 1280x960"
echo "  - applies the shared external BareCRT shader"
echo
echo "BareFront's 1920x1080 PS2 overlay provides the black surround"
echo "around the centred 1280x960 gameplay aperture."
echo
echo "This preserves the authentic PS2 BIOS/startup sequence"
echo "while supporting mixed-region curated libraries."
echo
echo "PCSX2 still requires BIOS images dumped from legitimately"
echo "owned PlayStation 2 consoles. BareFront supplies no BIOS."
echo
echo "PCSX2 stage complete."


# ============================================================
# Stage 3B - Locally managed emulators
# Part 4: Flycast
# ============================================================

heading "STAGE 3B / FLYCAST"

FLYCAST_DIR="$BAREFRONT_DIR/emulators/flycast"
FLYCAST_EXE="$FLYCAST_DIR/Flycast.AppImage"
FLYCAST_LAUNCHER="$FLYCAST_DIR/launch_flycast.sh"
FLYCAST_DATA_DIR="$FLYCAST_DIR/data"
FLYCAST_GAMESCOPE="/usr/games/gamescope"
FLYCAST_OVERLAY="$BAREFRONT_DIR/assets/overlays/dreamcast.png"

# BareFront Stage 8 known-good Flycast build.
FLYCAST_EXPECTED_VERSION="v2.7"
FLYCAST_EXPECTED_ASSET="flycast-x86_64-2.7.AppImage"
FLYCAST_EXPECTED_SHA256="5b9f8a636a6acb8446bc78fe96650d8cb8233ac9f8ce69665dab3f39a1cbaae1"
FLYCAST_API="https://api.github.com/repos/flyinghead/flycast/releases/tags/$FLYCAST_EXPECTED_VERSION"

echo "BareFront uses Flycast for:"
echo "  Dreamcast"
echo
echo "Install location:"
echo "  $FLYCAST_DIR"
echo

mkdir -p \
    "$FLYCAST_DIR" \
    "$FLYCAST_DATA_DIR" \
    "$BAREFRONT_DIR/bios/dreamcast" \
    "$BAREFRONT_DIR/saves/dreamcast"


FLYCAST_INSTALLED_SHA256=""

if [[ -x "$FLYCAST_EXE" ]]; then
    FLYCAST_INSTALLED_SHA256="$(
        sha256sum "$FLYCAST_EXE" | awk '{print $1}'
    )"
fi


if [[ -x "$FLYCAST_EXE" \
   && "$FLYCAST_INSTALLED_SHA256" == "$FLYCAST_EXPECTED_SHA256" ]]
then

    echo "Flycast pinned build is already installed."
    echo "Executable:"
    echo "  $FLYCAST_EXE"
    echo "  SHA-256: OK"
    echo "Action: SKIP"

else

    if [[ -x "$FLYCAST_EXE" ]]; then
        echo "Existing Flycast build does not match the BareFront pin."
        echo "Action: REPLACE"
        echo
    fi

    echo "Asking GitHub for the pinned Flycast release..."
    echo

    # /releases/latest returns the newest normal tagged release,
    # not nightly/master development builds.
    if ! FLYCAST_RELEASE_JSON="$(curl -fsSL "$FLYCAST_API")"; then
        die "Could not retrieve Flycast stable release information."
    fi

    FLYCAST_VERSION="$(
        printf '%s' "$FLYCAST_RELEASE_JSON" \
        | jq -r '.tag_name // empty'
    )"

    if [[ -z "$FLYCAST_VERSION" ]]; then
        die "GitHub did not return a Flycast stable release version."
    fi

    if [[ "$FLYCAST_VERSION" != "$FLYCAST_EXPECTED_VERSION" ]]; then
        die "Flycast release mismatch: expected $FLYCAST_EXPECTED_VERSION, got $FLYCAST_VERSION."
    fi

    echo "Latest stable release:"
    echo "  $FLYCAST_VERSION"
    echo

    # Pick the official Linux x86-64 AppImage.
    #
    # Asset names have changed slightly between releases, so we
    # select by characteristics rather than hard-coding the exact
    # filename forever.
    FLYCAST_ASSET_JSON="$(
        printf '%s' "$FLYCAST_RELEASE_JSON" \
        | jq -c '
            [
              .assets[]
              | select(.name | test("appimage"; "i"))
              | select(.name | test("x86_64|x64"; "i"))
              | select((.name | test("arm|aarch64"; "i")) | not)
            ][0] // empty
          '
    )"

    if [[ -z "$FLYCAST_ASSET_JSON" ]]; then
        echo "Release assets returned by GitHub:"
        printf '%s' "$FLYCAST_RELEASE_JSON" \
            | jq -r '.assets[]?.name' \
            | sed 's/^/  /'
        die "Could not identify the official Flycast Linux x86-64 AppImage."
    fi

    FLYCAST_ASSET_NAME="$(
        printf '%s' "$FLYCAST_ASSET_JSON" \
        | jq -r '.name'
    )"

    FLYCAST_DOWNLOAD_URL="$(
        printf '%s' "$FLYCAST_ASSET_JSON" \
        | jq -r '.browser_download_url'
    )"

    if [[ "$FLYCAST_ASSET_NAME" != "$FLYCAST_EXPECTED_ASSET" ]]; then
        die "Flycast asset mismatch: expected $FLYCAST_EXPECTED_ASSET, got $FLYCAST_ASSET_NAME."
    fi

    FLYCAST_DIGEST="$(
        printf '%s' "$FLYCAST_ASSET_JSON" \
        | jq -r '.digest // empty'
    )"

    echo "Selected asset:"
    echo "  $FLYCAST_ASSET_NAME"
    echo

    TEMP_DIR="$(mktemp -d)"
    TEMP_DOWNLOAD="$TEMP_DIR/Flycast.AppImage"

    echo "Downloading official stable AppImage..."

    if ! curl -fL --progress-bar \
        "$FLYCAST_DOWNLOAD_URL" \
        -o "$TEMP_DOWNLOAD"
    then
        rm -rf "$TEMP_DIR"
        die "Flycast download failed."
    fi

    PINNED_SHA256="$(sha256sum "$TEMP_DOWNLOAD" | awk '{print $1}')"

    echo
    echo "Checking pinned Flycast SHA-256..."

    if [[ "$PINNED_SHA256" != "$FLYCAST_EXPECTED_SHA256" ]]; then
        rm -rf "$TEMP_DIR"
        die "Flycast pinned SHA-256 verification failed."
    fi

    echo "  SHA-256: OK"

    if [[ "$FLYCAST_DIGEST" == sha256:* ]]; then

        EXPECTED_SHA256="${FLYCAST_DIGEST#sha256:}"
        ACTUAL_SHA256="$(sha256sum "$TEMP_DOWNLOAD" | awk '{print $1}')"

        echo
        echo "Checking Flycast SHA-256..."

        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            rm -rf "$TEMP_DIR"
            die "Flycast SHA-256 verification failed."
        fi

        echo "  SHA-256: OK"

    else

        echo
        echo "No release-asset SHA-256 was supplied by GitHub."
        echo "The AppImage was downloaded directly from the official"
        echo "Flycast GitHub release."

    fi

    DOWNLOAD_TYPE="$(file -b "$TEMP_DOWNLOAD")"

    echo
    echo "Downloaded file type:"
    echo "  $DOWNLOAD_TYPE"

    if ! grep -qiE 'ELF|AppImage|executable' <<< "$DOWNLOAD_TYPE"; then
        rm -rf "$TEMP_DIR"
        die "Downloaded Flycast file does not look executable."
    fi

    cp "$TEMP_DOWNLOAD" "$FLYCAST_EXE"
    chmod +x "$FLYCAST_EXE"

    cat > "$FLYCAST_DIR/VERSION.txt" <<EOF
BareFront managed emulator
Emulator: Flycast
Release: $FLYCAST_VERSION
Source: https://github.com/flyinghead/flycast
Asset: $FLYCAST_ASSET_NAME
EOF

    rm -rf "$TEMP_DIR"

    echo
    echo "Flycast AppImage installed."
fi


# ------------------------------------------------------------
# Dreamcast firmware layout
# ------------------------------------------------------------

echo
echo "Preparing Dreamcast firmware layout..."

# Flycast looks for Dreamcast firmware inside a folder named
# "data" beside the emulator.
#
# BareFront keeps the user's ORIGINAL verified firmware in:
#
#   bios/dreamcast/
#
# dc_boot.bin is effectively read-only firmware, so Flycast's
# expected filename can safely be a symbolic link to that file.
#
# dc_flash.bin is writable console flash/NVRAM. We deliberately
# do NOT point Flycast at the original BIOS copy because Flycast
# may modify it during normal use. Instead the working copy lives
# under saves/dreamcast/.
#
# The future BIOS checker will verify the user's source flash file
# and seed the writable copy when necessary.

FLYCAST_BOOT_LINK="$FLYCAST_DATA_DIR/dc_boot.bin"
FLYCAST_FLASH_LINK="$FLYCAST_DATA_DIR/dc_flash.bin"

BAREFRONT_DC_BOOT="$BAREFRONT_DIR/bios/dreamcast/dc_boot.bin"
BAREFRONT_DC_FLASH_WORKING="$BAREFRONT_DIR/saves/dreamcast/dc_flash.bin"


ensure_simple_symlink()
{
    local target="$1"
    local link_path="$2"
    local description="$3"

    if [[ -L "$link_path" ]]; then

        local current_target
        current_target="$(readlink "$link_path")"

        if [[ "$current_target" == "$target" ]]; then
            echo "  $description: OK"
        else
            echo
            echo "WARNING: Existing symbolic link:"
            echo "  $link_path"
            echo "points to:"
            echo "  $current_target"
            echo "Expected:"
            echo "  $target"
            echo "Leaving it untouched."
        fi

    elif [[ -e "$link_path" ]]; then

        echo
        echo "WARNING: A real file already exists at:"
        echo "  $link_path"
        echo "BareFront will not overwrite it."

    else

        # Linux allows a symbolic link to point at a file which
        # does not exist yet. The link becomes valid automatically
        # when the user later supplies the target file.
        ln -s "$target" "$link_path"

        echo "  $description: linked"
        echo "    $link_path"
        echo "      -> $target"

    fi
}


ensure_simple_symlink \
    "$BAREFRONT_DC_BOOT" \
    "$FLYCAST_BOOT_LINK" \
    "Dreamcast boot ROM"

ensure_simple_symlink \
    "$BAREFRONT_DC_FLASH_WORKING" \
    "$FLYCAST_FLASH_LINK" \
    "Dreamcast writable flash"


# ------------------------------------------------------------
# Flycast BareFront runtime integration
# ------------------------------------------------------------

FLYCAST_CONFIG_DIR="$HOME/.config/flycast"
FLYCAST_MAPPING_DIR="$FLYCAST_CONFIG_DIR/mappings"
FLYCAST_CONFIG="$FLYCAST_CONFIG_DIR/emu.cfg"
FLYCAST_KEYBOARD_MAPPING="$FLYCAST_MAPPING_DIR/SDL_Keyboard.cfg"

mkdir -p "$FLYCAST_CONFIG_DIR" "$FLYCAST_MAPPING_DIR"

if [[ ! -f "$FLYCAST_CONFIG" ]]; then

    cat > "$FLYCAST_CONFIG" <<EOF
[config]
UseReios = no
FastGDRomLoad = no
Dreamcast.BiosPath = $FLYCAST_DATA_DIR
rend.Resolution = 480
rend.IntegerScale = no
rend.LinearInterpolation = no
rend.AnisotropicFiltering = 1
rend.TextureFiltering = 0
rend.TextureUpscale2 = 1
rend.WideScreen = no
rend.SuperWideScreen = no
rend.WidescreenGameHacks = no
rend.ScreenStretching = 100
EOF

    echo "  Flycast BareFront config: CREATED"

else

    echo "  Flycast config already exists: PRESERVED"

    if ! grep -Fqx 'UseReios = no' "$FLYCAST_CONFIG" \
       || ! grep -Fqx 'FastGDRomLoad = no' "$FLYCAST_CONFIG" \
       || ! grep -Fqx "Dreamcast.BiosPath = $FLYCAST_DATA_DIR" "$FLYCAST_CONFIG" \
       || ! grep -Fqx 'rend.Resolution = 480' "$FLYCAST_CONFIG" \
       || ! grep -Fqx 'rend.LinearInterpolation = no' "$FLYCAST_CONFIG" \
       || ! grep -Fqx 'rend.TextureUpscale2 = 1' "$FLYCAST_CONFIG" \
       || ! grep -Fqx 'rend.WideScreen = no' "$FLYCAST_CONFIG"
    then
        echo "  WARNING: existing Flycast config does not contain"
        echo "           the complete BareFront Dreamcast presentation baseline."
    fi

fi


if [[ ! -f "$FLYCAST_KEYBOARD_MAPPING" ]]; then

    cat > "$FLYCAST_KEYBOARD_MAPPING" <<'EOF'
[digital]
bind0 = 4:btn_d
bind1 = 6:btn_b
bind10 = 27:btn_a
bind11 = 40:btn_start
bind12 = 41:btn_escape
bind13 = 43:btn_menu
bind14 = 44:btn_fforward
bind15 = 69:btn_screenshot
bind16 = 79:btn_dpad1_right
bind17 = 80:btn_dpad1_left
bind18 = 81:btn_dpad1_down
bind19 = 82:btn_dpad1_up
bind2 = 7:btn_y
bind3 = 9:btn_trigger_left
bind4 = 12:btn_analog_up
bind5 = 13:btn_analog_left
bind6 = 14:btn_analog_down
bind7 = 15:btn_analog_right
bind8 = 22:btn_x
bind9 = 25:btn_trigger_right

[emulator]
dead_zone = 10
mapping_name = Keyboard
rumble_power = 100
saturation = 100
triggers =
version = 4
EOF

    echo "  Flycast keyboard baseline: CREATED"

else

    echo "  Flycast keyboard mapping already exists: PRESERVED"

    if ! grep -Fq '41:btn_escape' "$FLYCAST_KEYBOARD_MAPPING"; then
        echo "  WARNING: existing Flycast keyboard map does not bind"
        echo "           Escape to the emulator Exit action."
    fi

fi


# Xbox Series X controller baseline.
# Install only when absent; never overwrite a user's Flycast mapping.
FLYCAST_XBOX_MAPPING_SOURCE="$BAREFRONT_DIR/assets/config/flycast/SDL_Xbox Series X Controller.cfg"
FLYCAST_XBOX_MAPPING="$FLYCAST_MAPPING_DIR/SDL_Xbox Series X Controller.cfg"

if [[ ! -f "$FLYCAST_XBOX_MAPPING" ]]; then

    [[ -f "$FLYCAST_XBOX_MAPPING_SOURCE" ]] ||
        die "Bundled Flycast Xbox controller mapping is missing."

    install -m 0644 "$FLYCAST_XBOX_MAPPING_SOURCE" "$FLYCAST_XBOX_MAPPING"

    echo "  Flycast Xbox controller baseline: CREATED"

else

    # Upgrade only BareFront's exact previous Xbox mapping.
    # Customised Flycast mappings must never be overwritten.
    FLYCAST_OLD_XBOX_SHA256="b2f25c244ecd2d3694d4ff011374cbefee9b98254a2948ae52dffb80c30d503e"
    FLYCAST_INSTALLED_XBOX_SHA256="$(
        sha256sum "$FLYCAST_XBOX_MAPPING" | awk '{print $1}'
    )"

    if [[ "$FLYCAST_INSTALLED_XBOX_SHA256" == "$FLYCAST_OLD_XBOX_SHA256" ]]; then

        [[ -f "$FLYCAST_XBOX_MAPPING_SOURCE" ]] ||
            die "Bundled Flycast Xbox controller mapping is missing."

        if grep -Fq '6:btn_menu' "$FLYCAST_XBOX_MAPPING_SOURCE" ||
           ! grep -Fq '11:btn_escape' "$FLYCAST_XBOX_MAPPING_SOURCE"; then
            die "Bundled Flycast Xbox controller mapping failed validation."
        fi

        FLYCAST_XBOX_MAPPING_BACKUP="$(
            mktemp "${FLYCAST_XBOX_MAPPING}.pre-select-menu.XXXXXX"
        )"

        cp -p "$FLYCAST_XBOX_MAPPING" "$FLYCAST_XBOX_MAPPING_BACKUP" ||
            die "Could not back up the previous Flycast Xbox mapping."

        install -m 0644 "$FLYCAST_XBOX_MAPPING_SOURCE" "$FLYCAST_XBOX_MAPPING" ||
            die "Could not migrate the Flycast Xbox mapping."

        echo "  Flycast Xbox Select-menu mapping: MIGRATED"
        echo "  Previous mapping: $FLYCAST_XBOX_MAPPING_BACKUP"

    else

        echo "  Flycast Xbox controller mapping already exists: PRESERVED"

        if grep -Fq '6:btn_menu' "$FLYCAST_XBOX_MAPPING"; then
            echo "  WARNING: existing custom mapping still assigns"
            echo "           Select to the Flycast menu."
        fi

    fi

    if ! grep -Fq '11:btn_escape' "$FLYCAST_XBOX_MAPPING"; then
        echo "  WARNING: existing Xbox mapping does not contain"
        echo "           the tested Guide-to-Exit binding."
    fi

fi


# BareFront-owned launcher adapter.
# XDG_DATA_HOME routes VMU/NVRAM data into BareFront/saves.
# Flycast renders a neutral 640x480 surface; Gamescope owns the
# 2x integer nearest presentation; the selected shader remains external.
if [[ ! -x "$BAREFRONT_DIR/scripts/launch_flycast.sh" ]]; then
    die "Tracked Flycast launcher is missing or not executable."
fi

if [[ ! -f "$BAREFRONT_DIR/scripts/flycast_shader_activate.py" ]]; then
    die "Flycast shader activation helper is missing."
fi

# Compatibility adapter. The implementation is tracked under scripts/.
# Keep this path stable for existing barefront.ini installations.
cat > "$FLYCAST_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$ROOT/scripts/launch_flycast.sh" "$@"
EOF

chmod +x "$FLYCAST_LAUNCHER"

echo "  Flycast BareFront launcher: READY"


# ------------------------------------------------------------
# Record firmware instructions for the later checker
# ------------------------------------------------------------

cat > "$FLYCAST_DIR/FIRMWARE_LAYOUT.txt" <<EOF
BareFront Dreamcast firmware layout

Original firmware supplied by user:
  $BAREFRONT_DIR/bios/dreamcast/dc_boot.bin
  $BAREFRONT_DIR/bios/dreamcast/dc_flash.bin

Flycast runtime paths:
  $FLYCAST_DATA_DIR/dc_boot.bin
    -> original verified boot ROM

  $FLYCAST_DATA_DIR/dc_flash.bin
    -> writable working copy:
       $BAREFRONT_DIR/saves/dreamcast/dc_flash.bin

The future BareFront BIOS checker will verify source firmware
and create/update the working dc_flash.bin when appropriate.
EOF


# ------------------------------------------------------------
# Final Flycast verification
# ------------------------------------------------------------

echo
echo "Verifying Flycast..."

if [[ -x "$FLYCAST_EXE" ]]; then
    echo "  Executable: OK"
    echo "  $FLYCAST_EXE"
else
    die "Flycast installation verification failed."
fi

if [[ -x "$FLYCAST_LAUNCHER" ]]; then
    echo "  BareFront wrapper: OK"
else
    die "Flycast BareFront wrapper is missing."
fi

if [[ -x "$FLYCAST_GAMESCOPE" ]]; then
    echo "  Gamescope: OK"
else
    die "Gamescope is required for Dreamcast presentation."
fi

if [[ -f "$FLYCAST_OVERLAY" ]]; then
    echo "  Dreamcast presentation overlay: OK"
else
    die "Dreamcast presentation overlay is missing."
fi

if [[ -L "$FLYCAST_BOOT_LINK" ]]; then
    echo "  Boot ROM link: OK"
else
    echo "  Boot ROM link: WARNING"
fi

if [[ -L "$FLYCAST_FLASH_LINK" ]]; then
    echo "  Writable flash link: OK"
else
    echo "  Writable flash link: WARNING"
fi

echo
echo "Flycast launch command will later use:"
echo "  {rom}"
echo
echo "Flycast stage complete."


# ============================================================
# Stage 3B - Locally managed emulators
# Part 5: BigPEmu
# ============================================================

heading "STAGE 3B / BIGPEMU"

BIGPEMU_DIR="$BAREFRONT_DIR/emulators/bigpemu"
BIGPEMU_LAUNCHER="$BIGPEMU_DIR/BigPEmu"
BIGPEMU_WRAPPER="$BAREFRONT_DIR/scripts/launch_bigpemu.sh"
BIGPEMU_ESC_SOURCE="$BAREFRONT_DIR/src/bigpemu_esc_helper.cpp"
BIGPEMU_ESC_HELPER="$BIGPEMU_DIR/bigpemu_esc_helper"
BIGPEMU_GAMESCOPE="/usr/games/gamescope"
BIGPEMU_OVERLAY="$BAREFRONT_DIR/assets/overlays/jaguar.png"

# BigPEmu does not currently publish releases through a package
# manager or machine-readable release API.
#
# For reproducibility BareFront pins the current known stable
# Linux x64 build and verifies the exact size and upstream
# FNV-1a hash before extracting it.
BIGPEMU_VERSION="1.221"
BIGPEMU_URL="https://www.richwhitehouse.com/jaguar/builds/BigPEmu_Linux64_v1221.tar.gz"
BIGPEMU_EXPECTED_SIZE="8912737"
BIGPEMU_EXPECTED_FNV="C1B241BBFA5135CB"

echo "BareFront uses BigPEmu for:"
echo "  Atari Jaguar"
echo
echo "Pinned stable release:"
echo "  $BIGPEMU_VERSION"
echo
echo "Install location:"
echo "  $BIGPEMU_DIR"
echo


BIGPEMU_UPSTREAM_EXEC="$BIGPEMU_DIR/bigpemu/bigpemu"

if [[ -x "$BIGPEMU_LAUNCHER" ]]; then

    echo "BigPEmu is already installed."
    echo "BareFront launcher:"
    echo "  $BIGPEMU_LAUNCHER"
    echo "Action: SKIP"

elif [[ -x "$BIGPEMU_UPSTREAM_EXEC" ]]; then

    echo "Existing BigPEmu installation recognised."
    echo "Executable:"
    echo "  $BIGPEMU_UPSTREAM_EXEC"
    echo
    echo "Creating BareFront launcher link."

    ln -s "$BIGPEMU_UPSTREAM_EXEC" "$BIGPEMU_LAUNCHER"

    echo "Action: ADOPT EXISTING INSTALLATION"

else

    # If a partial/unrecognised installation already exists,
    # do not destroy it automatically.
    if [[ -d "$BIGPEMU_DIR" ]] && \
       [[ -n "$(find "$BIGPEMU_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
    then
        echo
        echo "A non-empty BigPEmu directory already exists:"
        echo "  $BIGPEMU_DIR"
        echo
        echo "BareFront will not overwrite an unrecognised installation."
        die "Inspect or remove the existing BigPEmu directory before retrying."
    fi

    mkdir -p "$BIGPEMU_DIR"

    TEMP_DIR="$(mktemp -d)"
    TEMP_ARCHIVE="$TEMP_DIR/BigPEmu.tar.gz"
    EXTRACT_DIR="$TEMP_DIR/extracted"

    mkdir -p "$EXTRACT_DIR"

    echo "Downloading official BigPEmu Linux x64 archive..."

    if ! curl -fL --progress-bar \
        "$BIGPEMU_URL" \
        -o "$TEMP_ARCHIVE"
    then
        rm -rf "$TEMP_DIR"
        die "BigPEmu download failed."
    fi


    # --------------------------------------------------------
    # Verify exact byte size
    #
    # stat -c%s prints only the file size in bytes.
    # --------------------------------------------------------

    ACTUAL_SIZE="$(stat -c%s "$TEMP_ARCHIVE")"

    echo
    echo "Checking download size..."
    echo "  Expected: $BIGPEMU_EXPECTED_SIZE bytes"
    echo "  Actual:   $ACTUAL_SIZE bytes"

    if [[ "$ACTUAL_SIZE" != "$BIGPEMU_EXPECTED_SIZE" ]]; then
        rm -rf "$TEMP_DIR"
        die "BigPEmu file-size verification failed."
    fi

    echo "  Size: OK"


    # --------------------------------------------------------
    # Verify BigPEmu's upstream 64-bit FNV-1a hash.
    #
    # The BigPEmu author publishes FNV-1a rather than SHA-256.
    # Python is used here only to calculate that exact algorithm
    # reliably across Linux shells.
    # --------------------------------------------------------

    ACTUAL_FNV="$(
        python3 - "$TEMP_ARCHIVE" <<'PY'
import sys

path = sys.argv[1]

# 64-bit FNV-1a constants.
h = 0xcbf29ce484222325
prime = 0x100000001b3
mask = 0xffffffffffffffff

with open(path, "rb") as f:
    while True:
        block = f.read(1024 * 1024)
        if not block:
            break

        for byte in block:
            h ^= byte
            h = (h * prime) & mask

print(f"{h:016X}")
PY
    )"

    echo
    echo "Checking upstream FNV-1a hash..."
    echo "  Expected: $BIGPEMU_EXPECTED_FNV"
    echo "  Actual:   $ACTUAL_FNV"

    if [[ "$ACTUAL_FNV" != "$BIGPEMU_EXPECTED_FNV" ]]; then
        rm -rf "$TEMP_DIR"
        die "BigPEmu FNV-1a verification failed."
    fi

    echo "  FNV-1a: OK"


    # --------------------------------------------------------
    # Extract without changing the upstream layout.
    #
    # tar:
    #   -x = extract
    #   -z = decompress gzip
    #   -f = archive filename follows
    #   -C = extract into this directory
    # --------------------------------------------------------

    echo
    echo "Extracting BigPEmu..."

    if ! tar -xzf "$TEMP_ARCHIVE" -C "$EXTRACT_DIR"; then
        rm -rf "$TEMP_DIR"
        die "BigPEmu archive extraction failed."
    fi


    # Locate the real executable inside the preserved archive
    # structure. The current Linux archive contains a top-level
    # bigpemu directory, but discovery avoids depending on that
    # nesting forever.
    FOUND_BIGPEMU="$(
        find "$EXTRACT_DIR" \
            -type f \
            -name 'bigpemu' \
            -print \
            -quit
    )"

    if [[ -z "$FOUND_BIGPEMU" ]]; then
        rm -rf "$TEMP_DIR"
        die "BigPEmu executable was not found in the official archive."
    fi

    chmod +x "$FOUND_BIGPEMU"

    # Copy the entire extracted tree, not merely the executable.
    # BigPEmu explicitly expects its support directory structure
    # to remain intact.
    cp -a "$EXTRACT_DIR"/. "$BIGPEMU_DIR"/

    rm -rf "$TEMP_DIR"


    # --------------------------------------------------------
    # Create a predictable BareFront launcher link.
    #
    # Upstream keeps its own directory layout intact, while
    # BareFront can always launch:
    #
    #   emulators/bigpemu/BigPEmu
    # --------------------------------------------------------

    INSTALLED_BIGPEMU="$(
        find "$BIGPEMU_DIR" \
            -type f \
            -name 'bigpemu' \
            -print \
            -quit
    )"

    if [[ -z "$INSTALLED_BIGPEMU" ]]; then
        die "BigPEmu executable disappeared after installation."
    fi

    chmod +x "$INSTALLED_BIGPEMU"

    ln -s "$INSTALLED_BIGPEMU" "$BIGPEMU_LAUNCHER"


    cat > "$BIGPEMU_DIR/VERSION.txt" <<EOF
BareFront managed emulator
Emulator: BigPEmu
Release: $BIGPEMU_VERSION
Source: https://www.richwhitehouse.com/jaguar/
Linux archive: BigPEmu_Linux64_v1221.tar.gz
Expected size: $BIGPEMU_EXPECTED_SIZE bytes
Expected FNV-1a 64: $BIGPEMU_EXPECTED_FNV
EOF

    echo
    echo "BigPEmu installed."
fi


# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo
echo "Verifying BigPEmu..."

if [[ -L "$BIGPEMU_LAUNCHER" ]] && [[ -x "$BIGPEMU_LAUNCHER" ]]; then
    echo "  BareFront launcher: OK"
    echo "  $BIGPEMU_LAUNCHER"
    echo "    -> $(readlink "$BIGPEMU_LAUNCHER")"
else
    die "BigPEmu installation verification failed."
fi


# ------------------------------------------------------------
# BareFront Jaguar integration
#
# BigPEmu reserves Esc for its own menu. BareFront therefore
# owns Esc externally while BigPEmu is running inside Gamescope.
# The wrapper discovers BigPEmu's nested Xwayland DISPLAY and
# starts the existing X11 Esc helper on that display. The helper
# terminates only BigPEmu; Gamescope then exits naturally.
# ------------------------------------------------------------

echo
echo "Configuring BareFront Jaguar integration..."

if [[ ! -f "$BIGPEMU_ESC_SOURCE" ]]; then
    die "BigPEmu Esc helper source is missing."
fi

if [[ ! -x "$BIGPEMU_WRAPPER" ]]; then
    die "BigPEmu BareFront wrapper is missing or not executable."
fi

if [[ ! -x "$BIGPEMU_GAMESCOPE" ]]; then
    die "Gamescope is required for Atari Jaguar presentation."
fi

if [[ ! -f "$BIGPEMU_OVERLAY" ]]; then
    die "Atari Jaguar presentation overlay is missing."
fi

if [[ ! -x "$BIGPEMU_ESC_HELPER" ]] || \
   [[ "$BIGPEMU_ESC_SOURCE" -nt "$BIGPEMU_ESC_HELPER" ]]
then
    echo "Building BigPEmu Esc helper..."

    g++ -std=c++17 -O2 \
        "$BIGPEMU_ESC_SOURCE" \
        -o "$BIGPEMU_ESC_HELPER" \
        -lX11

    echo "Action: BUILD"
else
    echo "BigPEmu Esc helper is already current."
    echo "Action: SKIP"
fi

if [[ ! -x "$BIGPEMU_ESC_HELPER" ]]; then
    die "BigPEmu Esc helper build failed."
fi

echo
echo "BareFront Jaguar launcher:"
echo "  $BIGPEMU_WRAPPER"
echo
echo "BareFront-owned controls:"
echo "  Esc = return directly to BareFront"

echo
echo "BigPEmu needs no mandatory Jaguar BIOS for normal"
echo "cartridge-image use."
echo
echo "BareFront launch command will later use:"
echo "  $BIGPEMU_WRAPPER {rom}"
echo
echo "BigPEmu stage complete."


# ============================================================
# Stage 3B - Dolphin integration
# ============================================================

heading "STAGE 3B / DOLPHIN"

DOLPHIN_EXE="/usr/games/dolphin-emu"
DOLPHIN_GAMESCOPE="/usr/games/gamescope"
DOLPHIN_WRAPPER="$BAREFRONT_DIR/scripts/launch_dolphin.sh"
DOLPHIN_USER_DIR="$BAREFRONT_DIR/saves/gamecube/dolphin"
DOLPHIN_OVERLAY="$BAREFRONT_DIR/assets/overlays/gamecube.png"

if [[ ! -x "$DOLPHIN_EXE" ]]; then
    die "Dolphin executable not found: $DOLPHIN_EXE"
fi

if [[ ! -x "$DOLPHIN_GAMESCOPE" ]]; then
    die "Gamescope executable not found: $DOLPHIN_GAMESCOPE"
fi

if [[ ! -x "$DOLPHIN_WRAPPER" ]]; then
    die "Dolphin BareFront wrapper is missing or not executable."
fi

if [[ ! -s "$DOLPHIN_OVERLAY" ]]; then
    die "Tracked GameCube overlay missing: $DOLPHIN_OVERLAY"
fi

mkdir -p \
    "$BAREFRONT_DIR/bios/gamecube/EUR" \
    "$BAREFRONT_DIR/bios/gamecube/USA" \
    "$BAREFRONT_DIR/bios/gamecube/JAP" \
    "$DOLPHIN_USER_DIR/GC/EUR" \
    "$DOLPHIN_USER_DIR/GC/USA" \
    "$DOLPHIN_USER_DIR/GC/JAP"

for REGION in EUR USA JAP; do
    IPL_LINK="$DOLPHIN_USER_DIR/GC/$REGION/IPL.bin"
    EXPECTED_TARGET="../../../../../bios/gamecube/$REGION/IPL.bin"

    if [[ -L "$IPL_LINK" ]]; then
        if [[ "$(readlink "$IPL_LINK")" != "$EXPECTED_TARGET" ]]; then
            die "Unexpected Dolphin $REGION IPL link: $IPL_LINK"
        fi
    elif [[ -e "$IPL_LINK" ]]; then
        die "Unmanaged Dolphin $REGION IPL path exists: $IPL_LINK"
    else
        ln -s "$EXPECTED_TARGET" "$IPL_LINK"
    fi
done

echo "Verifying Dolphin integration..."
echo "  System executable: OK"
echo "  Gamescope: OK"
echo "  BareFront launcher: OK"
echo "  Presentation overlay: OK"
echo "  IPL links: OK"
echo
echo "Dolphin integration stage complete."


# ============================================================
# Stage 3B - Locally managed emulators
# Part 6: bsnes v115
# ============================================================

heading "STAGE 3B / BSNES"

BSNES_DIR="$BAREFRONT_DIR/emulators/bsnes"
BSNES_EXE="$BSNES_DIR/bsnes"
BSNES_LAUNCHER="$BAREFRONT_DIR/scripts/launch_bsnes.sh"

# v115 is the final official stable bsnes release from Near/byuu.
# Official stable Linux binaries are not provided in a form we
# want to depend on, so BareFront builds the tagged stable source.
BSNES_VERSION="v115"
BSNES_SOURCE_URL="https://github.com/bsnes-emu/bsnes/archive/refs/tags/v115.tar.gz"

echo "BareFront uses bsnes for:"
echo "  Super NES"
echo
echo "Stable source release:"
echo "  $BSNES_VERSION"
echo
echo "Install location:"
echo "  $BSNES_DIR"
echo


if [[ -x "$BSNES_EXE" ]]; then

    echo "bsnes is already installed."
    echo "Executable:"
    echo "  $BSNES_EXE"
    echo "Action: SKIP"

else

    # --------------------------------------------------------
    # Build dependencies
    # --------------------------------------------------------

    echo "Installing/verifying bsnes build dependencies..."
    echo

    BSNES_BUILD_PACKAGES=(
        libgtk-3-dev
        libgtksourceview-3.0-dev
        libsdl2-dev
        libxv-dev
        libgl1-mesa-dev
        libasound2-dev
        libopenal-dev
        libpulse-dev
        libao-dev
        libudev-dev
        libxrandr-dev
        libxext-dev
    )

    if ! sudo apt-get install -y "${BSNES_BUILD_PACKAGES[@]}"; then
        die "Could not install bsnes build dependencies."
    fi


    # --------------------------------------------------------
    # Temporary build workspace
    # --------------------------------------------------------

    TEMP_DIR="$(mktemp -d)"
    SOURCE_ARCHIVE="$TEMP_DIR/bsnes-v115.tar.gz"
    SOURCE_ROOT="$TEMP_DIR/source"

    mkdir -p "$SOURCE_ROOT"

    echo
    echo "Downloading official bsnes v115 source..."

    if ! curl -fL --progress-bar \
        "$BSNES_SOURCE_URL" \
        -o "$SOURCE_ARCHIVE"
    then
        rm -rf "$TEMP_DIR"
        die "bsnes v115 source download failed."
    fi

    echo
    echo "Downloaded archive:"
    echo "  $(file -b "$SOURCE_ARCHIVE")"


    # --------------------------------------------------------
    # Extract source
    # --------------------------------------------------------

    echo
    echo "Extracting bsnes source..."

    if ! tar -xzf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT"; then
        rm -rf "$TEMP_DIR"
        die "bsnes source extraction failed."
    fi

    BSNES_SOURCE_DIR="$(
        find "$SOURCE_ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name 'bsnes-*' \
            -print \
            -quit
    )"

    if [[ -z "$BSNES_SOURCE_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        die "Could not locate the extracted bsnes source directory."
    fi

    echo "Source directory:"
    echo "  $BSNES_SOURCE_DIR"


    # --------------------------------------------------------
    # Debian 13 / modern GCC compatibility patch
    #
    # v115 uses std::runtime_error in natural.hpp but does not
    # explicitly include <stdexcept>. Modern GCC correctly
    # requires that header.
    #
    # The patch is tiny and applied only if it is not already
    # present.
    # --------------------------------------------------------

    NATURAL_HPP="$BSNES_SOURCE_DIR/nall/arithmetic/natural.hpp"

    if [[ ! -f "$NATURAL_HPP" ]]; then
        rm -rf "$TEMP_DIR"
        die "Expected bsnes source file natural.hpp is missing."
    fi

    if grep -q '^#include <stdexcept>' "$NATURAL_HPP"; then

        echo
        echo "Modern-GCC compatibility include already present."

    else

        echo
        echo "Applying Debian 13 / modern-GCC compatibility patch..."
        echo "  Adding: #include <stdexcept>"

        # sed -i edits the file in place.
        #
        # 1i means:
        #   at line 1, INSERT the following text.
        sed -i '1i#include <stdexcept>' "$NATURAL_HPP"

    fi


    # --------------------------------------------------------
    # BareFront pseudo-fullscreen startup patch
    #
    # bsnes v115's normal --fullscreen path creates a separate
    # override-redirect X11 video surface. Inside Gamescope that
    # competes with the managed Hiro presentation window.
    #
    # BareFront adds --pseudo-fullscreen, using bsnes' existing
    # managed-window pseudo-fullscreen path instead.
    # --------------------------------------------------------

    BSNES_MAIN_CPP="$BSNES_SOURCE_DIR/bsnes/target-bsnes/bsnes.cpp"
    BSNES_PROGRAM_HPP="$BSNES_SOURCE_DIR/bsnes/target-bsnes/program/program.hpp"
    BSNES_PROGRAM_CPP="$BSNES_SOURCE_DIR/bsnes/target-bsnes/program/program.cpp"

    for required_file in \
        "$BSNES_MAIN_CPP" \
        "$BSNES_PROGRAM_HPP" \
        "$BSNES_PROGRAM_CPP"
    do
        if [[ ! -f "$required_file" ]]; then
            rm -rf "$TEMP_DIR"
            die "Expected bsnes source file is missing: $required_file"
        fi
    done

    echo
    echo "Applying BareFront bsnes pseudo-fullscreen patch..."

    python3 - \
        "$BSNES_MAIN_CPP" \
        "$BSNES_PROGRAM_HPP" \
        "$BSNES_PROGRAM_CPP" \
        <<'PYBSNESPSEUDO'
from pathlib import Path
import sys

main_cpp = Path(sys.argv[1])
program_hpp = Path(sys.argv[2])
program_cpp = Path(sys.argv[3])

def replace_once(path, old, new):
    text = path.read_text()

    if new in text:
        return

    if old not in text:
        raise SystemExit(
            f"Expected bsnes v115 source text was not found in {path}"
        )

    path.write_text(text.replace(old, new, 1))

replace_once(
    main_cpp,
    '''    if(argument == "--fullscreen") {
      program.startFullScreen = true;
''',
    '''    if(argument == "--fullscreen") {
      program.startFullScreen = true;
    } else if(argument == "--pseudo-fullscreen") {
      program.startPseudoFullScreen = true;
'''
)

replace_once(
    program_hpp,
    '''  bool startFullScreen = false;
''',
    '''  bool startFullScreen = false;
  bool startPseudoFullScreen = false;
'''
)

replace_once(
    program_cpp,
    '''  if(startFullScreen && emulator->loaded()) {
    toggleVideoFullScreen();
  }
  Application::onMain({&Program::main, this});
''',
    '''  if(startFullScreen && emulator->loaded()) {
    toggleVideoFullScreen();
  }
  if(startPseudoFullScreen && emulator->loaded()) {
    toggleVideoPseudoFullScreen();
  }
  Application::onMain({&Program::main, this});
'''
)

print("BareFront pseudo-fullscreen patch applied.")
PYBSNESPSEUDO


    # --------------------------------------------------------
    # Compile
    #
    # make tells GNU Make to follow the project's build rules.
    #
    # -C bsnes
    #   changes into the source's bsnes directory before building.
    #
    # hiro=gtk3
    #   builds the Linux GTK3 graphical interface.
    #
    # local=false
    #   IMPORTANT: do not optimise the binary only for the CPU
    #   currently doing the build. This makes the resulting
    #   BareFront bsnes binary more portable to other amd64 PCs.
    #
    # -j"$(nproc)"
    #   compile several files in parallel. `nproc` asks Linux how
    #   many CPU processing units are available.
    # --------------------------------------------------------

    echo
    echo "Building bsnes $BSNES_VERSION..."
    echo
    echo "Build command:"
    echo '  make -C bsnes hiro=gtk3 local=false -j"$(nproc)"'
    echo

    if ! make \
        -C "$BSNES_SOURCE_DIR/bsnes" \
        hiro=gtk3 \
        local=false \
        -j"$(nproc)"
    then
        rm -rf "$TEMP_DIR"
        die "bsnes compilation failed."
    fi


    BUILT_BSNES="$BSNES_SOURCE_DIR/bsnes/out/bsnes"

    if [[ ! -x "$BUILT_BSNES" ]]; then
        rm -rf "$TEMP_DIR"
        die "bsnes build completed but the expected executable was not produced."
    fi


    # --------------------------------------------------------
    # Install the finished build
    # --------------------------------------------------------

    mkdir -p "$BSNES_DIR"

    cp "$BUILT_BSNES" "$BSNES_EXE"
    chmod +x "$BSNES_EXE"

    # Keep the stable release database beside the executable
    # when it is present in the source tree.
    if [[ -d "$BSNES_SOURCE_DIR/bsnes/Database" ]]; then
        rm -rf "$BSNES_DIR/Database"
        cp -a \
            "$BSNES_SOURCE_DIR/bsnes/Database" \
            "$BSNES_DIR/Database"
    fi

    cat > "$BSNES_DIR/VERSION.txt" <<EOF
BareFront managed emulator
Emulator: bsnes
Release: v115
Source: https://github.com/bsnes-emu/bsnes
Build UI: GTK3
CPU-specific optimisation: disabled (local=false)
BareFront Debian 13 compatibility patch:
  nall/arithmetic/natural.hpp includes <stdexcept>
EOF

    rm -rf "$TEMP_DIR"

    echo
    echo "bsnes v115 built and installed."
fi


# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo
echo "Verifying bsnes..."

if [[ -x "$BSNES_EXE" ]]; then

    echo "  Executable: OK"
    echo "  $BSNES_EXE"

else

    die "bsnes installation verification failed."

fi

if [[ -d "$BSNES_DIR/Database" ]]; then
    echo "  Database: OK"
else
    echo "  Database: not present"
    echo "  This is not treated as a fatal installer error."
fi

if ! command -v pactl >/dev/null 2>&1; then
    die "SNES HDMI sink routing requires pactl."
fi

# ------------------------------------------------------------
# BareFront bsnes baseline
#
# BareFront owns the settings required to provide a clean,
# predictable SNES presentation:
#   - raw, unfiltered 256x224 emulator output
#   - neutral colour/gamma handling
#   - stable PulseAudio routed to BareFront-selected HDMI
#   - no bsnes status bar
#   - Esc exits directly to BareFront
#   - saves/states remain under BareFront
#
# Unrelated bsnes settings are preserved.
# ------------------------------------------------------------

BSNES_CONFIG_DIR="$HOME/.config/bsnes"
BSNES_CONFIG="$BSNES_CONFIG_DIR/settings.bml"
BSNES_SAVE_DIR="$BAREFRONT_DIR/saves/snes"
BSNES_STATE_DIR="$BSNES_SAVE_DIR/states"

mkdir -p \
    "$BSNES_CONFIG_DIR" \
    "$BSNES_SAVE_DIR" \
    "$BSNES_STATE_DIR"

echo
echo "Creating/verifying BareFront bsnes baseline..."

if [[ -f "$BSNES_CONFIG" ]]; then
    echo "Existing bsnes user configuration found."
    echo "Preserving unrelated emulator settings."
    BSNES_CONFIG_ACTION="REPAIR BAREFRONT INTEGRATION"
else
    echo "No existing bsnes configuration found."
    BSNES_CONFIG_ACTION="CREATE BASELINE"
fi

python3 - \
    "$BSNES_CONFIG" \
    "$BSNES_SAVE_DIR" \
    "$BSNES_STATE_DIR" \
    <<'PYBSNESCONFIG'
from pathlib import Path
import sys

config = Path(sys.argv[1])
save_dir = sys.argv[2]
state_dir = sys.argv[3]

if config.exists():
    lines = config.read_text().splitlines()
else:
    lines = []


def ensure(section, key, value):
    global lines

    try:
        section_index = lines.index(section)
    except ValueError:
        if lines and lines[-1] != "":
            lines.append("")
        lines.append(section)
        section_index = len(lines) - 1

    section_end = len(lines)

    for i in range(section_index + 1, len(lines)):
        line = lines[i]

        if line and not line[0].isspace():
            section_end = i
            break

    prefix = f"  {key}:"

    for i in range(section_index + 1, section_end):
        if lines[i].startswith(prefix):
            lines[i] = f"  {key}: {value}"
            return

    lines.insert(section_end, f"  {key}: {value}")


def seed_xbox_gamepad():
    global lines

    mapping = {
        "Up":     "0x45e0b12/1/1/Lo",
        "Down":   "0x45e0b12/1/1/Hi",
        "Left":   "0x45e0b12/1/0/Lo",
        "Right":  "0x45e0b12/1/0/Hi",
        "B":      "0x45e0b12/3/0",
        "A":      "0x45e0b12/3/1",
        "Y":      "0x45e0b12/3/2",
        "X":      "0x45e0b12/3/3",
        "L":      "0x45e0b12/3/4",
        "R":      "0x45e0b12/3/5",
        "Select": "0x45e0b12/3/6",
        "Start":  "0x45e0b12/3/7",
    }

    def mapped_gamepad_lines():
        result = [
            "  ControllerPort1: Gamepad",
            "    Gamepad",
        ]

        for key, value in mapping.items():
            result.append(f"      {key}: {value}")

        return result

    # --------------------------------------------------------
    # Fresh configuration:
    # create the Super Famicom / Port 1 structure ourselves.
    # --------------------------------------------------------

    try:
        system_index = lines.index("SuperFamicom")
    except ValueError:
        if lines and lines[-1] != "":
            lines.append("")

        lines.append("SuperFamicom")
        lines.extend(mapped_gamepad_lines())
        return

    # Find the end of the SuperFamicom top-level section.
    system_end = len(lines)

    for i in range(system_index + 1, len(lines)):
        line = lines[i]

        if line and not line[0].isspace():
            system_end = i
            break

    # --------------------------------------------------------
    # Existing SuperFamicom section but no Port 1:
    # treat it as unconfigured and add our baseline.
    # --------------------------------------------------------

    port_index = None

    for i in range(system_index + 1, system_end):
        if lines[i] == "  ControllerPort1: Gamepad":
            port_index = i
            break

    if port_index is None:
        lines[system_end:system_end] = mapped_gamepad_lines()
        return

    # Find the end of ControllerPort1.
    port_end = system_end

    for i in range(port_index + 1, system_end):
        line = lines[i]

        if not line:
            continue

        indent = len(line) - len(line.lstrip())

        if indent <= 2:
            port_end = i
            break

    # --------------------------------------------------------
    # Existing Port 1 but no Gamepad subsection:
    # also treat this as unconfigured.
    # --------------------------------------------------------

    gamepad_index = None

    for i in range(port_index + 1, port_end):
        if lines[i] == "    Gamepad":
            gamepad_index = i
            break

    if gamepad_index is None:
        block = ["    Gamepad"]

        for key, value in mapping.items():
            block.append(f"      {key}: {value}")

        lines[port_end:port_end] = block
        return

    # Find the end of the Gamepad subsection.
    gamepad_end = port_end

    for i in range(gamepad_index + 1, port_end):
        line = lines[i]

        if not line:
            continue

        indent = len(line) - len(line.lstrip())

        if indent <= 4:
            gamepad_end = i
            break

    control_lines = {}

    for i in range(gamepad_index + 1, gamepad_end):
        line = lines[i]

        if not line.startswith("      "):
            continue

        stripped = line.strip()

        if ":" in stripped:
            key, value = stripped.split(":", 1)
            value = value.strip()
        else:
            key = stripped
            value = ""

        if key in mapping:
            control_lines[key] = (i, value)

    # An unexpected or incomplete native layout is left alone.
    if set(control_lines) != set(mapping):
        return

    # Existing mappings belong to the user/emulator.
    # If even one normal gameplay control is assigned,
    # preserve the complete Port 1 mapping unchanged.
    if any(value for _, value in control_lines.values()):
        return

    # Complete native gamepad exists and all normal controls
    # are unassigned: seed BareFront's Xbox-layout baseline.
    for key, value in mapping.items():
        i, _ = control_lines[key]
        lines[i] = f"      {key}: {value}"


seed_xbox_gamepad()


ensure("Path", "Saves", f"{save_dir}/")
ensure("Path", "States", f"{state_dir}/")

ensure("Hotkey", "QuitEmulator", "0x1/0/0")

ensure("Video", "Driver", "XShm")
ensure("Video", "Shader", "None")
ensure("Video", "Output", "Scale")
ensure("Video", "Multiplier", "1")
ensure("Video", "AspectCorrection", "false")
ensure("Video", "Overscan", "false")
ensure("Video", "Blur", "false")
ensure("Video", "Filter", "None")
ensure("Video", "Luminance", "100")
ensure("Video", "Saturation", "100")
ensure("Video", "Gamma", "100")
ensure("Video", "Dimming", "false")

ensure("Audio", "Driver", "PulseAudio")
ensure("Audio", "Device", "Default")
ensure("Audio", "Blocking", "true")
ensure("Audio", "Frequency", "48000")
ensure("Audio", "Latency", "40")

ensure("General", "StatusBar", "false")

config.write_text("\n".join(lines) + "\n")
PYBSNESCONFIG

echo
echo "BareFront bsnes integration:"
echo "  Video: raw / unfiltered"
echo "  Gamma: 100"
echo "  Dimming: false"
echo "  Audio: PulseAudio -> BareFront-selected HDMI / 48 kHz / 40 ms"
echo "  Status bar: disabled"
echo "  Esc: exit directly to BareFront"
echo "  SRAM saves: $BSNES_SAVE_DIR/"
echo "  Save states: $BSNES_STATE_DIR/"
echo "  Action: $BSNES_CONFIG_ACTION"

echo
echo "No SNES BIOS is required for ordinary cartridge games."
echo
echo "BareFront launch command will later use:"
echo "  $BSNES_LAUNCHER {rom}"
echo
echo "bsnes stage complete."


# ============================================================
# Stage 3B - Locally managed integration
# Part 7: Amiberry
# ============================================================

heading "STAGE 3B / AMIBERRY"

AMIBERRY_EXE="/usr/bin/amiberry"
AMIBERRY_LOCAL_DIR="$BAREFRONT_DIR/emulators/amiberry"
AMIBERRY_CONF="$AMIBERRY_LOCAL_DIR/amiberry.conf"
AMIBERRY_LAUNCHER="$BAREFRONT_DIR/scripts/launch_amiberry.sh"
AMIBERRY_ESC_SOURCE="$BAREFRONT_DIR/src/amiberry_esc_helper.cpp"
AMIBERRY_ESC_HELPER="$AMIBERRY_LOCAL_DIR/amiberry_esc_helper"
AMIBERRY_PROFILE="$BAREFRONT_DIR/saves/amiga/amiberry"
AMIBERRY_WHD_SOURCE="/usr/share/amiberry/whdboot"
AMIBERRY_WHD_BOOT="$AMIBERRY_PROFILE/xdg-data/amiberry/WHDBoot"

echo "BareFront uses Amiberry for:"
echo "  Amiga"
echo
echo "Amiberry installation method:"
echo "  Official Amiberry Debian package repository"
echo
echo "Expected executable:"
echo "  $AMIBERRY_EXE"
echo


# ------------------------------------------------------------
# Install Amiberry from the official package repository
# ------------------------------------------------------------

if package_is_installed "amiberry" && [[ -x "$AMIBERRY_EXE" ]]; then

    echo "Amiberry is already installed."
    echo "Action: SKIP package installation."

else

    # First ask APT whether an Amiberry package is already visible.
    AMIBERRY_CANDIDATE="$(
        apt-cache policy amiberry 2>/dev/null \
        | awk '/Candidate:/ {print $2}'
    )"

    if [[ -z "$AMIBERRY_CANDIDATE" || "$AMIBERRY_CANDIDATE" == "(none)" ]]; then

        echo
        echo "Amiberry is not currently visible to Debian APT."
        echo
        echo "The Amiberry project recommends its official package"
        echo "repository for Debian 13."
        echo
        echo "BareFront can add that repository using the official"
        echo "Amiberry repository setup script from:"
        echo
        echo "  https://packages.amiberry.com/install.sh"
        echo
        echo "This will add Amiberry's package source/signing setup"
        echo "to Debian. It does NOT install ROMs or Kickstart files."
        echo

        read -r -p "Add the official Amiberry repository? [Y/n] " reply
        reply="${reply:-Y}"

        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            die "Amiberry repository setup was declined."
        fi

        TEMP_DIR="$(mktemp -d)"
        AMIBERRY_REPO_SCRIPT="$TEMP_DIR/amiberry-install.sh"

        echo
        echo "Downloading the official Amiberry repository setup script..."

        # We deliberately download the script FIRST and run the saved
        # file afterwards. This is clearer than piping web content
        # directly into a root shell.
        if ! curl -fsSL \
            "https://packages.amiberry.com/install.sh" \
            -o "$AMIBERRY_REPO_SCRIPT"
        then
            rm -rf "$TEMP_DIR"
            die "Could not download Amiberry's repository setup script."
        fi

        echo "Downloaded:"
        echo "  $AMIBERRY_REPO_SCRIPT"
        echo
        echo "Running the official repository setup..."

        if ! sudo sh "$AMIBERRY_REPO_SCRIPT"; then
            rm -rf "$TEMP_DIR"
            die "Amiberry repository setup failed."
        fi

        rm -rf "$TEMP_DIR"

        echo
        echo "Refreshing Debian package catalogue..."

        if ! sudo apt-get update; then
            die "APT refresh failed after adding the Amiberry repository."
        fi
    fi


    echo
    echo "Installing Amiberry..."

    if ! sudo apt-get install -y amiberry; then
        die "Amiberry package installation failed."
    fi

fi


# ------------------------------------------------------------
# Verify installed package
# ------------------------------------------------------------

echo
echo "Verifying Amiberry package..."

if [[ ! -x "$AMIBERRY_EXE" ]]; then
    die "Amiberry package was installed but /usr/bin/amiberry is missing."
fi

AMIBERRY_PACKAGE_VERSION="$(
    dpkg-query -W -f='${Version}' amiberry 2>/dev/null || true
)"

echo "  Executable: OK"
echo "  $AMIBERRY_EXE"
echo
echo "Installed package version:"
echo "  ${AMIBERRY_PACKAGE_VERSION:-Unknown}"


# ------------------------------------------------------------
# BareFront-owned Amiga directories
# ------------------------------------------------------------

mkdir -p \
    "$AMIBERRY_LOCAL_DIR" \
    "$AMIBERRY_LOCAL_DIR/conf" \
    "$AMIBERRY_PROFILE/home" \
    "$AMIBERRY_PROFILE/xdg-config" \
    "$AMIBERRY_PROFILE/xdg-data" \
    "$AMIBERRY_WHD_BOOT" \
    "$BAREFRONT_DIR/roms/amiga" \
    "$BAREFRONT_DIR/bios/amiga" \
    "$BAREFRONT_DIR/saves/amiga/savestates" \
    "$BAREFRONT_DIR/saves/amiga/nvram" \
    "$BAREFRONT_DIR/saves/amiga/saveimages" \
    "$BAREFRONT_DIR/assets/games/amiga"


# ------------------------------------------------------------
# Seed Amiberry's WHDLoad Booter runtime
#
# The Debian package provides the runtime files. Copy only files
# which are not already present so reinstalling BareFront cannot
# overwrite WHDLoad saves or a database updated by the user.
# ------------------------------------------------------------

if [[ ! -d "$AMIBERRY_WHD_SOURCE" ]]; then
    die "Amiberry WHDLoad runtime not found: $AMIBERRY_WHD_SOURCE"
fi

echo
echo "Seeding BareFront WHDLoad runtime..."

cp -a --no-clobber \
    "$AMIBERRY_WHD_SOURCE/." \
    "$AMIBERRY_WHD_BOOT/"

AMIBERRY_WHD_REQUIRED=(
    AmiQuit
    boot-data.zip
    game-data/whdload_db.json
    JST
    WHDLoad
)

for REQUIRED_FILE in "${AMIBERRY_WHD_REQUIRED[@]}"; do
    if [[ ! -f "$AMIBERRY_WHD_BOOT/$REQUIRED_FILE" ]]; then
        die "Missing WHDLoad runtime file: $REQUIRED_FILE"
    fi
done

echo "  WHDLoad runtime: OK"


# ------------------------------------------------------------
# Build the BareFront Amiberry Escape helper
#
# It watches the raw XInput2 keyboard stream so Esc still works
# while Amiberry owns keyboard focus, then requests a clean exit
# through Amiberry's Unix-domain IPC socket.
# ------------------------------------------------------------

if [[ ! -f "$AMIBERRY_ESC_SOURCE" ]]; then
    die "Amiberry Escape helper source missing: $AMIBERRY_ESC_SOURCE"
fi

if [[ ! -x "$AMIBERRY_ESC_HELPER" ]] ||
   [[ "$AMIBERRY_ESC_SOURCE" -nt "$AMIBERRY_ESC_HELPER" ]]
then
    echo
    echo "Building BareFront Amiberry Escape helper..."

    if ! g++ \
        -std=c++17 \
        -O2 \
        -Wall \
        -Wextra \
        -pedantic \
        "$AMIBERRY_ESC_SOURCE" \
        -o "$AMIBERRY_ESC_HELPER" \
        -lX11 \
        -lXi
    then
        die "Could not build the Amiberry Escape helper."
    fi

    echo "  Action: BUILD"
else
    echo "  Escape helper is already built and current."
    echo "  Action: SKIP"
fi

if [[ ! -x "$AMIBERRY_ESC_HELPER" ]]; then
    die "Amiberry Escape helper verification failed."
fi


# ------------------------------------------------------------
# Generate BareFront's Amiberry global configuration
#
# Amiberry normally spreads its content between ~/Amiberry,
# ~/.config/amiberry and ~/.local/share/amiberry.
#
# For a BareFront appliance we instead use a dedicated config
# file and explicitly point the useful paths at our project.
# ------------------------------------------------------------

echo
echo "Generating BareFront Amiberry path configuration..."

cat > "$AMIBERRY_CONF" <<EOF
# BareFront-managed Amiberry configuration
#
# Emulator-specific settings can still be changed inside Amiberry.
# These entries only make BareFront's filesystem layout predictable.

# BareFront presentation policy.
#
# Amiberry is responsible only for native Amiga emulation.
# Gamescope owns scaling/presentation and BareCRT is external.
#
# WHDLoad may still choose the correct emulated hardware for
# each title, but its JSON database must not override display
# presentation settings.
allow_display_settings_from_json=no
default_line_mode=0
default_scaling_method=0
default_gfx_autoresolution=1
default_auto_crop=no
default_correct_aspect_ratio=no

config_path=$AMIBERRY_LOCAL_DIR/conf
rom_path=$BAREFRONT_DIR/bios/amiga

# BareFront keeps all Amiga game media in the system ROM folder.
whdload_arch_path=$BAREFRONT_DIR/roms/amiga
floppy_path=$BAREFRONT_DIR/roms/amiga
harddrive_path=$BAREFRONT_DIR/roms/amiga
cdrom_path=$BAREFRONT_DIR/roms/amiga

savestate_dir=$BAREFRONT_DIR/saves/amiga/savestates
nvram_dir=$BAREFRONT_DIR/saves/amiga/nvram
saveimage_dir=$BAREFRONT_DIR/saves/amiga/saveimages
screenshot_dir=$BAREFRONT_DIR/assets/games/amiga

logfile_path=$BAREFRONT_DIR/logs/amiberry.log
EOF

echo "  Configuration:"
echo "  $AMIBERRY_CONF"


# ------------------------------------------------------------
# Verify the tracked BareFront launcher wrapper
#
# /usr/bin/amiberry is owned by Debian/APT and remains untouched.
# The tracked wrapper supplies BareFront's isolated profile,
# automatic media loading and clean Esc-to-IPC shutdown.
# ------------------------------------------------------------

echo
echo "Verifying BareFront Amiberry launcher..."

if [[ ! -f "$AMIBERRY_LAUNCHER" ]]; then
    die "Tracked Amiberry launcher is missing: $AMIBERRY_LAUNCHER"
fi

chmod +x "$AMIBERRY_LAUNCHER"

if [[ ! -x "$AMIBERRY_LAUNCHER" ]]; then
    die "Amiberry launcher is not executable: $AMIBERRY_LAUNCHER"
fi

echo "  Launcher: OK"
echo "  $AMIBERRY_LAUNCHER"


# ------------------------------------------------------------
# Verify Amiberry's resolved paths without launching the GUI.
#
# --dump-paths is an official diagnostic/dry-run command.
# It prints the paths Amiberry resolved and exits.
# ------------------------------------------------------------

echo
echo "Checking Amiberry resolved paths..."

AMIBERRY_PATH_DUMP="$(
    AMIBERRY_HOME_DIR="$AMIBERRY_PROFILE/home" \
    XDG_CONFIG_HOME="$AMIBERRY_PROFILE/xdg-config" \
    XDG_DATA_HOME="$AMIBERRY_PROFILE/xdg-data" \
    "$AMIBERRY_EXE" \
        -o "amiberry_config=$AMIBERRY_CONF" \
        --dump-paths \
        2>&1 || true
)"

printf '%s\n' "$AMIBERRY_PATH_DUMP" \
    | sed 's/^/  /'

AMIBERRY_EXPECTED_PATHS=(
    "settings_dir=$AMIBERRY_PROFILE/xdg-config/amiberry"
    "home_dir=$AMIBERRY_PROFILE/home"
    "controllers_path=$AMIBERRY_PROFILE/xdg-data/amiberry/Controllers/"
    "whdboot_path=$AMIBERRY_WHD_BOOT/"
)

for EXPECTED_PATH in "${AMIBERRY_EXPECTED_PATHS[@]}"; do
    if ! grep -Fqx \
        "$EXPECTED_PATH" \
        <<< "$AMIBERRY_PATH_DUMP"
    then
        die "Amiberry path isolation failed: $EXPECTED_PATH"
    fi
done

echo
echo "  BareFront path isolation: OK"


# ------------------------------------------------------------
# Kickstart note
# ------------------------------------------------------------

echo
echo "Amiga Kickstart ROMs belong in:"
echo "  $BAREFRONT_DIR/bios/amiga/"
echo
echo "For encrypted/licensed Cloanto ROM sets, rom.key should be"
echo "kept alongside the Kickstart ROMs."
echo
echo "BareFront will later verify known Kickstart files by:"
echo "  filename / size / CRC32 / SHA-256"
echo
echo "Amiberry does not require one single Kickstart version for"
echo "every game; the firmware checker will accept recognised"
echo "compatible variants."


# ------------------------------------------------------------
# Install record
# ------------------------------------------------------------

cat > "$AMIBERRY_LOCAL_DIR/VERSION.txt" <<EOF
BareFront managed emulator integration
Emulator: Amiberry
Package version: ${AMIBERRY_PACKAGE_VERSION:-Unknown}
Executable: /usr/bin/amiberry
Source: https://packages.amiberry.com/
BareFront config: $AMIBERRY_CONF
BareFront launcher: $AMIBERRY_LAUNCHER
BareFront profile: $AMIBERRY_PROFILE
WHDLoad runtime: $AMIBERRY_WHD_BOOT
Escape helper: $AMIBERRY_ESC_HELPER
EOF


# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo
echo "Verifying Amiberry integration..."

if [[ -x "$AMIBERRY_EXE" ]]; then
    echo "  System executable: OK"
else
    die "Amiberry executable verification failed."
fi

if [[ -f "$AMIBERRY_CONF" ]]; then
    echo "  BareFront config: OK"
else
    die "Amiberry BareFront config was not created."
fi

if [[ -x "$AMIBERRY_LAUNCHER" ]]; then
    echo "  BareFront launcher: OK"
else
    die "Amiberry BareFront launcher was not created."
fi

if [[ -x "$AMIBERRY_ESC_HELPER" ]]; then
    echo "  Escape helper: OK"
else
    die "Amiberry Escape helper verification failed."
fi

if [[ -f "$AMIBERRY_WHD_BOOT/boot-data.zip" ]] &&
   [[ -f "$AMIBERRY_WHD_BOOT/game-data/whdload_db.json" ]]
then
    echo "  WHDLoad runtime: OK"
else
    die "Amiberry WHDLoad runtime verification failed."
fi

echo
echo "BareFront launch command will later use:"
echo "  $AMIBERRY_LAUNCHER {rom}"
echo
echo "BareFront-owned controls:"
echo "  Esc = return directly to BareFront"
echo
echo "Amiberry stage complete."


# ============================================================
# Stage 3B - PC Engine / Mednafen integration
# ============================================================

heading "STAGE 3B / PC ENGINE"

MEDNAFEN_PCE_EXE="/usr/games/mednafen"
MEDNAFEN_PCE_LOCAL_DIR="$BAREFRONT_DIR/emulators/mednafen"
MEDNAFEN_PCE_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mednafen_pce.sh"
MEDNAFEN_PCE_PROFILE="$BAREFRONT_DIR/saves/pcengine/mednafen"
MEDNAFEN_PCE_CONFIG="$MEDNAFEN_PCE_PROFILE/mednafen.cfg"

MEDNAFEN_PCE_BARECRT_DIR="$BAREFRONT_DIR/assets/shaders/barecrt"
MEDNAFEN_PCE_BARECRT_SHADER="$MEDNAFEN_PCE_BARECRT_DIR/BareCRT_v2.fx"
MEDNAFEN_PCE_RESHADE_INCLUDE="$MEDNAFEN_PCE_BARECRT_DIR/ReShade.fxh"
MEDNAFEN_PCE_OVERLAY="$BAREFRONT_DIR/assets/overlays/pcengine.png"

VKBASALT_LAYER="/usr/share/vulkan/implicit_layer.d/vkBasalt.json"

echo "Configuring BareFront PC Engine integration..."
echo

if [[ ! -x "$MEDNAFEN_PCE_EXE" ]]; then
    die "Mednafen executable not found: $MEDNAFEN_PCE_EXE"
fi

if [[ ! -f "$MEDNAFEN_PCE_LAUNCHER" ]]; then
    die "Tracked PC Engine launcher missing: $MEDNAFEN_PCE_LAUNCHER"
fi

chmod +x "$MEDNAFEN_PCE_LAUNCHER"

if [[ ! -x "$MEDNAFEN_PCE_LAUNCHER" ]]; then
    die "PC Engine launcher is not executable."
fi

if ! command -v pactl >/dev/null 2>&1; then
    die "PC Engine direct-HDMI audio requires pactl."
fi

if ! command -v pasuspender >/dev/null 2>&1; then
    die "PC Engine direct-HDMI audio requires pasuspender."
fi

if ! command -v xrandr >/dev/null 2>&1; then
    die "PC Engine presentation requires xrandr."
fi

if [[ ! -f "$VKBASALT_LAYER" ]]; then
    die "vkBasalt Vulkan layer is missing: $VKBASALT_LAYER"
fi

if [[ ! -s "$MEDNAFEN_PCE_BARECRT_SHADER" ]]; then
    die "BareCRT shader is missing: $MEDNAFEN_PCE_BARECRT_SHADER"
fi

if [[ ! -s "$MEDNAFEN_PCE_RESHADE_INCLUDE" ]]; then
    die "BareCRT ReShade include is missing: $MEDNAFEN_PCE_RESHADE_INCLUDE"
fi

if [[ ! -s "$MEDNAFEN_PCE_OVERLAY" ]]; then
    die "PC Engine overlay artwork is missing: $MEDNAFEN_PCE_OVERLAY"
fi

mkdir -p \
    "$MEDNAFEN_PCE_LOCAL_DIR" \
    "$MEDNAFEN_PCE_PROFILE" \
    "$BAREFRONT_DIR/bios/pcengine" \
    "$BAREFRONT_DIR/roms/pcengine" \
    "$BAREFRONT_DIR/saves/pcengine" \
    "$BAREFRONT_DIR/assets/games/pcengine" \
    "$BAREFRONT_DIR/assets/videos/pcengine"

if [[ ! -f "$MEDNAFEN_PCE_CONFIG" ]]; then
    echo "Creating isolated Mednafen profile..."

    MEDNAFEN_HOME="$MEDNAFEN_PCE_PROFILE" \
        "$MEDNAFEN_PCE_EXE" -help \
        > "$LOG_DIR/mednafen-pcengine-profile.log" \
        2>&1 || true

    echo "  Action: CREATE"
else
    echo "Isolated Mednafen profile already exists."
    echo "  Action: PRESERVE"
fi

if [[ ! -f "$MEDNAFEN_PCE_CONFIG" ]]; then
    die "Mednafen did not create the PC Engine profile."
fi

MEDNAFEN_PCE_CONFIG_PATH="$MEDNAFEN_PCE_CONFIG" python3 - <<'PYMEDNAFEN'
import os
from pathlib import Path

path = Path(os.environ["MEDNAFEN_PCE_CONFIG_PATH"])
original = path.read_text()
lines = original.splitlines()

enforced = {
    "command.exit": "keyboard 0x0 41",
}

defaults = {
    "pce_fast.input.port1.gamepad.up": "keyboard 0x0 82",
    "pce_fast.input.port1.gamepad.down": "keyboard 0x0 81",
    "pce_fast.input.port1.gamepad.left": "keyboard 0x0 80",
    "pce_fast.input.port1.gamepad.right": "keyboard 0x0 79",
    "pce_fast.input.port1.gamepad.i": "keyboard 0x0 27",
    "pce_fast.input.port1.gamepad.ii": "keyboard 0x0 29",
    "pce_fast.input.port1.gamepad.run": "keyboard 0x0 40",
    "pce_fast.input.port1.gamepad.select": "keyboard 0x0 43",
}

seen = set()

for index, line in enumerate(lines):
    parts = line.split(None, 1)

    if not parts:
        continue

    key = parts[0]

    if key in enforced:
        lines[index] = f"{key} {enforced[key]}"
        seen.add(key)
    elif key in defaults:
        seen.add(key)

        if len(parts) == 1 or not parts[1].strip():
            lines[index] = f"{key} {defaults[key]}"

for key, value in {**enforced, **defaults}.items():
    if key not in seen:
        lines.append(f"{key} {value}")

updated = "\n".join(lines) + "\n"

if updated != original:
    path.write_text(updated)

resolved = {}

for line in lines:
    parts = line.split(None, 1)

    if len(parts) == 2:
        resolved[parts[0]] = parts[1].strip()

if resolved.get("command.exit") != enforced["command.exit"]:
    raise SystemExit("Could not enforce Mednafen Esc binding")

for key in defaults:
    if not resolved.get(key):
        raise SystemExit(f"Empty Mednafen input binding: {key}")

print("  Keyboard controls: OK")
print("  Esc exit binding: OK")
PYMEDNAFEN

MEDNAFEN_PCE_PACKAGE_VERSION="$(
    dpkg-query -W -f='${Version}' mednafen 2>/dev/null || true
)"

cat > "$MEDNAFEN_PCE_LOCAL_DIR/PCENGINE_VERSION.txt" <<EOF
BareFront managed emulator integration
System: PC Engine / TurboGrafx-16 / SuperGrafx / CD
Emulator: Mednafen
Package version: ${MEDNAFEN_PCE_PACKAGE_VERSION:-Unknown}
Executable: $MEDNAFEN_PCE_EXE
BareFront launcher: $MEDNAFEN_PCE_LAUNCHER
BareFront profile: $MEDNAFEN_PCE_PROFILE
CD BIOS path: $BAREFRONT_DIR/bios/pcengine/syscard3.pce
EOF

echo
echo "Verifying PC Engine integration..."
echo "  System executable: OK"
echo "  BareFront launcher: OK"
echo "  Isolated profile: OK"
echo "  Gamescope presentation: OK"
echo "  vkBasalt Vulkan layer: OK"
echo "  BareCRT shader: OK"
echo "  PC Engine overlay: OK"
echo "  Screenshot/video folders: OK"
echo "  Audio: BareFront-selected HDMI -> direct ALSA / 48 kHz / 20 ms"
echo
echo "BareFront-owned controls:"
echo "  Esc = return directly to BareFront"
echo
echo "PC Engine integration stage complete."


# ============================================================
# Stage 3C - Sega Saturn / Mednafen
# ============================================================

heading "STAGE 3C / SATURN"

MEDNAFEN_SATURN_EXE="/usr/games/mednafen"
MEDNAFEN_SATURN_GAMESCOPE="/usr/games/gamescope"
MEDNAFEN_SATURN_LOCAL_DIR="$BAREFRONT_DIR/emulators/mednafen"
MEDNAFEN_SATURN_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mednafen_saturn.sh"
MEDNAFEN_SATURN_PROFILE="$BAREFRONT_DIR/saves/saturn/mednafen"
MEDNAFEN_SATURN_CONFIG="$MEDNAFEN_SATURN_PROFILE/mednafen.cfg"
MEDNAFEN_SATURN_OVERLAY="$BAREFRONT_DIR/assets/overlays/saturn.png"

echo "Configuring BareFront Saturn integration..."
echo

if [[ ! -x "$MEDNAFEN_SATURN_EXE" ]]; then
    die "Mednafen executable not found: $MEDNAFEN_SATURN_EXE"
fi

if [[ ! -x "$MEDNAFEN_SATURN_GAMESCOPE" ]]; then
    die "Gamescope executable not found: $MEDNAFEN_SATURN_GAMESCOPE"
fi

if ! command -v pactl >/dev/null 2>&1; then
    die "Saturn direct-HDMI audio requires pactl."
fi

if ! command -v pasuspender >/dev/null 2>&1; then
    die "pasuspender is required for Saturn direct ALSA audio."
fi

if [[ ! -f "$MEDNAFEN_SATURN_LAUNCHER" ]]; then
    die "Tracked Saturn launcher missing: $MEDNAFEN_SATURN_LAUNCHER"
fi

chmod +x "$MEDNAFEN_SATURN_LAUNCHER"

if [[ ! -x "$MEDNAFEN_SATURN_LAUNCHER" ]]; then
    die "Saturn launcher is not executable."
fi

if [[ ! -s "$MEDNAFEN_SATURN_OVERLAY" ]]; then
    die "Tracked Saturn overlay missing: $MEDNAFEN_SATURN_OVERLAY"
fi

mkdir -p \
    "$MEDNAFEN_SATURN_LOCAL_DIR" \
    "$MEDNAFEN_SATURN_PROFILE" \
    "$BAREFRONT_DIR/bios/saturn" \
    "$BAREFRONT_DIR/roms/saturn" \
    "$BAREFRONT_DIR/saves/saturn" \
    "$BAREFRONT_DIR/assets/games/saturn" \
    "$BAREFRONT_DIR/assets/videos/saturn"

if [[ ! -f "$MEDNAFEN_SATURN_CONFIG" ]]; then
    echo "Creating isolated Mednafen profile..."

    MEDNAFEN_HOME="$MEDNAFEN_SATURN_PROFILE" \
        "$MEDNAFEN_SATURN_EXE" -help \
        > "$LOG_DIR/mednafen-saturn-profile.log" \
        2>&1 || true

    echo "  Action: CREATE"
else
    echo "Isolated Mednafen profile already exists."
    echo "  Action: PRESERVE"
fi

if [[ ! -f "$MEDNAFEN_SATURN_CONFIG" ]]; then
    die "Mednafen did not create the Saturn profile."
fi

MEDNAFEN_SATURN_CONFIG_PATH="$MEDNAFEN_SATURN_CONFIG" python3 - <<'PYMEDNAFEN_SATURN'
import os
from pathlib import Path

path = Path(os.environ["MEDNAFEN_SATURN_CONFIG_PATH"])
original = path.read_text()
lines = original.splitlines()

enforced = {
    "command.exit": "keyboard 0x0 41",
    "ss.correct_aspect": "0",
    "ss.stretch": "0",
    "ss.videoip": "0",
    "ss.shader": "none",
    "ss.special": "none",
    "ss.scanlines": "0",
    "ss.xscale": "1.000000",
    "ss.yscale": "1.000000",
}

defaults = {
    "ss.input.port1.gamepad.up": "keyboard 0x0 82",
    "ss.input.port1.gamepad.down": "keyboard 0x0 81",
    "ss.input.port1.gamepad.left": "keyboard 0x0 80",
    "ss.input.port1.gamepad.right": "keyboard 0x0 79",
    "ss.input.port1.gamepad.a": "keyboard 0x0 29",
    "ss.input.port1.gamepad.b": "keyboard 0x0 27",
    "ss.input.port1.gamepad.c": "keyboard 0x0 6",
    "ss.input.port1.gamepad.x": "keyboard 0x0 4",
    "ss.input.port1.gamepad.y": "keyboard 0x0 22",
    "ss.input.port1.gamepad.z": "keyboard 0x0 7",
    "ss.input.port1.gamepad.ls": "keyboard 0x0 20",
    "ss.input.port1.gamepad.rs": "keyboard 0x0 8",
    "ss.input.port1.gamepad.start": "keyboard 0x0 40",
}

seen = set()

for index, line in enumerate(lines):
    parts = line.split(None, 1)

    if not parts:
        continue

    key = parts[0]

    if key in enforced:
        lines[index] = f"{key} {enforced[key]}"
        seen.add(key)
    elif key in defaults:
        seen.add(key)

        if len(parts) == 1 or not parts[1].strip():
            lines[index] = f"{key} {defaults[key]}"

for key, value in {**enforced, **defaults}.items():
    if key not in seen:
        lines.append(f"{key} {value}")

updated = "\n".join(lines) + "\n"

if updated != original:
    path.write_text(updated)

resolved = {}

for line in lines:
    parts = line.split(None, 1)

    if len(parts) == 2:
        resolved[parts[0]] = parts[1].strip()

for key, value in enforced.items():
    if resolved.get(key) != value:
        raise SystemExit(f"Could not enforce Saturn setting: {key}")

for key in defaults:
    if not resolved.get(key):
        raise SystemExit(f"Empty Saturn input binding: {key}")

print("  Keyboard controls: OK")
print("  No visual filtering: OK")
print("  Esc exit binding: OK")
PYMEDNAFEN_SATURN

MEDNAFEN_SATURN_PACKAGE_VERSION="$(
    dpkg-query -W -f='${Version}' mednafen 2>/dev/null || true
)"

cat > "$MEDNAFEN_SATURN_LOCAL_DIR/SATURN_VERSION.txt" <<EOF
BareFront managed emulator integration
System: Sega Saturn
Emulator: Mednafen
Package version: ${MEDNAFEN_SATURN_PACKAGE_VERSION:-Unknown}
Executable: $MEDNAFEN_SATURN_EXE
BareFront launcher: $MEDNAFEN_SATURN_LAUNCHER
BareFront profile: $MEDNAFEN_SATURN_PROFILE
North America / Europe BIOS: $BAREFRONT_DIR/bios/saturn/mpr-17933.bin
Japan BIOS: $BAREFRONT_DIR/bios/saturn/sega_101.bin
EOF

echo
echo "Verifying Saturn integration..."
echo "  System executable: OK"
echo "  Gamescope: OK"
echo "  BareFront launcher: OK"
echo "  Presentation overlay: OK"
echo "  Isolated profile: OK"
echo
echo "BareFront-owned controls:"
echo "  Esc = return directly to BareFront"
echo
echo "Saturn integration stage complete."


# ============================================================
# Stage 4 - Production BareFront configuration
# ============================================================

heading "STAGE 4 / PRODUCTION CONFIGURATION"

CONFIG_FILE="$BAREFRONT_DIR/barefront.ini"
CONFIG_CONFLICT="$LOG_DIR/barefront.ini.generated"
VICE_LAUNCHER="$BAREFRONT_DIR/scripts/launch_vice.sh"
VICE_HOTKEY_DIR="$BAREFRONT_DIR/emulators/vice"
VICE_HOTKEY_FILE="$VICE_HOTKEY_DIR/barefront.vhk"
VICE_PRESENTATION_SOURCE="$BAREFRONT_DIR/src/c64_presentation_helper.cpp"
VICE_PRESENTATION_HELPER="$BAREFRONT_DIR/c64_presentation_helper"
VICE_BEZEL="$BAREFRONT_DIR/assets/overlays/plain/c64.png"
VICE_BEZEL_SHADER="$BAREFRONT_DIR/assets/shaders/c64/BareFront_C64_Bezel.fx"
MAME_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mame.sh"
MAME_ARCADE_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mame_arcade.sh"
MAME_NEOGEO_LAUNCHER="$BAREFRONT_DIR/scripts/launch_mame_neogeo.sh"

mkdir -p "$BAREFRONT_DIR/scripts"
mkdir -p "$VICE_HOTKEY_DIR"


# ------------------------------------------------------------
# VICE launcher adapter
#
# BareFront deliberately keeps emulator-specific setup outside
# the C++ frontend.
#
# The Debian VICE executable needs several C64 ROM paths on the
# command line in our known-working setup. Keeping that detail
# inside this adapter gives barefront.ini a simple:
#
#   emulator=.../launch_vice.sh
#   arguments={rom}
#
# The end user never has to type or maintain those arguments.
# ------------------------------------------------------------

echo "Creating/verifying C64 VICE launcher..."

if [[ ! -f "$VICE_PRESENTATION_SOURCE" ]]; then
    die "C64 presentation helper source is missing: $VICE_PRESENTATION_SOURCE"
fi

if [[ ! -f "$VICE_BEZEL" ]]; then
    die "C64 presentation bezel is missing: $VICE_BEZEL"
fi

if [[ ! -f "$VICE_BEZEL_SHADER" ]]; then
    die "C64 bezel shader is missing: $VICE_BEZEL_SHADER"
fi

if [[ ! -x "$VICE_PRESENTATION_HELPER" ]] || \
   [[ "$VICE_PRESENTATION_SOURCE" -nt "$VICE_PRESENTATION_HELPER" ]]
then
    echo
    echo "Building C64 presentation helper..."

    if ! g++ \
        -std=c++17 \
        -O2 \
        -Wall \
        -Wextra \
        -pedantic \
        "$VICE_PRESENTATION_SOURCE" \
        -o "$VICE_PRESENTATION_HELPER" \
        -lX11
    then
        die "C64 presentation helper build failed."
    fi

    echo "  Action: BUILD"
else
    echo
    echo "C64 presentation helper is already current."
    echo "  Action: SKIP"
fi

if [[ ! -x "$VICE_PRESENTATION_HELPER" ]]; then
    die "C64 presentation helper executable is missing after build."
fi

echo "  C64 presentation helper: OK"

VICE_DEFAULT_HOTKEYS="/usr/share/vice/hotkeys/hotkeys.vhk"

if [[ ! -f "$VICE_DEFAULT_HOTKEYS" ]]; then
    die "VICE default hotkey file is missing: $VICE_DEFAULT_HOTKEYS"
fi

cp "$VICE_DEFAULT_HOTKEYS" "$VICE_HOTKEY_FILE"

cat >> "$VICE_HOTKEY_FILE" <<'EOF'

# BareFront integration
quit    Escape
EOF

echo "  BareFront VICE hotkeys: OK"
echo "  $VICE_HOTKEY_FILE"
echo "  Esc: exit directly to BareFront"

cat > "$VICE_LAUNCHER" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

VICE="/usr/bin/x64sc"
GAMESCOPE="/usr/games/gamescope"
PRESENTATION_HELPER="$ROOT/c64_presentation_helper"

NATIVE_WIDTH=408
NATIVE_HEIGHT=293

OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080

C64_PAL_MODE="1920x1080_C64PAL"

BEZEL="$ROOT/assets/overlays/plain/c64.png"
BEZEL_SHADER="$ROOT/assets/shaders/c64/BareFront_C64_Bezel.fx"
BARECRT_SHADER="$ROOT/assets/shaders/barecrt/BareCRT_v2.fx"

VKBASALT_CONFIG="/tmp/barefront-vkbasalt-c64.conf"

GAMESCOPE_PID=""
PANELS_HIDDEN=0
C64_TEXTURE_DIR=""

DISPLAY_OUTPUT=""
ORIGINAL_MODE=""
ORIGINAL_RATE=""


if [[ -z "$ROM" ]]; then
    echo "Usage: launch_vice.sh <game-file>" >&2
    exit 1
fi


# BareFront normally supplies a path relative to its root.
# Convert it to an absolute path so VICE fliplist entries can
# be resolved reliably regardless of the caller's directory.
if [[ "$ROM" != /* ]]; then
    ROM="$ROOT/${ROM#./}"
fi


if [[ ! -f "$ROM" ]]; then
    echo "C64 game not found:" >&2
    echo "  $ROM" >&2
    exit 1
fi



for required in \
    "$VICE" \
    "$GAMESCOPE" \
    "$PRESENTATION_HELPER"
do
    if [[ ! -x "$required" ]]; then
        echo "Required C64 executable not found:" >&2
        echo "  $required" >&2
        exit 1
    fi
done


for required in \
    "$ROOT/bios/c64/basic-901226-01.bin" \
    "$ROOT/bios/c64/kernal-901227-03.bin" \
    "$ROOT/bios/c64/chargen-901225-01.bin" \
    "$ROOT/bios/c64/dos1541-325302-01+901229-05.bin" \
    "$BARECRT_SHADER" \
    "$BEZEL_SHADER" \
    "$BEZEL"
do
    if [[ ! -f "$required" ]]; then
        echo "Required C64 file not found:" >&2
        echo "  $required" >&2
        exit 1
    fi
done


export DISPLAY="${DISPLAY:-:0}"

if [[ -z "${XAUTHORITY:-}" &&
      -f "$HOME/.Xauthority" ]]
then
    export XAUTHORITY="$HOME/.Xauthority"
fi

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi


# ------------------------------------------------------------
# Capture the current physical display state.
#
# The original mode/rate is restored when VICE exits.
# ------------------------------------------------------------

XRANDR_STATE="$(xrandr --query)"

DISPLAY_OUTPUT="$(
    awk '
        $2 == "connected" {
            output = $1
        }

        /\*/ {
            print output
            exit
        }
    ' <<< "$XRANDR_STATE"
)"

ORIGINAL_MODE="$(
    awk '
        /\*/ {
            print $1
            exit
        }
    ' <<< "$XRANDR_STATE"
)"

ORIGINAL_RATE="$(
    awk '
        /\*/ {
            for (i = 2; i <= NF; ++i) {
                if ($i ~ /\*/) {
                    gsub(/[\*\+]/, "", $i)
                    print $i
                    exit
                }
            }
        }
    ' <<< "$XRANDR_STATE"
)"


if [[ -z "$DISPLAY_OUTPUT" ||
      -z "$ORIGINAL_MODE" ||
      -z "$ORIGINAL_RATE" ]]
then
    echo "Unable to determine the active X11 display mode." >&2
    exit 1
fi


cleanup()
{
    local exit_code=$?

    trap - EXIT INT TERM

    if [[ -n "$GAMESCOPE_PID" ]]; then
        kill "$GAMESCOPE_PID" \
            >/dev/null 2>&1 || true

        wait "$GAMESCOPE_PID" \
            >/dev/null 2>&1 || true
    fi

    echo
    echo "Restoring display:"
    echo "  Output: $DISPLAY_OUTPUT"
    echo "  Mode:   $ORIGINAL_MODE"
    echo "  Rate:   $ORIGINAL_RATE"

    xrandr \
        --output "$DISPLAY_OUTPUT" \
        --mode "$ORIGINAL_MODE" \
        --rate "$ORIGINAL_RATE" \
        >/dev/null 2>&1 || true

    if [[ "$PANELS_HIDDEN" == "1" ]]; then
        "$PRESENTATION_HELPER" show-panels \
            >/dev/null 2>&1 || true
    fi


    if [[ -n "$C64_TEXTURE_DIR" ]]; then
        rm -rf -- "$C64_TEXTURE_DIR"
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# Select C64 artwork without opening a separate X11 overlay.
OVERLAY_ROOT="$ROOT/assets/overlays"
OVERLAY_MAP="$OVERLAY_ROOT/overlays.ini"
DEFAULT_C64="$OVERLAY_ROOT/plain/c64.png"
C64_SELECTION="plain/c64.png"

if [[ ! -f "$OVERLAY_MAP" ]]; then
    OVERLAY_MAP="$OVERLAY_ROOT/overlays.ini.example"
fi

if [[ -f "$OVERLAY_MAP" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"

        if [[ "$key" == "c64" ]]; then
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            C64_SELECTION="$value"
        fi
    done < "$OVERLAY_MAP"
fi

case "$C64_SELECTION" in
    /*|*..*|*\\*|!*.png)
        echo "Invalid C64 overlay selection: $C64_SELECTION"
        C64_SELECTION="plain/c64.png"
        ;;
esac

C64_SELECTED="$OVERLAY_ROOT/$C64_SELECTION"
C64_VALIDATOR="$ROOT/overlay_helper"

# The reference mask must itself be valid and available.
if [[ ! -f "$DEFAULT_C64" ]] ||
   ! "$C64_VALIDATOR" --validate-c64 \
       "$DEFAULT_C64" "$DEFAULT_C64"; then
    echo "Required plain C64 texture or validator unavailable." >&2
    exit 1
fi

if [[ ! -f "$C64_SELECTED" ]] ||
   ! "$C64_VALIDATOR" --validate-c64 \
       "$C64_SELECTED" "$DEFAULT_C64"; then
    echo "Invalid or missing C64 artwork: $C64_SELECTED"
    C64_SELECTED="$DEFAULT_C64"
fi

C64_TEXTURE_DIR="$(mktemp -d /tmp/barefront-c64-texture.XXXXXX)"
cp -- "$C64_SELECTED" "$C64_TEXTURE_DIR/c64.png"

echo "C64 overlay: $C64_SELECTED"
echo "C64 texture directory: $C64_TEXTURE_DIR"



# ------------------------------------------------------------
# Determine whether this output advertises 1080p50.
#
# BareFront only attempts the PAL-matched custom mode on a
# display which already reports 1920x1080 at approximately
# 50 Hz. Otherwise the existing display mode is retained.
# ------------------------------------------------------------

SUPPORTS_1080P50="$(
    awk -v target="$DISPLAY_OUTPUT" '
        $1 == target && $2 == "connected" {
            inside = 1
            next
        }

        inside && /^[^[:space:]]/ {
            inside = 0
        }

        inside && $1 == "1920x1080" {
            for (i = 2; i <= NF; ++i) {
                rate = $i
                gsub(/[\*\+]/, "", rate)

                if (rate ~ /^50(\.0+)?$/) {
                    print "yes"
                    exit
                }
            }
        }
    ' <<< "$XRANDR_STATE"
)"


echo "Starting Commodore 64 through BareFront..."
echo "  VICE:        PAL"
echo "  Surface:     ${NATIVE_WIDTH}x${NATIVE_HEIGHT}"
echo "  Gamescope:   ${OUTPUT_WIDTH}x${OUTPUT_HEIGHT}"
echo "  Scaling:     integer / nearest"
echo "  Borders:     full"
echo "  CRT:         BareCRT"
echo "  Bezel:       black"


# ------------------------------------------------------------
# Release XFCE's panel work area BEFORE Gamescope is created.
#
# This allows the borderless 1920x1080 Gamescope window to be
# placed at the real desktop origin instead of y=27.
# ------------------------------------------------------------

"$PRESENTATION_HELPER" hide-panels
PANELS_HIDDEN=1

sleep 1


# ------------------------------------------------------------
# PAL display timing.
#
# A real PAL C64 runs at approximately 50.12 Hz. The M7 display
# accepts this custom 1080p mode and it removes the periodic
# cadence judder visible at ordinary 50.000 Hz.
#
# If the display cannot use it, fall back to its advertised
# 1080p50 mode. If even that fails, retain the original mode.
# ------------------------------------------------------------

if [[ "$SUPPORTS_1080P50" == "yes" ]]; then

    xrandr --newmode \
        "$C64_PAL_MODE" \
        148.87 \
        1920 2448 2492 2640 \
        1080 1084 1089 1125 \
        +HSync +VSync \
        >/dev/null 2>&1 || true

    xrandr --addmode \
        "$DISPLAY_OUTPUT" \
        "$C64_PAL_MODE" \
        >/dev/null 2>&1 || true

    if xrandr \
        --output "$DISPLAY_OUTPUT" \
        --mode "$C64_PAL_MODE"
    then
        echo "  Display:     PAL matched ~50.12 Hz"
    elif xrandr \
        --output "$DISPLAY_OUTPUT" \
        --mode 1920x1080 \
        --rate 50.00
    then
        echo "  Display:     50.00 Hz fallback"
    else
        echo "  Display:     original mode retained"
    fi

else
    echo "  Display:     no advertised 1080p50; original mode retained"
fi

# Give the physical display and X11 stack time to settle on the
# new refresh timing before Gamescope establishes its pacing.
sleep 3


# ------------------------------------------------------------
# vkBasalt / ReShade presentation.
#
# BareCRT runs first. The C64 bezel is then composited inside
# the same shader path, avoiding the separate X11 overlay
# window which caused visible scrolling judder.
# ------------------------------------------------------------

cat > "$VKBASALT_CONFIG" <<EOF2
effects = barecrt:c64bezel

barecrt = $BARECRT_SHADER
c64bezel = $BEZEL_SHADER

reshadeIncludePath = $ROOT/assets/shaders/barecrt
reshadeTexturePath = $C64_TEXTURE_DIR

enableOnLaunch = True
toggleKey = F8
BareFrontScale = 3.0
BareFrontPhaseY = 1.0
EOF2


VICE_ARGS=(
    -hotkeyfile "$ROOT/emulators/vice/barefront.vhk"
    +confirmonexit

    -pal

    -VICIIborders 1
    -VICIIfilter 0
    -VICIIglfilter 0
    -VICIIaspectmode 0

    -VICIIfull
    +fullscreen-decorations
    +VICIIshowstatusbar

    +VICIIdsize
    +VICIIdscan
    +VICIIvsync

    -basic "$ROOT/bios/c64/basic-901226-01.bin"
    -kernal "$ROOT/bios/c64/kernal-901227-03.bin"
    -chargen "$ROOT/bios/c64/chargen-901225-01.bin"
    -dos1541 "$ROOT/bios/c64/dos1541-325302-01+901229-05.bin"

    -drive8type 1541
)


# ------------------------------------------------------------
# Native VICE multi-disk support.
#
# A .vfl file is presented to BareFront as one game. The first
# non-comment entry is autostarted and VICE receives the whole
# fliplist so its normal disk-next / disk-previous controls
# remain available.
# ------------------------------------------------------------

ROM_EXTENSION="${ROM##*.}"
ROM_EXTENSION="${ROM_EXTENSION,,}"

if [[ "$ROM_EXTENSION" == "vfl" ]]; then

    FIRST_DISK="$(
        awk '
            {
                line = $0
                sub(/\r$/, "", line)
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)

                if (line != "" &&
                    substr(line, 1, 1) != ";")
                {
                    print line
                    exit
                }
            }
        ' "$ROM"
    )"

    if [[ -z "$FIRST_DISK" ]]; then
        echo "VICE fliplist contains no disk images:" >&2
        echo "  $ROM" >&2
        exit 1
    fi

    if [[ "$FIRST_DISK" == /* ]]; then
        AUTOSTART_DISK="$FIRST_DISK"
    else
        AUTOSTART_DISK="$(dirname "$ROM")/$FIRST_DISK"
    fi

    if [[ ! -f "$AUTOSTART_DISK" ]]; then
        echo "First VICE fliplist disk not found:" >&2
        echo "  $AUTOSTART_DISK" >&2
        exit 1
    fi

    echo "  Fliplist:    $(basename "$ROM")"
    echo "  First disk:  $(basename "$AUTOSTART_DISK")"

    VICE_ARGS+=(
        -flipname "$ROM"
        -autostart "$AUTOSTART_DISK"
    )

else

    VICE_ARGS+=(
        -autostart "$ROM"
    )

fi


env \
    ENABLE_VKBASALT=1 \
    VKBASALT_CONFIG_FILE="$VKBASALT_CONFIG" \
    "$GAMESCOPE" \
        -b \
        -g \
        -r 50.12 \
        -w "$NATIVE_WIDTH" \
        -h "$NATIVE_HEIGHT" \
        -W "$OUTPUT_WIDTH" \
        -H "$OUTPUT_HEIGHT" \
        -S integer \
        -F nearest \
        -- \
        "$VICE" \
        "${VICE_ARGS[@]}" &

GAMESCOPE_PID=$!


# Gamescope exists as a normal borderless X11 window. Apply an
# invisible cursor once, then leave no resident X11 helper
# running during gameplay.
sleep 3

"$PRESENTATION_HELPER" hide-cursor || true


if wait "$GAMESCOPE_PID"; then
    GAME_EXIT=0
else
    GAME_EXIT=$?
fi

GAMESCOPE_PID=""

exit "$GAME_EXIT"
EOF

chmod +x "$VICE_LAUNCHER"

if [[ -x "$VICE_LAUNCHER" ]]; then
    echo "  VICE adapter: OK"
    echo "  $VICE_LAUNCHER"
else
    die "Could not create the BareFront VICE launcher."
fi


# ------------------------------------------------------------
# MAME launcher adapter
#
# BareFront stores the selected ROM as a complete path such as:
#
#   roms/arcade/pacman.zip
#
# MAME normally launches by SET NAME:
#
#   mame pacman
#
# This adapter converts the selected archive path into its set
# name and supplies all BareFront Arcade / Neo Geo ROM and BIOS
# locations as MAME search paths.
# ------------------------------------------------------------

echo
echo "Verifying tracked Arcade MAME presentation launcher..."

if [[ ! -f "$MAME_ARCADE_LAUNCHER" ]]; then
    die "Tracked Arcade MAME launcher missing: $MAME_ARCADE_LAUNCHER"
fi

chmod +x "$MAME_ARCADE_LAUNCHER"

if ! bash -n "$MAME_ARCADE_LAUNCHER"; then
    die "Arcade MAME launcher shell syntax verification failed."
fi

if [[ ! -x "$MAME_ARCADE_LAUNCHER" ]]; then
    die "Arcade MAME launcher is not executable."
fi

if [[ ! -x "/usr/games/gamescope" ]]; then
    die "Arcade presentation requires Gamescope."
fi

if [[ ! -f "$BAREFRONT_DIR/assets/shaders/barecrt/BareCRT_v2.fx" ]]; then
    die "Arcade presentation requires the shared BareCRT shader."
fi

if [[ ! -x "$VICE_PRESENTATION_HELPER" ]]; then
    die "Arcade presentation requires the X11 presentation helper."
fi

echo "  Arcade launcher: OK"
echo "  $MAME_ARCADE_LAUNCHER"
echo "  Gamescope: OK"
echo "  BareCRT: OK"
echo "  Presentation helper: OK"

echo
echo "Verifying tracked Neo Geo MAME presentation launcher..."

if [[ ! -f "$MAME_NEOGEO_LAUNCHER" ]]; then
    die "Tracked Neo Geo MAME launcher missing: $MAME_NEOGEO_LAUNCHER"
fi

chmod +x "$MAME_NEOGEO_LAUNCHER"

if ! bash -n "$MAME_NEOGEO_LAUNCHER"; then
    die "Neo Geo MAME launcher shell syntax verification failed."
fi

if [[ ! -x "$MAME_NEOGEO_LAUNCHER" ]]; then
    die "Neo Geo MAME launcher is not executable."
fi

if [[ ! -x "/usr/games/gamescope" ]]; then
    die "Neo Geo presentation requires Gamescope."
fi

if [[ ! -f "$BAREFRONT_DIR/assets/shaders/barecrt/BareCRT_v2.fx" ]]; then
    die "Neo Geo presentation requires the shared BareCRT shader."
fi

if [[ ! -x "$VICE_PRESENTATION_HELPER" ]]; then
    die "Neo Geo presentation requires the X11 presentation helper."
fi

echo "  Neo Geo launcher: OK"
echo "  $MAME_NEOGEO_LAUNCHER"
echo "  Gamescope: OK"
echo "  BareCRT: OK"
echo "  Presentation helper: OK"

echo
echo "Creating/verifying legacy shared MAME launcher..."

cat > "$MAME_LAUNCHER" <<'EOF'
#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROM="${1:-}"

if [[ -z "$ROM" ]]; then
    echo "Usage: launch_mame.sh <rom-archive>" >&2
    exit 1
fi

ROM_DIR="$(dirname "$ROM")"
ROM_FILE="$(basename "$ROM")"
SET_NAME="${ROM_FILE%.*}"

# MAME accepts a semicolon-separated ROM search path.
#
# Include the selected game's own directory first, then both
# BareFront MAME-backed system libraries and BIOS directories.
ROMPATH="$ROM_DIR;$ROOT/roms/arcade;$ROOT/roms/neogeo;$ROOT/bios/arcade;$ROOT/bios/neogeo"

case "$ROM" in
    "$ROOT"/roms/neogeo/*|roms/neogeo/*|./roms/neogeo/*)
        SAVE_ROOT="$ROOT/saves/neogeo/mame"
        ;;
    *)
        SAVE_ROOT="$ROOT/saves/arcade/mame"
        ;;
esac

mkdir -p \
    "$SAVE_ROOT/cfg" \
    "$SAVE_ROOT/nvram" \
    "$SAVE_ROOT/states" \
    "$SAVE_ROOT/input"

exec /usr/games/mame \
    "$SET_NAME" \
    -rompath "$ROMPATH" \
    -cfg_directory "$SAVE_ROOT/cfg" \
    -nvram_directory "$SAVE_ROOT/nvram" \
    -state_directory "$SAVE_ROOT/states" \
    -input_directory "$SAVE_ROOT/input"
EOF

chmod +x "$MAME_LAUNCHER"

if [[ -x "$MAME_LAUNCHER" ]]; then
    echo "  MAME adapter: OK"
    echo "  $MAME_LAUNCHER"
else
    die "Could not create the BareFront MAME launcher."
fi


# ------------------------------------------------------------
# Generate the production barefront.ini
#
# ROM and screenshot locations are deliberately relative to the
# BareFront project root. BareFront already loads its assets and
# barefront.ini relative to that root, and relative library paths
# mean the whole BareFront folder can move without embedding a
# particular Linux username in every system entry.
#
# Emulator executables/adapters use the paths which this installer
# has just installed and verified.
# ------------------------------------------------------------

echo
echo "Generating production BareFront configuration..."

TEMP_CONFIG="$(mktemp)"

cat > "$TEMP_CONFIG" <<EOF
# ============================================================
# BareFront production configuration
# Generated by the BareFront installer
#
# Managed paths only:
#   roms        game library
#   screenshots preview screenshot library
#   emulator    executable / BareFront adapter
#   arguments   emulator launch arguments
#
# {rom} is replaced safely by BareFront with the selected game's
# complete path. Do not put quotes around {rom}.
#
# Production installs use roms/, NEVER testroms/.
# ============================================================

[megadrive]
roms=roms/megadrive
screenshots=assets/games/megadrive
emulator=$MEDNAFEN_MD_LAUNCHER
arguments={rom}

[nes]
roms=roms/nes
screenshots=assets/games/nes
emulator=$MESEN_NES_LAUNCHER
arguments={rom}

[snes]
roms=roms/snes
screenshots=assets/games/snes
emulator=$BSNES_LAUNCHER
arguments={rom}

[ps1]
roms=roms/ps1
screenshots=assets/games/ps1
emulator=$DUCKSTATION_WRAPPER
arguments={rom}

[ps2]
roms=roms/ps2
screenshots=assets/games/ps2
emulator=$PCSX2_LAUNCHER
arguments={rom}

[mastersystem]
roms=roms/mastersystem
screenshots=assets/games/mastersystem
emulator=$MESEN_SMS_LAUNCHER
arguments={rom}

[atari2600]
roms=roms/atari2600
screenshots=assets/games/atari2600
emulator=$STELLA_LAUNCHER
arguments={rom}

[c64]
roms=roms/c64
screenshots=assets/games/c64
emulator=$VICE_LAUNCHER
arguments={rom}

[arcade]
roms=roms/arcade
screenshots=assets/games/arcade
emulator=$MAME_ARCADE_LAUNCHER
arguments={rom}

[neogeo]
roms=roms/neogeo
screenshots=assets/games/neogeo
emulator=$MAME_NEOGEO_LAUNCHER
arguments={rom}

[dreamcast]
roms=roms/dreamcast
screenshots=assets/games/dreamcast
emulator=$FLYCAST_LAUNCHER
arguments={rom}

[saturn]
roms=roms/saturn
screenshots=assets/games/saturn
emulator=$MEDNAFEN_SATURN_LAUNCHER
arguments={rom}

[pcengine]
roms=roms/pcengine
screenshots=assets/games/pcengine
emulator=$MEDNAFEN_PCE_LAUNCHER
arguments={rom}

[jaguar]
roms=roms/jaguar
screenshots=assets/games/jaguar
emulator=$BIGPEMU_WRAPPER
arguments={rom}

[gamecube]
roms=roms/gamecube
screenshots=assets/games/gamecube
emulator=$DOLPHIN_WRAPPER
arguments={rom}

[amiga]
roms=roms/amiga
screenshots=assets/games/amiga
emulator=$AMIBERRY_LAUNCHER
arguments={rom}
EOF


# ------------------------------------------------------------
# Sanity-check the generated candidate before touching the live
# configuration.
# ------------------------------------------------------------

echo
echo "Checking generated configuration..."

EXPECTED_SECTIONS=(
    megadrive
    nes
    snes
    ps1
    ps2
    mastersystem
    atari2600
    c64
    arcade
    neogeo
    dreamcast
    saturn
    pcengine
    jaguar
    gamecube
    amiga
)

for section in "${EXPECTED_SECTIONS[@]}"; do

    count="$(
        grep -c -x "\[$section\]" "$TEMP_CONFIG" || true
    )"

    if [[ "$count" -ne 1 ]]; then
        rm -f "$TEMP_CONFIG"
        die "Generated barefront.ini has an invalid [$section] section."
    fi

done

if grep -Eq '^(roms|screenshots|emulator|arguments)=.*testroms/' "$TEMP_CONFIG"; then
    rm -f "$TEMP_CONFIG"
    die "Production configuration unexpectedly contains testroms/."
fi

if [[ "$(grep -c '^roms=roms/' "$TEMP_CONFIG")" -ne 16 ]]; then
    rm -f "$TEMP_CONFIG"
    die "Generated barefront.ini does not contain 16 production ROM paths."
fi

if [[ "$(grep -c '^screenshots=assets/games/' "$TEMP_CONFIG")" -ne 16 ]]; then
    rm -f "$TEMP_CONFIG"
    die "Generated barefront.ini does not contain 16 screenshot paths."
fi

if [[ "$(grep -c '^emulator=' "$TEMP_CONFIG")" -ne 16 ]]; then
    rm -f "$TEMP_CONFIG"
    die "Generated barefront.ini does not contain 16 emulator entries."
fi

if [[ "$(grep -c '^arguments=' "$TEMP_CONFIG")" -ne 16 ]]; then
    rm -f "$TEMP_CONFIG"
    die "Generated barefront.ini does not contain 16 argument entries."
fi

echo "  16 systems: OK"
echo "  roms/ production paths: OK"
echo "  testroms/ absent: OK"
echo "  emulator entries: OK"


# ------------------------------------------------------------
# Idempotent/safe config installation
#
# Fresh install:
#   install barefront.ini automatically.
#
# Exact rerun:
#   leave the identical file alone.
#
# Existing DIFFERENT configuration:
#   NEVER silently overwrite the user's file. Keep the candidate
#   in logs/barefront.ini.generated so it can be compared during
#   development/update handling.
# ------------------------------------------------------------

echo


# ------------------------------------------------------------
# Known safe configuration migrations
#
# BareFront never generally overwrites an existing user config.
# However, specific values previously generated by BareFront
# itself may be migrated when their meaning has changed.
#
# This migration moves exact legacy BareFront Mega Drive
# emulator paths to the Mednafen presentation launcher.
#
# Recognised legacy values:
#   /usr/games/blastem
#   <BareFront>/emulators/blastem/blastem
#   emulators/blastem/blastem
#
# It runs only on production configs. Development configs using
# testroms/ are intentionally left untouched.
# ------------------------------------------------------------

MEDNAFEN_MD_MIGRATION_BACKUP="$LOG_DIR/barefront.ini.pre-megadrive-mednafen-migration"

if [[ -f "$CONFIG_FILE" ]] &&
   ! grep -Eq '^roms=testroms/' "$CONFIG_FILE"
then

    MEDNAFEN_MD_MIGRATION_RESULT="$(
        python3 - \
            "$CONFIG_FILE" \
            "$BAREFRONT_DIR/emulators/blastem/blastem" \
            "$MEDNAFEN_MD_LAUNCHER" \
            "$MEDNAFEN_MD_MIGRATION_BACKUP" \
            <<'PYMIGRATE_MD'
from pathlib import Path
import shutil
import sys

config = Path(sys.argv[1])
old_managed = sys.argv[2]
new_launcher = sys.argv[3]
backup = Path(sys.argv[4])

legacy_values = {
    "emulator=/usr/games/blastem",
    f"emulator={old_managed}",
    "emulator=emulators/blastem/blastem",
}

lines = config.read_text().splitlines()

in_megadrive = False
target = None

for index, line in enumerate(lines):
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        in_megadrive = stripped == "[megadrive]"
        continue

    if in_megadrive and stripped.startswith("emulator="):
        if stripped in legacy_values:
            target = index
        break

if target is None:
    print("NO_CHANGE")
    raise SystemExit(0)

backup.parent.mkdir(parents=True, exist_ok=True)

if not backup.exists():
    shutil.copy2(config, backup)

indent = lines[target][:len(lines[target]) - len(lines[target].lstrip())]
lines[target] = f"{indent}emulator={new_launcher}"

config.write_text("\n".join(lines) + "\n")

print("MIGRATED")
PYMIGRATE_MD
    )"

    if [[ "$MEDNAFEN_MD_MIGRATION_RESULT" == "MIGRATED" ]]; then
        echo "Migrated legacy Mega Drive emulator path:"
        echo "  BlastEm"
        echo "    ->"
        echo "  $MEDNAFEN_MD_LAUNCHER"
        echo
        echo "Previous configuration backed up to:"
        echo "  $MEDNAFEN_MD_MIGRATION_BACKUP"
    fi

fi


# ------------------------------------------------------------
# Stella production-config migration
#
# Older BareFront production configs launched Stella directly
# with only {rom}. Stella 7.0 is now given a BareFront-managed
# base directory so its configuration and save states remain
# under the BareFront tree.
#
# Only the exact old BareFront-generated Atari 2600 settings are
# changed. Custom configurations are preserved.
# ------------------------------------------------------------

STELLA_MIGRATION_BACKUP="$LOG_DIR/barefront.ini.pre-stella-migration"

if [[ -f "$CONFIG_FILE" ]] &&
   ! grep -Eq '^roms=testroms/' "$CONFIG_FILE"
then

    STELLA_MIGRATION_RESULT="$(
        python3 - "$CONFIG_FILE" "$STELLA_BASE_DIR" "$STELLA_MIGRATION_BACKUP" <<'PYSTELLAMIGRATE'
from pathlib import Path
import shutil
import sys

config = Path(sys.argv[1])
base_dir = sys.argv[2]
backup = Path(sys.argv[3])

lines = config.read_text().splitlines()

in_atari = False
emulator_index = None
arguments_index = None

for index, line in enumerate(lines):
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        if in_atari:
            break
        in_atari = stripped == "[atari2600]"
        continue

    if not in_atari:
        continue

    if stripped.startswith("emulator="):
        emulator_index = index
    elif stripped.startswith("arguments="):
        arguments_index = index

if emulator_index is None or arguments_index is None:
    print("NO_CHANGE")
    raise SystemExit(0)

if lines[emulator_index].strip() != "emulator=/usr/bin/stella":
    print("NO_CHANGE")
    raise SystemExit(0)

if lines[arguments_index].strip() != "arguments={rom}":
    print("NO_CHANGE")
    raise SystemExit(0)

backup.parent.mkdir(parents=True, exist_ok=True)

if not backup.exists():
    shutil.copy2(config, backup)

indent = lines[arguments_index][
    :len(lines[arguments_index]) - len(lines[arguments_index].lstrip())
]

lines[arguments_index] = (
    f"{indent}arguments=-basedir {base_dir} {{rom}}"
)

config.write_text("\n".join(lines) + "\n")

print("MIGRATED")
PYSTELLAMIGRATE
    )"

    if [[ "$STELLA_MIGRATION_RESULT" == "MIGRATED" ]]; then
        echo
        echo "Migrated legacy Atari 2600 Stella arguments:"
        echo "  arguments={rom}"
        echo "    ->"
        echo "  arguments=-basedir $STELLA_BASE_DIR {rom}"
        echo
        echo "Previous configuration backed up to:"
        echo "  $STELLA_MIGRATION_BACKUP"
    fi

fi


# ------------------------------------------------------------
# Stella presentation-wrapper migration
#
# Current BareFront production configs launch Stella directly
# with the BareFront-managed base directory.  Atari 2600 now uses
# the tracked BareFront wrapper so Gamescope owns presentation and
# BareCRT remains external to Stella.
#
# Only the exact BareFront-generated direct-Stella configuration is
# changed. Custom Atari configurations are preserved.
# ------------------------------------------------------------

STELLA_WRAPPER_MIGRATION_BACKUP="$LOG_DIR/barefront.ini.pre-stella-wrapper-migration"

if [[ -f "$CONFIG_FILE" ]] &&
   ! grep -Eq '^roms=testroms/' "$CONFIG_FILE"
then

    STELLA_WRAPPER_MIGRATION_RESULT="$(
        python3 - \
            "$CONFIG_FILE" \
            "$STELLA_BASE_DIR" \
            "$STELLA_LAUNCHER" \
            "$STELLA_WRAPPER_MIGRATION_BACKUP" \
            <<'PYSTELLAWRAPPERMIGRATE'
from pathlib import Path
import shutil
import sys

config = Path(sys.argv[1])
base_dir = sys.argv[2]
launcher = sys.argv[3]
backup = Path(sys.argv[4])

lines = config.read_text().splitlines()

in_atari = False
emulator_index = None
arguments_index = None

for index, line in enumerate(lines):
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        if in_atari:
            break

        in_atari = stripped == "[atari2600]"
        continue

    if not in_atari:
        continue

    if stripped.startswith("emulator="):
        emulator_index = index
    elif stripped.startswith("arguments="):
        arguments_index = index

if emulator_index is None or arguments_index is None:
    print("NO_CHANGE")
    raise SystemExit(0)

expected_emulator = "emulator=/usr/bin/stella"
expected_arguments = f"arguments=-basedir {base_dir} {{rom}}"

if lines[emulator_index].strip() != expected_emulator:
    print("NO_CHANGE")
    raise SystemExit(0)

if lines[arguments_index].strip() != expected_arguments:
    print("NO_CHANGE")
    raise SystemExit(0)

backup.parent.mkdir(parents=True, exist_ok=True)

if not backup.exists():
    shutil.copy2(config, backup)

emulator_indent = lines[emulator_index][
    :len(lines[emulator_index]) - len(lines[emulator_index].lstrip())
]

arguments_indent = lines[arguments_index][
    :len(lines[arguments_index]) - len(lines[arguments_index].lstrip())
]

lines[emulator_index] = (
    f"{emulator_indent}emulator={launcher}"
)

lines[arguments_index] = (
    f"{arguments_indent}arguments={{rom}}"
)

config.write_text("\n".join(lines) + "\n")

print("MIGRATED")
PYSTELLAWRAPPERMIGRATE
    )"

    if [[ "$STELLA_WRAPPER_MIGRATION_RESULT" == "MIGRATED" ]]; then
        echo
        echo "Migrated Atari 2600 to BareFront presentation wrapper:"
        echo "  emulator=/usr/bin/stella"
        echo "  arguments=-basedir $STELLA_BASE_DIR {rom}"
        echo "    ->"
        echo "  emulator=$STELLA_LAUNCHER"
        echo "  arguments={rom}"
        echo
        echo "Previous configuration backed up to:"
        echo "  $STELLA_WRAPPER_MIGRATION_BACKUP"
    fi

fi


# ------------------------------------------------------------
# Flycast production-config migration
#
# Older BareFront production configs launched Flycast's AppImage
# directly. Dreamcast now uses the BareFront launcher so Flycast
# VMU/NVRAM data is routed under saves/dreamcast/.
#
# Only the exact old BareFront-generated Dreamcast settings are
# changed. Custom configurations are preserved.
# ------------------------------------------------------------

FLYCAST_MIGRATION_BACKUP="$LOG_DIR/barefront.ini.pre-flycast-migration"

if [[ -f "$CONFIG_FILE" ]] &&
   ! grep -Eq '^roms=testroms/' "$CONFIG_FILE"
then

    FLYCAST_MIGRATION_RESULT="$(
        python3 - "$CONFIG_FILE" "$FLYCAST_EXE" "$FLYCAST_LAUNCHER" "$FLYCAST_MIGRATION_BACKUP" <<'PYFLYCASTMIGRATE'
from pathlib import Path
import shutil
import sys

config = Path(sys.argv[1])
old_exe = sys.argv[2]
new_launcher = sys.argv[3]
backup = Path(sys.argv[4])

lines = config.read_text().splitlines()

in_dreamcast = False
emulator_index = None
arguments_index = None

for index, line in enumerate(lines):
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        if in_dreamcast:
            break
        in_dreamcast = stripped == "[dreamcast]"
        continue

    if not in_dreamcast:
        continue

    if stripped.startswith("emulator="):
        emulator_index = index
    elif stripped.startswith("arguments="):
        arguments_index = index

if emulator_index is None or arguments_index is None:
    print("NO_CHANGE")
    raise SystemExit(0)

if lines[emulator_index].strip() != f"emulator={old_exe}":
    print("NO_CHANGE")
    raise SystemExit(0)

if lines[arguments_index].strip() != "arguments={rom}":
    print("NO_CHANGE")
    raise SystemExit(0)

backup.parent.mkdir(parents=True, exist_ok=True)

if not backup.exists():
    shutil.copy2(config, backup)

indent = lines[emulator_index][
    :len(lines[emulator_index]) - len(lines[emulator_index].lstrip())
]

lines[emulator_index] = f"{indent}emulator={new_launcher}"

config.write_text("\n".join(lines) + "\n")

print("MIGRATED")
PYFLYCASTMIGRATE
    )"

    if [[ "$FLYCAST_MIGRATION_RESULT" == "MIGRATED" ]]; then
        echo
        echo "Migrated legacy Dreamcast Flycast launcher:"
        echo "  $FLYCAST_EXE"
        echo "    ->"
        echo "  $FLYCAST_LAUNCHER"
        echo
        echo "Previous configuration backed up to:"
        echo "  $FLYCAST_MIGRATION_BACKUP"
    fi

fi


if [[ ! -e "$CONFIG_FILE" ]]; then

    mv "$TEMP_CONFIG" "$CONFIG_FILE"

    echo "Production configuration installed:"
    echo "  $CONFIG_FILE"

elif cmp -s "$TEMP_CONFIG" "$CONFIG_FILE"; then

    rm -f "$TEMP_CONFIG"

    echo "Production configuration already matches."
    echo "  Action: SKIP"

else

    mv "$TEMP_CONFIG" "$CONFIG_CONFLICT"

    echo "WARNING: An existing barefront.ini is different."
    echo
    echo "BareFront has NOT overwritten it."
    echo
    echo "Existing:"
    echo "  $CONFIG_FILE"
    echo
    echo "Fresh generated candidate:"
    echo "  $CONFIG_CONFLICT"
    echo
    echo "This is intentional protection against destroying user"
    echo "configuration on a rerun or upgrade."

fi


# ------------------------------------------------------------
# Validate whichever live file exists.
# ------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    die "barefront.ini was not created."
fi

echo
echo "Live BareFront configuration:"
echo "  $CONFIG_FILE"

LIVE_SECTION_COUNT="$(
    grep -c '^\[[^]]\+\]$' "$CONFIG_FILE" || true
)"

echo "  Sections found: $LIVE_SECTION_COUNT"

if grep -Eq '^roms=testroms/' "$CONFIG_FILE"; then

    echo
    echo "NOTE: The existing live configuration still contains"
    echo "development testroms/ paths."
    echo
    echo "The production candidate is available at:"
    echo "  $CONFIG_CONFLICT"
    echo
    echo "We will compare this with the golden VM before replacing"
    echo "its known-good development configuration."

else

    echo "  Production ROM paths: OK"

fi


# ------------------------------------------------------------
# Flycast disc-insertion library
#
# Use the effective Dreamcast ROM path from the live BareFront
# configuration. Preserve an existing non-empty Flycast path.
# ------------------------------------------------------------

python3 - "$CONFIG_FILE" "$FLYCAST_CONFIG" "$BAREFRONT_DIR" <<'PYFLYCASTCONTENT'
from pathlib import Path
import os
import shutil
import sys
import tempfile

barefront = Path(sys.argv[1])
flycast = Path(sys.argv[2])
root = Path(sys.argv[3])

section = ""
rom_paths = []

for raw in barefront.read_text().splitlines():
    line = raw.strip()

    if line.startswith("[") and line.endswith("]"):
        section = line
    elif section == "[dreamcast]" and line.startswith("roms="):
        rom_paths.append(line.split("=", 1)[1].strip())

if len(rom_paths) != 1 or not rom_paths[0]:
    print("  WARNING: Cannot determine the live Dreamcast ROM path.")
    print("           Flycast content path left unchanged.")
    raise SystemExit(0)

rom_path = os.path.expanduser(rom_paths[0])

if not os.path.isabs(rom_path):
    rom_path = os.path.join(root, rom_path)

rom_path = os.path.abspath(rom_path)

original = flycast.read_text()
lines = original.splitlines()

matches = [
    i for i, line in enumerate(lines)
    if line.strip().startswith("Dreamcast.ContentPath")
    and line.split("=", 1)[0].strip() == "Dreamcast.ContentPath"
    and "=" in line
]

if len(matches) > 1:
    print("  WARNING: Multiple Flycast content-path entries.")
    print("           Existing config preserved.")
    raise SystemExit(0)

if matches:
    index = matches[0]
    current = lines[index].split("=", 1)[1].strip()

    if current:
        print("  Flycast content path: PRESERVED")
        print(f"    {current}")
        raise SystemExit(0)

    prefix = lines[index].split("=", 1)[0]
    lines[index] = f"{prefix}= {rom_path}"

else:
    headers = [
        i for i, line in enumerate(lines)
        if line.strip() == "[config]"
    ]

    if len(headers) != 1:
        print("  WARNING: Flycast [config] section is ambiguous.")
        print("           Existing config preserved.")
        raise SystemExit(0)

    lines.insert(
        headers[0] + 1,
        f"Dreamcast.ContentPath = {rom_path}"
    )

fd, backup = tempfile.mkstemp(
    prefix="emu.cfg.pre-content-path.",
    dir=flycast.parent
)
os.close(fd)
shutil.copy2(flycast, backup)

flycast.write_text("\n".join(lines) + "\n")

print("  Flycast disc-insertion content path: CONFIGURED")
print(f"    {rom_path}")
print(f"  Previous Flycast config: {backup}")
PYFLYCASTCONTENT


# ------------------------------------------------------------
# Human-readable summary
# ------------------------------------------------------------

echo
echo "BareFront production library layout:"
echo
echo "  Games:"
echo "    $BAREFRONT_DIR/roms/<system>/"
echo
echo "  BIOS / firmware:"
echo "    $BAREFRONT_DIR/bios/<system>/"
echo
echo "  Saves:"
echo "    $BAREFRONT_DIR/saves/<system>/"
echo
echo "  Preview screenshots:"
echo "    $BAREFRONT_DIR/assets/games/<system>/"
echo
echo "  Preview videos:"
echo "    $BAREFRONT_DIR/assets/videos/<system>/"
echo
echo "Stage 4 configuration generation complete."


# ============================================================
# Stage 5A - BIOS / firmware readiness checker
# ============================================================

heading "STAGE 5A / FIRMWARE READINESS"

CHECK_BIOS_SCRIPT="$BAREFRONT_DIR/scripts/check_bios.sh"

echo "Creating BareFront firmware checker..."
echo


cat > "$CHECK_BIOS_SCRIPT" <<'EOF'
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
# Mednafen uses separate BIOS files for Japan and for
# North America/Europe. Stage 5B will validate accepted
# legitimate variants by size, CRC32 and SHA-256.
# ------------------------------------------------------------

SATURN_DIR="$ROOT/bios/saturn"
SATURN_JP="$SATURN_DIR/sega_101.bin"
SATURN_NA_EU="$SATURN_DIR/mpr-17933.bin"

if [[ -f "$SATURN_JP" && -f "$SATURN_NA_EU" ]]; then
    pass "Saturn" "Japan and North America/Europe BIOS files present"
elif [[ -f "$SATURN_JP" ]]; then
    warn "Saturn" "Japan BIOS present; add mpr-17933.bin for NA/Europe"
elif [[ -f "$SATURN_NA_EU" ]]; then
    warn "Saturn" "NA/Europe BIOS present; add sega_101.bin for Japan"
else
    fail "Saturn" "BIOS missing - add sega_101.bin and mpr-17933.bin"
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
EOF


chmod +x "$CHECK_BIOS_SCRIPT"

if [[ ! -x "$CHECK_BIOS_SCRIPT" ]]; then
    die "Could not create the BareFront firmware checker."
fi

echo "Firmware checker created:"
echo "  $CHECK_BIOS_SCRIPT"


# ------------------------------------------------------------
# Syntax-check the generated checker before running it.
# ------------------------------------------------------------

echo
echo "Checking firmware-checker syntax..."

if bash -n "$CHECK_BIOS_SCRIPT"; then
    echo "  Syntax: OK"
else
    die "Generated check_bios.sh contains a shell syntax error."
fi


# ------------------------------------------------------------
# Run the checker now.
#
# This is informational. Missing user-supplied BIOS files should
# not make a fresh BareFront installation itself fail.
# ------------------------------------------------------------

echo
echo "Running initial firmware readiness check..."

"$CHECK_BIOS_SCRIPT"

echo
echo "Stage 5A firmware readiness framework complete."


# ============================================================
# STAGE 6 / BUILD BAREFRONT
# ============================================================

heading "STAGE 6 / BUILD BAREFRONT"

BUILD_SCRIPT="$BAREFRONT_DIR/scripts/build_barefront.sh"
BAREFRONT_BINARY="$BAREFRONT_DIR/barefront"
OVERLAY_SOURCE="$BAREFRONT_DIR/src/overlay_helper.cpp"
OVERLAY_BINARY="$BAREFRONT_DIR/overlay_helper"

if [[ ! -x "$BUILD_SCRIPT" ]]; then
    die "BareFront build script is missing or not executable: $BUILD_SCRIPT"
fi

if [[ ! -f "$OVERLAY_SOURCE" ]]; then
    die "BareFront overlay helper source is missing: $OVERLAY_SOURCE"
fi

echo "Building BareFront from source..."
"$BUILD_SCRIPT"

if [[ ! -x "$BAREFRONT_BINARY" ]]; then
    die "BareFront build completed without producing an executable: $BAREFRONT_BINARY"
fi

if [[ ! -x "$OVERLAY_BINARY" ]]; then
    die "BareFront build completed without producing the overlay helper: $OVERLAY_BINARY"
fi

echo
echo "BareFront executable verified:"
echo "  $BAREFRONT_BINARY"
echo "Presentation overlay helper verified:"
echo "  $OVERLAY_BINARY"
echo
echo "Stage 6 BareFront build complete."


# ============================================================
# STAGE 7 / CAPTURE HELPER
# ============================================================

heading "STAGE 7 / CAPTURE HELPER"

CAPTURE_SOURCE="$BAREFRONT_DIR/src/capture_helper.cpp"
CAPTURE_BINARY="$BAREFRONT_DIR/capture_helper"
CAPTURE_RECORDER="$BAREFRONT_DIR/scripts/capture_gamescope_video.sh"

if [[ ! -f "$CAPTURE_SOURCE" ]]; then
    die "Capture helper source is missing: $CAPTURE_SOURCE"
fi

if [[ ! -f "$CAPTURE_RECORDER" ]]; then
    die "Gamescope capture recorder is missing: $CAPTURE_RECORDER"
fi

chmod +x "$CAPTURE_RECORDER"

if [[ ! -x "$CAPTURE_RECORDER" ]]; then
    die "Gamescope capture recorder is not executable: $CAPTURE_RECORDER"
fi

if [[ ! -x "$CAPTURE_BINARY" || "$CAPTURE_SOURCE" -nt "$CAPTURE_BINARY" ]]; then

    echo "Building BareFront capture helper..."

    g++ -std=c++17 "$CAPTURE_SOURCE" -o "$CAPTURE_BINARY" \
        $(sdl2-config --cflags --libs) \
        -lX11 -lXi

    echo "Action: BUILD"

else

    echo "Capture helper is already built and current."
    echo "Action: SKIP"

fi

if [[ ! -x "$CAPTURE_BINARY" ]]; then
    die "Capture helper build did not produce an executable: $CAPTURE_BINARY"
fi

CAPTURE_COMMANDS=(
    ffmpeg
    gst-launch-1.0
    gst-inspect-1.0
    pw-dump
    pw-link
    python3
    timeout
)

for CAPTURE_COMMAND in "${CAPTURE_COMMANDS[@]}"; do
    if ! command -v "$CAPTURE_COMMAND" >/dev/null 2>&1; then
        die "Capture command is unavailable: $CAPTURE_COMMAND"
    fi
done

CAPTURE_GSTREAMER_ELEMENTS=(
    pipewiresrc
    queue
    videoconvert
    videorate
    videoscale
    identity
    x264enc
    h264parse
    mp4mux
    filesink
)

for CAPTURE_ELEMENT in "${CAPTURE_GSTREAMER_ELEMENTS[@]}"; do
    if ! gst-inspect-1.0 "$CAPTURE_ELEMENT" >/dev/null 2>&1; then
        die "Required GStreamer element is unavailable: $CAPTURE_ELEMENT"
    fi
done

echo
echo "Capture helper verified:"
echo "  $CAPTURE_BINARY"
echo "Gamescope video recorder verified:"
echo "  $CAPTURE_RECORDER"
echo "Capture commands and GStreamer elements: OK"
echo
echo "Keyboard capture controls:"
echo "  P = screenshot"
echo "  R = 5-second video"
echo
echo "Stage 7 capture helper complete."


# ============================================================
# BAREFRONT DESKTOP INTEGRATION
# ============================================================

heading "BAREFRONT DESKTOP INTEGRATION"

ICON_FILE="$BAREFRONT_DIR/assets/icons/barefront.png"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPLICATIONS_DIR/barefront.desktop"

if [[ ! -f "$ICON_FILE" ]]; then
    die "BareFront application icon is missing: $ICON_FILE"
fi

if [[ ! -x "$BAREFRONT_BINARY" ]]; then
    die "BareFront executable is missing: $BAREFRONT_BINARY"
fi

DESKTOP_WORK="$(mktemp -d "$LOG_DIR/barefront-desktop.XXXXXX")"
DESKTOP_CANDIDATE="$DESKTOP_WORK/barefront.desktop"

cat > "$DESKTOP_CANDIDATE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=BareFront
Comment=Curated emulator frontend
Exec=$BAREFRONT_DIR/barefront
Path=$BAREFRONT_DIR
Icon=$ICON_FILE
Terminal=false
Categories=Game;
StartupNotify=false
EOF

if command -v desktop-file-validate >/dev/null 2>&1; then
    if ! desktop-file-validate "$DESKTOP_CANDIDATE"; then
        die "Generated BareFront desktop entry failed validation."
    fi
fi

mkdir -p "$APPLICATIONS_DIR"

if [[ -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" ]]; then

    if [[ ! -L "$DESKTOP_FILE" ]] &&
       cmp -s "$DESKTOP_CANDIDATE" "$DESKTOP_FILE"; then

        echo "BareFront desktop launcher already current."
        echo "Action: SKIP"

    else

        echo "Existing BareFront desktop launcher differs."
        echo "Preserving the user's existing launcher."
        echo "Action: PRESERVE"

    fi

else

    install -m 644 "$DESKTOP_CANDIDATE" "$DESKTOP_FILE"

    echo "BareFront desktop launcher installed:"
    echo "  $DESKTOP_FILE"
    echo "Action: INSTALL"

fi

rm -rf -- "$DESKTOP_WORK"

echo
echo "BareFront desktop integration complete."


# ============================================================
# v0.12 checkpoint
# ============================================================

heading "INSTALLER v0.12 CHECKPOINT"

echo "Completed:"
echo "  Pre-flight checks"
echo "  Common Debian dependencies"
echo "  Gamescope presentation dependencies / PipeWire service"
echo "  Production roms/bios/saves directory structure"
echo "  Debian-managed emulator stage"
echo "  MesenCE stable installation / verification"
echo "  DuckStation stable AppImage installation / verification"
echo "  PCSX2 stable AppImage installation / verification"
echo "  Flycast stable AppImage installation / verification"
echo "  Dreamcast BIOS/flash runtime layout"
echo "  BigPEmu pinned stable installation / verification"
echo "  bsnes v115 stable-source build / verification"
echo "  Amiberry official Debian-package installation / integration"
echo "  PC Engine Mednafen launcher / isolated profile"
echo "  Saturn Mednafen launcher / isolated profile"
echo "  VICE BareFront launcher adapter"
echo "  MAME Arcade / Neo Geo presentation launchers"
echo "  Production barefront.ini generation / validation"
echo "  Firmware readiness checker framework"
echo
echo "Mesen executable:"
echo "  $MESEN_EXE"
echo
echo "Stage 3 emulator installation is complete."
echo "Stage 4 production configuration generation is complete."
echo "Stage 5A firmware readiness checking is complete."
echo
echo "Next:"
echo "  Stage 5B: add verified firmware size / CRC32 / SHA-256"
echo "  recognition tables and accepted legitimate variants."
echo
echo "Installer log:"
echo "  $LOG_FILE"
echo
