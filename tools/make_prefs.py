#!/usr/bin/env python3
"""Build Chakra's plist-only Settings page. (Its icon is made by tools/make_art.py.)

Plist-only, like Wingman and Dynamic Stage+: the page itself has no compiled
code. The one thing a plist cannot do, bring AltList into Settings for the app
lists, is done by ChakraPrefs.dylib (PrefsHelper.m).

Every control posts com.adarsh.chakra/prefs, and SpringBoard re-reads the
settings the moment you change something - no respring.

The shortcuts' names and links are typed here rather than in Chakra's own sheet:
a text field in a SpringBoard window has to take keyboard focus away from the app
in front, and Settings has no such trouble. For the same reason the searchable
list of apps is here too (AltList's), next to the plain A to Z one in the sheet.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
        python3 tools/make_prefs.py --glyphs      (prints the icon names, for the on-device glyph check)
"""

import os
import plistlib
import sys

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
    many=False: pick one, its bundle id is saved, and the row shows that app's name.

    The rows only name AltList's classes, the way a compiled settings bundle's plist does, so
    AltList has to be in Settings before the page is read. This page has no code to do that, and
    "bundle = AltList" on a row does not do it either (1.0.1 and 1.0.2 tried: PreferenceLoader
    finds AltList's bundle for a top-level entry only, and shows an error page for a row). So
    ChakraPrefs.dylib (PrefsHelper.m) loads AltList when Settings starts.
    """
    row = {"cell": "PSLinkCell" if many else "PSLinkListCell",
           "detail": "ATLApplicationListMultiSelectionController" if many else "ATLApplicationListSelectionController",
           "defaults": D, "key": key, "label": label, "PostNotification": NOTE,
           "sections": [{"sectionType": "Visible"}],
           "useSearchBar": True, "hideSearchBarWhileScrolling": False, "alphabeticIndexingEnabled": True}
    if many:
        row["defaultApplicationSwitchValue"] = False
    else:
        row["cellClass"] = "ATLApplicationSelectionCell"
    return row


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
    group("Ball",
          "Icon: the golden sun wheel on its own, or the plain white wheel mark on a dark disc "
          "ringed in the colour chosen below.\n\n"
          "Tucked, the ball slides part-way off the screen while it waits and comes out when you touch it."),
    choice("ballIcon", "Icon", 0, [(0, "Golden Sun"), (1, "Plain Wheel")]),
    switch("tuck", "Tuck Into the Edge", True),
    choice("accent", "Colour", 0, [(0, "Indigo"), (1, "Blue"), (2, "Teal"), (3, "Green"),
                                   (4, "Saffron"), (5, "Pink"), (6, "Red"), (7, "Graphite"), (8, "Gold")]),

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


os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "Chakra.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  Chakra.plist       {os.path.getsize(path):6d} bytes  OK  ({len(items)} rows, {len(GLYPHS)} shortcut icons)")
