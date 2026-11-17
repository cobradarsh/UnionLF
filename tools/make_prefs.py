#!/usr/bin/env python3
"""Build Chakra's plist-only Settings page (and its icon).

Plist-only, like Wingman and Dynamic Stage+: Preferences.app is arm64e and a
preference *bundle* would need a compiled binary; a plist has none, so it
always loads.

Every control posts com.adarsh.chakra/prefs, and SpringBoard re-reads the
settings the moment you change something - no respring.

The shortcuts' names and links are typed here rather than in Chakra's own sheet:
a text field in a SpringBoard window has to take keyboard focus away from the app
in front, and Settings has no such trouble. For the same reason the searchable
list of apps is here too (AltList's), next to the plain A to Z one in the sheet.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
        python3 tools/make_prefs.py --glyphs      (prints the icon names, for the on-device glyph check)
"""

import math
import os
import plistlib
import struct
import sys
import zlib

D = "com.adarsh.chakra"
NOTE = "com.adarsh.chakra/prefs"
SLOTS = 4                      # keep in step with CHAKRA_SLOTS in Chakra.h

# What a shortcut's icon can be: (SF Symbol name, what the list calls it).
# Every name exists on iOS 15 and later; ck.chakra is drawn by the tweak itself.
GLYPHS = [
    ("star.fill", "Star"), ("heart.fill", "Heart"), ("bolt.fill", "Bolt"), ("flame.fill", "Flame"),
    ("link", "Link"), ("globe", "Globe"), ("magnifyingglass", "Search"), ("qrcode", "QR Code"),
    ("phone.fill", "Phone"), ("message.fill", "Message"), ("envelope.fill", "Envelope"),
    ("paperplane.fill", "Paper Plane"), ("person.fill", "Person"), ("person.2.fill", "People"),
    ("indianrupeesign.circle.fill", "Rupee"), ("creditcard.fill", "Card"), ("banknote.fill", "Banknote"),
    ("cart.fill", "Cart"), ("bag.fill", "Bag"), ("gift.fill", "Gift"), ("briefcase.fill", "Briefcase"),
    ("map.fill", "Map"), ("location.fill", "Location"), ("car.fill", "Car"), ("tram.fill", "Train"),
    ("airplane", "Plane"), ("bicycle", "Bicycle"), ("figure.walk", "Walk"),
    ("music.note", "Music"), ("headphones", "Headphones"), ("play.fill", "Play"), ("tv.fill", "TV"),
    ("camera.fill", "Camera"), ("photo.fill", "Photo"), ("video.fill", "Video"), ("mic.fill", "Microphone"),
    ("gamecontroller.fill", "Game"), ("book.fill", "Book"), ("doc.fill", "Document"), ("folder.fill", "Folder"),
    ("calendar", "Calendar"), ("alarm.fill", "Alarm"), ("timer", "Timer"), ("bell.fill", "Bell"),
    ("house.fill", "House"), ("lightbulb.fill", "Light Bulb"), ("lock.fill", "Lock"), ("key.fill", "Key"),
    ("fork.knife", "Food"), ("cup.and.saucer.fill", "Coffee"), ("cross.case.fill", "First Aid"), ("pills.fill", "Pills"),
    ("leaf.fill", "Leaf"), ("moon.fill", "Moon"), ("sun.max.fill", "Sun"), ("cloud.fill", "Cloud"),
    ("wand.and.stars", "Magic Wand"), ("terminal.fill", "Terminal"), ("gearshape.fill", "Gear"),
    ("ck.chakra", "Chakra Wheel"),
]

if "--glyphs" in sys.argv:
    print(" ".join(name for name, _ in GLYPHS))
    sys.exit(0)

OUT = sys.argv[1] if len(sys.argv) > 1 else "layout/Library/PreferenceLoader/Preferences"


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


def text(key, label, placeholder):
    return {"cell": "PSEditTextCell", "defaults": D, "key": key, "label": label,
            "placeholder": placeholder, "default": "", "noAutoCorrect": True, "autoCaps": "none",
            "PostNotification": NOTE}


def segments(key, default, options):
    return {"cell": "PSSegmentCell", "defaults": D, "key": key, "default": default, "PostNotification": NOTE,
            "validValues": [v for v, _ in options], "validTitles": [t for _, t in options]}


def app_list(key, label, many):
    """A list of every app, from AltList (com.opa334.altlist): searchable, A to Z.

    many=True: a switch per app, the bundle ids that are on are saved as an array.
    many=False: pick one, its bundle id is saved.
    "bundle" makes Settings load AltList's own preference bundle first, which is what brings its
    classes in: this page has no compiled code of its own to do that.
    """
    return {"cell": "PSLinkListCell", "bundle": "AltList", "isController": True, "overridePrincipalClass": True,
            "detail": "ATLApplicationListMultiSelectionController" if many else "ATLApplicationListSelectionController",
            "defaults": D, "key": key, "label": label, "PostNotification": NOTE,
            "sections": [{"sectionType": "Visible"}],
            "useSearchBar": True, "hideSearchBarWhileScrolling": False, "alphabeticIndexingEnabled": True,
            "defaultApplicationSwitchValue": False}


# What a double tap, a triple tap or a hold on the ball can do. Values are read by
# +[ChakraItems itemForGesture:]; the action ids are the ones in ChakraActions.m.
GESTURES = [
    ("none", "Nothing"),
    ("action:edit", "Edit the Wheel"),
    ("action:lastapp", "Last App"),
    ("action:home", "Home"),
    ("action:switcher", "App Switcher"),
    ("action:lock", "Lock Screen"),
    ("action:screenshot", "Screenshot"),
    ("action:controlcentre", "Control Centre"),
    ("action:notifications", "Notification Centre"),
    ("action:reachability", "Reachability"),
    ("action:flashlight", "Torch"),
    ("action:rotation", "Rotation Lock"),
    ("action:lowpower", "Low Power Mode"),
    ("action:darkmode", "Dark Mode"),
    ("action:wifi", "Wi-Fi"),
    ("action:bluetooth", "Bluetooth"),
    ("action:airplane", "Aeroplane Mode"),
    ("action:respring", "Respring"),
] + [("shortcut:%d" % n, "Shortcut %d" % n) for n in range(1, SLOTS + 1)] + [
    ("app", "Open the App Chosen Below"),
]

items = [
    group(None,
          "A ball on the edge of the screen that opens a wheel of your apps.\n\n"
          "Tap the ball to open the wheel. Or slide from the ball and lift your finger "
          "over an icon: one move.\n\n"
          "The last entry on the wheel, Edit, is where you add, remove and reorder "
          "what is on it."),
    switch("enabled", "Chakra", True),

    group("Apps",
          "Switch on any app you want on the wheel; there is a search field at the top "
          "of the list. New ones go to the end of the wheel.\n\n"
          "To change the order, or to add actions and shortcuts, open the wheel and tap Edit."),
    app_list("apps", "Apps on the Wheel", True),

    group("Ball Position",
          "Side and Height put the ball exactly where you want it; it moves as you change them.\n\n"
          "By hand: hold the ball for half a second, then drag. Or set Dragging the Ball to "
          "Moves the Ball, and a plain drag moves it (the wheel then opens by tap only).\n\n"
          "Lock Position keeps it where it is."),
    segments("ballEdge", 1, [(0, "Left Side"), (1, "Right Side")]),
    choice("dragMode", "Dragging the Ball", 0, [(0, "Opens the Wheel and Picks"), (1, "Moves the Ball")]),
    switch("lockPosition", "Lock Position", False),
    group("Height on the Screen", "Left is the top of the screen, right is the bottom."),
    slider("ballY", 0.06, 0.94, 0.44),

    group("Ball Size"),
    slider("ballSize", 36, 64, 46),
    group("Resting Strength", "How solid the ball looks while it waits."),
    slider("idleAlpha", 0.2, 1.0, 0.6),
    group("Ball", "Tucked, the ball slides part-way off the screen while it waits and comes out when you touch it."),
    switch("tuck", "Tuck Into the Edge", True),
    choice("accent", "Colour", 0, [(0, "Indigo"), (1, "Blue"), (2, "Teal"), (3, "Green"),
                                   (4, "Saffron"), (5, "Pink"), (6, "Red"), (7, "Graphite")]),

    group("Wheel",
          "Layout: rings of icons around the ball, which bend away from a corner, or a "
          "straight column beside it.\n\n"
          "Background: Glass lets what is behind show through, with a bright rim, like the "
          "glass of the newest iOS. Frosted is the darker, blurrier pane."),
    choice("style", "Layout", 0, [(0, "Wheel"), (1, "Column")]),
    choice("plateStyle", "Background", 0, [(0, "Glass"), (1, "Frosted")]),
    switch("labels", "Names Under Icons", True),
    switch("dim", "Dim the Screen Behind", True),
    switch("editEntry", "Edit Entry on the Wheel", True),
    choice("haptics", "Haptics", 1, [(0, "Off"), (1, "Light"), (2, "Medium"), (3, "Firm")]),
    group("Icon Size"),
    slider("iconSize", 44, 66, 54),

    group("Taps on the Ball",
          "What a double tap, a triple tap and a hold do. For an app, choose Open the App "
          "Chosen Below and pick it in the row underneath.\n\n"
          "While a double or triple tap is set, a single tap waits a quarter of a second "
          "to see whether another follows."),
    choice("gestureDouble", "Double Tap", "none", GESTURES),
    app_list("gestureDoubleApp", "App for Double Tap", False),
    choice("gestureTriple", "Triple Tap", "none", GESTURES),
    app_list("gestureTripleApp", "App for Triple Tap", False),
    choice("gestureHold", "Hold", "action:edit", GESTURES),
    app_list("gestureHoldApp", "App for Hold", False),

    group("Where",
          "On the Lock Screen: the ball stays when the iPhone is locked. Apps still "
          "ask for Face ID or the passcode first.\n\n"
          "Hide in Landscape: the ball steps aside while the app in front is on its "
          "side (games, videos).\n\n"
          "Keep Out of Screenshots: the ball and the wheel are left out of screenshots "
          "and screen recordings, while you still see them on the screen."),
    switch("lockScreen", "On the Lock Screen", False),
    switch("hideLandscape", "Hide in Landscape", False),
    switch("hideInShots", "Keep Out of Screenshots", True),
]

for n in range(1, SLOTS + 1):
    footer = None
    if n == 1:
        footer = ("Opens can be a web link (https://…), an app's own link (upi://pay, "
                  "whatsapp://send?phone=…) or the exact name of a shortcut in the Shortcuts "
                  "app.\n\nA filled-in shortcut can go on the wheel (Edit, then Shortcuts) "
                  "or on a tap of the ball (above).")
    items += [
        group("Shortcut %d" % n, footer),
        text("sc%dName" % n, "Name", "What the wheel calls it"),
        text("sc%dURL" % n, "Opens", "Link or Shortcut name"),
        choice("sc%dGlyph" % n, "Icon", "star.fill", GLYPHS),
    ]

items += [
    group("Troubleshooting",
          "Records what Chakra does in /var/mobile/Library/Logs/Chakra.log.\n\n"
          "If SpringBoard restarts right after Chakra starts, three times in a row, "
          "Chakra stays out of the way. Flip any switch on this page to bring the ball back."),
    switch("debugLog", "Debug Log", True),
]

page = {
    "entry": {"cell": "PSLinkCell", "label": "Chakra", "icon": "Chakra.png"},
    "title": "Chakra",
    "items": items,
}


# ---- icon: indigo rounded square, white wheel (rim, hub, eight spokes), drawn with the standard library only ----

def _seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def _in_round_rect(px, py, x0, y0, x1, y1, r):
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    return math.hypot(px - cx, py - cy) <= r


RIM, RIM_HALF, HUB, SPOKE_HALF = 0.300, 0.036, 0.086, 0.026
SPOKES = [(0.5 + math.cos(a) * HUB, 0.5 + math.sin(a) * HUB, 0.5 + math.cos(a) * RIM, 0.5 + math.sin(a) * RIM)
          for a in (i * math.pi / 4 + math.pi / 8 for i in range(8))]
TOP = (0x7A, 0x78, 0xF2)        # the square is a shade lighter at the top
BOTTOM = (0x4B, 0x49, 0xC8)


def _sample(u, v):
    """(inside the square, on the wheel) for a point in the unit square."""
    if not _in_round_rect(u, v, 0.0, 0.0, 1.0, 1.0, 0.225):
        return False, False
    d = math.hypot(u - 0.5, v - 0.5)
    wheel = abs(d - RIM) <= RIM_HALF or d <= HUB
    if not wheel and d < RIM:
        wheel = any(_seg_dist(u, v, ax, ay, bx, by) <= SPOKE_HALF for ax, ay, bx, by in SPOKES)
    return True, wheel


def _png(size, ss=4):
    rows = []
    for y in range(size):
        row = bytearray([0])                       # filter: none
        back = [round(TOP[i] + (BOTTOM[i] - TOP[i]) * (y + 0.5) / size) for i in range(3)]
        for x in range(size):
            cover = white = 0
            for sy in range(ss):
                for sx in range(ss):
                    inside, wheel = _sample((x + (sx + 0.5) / ss) / size, (y + (sy + 0.5) / ss) / size)
                    cover += inside
                    white += wheel
            n = ss * ss
            if cover == 0:
                row += bytes(4)
                continue
            mix = white / cover
            row += bytes([round(c + (255 - c) * mix) for c in back] + [round(255 * cover / n)])
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
            + chunk(b"IEND", b""))


os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "Chakra.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  Chakra.plist       {os.path.getsize(path):6d} bytes  OK  ({len(items)} rows, {len(GLYPHS)} shortcut icons)")
for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
    path = os.path.join(OUT, f"Chakra{suffix}.png")
    with open(path, "wb") as f:
        f.write(_png(29 * scale))
    print(f"  {os.path.basename(path):18} {os.path.getsize(path):6d} bytes")
