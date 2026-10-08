# BareFront

**BareFront launches. Emulators emulate. Gamescope presents.**

BareFront is a lightweight, curated Linux emulator frontend built around a simple idea: keep the frontend out of the emulator's job, keep the emulator out of the display's job, and make getting into a game as direct as possible.

It is designed for a dedicated 1080p retro-gaming machine running Debian 13.

## Status

BareFront is currently preparing for public beta.

Supported platform:

- Debian 13 (Trixie)
- amd64 / x86-64
- 1920x1080 output

## Presentation

BareFront deliberately keeps presentation outside the emulator.

Emulators run at **1x native resolution** for the emulated system. Gamescope then applies the largest whole-number integer scale that fits inside a **1920x1080** output.

There is no emulator-side stretching or presentation filtering.

External CRT shaders are applied outside the emulator.

Available shader presets are:

- NONE
- BARECRT
- CRT-LITE
- CRT-LOTTES

The default on first run is **NONE**.

Shader selection is stored per system and is chosen from the games list with **Y**. The selected preset is applied the next time a game is launched.

BareFront currently targets 1080p only. 1440p and 4K output switching are not part of the current release.

## Supported systems

BareFront currently supports:

- Mega Drive
- NES
- SNES
- PlayStation
- PlayStation 2
- Master System
- Atari 2600
- Commodore 64
- Arcade
- Neo Geo
- Dreamcast
- Saturn
- PC Engine
- Jaguar
- GameCube
- Amiga

## BareFront controls

### Menus

| Controller | Keyboard | Action |
|---|---|---|
| D-pad | Arrow keys | Navigate |
| A | Enter | Select |
| B | Esc | Back |

### Games list

The normal menu controls still apply.

| Controller | Action |
|---|---|
| X | Toggle favourite |
| Y | Open shader selection |

## In-game controls

### Return to BareFront

| Controller | Keyboard | Action |
|---|---|---|
| Hold Xbox Guide | Esc | Exit the game directly to BareFront |

### Screenshot and preview video

| Controller | Keyboard | Action |
|---|---|---|
| View + D-pad Left | P | Capture screenshot |
| View + D-pad Right | R | Record a 5-second preview video |

### Disc control

For supported disc, CD and DVD based systems:

| Controller | Action |
|---|---|
| LB + RB + Y | Next disc |
| LB + RB + X | Previous disc |

### On-screen keyboard

For Commodore 64 and Amiga:

| Controller | Action |
|---|---|
| LB + RB + B | Open on-screen keyboard |

## Exiting BareFront

From the BareFront frontend itself:

- **Esc** exits BareFront.
- **View + Menu together** exits BareFront.

On an Xbox controller, **View** is the small button to the left of Guide and **Menu** is the small button to the right of Guide.

## Games, ROMs and firmware

BareFront does **not** include ROMs, games, BIOS files or firmware.

BareFront does not download copyrighted game content or system firmware. Users provide their own legally obtained content.

The normal local game library lives under:

```text
roms/
```

BareFront can also use an optional SMB/CIFS network share for game content.

## Installation

BareFront currently supports Debian 13 (Trixie) on amd64/x86-64 systems.

Install it from a normal user account. Do **not** run the whole installer with `sudo`; it will request `sudo` access itself when required.

```bash
git clone --branch installer-v0.12 --single-branch https://github.com/craigaderbyshire/BareFront.git
cd BareFront
./scripts/install_barefront.sh
```

The installer installs and configures BareFront's supported emulators, presentation runtime and required dependencies.

It will also offer optional SMB/CIFS network-share setup for game content.

When installation is complete, BareFront is available from the desktop application menu.

## Configuration

The installer generates the production `barefront.ini`.

`barefront.ini.example` documents the expected configuration format and system layout.

## Project philosophy

BareFront is intentionally opinionated.

The aim is not to expose every emulator option. The aim is to provide a small, curated collection of systems with consistent controls, predictable presentation and a direct route from the frontend into the game and back again.

BareFront fronts.

Emulators emulate.

Gamescope presents.

## Licence

BareFront original source code and documentation are licensed under the **GNU General Public License v3.0 or later (GPL-3.0-or-later)**.

See `LICENSE` for the full licence text.

Third-party components and bundled assets retain their own licences and attribution. Where applicable, those licences are included alongside the relevant files.
