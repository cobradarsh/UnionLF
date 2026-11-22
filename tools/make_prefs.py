#!/usr/bin/env python3
"""Build Shani's Settings page (a plist, no compiled code) and its icon.

Every control posts com.adarsh.shani/prefs, and SpringBoard re-reads the settings the moment
something changes: no respring.

The one row a plist cannot serve by itself, "Apps & Log", names a class of ShaniPrefs.dylib
(PrefsHelper.m), which is loaded into the Settings app.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
        python3 tools/make_prefs.py --icons layout/Library/PreferenceLoader/Preferences
        (the second form also draws Shani.png / @2x / @3x and art/shani-icon.png; it needs
         Pillow, so it is run on the PC and the pictures are committed. CI only checks the plist.)
        python3 tools/make_prefs.py --dump <folder>
        (also prints the page as Settings will list it)
"""

import os
import plistlib
import sys

D = "com.adarsh.shani"
NOTE = "com.adarsh.shani/prefs"

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


def number(key, label, placeholder):
    return {"cell": "PSEditTextCell", "defaults": D, "key": key, "label": label,
            "placeholder": placeholder, "default": "", "keyboard": "numbers",
            "noAutoCorrect": True, "PostNotification": NOTE}


def screen(cls, label):
    """A row that opens one of ShaniPrefs.dylib's screens.

    PSLinkListCell, not PSLinkCell: in a plist-only page PreferenceLoader (libprefs,
    -[PLCustomListController specifiers]) gives every PSLinkCell row without a `bundle` its own
    page class as the controller, whatever `detail` says, and that page then reports an error.
    A PSLinkListCell is left alone (found with Atelier 1.1.0 on the same phone)."""
    return {"cell": "PSLinkListCell", "detail": cls, "label": label}


items = [
    group(None,
          "Shani makes an app's notifications wait.\n\n"
          "Swipe a notification to the left and tap Shani, next to Clear. Or hold the "
          "notification down and choose Shani among its actions. It works on the Lock Screen "
          "too. That app is then on Shani's list: its notifications are kept back, without "
          "banner, sound or screen wake, for the time set below, and come up when the time "
          "is over.\n\n"
          "On a notification of an app that is being silenced the button says Shani Off."),
    switch("enabled", "Shani", True),

    group("How Long",
          "How long notifications are kept back. A number typed into Custom wins over the "
          "list; clear the field to use the list again. A hold that is already running keeps "
          "the length it started with."),
    choice("minutes", "Silence For", 60,
           [(5, "5 minutes"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"),
            (240, "4 hours"), (480, "8 hours"), (720, "12 hours"), (1440, "1 day")]),
    number("customMinutes", "Custom (minutes)", "for example 45"),

    group("When the Silence Starts",
          "With Each New Notification: the app stays on the list. Its next notification "
          "starts the clock; that one and everything else the app sends meanwhile are kept "
          "back and come up together when the time is over. The notification after that "
          "starts a new round. So a noisy app reaches you at most once per round.\n\n"
          "When I Tap Shani: the tap silences the app once, from that moment. When the time "
          "is over the kept notifications come up, and the app notifies as usual until you "
          "tap Shani on it again. It stays in Apps & Log, and its notifications go on being "
          "logged."),
    choice("mode", "Silence Starts", 0, [(0, "With Each New Notification"), (1, "When I Tap Shani")]),

    group("When the Time Is Over",
          "One Alert: everything that was kept comes up; only the newest one sounds and "
          "shows a banner, the others go straight to the list.\n\n"
          "Alert for Each: every one arrives the way it would have, one after another.\n\n"
          "Silently: all of them go to the list, no sound, no banner.\n\n"
          "Log Only: they are never shown and are removed; you find them in the app's log.\n\n"
          "Critical alerts are never kept back."),
    choice("release", "Kept Notifications", 0,
           [(0, "Show, One Alert"), (1, "Show, Alert for Each"), (2, "Show Silently"), (3, "Log Only")]),

    group("The Shani Button",
          "Clear the Tapped Notification: tapping Shani also clears the notification you "
          "tapped it on, as Clear would. Shani Off never clears anything."),
    switch("swipeButton", "Behind a Swipe, Next to Clear", True),
    switch("longPressButton", "Among the Actions (Hold Down)", True),
    switch("clearOnTap", "Clear the Tapped Notification", True),
    switch("toast", "Confirmation at the Top", True),
    switch("haptic", "Haptic", True),

    group("Apps and Log",
          "Apps & Log lists the apps on Shani with what is being kept for each and when it "
          "comes up. Add or remove apps there, show what is kept right away, and open an "
          "app's notification log.\n\n"
          "A log is kept only for apps on Shani's list, from the moment they are put on it. "
          "It holds each notification's title and text, when it came and what Shani did with "
          "it, and stays on this iPhone, in /var/mobile/Library/Shani."),
    screen("ShaniAppsController", "Apps & Log"),
    choice("logLimit", "Keep per App", 300,
           [(100, "100 Notifications"), (300, "300 Notifications"), (1000, "1,000 Notifications")]),

    group("Troubleshooting",
          "Records what Shani does (never a notification's text) in "
          "/var/mobile/Library/Logs/Shani.log, and lets test commands be sent to it over SSH.\n\n"
          "If SpringBoard restarts right after Shani starts, three times in a row, Shani "
          "stays out of the way. Flip any switch on this page and respring to start it again.\n\n"
          "Shani 1.0.0"),
    switch("debugLog", "Debug Log", True),
]

page = {
    "entry": {"cell": "PSLinkCell", "label": "Shani", "icon": "Shani.png"},
    "title": "Shani",
    "items": items,
}

os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "Shani.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  Shani.plist        {os.path.getsize(path):6d} bytes  OK  ({len(items)} rows)")

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
        if "detail" in row:
            extra += f" -> {row['detail']}"
        if "validTitles" in row:
            extra += " [" + " | ".join(str(t) for t in row["validTitles"]) + "]"
        default = row.get("default", "")
        print(f"     {kind:15s} {row.get('label', '(no label)'):34s} key {row.get('key', '-'):16s} default {default!r}{extra}")

if "--icons" in sys.argv:
    from PIL import Image, ImageDraw, ImageFilter  # only needed for the pictures

    GOLD = (243, 205, 112)
    PALE = (250, 228, 168)
    DEEP = (150, 108, 44)

    def saturn(px, rounded=True):
        """Saturn on a night-blue square: the planet in pale gold with two soft bands, its ring
        tilted up at the right, the near side of the ring passing in front."""
        big = px * 8 if px < 200 else px * 3        # drawn large, then scaled down for smooth edges
        img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        # the sky: indigo at the top to near black at the bottom
        sky = Image.new("RGBA", (big, big))
        sd = ImageDraw.Draw(sky)
        for y in range(big):
            t = y / (big - 1)
            sd.line([(0, y), (big, y)], fill=(int(40 - 30 * t), int(34 - 27 * t), int(104 - 76 * t), 255))
        mask = Image.new("L", (big, big), 0)
        if rounded:
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.225), fill=255)
        else:
            mask.paste(255, [0, 0, big, big])
        img.paste(sky, (0, 0), mask)

        c = big / 2
        r = big * 0.215                               # the planet
        rx, ry = big * 0.40, big * 0.115              # the ring
        w = max(2, int(big * 0.052))
        tilt = 21                                     # degrees, counter-clockwise: up at the right

        def ring_layer(front, colour, width):
            layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            d.ellipse([c - rx, c - ry, c + rx, c + ry], outline=colour + (255,), width=width)
            # keep the far half (above the axis) or the near half (below it); the halves overlap
            # by a hair so that no seam shows where they meet
            lap = big * 0.006
            if front:
                d.rectangle([0, 0, big, c - lap], fill=(0, 0, 0, 0))
            else:
                d.rectangle([0, c + lap, big, big], fill=(0, 0, 0, 0))
            return layer.rotate(tilt, resample=Image.BICUBIC, center=(c, c))

        img.alpha_composite(ring_layer(False, PALE, w))

        planet = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        pd = ImageDraw.Draw(planet)
        pd.ellipse([c - r, c - r, c + r, c + r], fill=GOLD + (255,))
        # two bands and a shaded lower edge, all clipped to the disc
        bands = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        bd = ImageDraw.Draw(bands)
        bd.rectangle([c - r, c - r * 0.50, c + r, c - r * 0.26], fill=PALE + (150,))
        bd.rectangle([c - r, c + r * 0.30, c + r, c + r * 0.52], fill=DEEP + (95,))
        bd.ellipse([c - r * 1.5, c + r * 0.55, c + r * 1.5, c + r * 2.4], fill=DEEP + (120,))
        bands = bands.rotate(tilt, resample=Image.BICUBIC, center=(c, c)).filter(ImageFilter.GaussianBlur(big * 0.006))
        disc = Image.new("L", (big, big), 0)
        ImageDraw.Draw(disc).ellipse([c - r, c - r, c + r, c + r], fill=255)
        planet.paste(Image.alpha_composite(planet, bands), (0, 0), disc)
        img.alpha_composite(planet)

        # the near side: a dark edge first so it reads against the planet, then the ring itself
        edge = ring_layer(True, (16, 13, 44), w + max(2, int(big * 0.03)))
        edge.putalpha(Image.composite(edge.getchannel("A"), Image.new("L", (big, big), 0), disc))      # only where it crosses the planet
        img.alpha_composite(edge)
        img.alpha_composite(ring_layer(True, PALE, w))
        if rounded:
            img.putalpha(Image.composite(img.getchannel("A"), Image.new("L", (big, big), 0), mask))
        return img.resize((px, px), Image.LANCZOS)

    for name, px in (("Shani.png", 29), ("Shani@2x.png", 58), ("Shani@3x.png", 87)):
        saturn(px).save(os.path.join(OUT, name))
        print(f"  {name:18s} {px}x{px}")
    os.makedirs("art", exist_ok=True)
    saturn(1024).save(os.path.join("art", "shani-icon.png"))
    print("  art/shani-icon.png 1024x1024")
