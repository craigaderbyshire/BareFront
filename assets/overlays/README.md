# BareFront presentation overlays

BareFront's first release targets **1920 × 1080 output**.

Emulators render their native image without internal visual filtering.
Gamescope owns presentation and integer scaling. Optional external
shaders and overlays sit outside the emulator.

Plain black is the default presentation. Original artwork is retained
for users who prefer a decorated surround.

## Choosing an overlay

The editable configuration is:

    assets/overlays/overlays.ini

To create it on a fresh installation:

    cp assets/overlays/overlays.ini.example assets/overlays/overlays.ini

Edit the existing file if you already have one. Do not overwrite it.

Each entry selects artwork for a system:

    nes=plain/nes.png
    snes=plain/snes.png
    c64=plain/c64.png

Paths are relative to `assets/overlays/`. For custom artwork, create
a `custom/` directory and select a PNG within it:

    snes=custom/my-snes.png

Personal `overlays.ini` is ignored by Git. Missing system entries use
their built-in defaults, so a personal file does not need all 16 lines.

Changes are read when the next game launches.

## Twelve measured-overlay systems

These systems use BareFront's X11 presentation overlay helper.
The gameplay aperture must remain completely transparent.

| System | Transparent aperture (x, y, width, height) |
| --- | --- |
| Atari 2600 | 320, 84, 1280, 912 |
| Dreamcast | 320, 60, 1280, 960 |
| GameCube | 320, 60, 1280, 960 |
| Jaguar | 320, 60, 1280, 960 |
| Master System | 448, 156, 1024, 768 |
| Mega Drive | 320, 92, 1280, 896 |
| NES | 448, 60, 1024, 960 |
| PC Engine | 384, 76, 1152, 928 |
| PlayStation | 320, 60, 1280, 960 |
| PlayStation 2 | 320, 60, 1280, 960 |
| Saturn | 256, 60, 1408, 960 |
| SNES | 448, 92, 1024, 896 |

Custom images must be 1920 × 1080 PNGs. BareFront validates
their dimensions and transparent gameplay aperture before use.
Invalid selections fall back to the system's plain template.

The original top-level PNGs and `branding/` artwork are retained.
Automatic branding is disabled. The optional `examples/nes.png`
combines NES artwork into a single validated presentation image.

## Commodore 64

C64 uses the same `c64=` mapping, but its artwork is composited
through the existing vkBasalt bezel shader—not an X11 overlay window.

Default:

    c64=plain/c64.png

Original artwork:

    c64=examples/c64.png

Custom C64 artwork must be 1920 × 1080 and preserve the exact
per-pixel alpha mask of `plain/c64.png`, including partially
transparent pixels. Artwork colours may change; the mask may not.

The validator rejects incompatible files and falls back to the
plain texture. A session-local texture is removed on exit.

This preserves the approved C64 PAL timing, Gamescope presentation
and shader-based bezel path.

## Systems without a fixed overlay

    amiga=none
    arcade=none
    neogeo=none

Amiga uses its approved full-screen presentation. Arcade and Neo Geo
retain their existing presentation without a fixed overlay.

These entries document their defaults. The frontend enforces the
no-X11-overlay rule for these systems; `none` is not a general
on/off setting for the twelve measured systems or C64.

## Scope and controls

This release is 1080p only. There is no output-resolution cycling
in this milestone.

Esc returns directly to BareFront. Overlay selection does not alter
emulator scaling, external shader selection, or capture controls.
