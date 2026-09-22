#!/usr/bin/env python3

import ctypes
import ctypes.util
import os
import re
import subprocess
import sys
import time
from pathlib import Path

if "BAREFRONT_FLYCAST_LOG" not in os.environ:
    sys.exit("ERROR: BAREFRONT_FLYCAST_LOG was not provided.")

LOG = Path(os.environ["BAREFRONT_FLYCAST_LOG"])
DESKTOP_DISPLAY = os.environ.get("DISPLAY", ":0")
DELAY = 1.0

def run(*args, display=None):
    env = os.environ.copy()
    env["DISPLAY"] = display if display is not None else DESKTOP_DISPLAY
    env["XAUTHORITY"] = os.environ.get(
        "XAUTHORITY",
        str(Path.home() / ".Xauthority")
    )
    return subprocess.run(
        args, env=env, capture_output=True, text=True, timeout=5
    ).stdout

def dreamcast_gamescope_pid():
    result = run("pgrep", "-f", "^/usr/games/gamescope .*Flycast[.]AppImage")
    matches = []

    for item in result.splitlines():
        try:
            pid = int(item)
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes()
            if b"Flycast.AppImage" in cmdline:
                matches.append(pid)
        except (ValueError, OSError):
            continue

    return matches[0] if len(matches) == 1 else None

def flycast_window_viewable(nested):
    tree = run("xwininfo", "-root", "-tree", display=nested)

    for window in re.findall(
        r'0x[0-9a-fA-F]+\s+"Flycast - [^"]+"', tree
    ):
        wid = window.split()[0]
        details = run("xwininfo", "-id", wid, display=nested)

        if "Map State: IsViewable" in details:
            return wid

    return None

print("Waiting for Flycast's game window...", flush=True)

deadline = time.monotonic() + 25
nested = None
window = None

while time.monotonic() < deadline:
    if not dreamcast_gamescope_pid():
        time.sleep(0.25)
        continue

    contents = LOG.read_text(errors="replace") if LOG.exists() else ""
    match = re.search(r"Starting Xwayland on (:\d+)", contents)

    if match and "Game ID is" in contents:
        nested = match.group(1)
        window = flycast_window_viewable(nested)

        if window:
            break

    time.sleep(0.25)

if not window:
    sys.exit("SKIP: Flycast window was not confirmed. No F8 sent.")

print(f"Flycast window {window} is viewable on {nested}.", flush=True)
print(f"Waiting {DELAY:g} seconds before activation...", flush=True)
time.sleep(DELAY)

pid = dreamcast_gamescope_pid()

if not pid or not flycast_window_viewable(nested):
    sys.exit("SKIP: Dreamcast session is no longer ready. No F8 sent.")

active = run("xprop", "-root", "_NET_ACTIVE_WINDOW")
ids = [
    wid for wid in re.findall(r"0x[0-9a-fA-F]+", active)
    if int(wid, 16) != 0
]

focused_gamescope = False

for wid in ids:
    properties = run(
        "xprop", "-id", wid,
        "WM_CLASS", "WM_NAME", "_NET_WM_PID"
    )

    if (
        "gamescope" in properties.lower()
        or re.search(rf"_NET_WM_PID.*=\s*{pid}\b", properties)
    ):
        focused_gamescope = True
        print(f"Confirmed focused Gamescope window: {wid}", flush=True)
        break

if not focused_gamescope:
    print(f"Active-window report: {active.strip()}", flush=True)
    sys.exit("SKIP: Gamescope focus not confirmed. No F8 sent.")

x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
xtst = ctypes.CDLL(ctypes.util.find_library("Xtst"))

x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
x11.XStringToKeysym.restype = ctypes.c_ulong
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XKeysymToKeycode.restype = ctypes.c_uint
x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
x11.XCloseDisplay.argtypes = [ctypes.c_void_p]

xtst.XTestFakeKeyEvent.argtypes = [
    ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong
]
xtst.XTestFakeKeyEvent.restype = ctypes.c_int

display = x11.XOpenDisplay(DESKTOP_DISPLAY.encode())

if not display:
    sys.exit("ERROR: cannot open desktop display.")

try:
    keycode = x11.XKeysymToKeycode(
        display, x11.XStringToKeysym(b"F8")
    )

    if not keycode:
        sys.exit("ERROR: F8 keycode unavailable.")

    print("Sending automatic F8 now...", flush=True)

    pressed = xtst.XTestFakeKeyEvent(display, keycode, 1, 0)
    x11.XSync(display, 0)

    # Hold F8 long enough for a frame-based key-state check.
    try:
        time.sleep(0.25)
    finally:
        released = xtst.XTestFakeKeyEvent(display, keycode, 0, 0)
        x11.XSync(display, 0)

    if not pressed or not released:
        sys.exit("ERROR: XTEST did not accept the keypress.")

    print("PASS: automatic F8 keypress sent.", flush=True)

finally:
    x11.XCloseDisplay(display)
