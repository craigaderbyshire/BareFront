BAREFRONT CAPTURE V2
====================

Controls while an emulator is running:

Keyboard:
  P = snapshot
  R = record exactly 5 seconds

Controller:
  Select + Left  = snapshot
  Select + Right = record exactly 5 seconds


WHAT CHANGED
------------
Capture no longer blindly forces everything into 640x480 / 4:3.

BareFront now uses two sensible preview limits:

  240p-era systems:
    max 320x240

  PS1 / Saturn / Dreamcast / PS2 / GameCube:
    max 640x480

The capture helper preserves the game's natural aspect ratio and orientation.

Examples:
  4:3       -> 320x240 or 640x480
  16:9      -> 320x180 or 640x360
  portrait  -> about 180x240 or 360x480

The helper also looks for solid black presentation bars around a fullscreen
emulator image and removes those outer bars before saving the media.

It never deliberately stretches a game to 4:3.

This is preparation for Arcade TATE support: portrait videos stay portrait,
so BareFront can later rotate the same CRT artwork by 90 degrees.


FILES
-----
Snapshots:
  assets/games/<system>/<exact ROM stem>.png

Videos:
  assets/videos/<system>/<exact ROM stem>.mp4


SETUP
-----
1. Copy this update over the BareFront folder.

2. From ~/BareFront run:

   ./scripts/setup_capture.sh

3. Recompile BareFront:

   g++ -std=c++17 src/main.cpp -o barefront \
   $(sdl2-config --cflags --libs) \
   -lSDL2_ttf -lSDL2_image

4. Run:

   ./barefront


NOTES
-----
- The capture helper remains X11-based for the current Debian XFCE VM.
- A missing helper never prevents games launching.
- Existing screenshots/videos are untouched.
- Video playback inside the CRT is the next separate step.
