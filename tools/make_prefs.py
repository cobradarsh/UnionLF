#!/usr/bin/env python3
"""Build Dynamic Stage+'s plist-only Settings page (and its icon).

Plist-only, like Wingman: Preferences.app is arm64e and a preference *bundle*
would need a compiled binary; a plist has none, so it always loads.

Every cell posts com.adarsh.stageduoplus/prefs, and SpringBoard re-reads the
settings the moment you flip something - no respring.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
"""

import os
import plistlib
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "layout/Library/PreferenceLoader/Preferences"
D = "com.adarsh.stageduoplus"
NOTE = "com.adarsh.stageduoplus/prefs"


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


def segment(key, titles, default=0):
    return {"cell": "PSSegmentCell", "defaults": D, "key": key, "default": default,
            "validValues": list(range(len(titles))), "validTitles": titles,
            "PostNotification": NOTE}


def slider(key, default, lo, hi):
    return {"cell": "PSSliderCell", "defaults": D, "key": key, "default": default,
            "min": lo, "max": hi, "showValue": True, "PostNotification": NOTE}


items = [
    group("Dynamic Stage+",
          "An add-on for Dynamic Stage 1.2. Changes apply right away, no respring."),
    switch("enabled", "Enabled", True),

    group("Hide-Keyboard Button",
          "A floating button appears while the keyboard is up. Tap it to hide the "
          "keyboard. Drag it anywhere: it snaps to the nearest edge and remembers "
          "the spot. Long-press it while two apps are open to swap them."),
    switch("kbButton", "Show the Button", True),
    switch("kbOnlyInStage", "Only When Two Apps Are Open", False),
    group("Button Size"),
    slider("kbButtonSize", 46, 34, 64),

    group("Auto-Swap",
          "Moves the app you're using in the bottom window up to the top, and the "
          "top app down to the bottom.\n\n"
          "When Typing: only when you tap a text box in the bottom app, so the "
          "keyboard never covers what you're typing.\n\n"
          "Any Tap: as soon as you touch the bottom app. That first touch moves the "
          "app; it doesn't also tap whatever was under your finger."),
    segment("swapMode", ["Off", "When Typing", "Any Tap"], 0),
    switch("refocusAfterSwap", "Reopen Keyboard After Swap", True),

    group("App Pairs",
          "Long-press an app icon and choose App Pairs… to pair it with another app. "
          "Then long-press either app's icon and choose Open with …: the first app "
          "opens on top and the second in the Dynamic Stage window."),
    switch("pairsEnabled", "Show in Icon Menus", True),

    group("Troubleshooting",
          "Records what Dynamic Stage+ does in /var/mobile/Library/Logs/StageDuoPlus.log. "
          "If a swap or a pair doesn't work, send that file."),
    switch("debugLog", "Debug Log", True),
]

page = {
    "entry": {"cell": "PSLinkCell", "label": "Dynamic Stage+", "icon": "StageDuoPlus.png"},
    "title": "Dynamic Stage+",
    "items": items,
}


def make_icons(out):
    """29pt Settings icon: purple rounded square with a split-window glyph."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("  (Pillow missing: icons not regenerated)")
        return
    for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
        s = 29 * scale
        big = s * 4                      # draw large, downsample = smooth edges
        img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.225), fill=(0x7C, 0x5C, 0xFF, 255))
        m = int(big * 0.20)
        gap = int(big * 0.06)
        mid = big // 2
        r = int(big * 0.07)
        d.rounded_rectangle([m, m, big - m, mid - gap // 2], radius=r, fill=(255, 255, 255, 255))
        d.rounded_rectangle([m, mid + gap // 2, big - m, big - m], radius=r, fill=(255, 255, 255, 170))
        img = img.resize((s, s), Image.LANCZOS)
        path = os.path.join(out, f"StageDuoPlus{suffix}.png")
        img.save(path)
        print(f"  {os.path.basename(path):24} {os.path.getsize(path):6d} bytes")


os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "StageDuoPlus.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                     # prove it parses
print(f"  StageDuoPlus.plist       {os.path.getsize(path):6d} bytes  OK")
make_icons(OUT)
