# BareFront Vector Layout Templates

These layouts are reusable MAME screen-positioning templates for vector arcade games.

They contain no bezel, backdrop, overlay or image artwork.

## Horizontal

Path:

    horizontal/default.lay

Designed for a 4:3 vector monitor on a 1920x1080 output.

Screen area:

    1280 x 960
    x = 320
    y = 60

## Vertical

Path:

    vertical/default.lay

Designed for a 3:4 vector monitor on a 1920x1080 output.

Screen area:

    720 x 960
    x = 600
    y = 60

## How to use

Choose the layout matching the game's monitor orientation.

Copy `default.lay` into a ZIP named after the MAME ROM set.

Example:

    artwork/asteroid.zip
        default.lay

or:

    artwork/tempest.zip
        default.lay

No PNG files are required for games that only need screen sizing and positioning.

Some vector cabinets relied on physical artwork as part of their original presentation.
Those games may require additional image assets as well as a layout.

Examples include:

- Armor Attack
- Asteroids Deluxe
- Star Castle

Do not replace genuine cabinet artwork with these generic layouts where that artwork is
important to the intended presentation.

These templates were visually accepted on BareFront at 1920x1080 output.
