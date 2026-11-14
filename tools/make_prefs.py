#!/usr/bin/env python3
"""Build BluetoothNoClicks' plist-only Settings page (and its icon).

Plist-only, like Wingman and Dynamic Stage+: Preferences.app is arm64e and a
preference *bundle* would need a compiled binary; a plist has none, so it
always loads.

Every switch posts com.adarsh.bluetoothnoclicks/prefs, and SpringBoard re-reads
the settings the moment you flip something - no respring.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
"""

import math
import os
import plistlib
import struct
import sys
import zlib

OUT = sys.argv[1] if len(sys.argv) > 1 else "layout/Library/PreferenceLoader/Preferences"
D = "com.adarsh.bluetoothnoclicks"
NOTE = "com.adarsh.bluetoothnoclicks/prefs"


def group(label=None, footer=None):
    g = {"cell": "PSGroupCell"}
    if label:
        g["label"] = label
    if footer:
        g["footerText"] = footer
    return g


def switch(key, label, default):
    return {"cell": "PSSwitchCell", "defaults": D, "key": key, "label": label,
            "default": default, "PostNotification": NOTE}


items = [
    group("Keyboard",
          "While sound goes to AirPods or any other Bluetooth device, Keyboard "
          "Feedback → Sound (Sounds & Haptics) is switched off. It goes back to "
          "how you had it as soon as the sound leaves Bluetooth. If you keep "
          "keyboard sounds off yourself, they stay off."),
    switch("kbClicks", "Mute Clicks on Bluetooth", True),

    group("Calls",
          "While you're on a call, notifications arrive without their sound, in "
          "Ring and in Silent mode. Alarms, timers and critical alerts still play.\n\n"
          "Only on the Earpiece: keep the sounds when the call is on speaker, "
          "AirPods or the car.\n\n"
          "Vibrate Instead: a short buzz replaces the muted sound."),
    switch("callMute", "Mute Notification Sounds", True),
    switch("callEarpieceOnly", "Only on the Earpiece", False),
    switch("callVibrate", "Vibrate Instead", True),

    group("Troubleshooting",
          "Records what the tweak does in "
          "/var/mobile/Library/Logs/BluetoothNoClicks.log. Turn it off when "
          "everything works."),
    switch("debugLog", "Debug Log", True),
]

page = {
    "entry": {"cell": "PSLinkCell", "label": "BluetoothNoClicks", "icon": "BluetoothNoClicks.png"},
    "title": "BluetoothNoClicks",
    "items": items,
}


# ---- icon: blue rounded square, white speaker with an x (drawn with the standard library only) ----

def _seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def _in_poly(px, py, pts):
    inside = False
    j = len(pts) - 1
    for i in range(len(pts)):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def _in_round_rect(px, py, x0, y0, x1, y1, r):
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    return math.hypot(px - cx, py - cy) <= r


SPEAKER = [(0.17, 0.40), (0.31, 0.40), (0.48, 0.25), (0.48, 0.75), (0.31, 0.60), (0.17, 0.60)]
CROSS = [((0.61, 0.39), (0.83, 0.61)), ((0.83, 0.39), (0.61, 0.61))]
BLUE = (0x0A, 0x84, 0xFF)


def _sample(u, v):
    """(inside the square, on the glyph) for a point in the unit square."""
    if not _in_round_rect(u, v, 0.0, 0.0, 1.0, 1.0, 0.225):
        return False, False
    glyph = _in_poly(u, v, SPEAKER) or any(_seg_dist(u, v, ax, ay, bx, by) <= 0.042
                                           for (ax, ay), (bx, by) in CROSS)
    return True, glyph


def _png(size, ss=4):
    rows = []
    for y in range(size):
        row = bytearray([0])                       # filter: none
        for x in range(size):
            cover = white = 0
            for sy in range(ss):
                for sx in range(ss):
                    inside, glyph = _sample((x + (sx + 0.5) / ss) / size, (y + (sy + 0.5) / ss) / size)
                    cover += inside
                    white += glyph
            n = ss * ss
            if cover == 0:
                row += bytes(4)
                continue
            mix = white / cover
            row += bytes([round(c + (255 - c) * mix) for c in BLUE] + [round(255 * cover / n)])
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
            + chunk(b"IEND", b""))


os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "BluetoothNoClicks.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  BluetoothNoClicks.plist       {os.path.getsize(path):6d} bytes  OK")
for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
    path = os.path.join(OUT, f"BluetoothNoClicks{suffix}.png")
    with open(path, "wb") as f:
        f.write(_png(29 * scale))
    print(f"  {os.path.basename(path):29} {os.path.getsize(path):6d} bytes")
