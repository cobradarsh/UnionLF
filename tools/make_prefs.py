#!/usr/bin/env python3
"""Build Atelier's plist-only Settings page, and its icon.

Plist-only, like Wingman, Dynamic Stage+ and Chakra: the page has no compiled code.
Every control posts com.adarsh.atelier/prefs, and SpringBoard re-reads the settings
the moment you change something - no respring.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
        python3 tools/make_prefs.py --icons layout/Library/PreferenceLoader/Preferences
        (the second form also draws Atelier.png / @2x / @3x; it needs Pillow, so it is run
         on the PC and the pictures are committed. CI only checks the plist.)
"""

import os
import plistlib
import sys

D = "com.adarsh.atelier"
NOTE = "com.adarsh.atelier/prefs"

args = [a for a in sys.argv[1:] if not a.startswith("--")]
OUT = args[0] if args else "layout/Library/PreferenceLoader/Preferences"


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


def slider(key, lo, hi, default):
    return {"cell": "PSSliderCell", "defaults": D, "key": key, "min": lo, "max": hi,
            "default": default, "showValue": True, "PostNotification": NOTE}


def choice(key, label, default, options):
    return {"cell": "PSLinkListCell", "detail": "PSListItemsController", "defaults": D, "key": key,
            "label": label, "default": default, "PostNotification": NOTE,
            "validValues": [v for v, _ in options], "validTitles": [t for _, t in options]}


def segments(key, default, options):
    return {"cell": "PSSegmentCell", "defaults": D, "key": key, "default": default, "PostNotification": NOTE,
            "validValues": [v for v, _ in options], "validTitles": [t for _, t in options]}


items = [
    group(None,
          "A workbench of live apps: one big app and up to four mini tiles. Tap a mini and it "
          "changes places with the big one.\n\n"
          "To open it, slide a finger in from the edge of the screen just above the bottom "
          "corner (or up along that edge). Or hold an app's icon on the Home Screen and choose "
          "Open in Atelier.\n\n"
          "The pill with three dots above the big app is its menu: Full Screen, Switch Layout, "
          "Replace App, Close App, Save as Set. Hold a mini for its own menu. A swipe up from "
          "the bottom of the screen puts the bench away."),
    switch("enabled", "Atelier", True),

    group("Layout",
          "Side: minis in a column on the left. Top: minis in a row across the top. "
          "Split: two apps next to each other, both usable at once.\n\n"
          "Normally every app keeps its full size and the bench shows it smaller, which works "
          "with every app. Resize Apps to Fit instead asks apps to lay themselves out at the "
          "size of their tile: the big app fills the width in Top, and Split becomes one app "
          "above the other. Apps that can't change size may look cut off or stretched; switch "
          "it off again if one does."),
    choice("layout", "Layout", 0, [(0, "Side"), (1, "Top"), (2, "Split")]),
    switch("resizeApps", "Resize Apps to Fit (Beta)", False),

    group("Mini Tiles",
          "Smart: minis are live while you use the bench, turn into still pictures after the "
          "pause set below, and wake when you touch the bench again. Their apps are suspended "
          "while they are stills, so they cost no battery.\n\n"
          "Always Live: every app on the bench keeps running. Uses the most battery.\n\n"
          "Stills Only: only the big app runs; a mini is refreshed when it comes off the big tile."),
    choice("miniMode", "Minis", 0, [(0, "Smart"), (1, "Always Live"), (2, "Stills Only")]),
    group("Seconds Before Minis Freeze (Smart)"),
    slider("freezeAfter", 5, 60, 20),

    group("Opening",
          "The edge strip is see-through, 16 points wide. It takes touches where it lies, so "
          "keep it only as tall as you need. The same swipe closes the bench.\n\n"
          "Bring the Current App Along: the app you are in when you open the bench becomes "
          "the big app.\n\n"
          "Icon Menu: Open in Atelier, your sets, and Atelier Sets… when you hold an app's icon."),
    switch("trigger", "Edge Swipe", True),
    segments("triggerSide", 1, [(0, "Left Edge"), (1, "Right Edge")]),
    group("Height of the Strip"),
    slider("triggerSize", 60, 220, 110),
    group(),
    switch("addFront", "Bring the Current App Along", True),
    switch("iconMenu", "Icon Menu", True),

    group("Feel"),
    choice("haptics", "Haptics", 1, [(0, "Off"), (1, "Light"), (2, "Medium"), (3, "Firm")]),

    group("Troubleshooting",
          "Records what Atelier does in /var/mobile/Library/Logs/Atelier.log, and lets test "
          "commands be sent to it over SSH.\n\n"
          "If SpringBoard restarts right after Atelier starts, three times in a row, Atelier "
          "stays out of the way. Flip any switch on this page to start it again."),
    switch("debugLog", "Debug Log", True),
]

page = {
    "entry": {"cell": "PSLinkCell", "label": "Atelier", "icon": "Atelier.png"},
    "title": "Atelier",
    "items": items,
}

os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "Atelier.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  Atelier.plist      {os.path.getsize(path):6d} bytes  OK  ({len(items)} rows)")

if "--icons" in sys.argv:
    from PIL import Image, ImageDraw               # only needed for the pictures

    def icon(px):
        big = px * 8                                # drawn large, then scaled down for smooth edges
        img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.225), fill=(72, 61, 196, 255))
        u = big / 29.0
        # three minis on the left, the main tile on the right
        for i in range(3):
            top = 6.2 + i * 5.9
            d.rounded_rectangle([5.0 * u, top * u, 9.6 * u, (top + 4.6) * u], radius=int(1.1 * u), fill=(255, 255, 255, 150))
        d.rounded_rectangle([11.4 * u, 6.2 * u, 24.0 * u, 22.6 * u], radius=int(2.0 * u), fill=(255, 255, 255, 255))
        return img.resize((px, px), Image.LANCZOS)

    for name, px in (("Atelier.png", 29), ("Atelier@2x.png", 58), ("Atelier@3x.png", 87)):
        icon(px).save(os.path.join(OUT, name))
        print(f"  {name:18s} {px}x{px}")
