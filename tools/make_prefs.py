#!/usr/bin/env python3
"""Build Guest Mode's Settings page (a plist, no compiled code) and its icon.

Every control posts com.adarsh.guestmode/prefs; Photos re-reads the settings the moment
something changes, so nothing has to be restarted.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
        python3 tools/make_prefs.py --icons layout/Library/PreferenceLoader/Preferences
        (the second form also draws GuestMode.png / @2x / @3x and art/guestmode-icon.png; it needs
         Pillow, so it is run on the PC and the pictures are committed. CI only checks the plist.)
        python3 tools/make_prefs.py --dump <folder>
        (also prints the page as Settings will list it)
"""

import os
import plistlib
import sys

D = "com.adarsh.guestmode"
NOTE = "com.adarsh.guestmode/prefs"
VERSION = "1.1.0"

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


def choice(key, label, default, options):
    return {"cell": "PSLinkListCell", "detail": "PSListItemsController", "defaults": D, "key": key,
            "label": label, "default": default, "PostNotification": NOTE,
            "validValues": [v for v, _ in options], "validTitles": [t for _, t in options]}


items = [
    group(None,
          "Guest Mode lets someone look at a few photos on your iPhone without the rest of "
          "your library, or the rest of your iPhone, within reach.\n\n"
          "1. In Photos, tap the round Guest Mode button and choose up to 10 photos or videos. "
          "The button turns blue and shows how many.\n"
          "2. Tap the button again. After Face ID, Photos shows only what you chose: a small "
          "gallery to swipe through, zoom and play. There is nothing else to scroll to, and "
          "nothing to share, edit or delete.\n"
          "3. Tap the button (now a lock) once more. After Face ID, Photos is back to normal "
          "and the selection is forgotten.\n\n"
          "Hold the button to change or clear the selection. Drag it to move it.\n\n"
          "Guest Mode stays on when Photos is closed and opened again."),
    switch("enabled", "Guest Mode Button", True),

    group("While Guest Mode Is On",
          "Stay in Photos switches off the Home gesture, the App Switcher, Control Centre, "
          "Notification Centre, Siri, screenshots and the double click for Wallet, and brings "
          "Photos straight back if anything else gets in front. Only Face ID on the Guest Mode "
          "button ends it.\n\n"
          "Held notifications make no sound and show nowhere; they all arrive when Guest Mode "
          "ends. A declined call lands in Recents as a missed call.\n\n"
          "The side button still locks the iPhone; unlocking it leads back to the same photos. "
          "Emergency SOS keeps working. Should Photos itself fail while Guest Mode is on, the "
          "iPhone locks its screen and lets go, so you are never shut out of it."),
    switch("lockdown", "Stay in Photos", True),
    switch("holdNotifications", "Hold Notifications", True),
    switch("declineCalls", "Decline Calls", True),

    group("Button",
          "Switching the button off does not end a Guest Mode that is on: only Face ID does.\n\n"
          "Guest Mode " + VERSION),
    choice("buttonSize", "Size", 46, [(40, "Small"), (46, "Medium"), (54, "Large")]),
    choice("buttonDim", "When Nothing Is Chosen", 0.85, [(1.0, "Solid"), (0.85, "Slightly See-Through"), (0.55, "Faint")]),
]

page = {
    "entry": {"cell": "PSLinkCell", "label": "Guest Mode", "icon": "GuestMode.png"},
    "title": "Guest Mode",
    "items": items,
}

os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "GuestMode.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  GuestMode.plist    {os.path.getsize(path):6d} bytes  OK  ({len(items)} rows)")

if "--dump" in sys.argv:
    with open(path, "rb") as f:
        made = plistlib.load(f)
    print(f"entry in Settings: \"{made['entry']['label']}\" (cell {made['entry']['cell']}, icon {made['entry']['icon']})")
    print(f"page title: \"{made['title']}\"")
    for row in made["items"]:
        kind = row["cell"]
        if kind == "PSGroupCell":
            print(f"  -- {row.get('label', '')}")
            continue
        extra = ""
        if "validTitles" in row:
            extra += " [" + " | ".join(str(t) for t in row["validTitles"]) + "]"
        default = row.get("default", "")
        print(f"     {kind:15s} {row.get('label', '(no label)'):26s} key {row.get('key', '-'):18s} default {default!r}{extra}")

if "--icons" in sys.argv:
    from PIL import Image, ImageDraw  # only needed for the pictures

    def icon(px, rounded=True):
        """A white head and shoulders with a small amber padlock, on an indigo-to-blue square."""
        big = px * 8 if px < 200 else px * 3        # drawn large, then scaled down for smooth edges
        ground = Image.new("RGBA", (big, big))
        gd = ImageDraw.Draw(ground)
        top, bottom = (104, 92, 232), (30, 126, 248)
        for y in range(big):
            t = y / (big - 1)
            gd.line([(0, y), (big, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
        mask = Image.new("L", (big, big), 0)
        if rounded:
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.225), fill=255)
        else:
            mask.paste(255, [0, 0, big, big])

        # the person: a head, and shoulders cut off by the bottom of the square
        person = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        pd = ImageDraw.Draw(person)
        white = (255, 255, 255, 255)
        cx = big * 0.44
        hr = big * 0.155
        pd.ellipse([cx - hr, big * 0.215 - hr + hr, cx + hr, big * 0.215 + hr + hr], fill=white)
        sw, st = big * 0.30, big * 0.60
        pd.rounded_rectangle([cx - sw, st, cx + sw, big * 1.2], radius=int(big * 0.22), fill=white)

        # the padlock, with a ring of the background colour around it so it reads as a badge
        lx, ly = big * 0.715, big * 0.70             # centre of the lock's body
        bw, bh = big * 0.135, big * 0.105            # half width, half height of the body
        ring = big * 0.045
        hole = (0, 0, 0, 0)
        pd.rounded_rectangle([lx - bw - ring, ly - bh - ring, lx + bw + ring, ly + bh + ring], radius=int(big * 0.06), fill=hole)
        sr = big * 0.085                              # the shackle's outer radius
        pd.ellipse([lx - sr - ring, ly - bh - sr * 1.15 - ring, lx + sr + ring, ly - bh + sr * 0.85 + ring], fill=hole)

        img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        img.paste(ground, (0, 0), mask)
        shown = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        shown.paste(person, (0, 0), mask)
        img = Image.alpha_composite(img, shown)

        d = ImageDraw.Draw(img)
        amber = (255, 190, 48, 255)
        thick = int(round(big * 0.036))
        d.arc([lx - sr, ly - bh - sr * 1.15, lx + sr, ly - bh + sr * 0.85], start=180, end=360, fill=amber, width=thick)
        d.line([(lx - sr + thick / 2 - 1, ly - bh - sr * 0.15), (lx - sr + thick / 2 - 1, ly - bh + 2)], fill=amber, width=thick)
        d.line([(lx + sr - thick / 2, ly - bh - sr * 0.15), (lx + sr - thick / 2, ly - bh + 2)], fill=amber, width=thick)
        d.rounded_rectangle([lx - bw, ly - bh, lx + bw, ly + bh], radius=int(big * 0.035), fill=amber)
        kr = big * 0.026
        d.ellipse([lx - kr, ly - kr * 1.3, lx + kr, ly + kr * 0.7], fill=(120, 76, 0, 255))
        out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        out.paste(img, (0, 0), mask)
        return out.resize((px, px), Image.LANCZOS)

    for name, px in (("GuestMode.png", 29), ("GuestMode@2x.png", 58), ("GuestMode@3x.png", 87)):
        icon(px).save(os.path.join(OUT, name))
        print(f"  {name:18s} {px}x{px}")
    os.makedirs("art", exist_ok=True)
    icon(512).save("art/guestmode-icon.png")
    print("  art/guestmode-icon.png 512x512")
