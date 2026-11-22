#!/usr/bin/env python3
"""Build HyperTrade's plist-only Settings page, and its icon.

(HyperTrade is the tweak's name since 1.2.0. The file is still Atelier.plist and the settings
domain still com.adarsh.atelier, so an update keeps every setting.)

Plist-only, like Wingman, Dynamic Stage+ and Chakra: the page has no compiled code.
Every control posts com.adarsh.atelier/prefs, and SpringBoard re-reads the settings
the moment you change something - no respring.

The one thing a plist cannot do, bring AltList into Settings for the Shortcut Apps
list, is done by AtelierPrefs.dylib (PrefsHelper.m).

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
        python3 tools/make_prefs.py --icons layout/Library/PreferenceLoader/Preferences
        (the second form also draws Atelier.png / @2x / @3x; it needs Pillow, so it is run
         on the PC and the pictures are committed. CI only checks the plist.)
        python3 tools/make_prefs.py --dump <folder>
        (also prints the page as Settings will list it: the entry, the title, every row)
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


def text(key, label, placeholder):
    return {"cell": "PSEditTextCell", "defaults": D, "key": key, "label": label,
            "placeholder": placeholder, "default": "", "noAutoCorrect": True, "autoCaps": "none",
            "PostNotification": NOTE}


def segments(key, default, options):
    return {"cell": "PSSegmentCell", "defaults": D, "key": key, "default": default, "PostNotification": NOTE,
            "validValues": [v for v, _ in options], "validTitles": [t for _, t in options]}


def app_list(key, label):
    """Every app with a switch, from AltList (com.opa334.altlist): searchable, A to Z. The bundle
    ids that are switched on are saved as an array.

    The row only names AltList's class, the way a compiled settings bundle's plist does, so
    AltList has to be in Settings before the page is read: AtelierPrefs.dylib (PrefsHelper.m)
    loads it when Settings starts. ("bundle = AltList" on a row does not work; Chakra tried.)

    The cell must be PSLinkListCell, not PSLinkCell. In a plist-only page PreferenceLoader
    (libprefs, -[PLCustomListController specifiers]) gives every PSLinkCell row without a
    `bundle` its own page class as the controller, whatever `detail` says: it takes the row
    for a sub-page made from another plist. Opened, that page finds no plist and says "There
    appears to be an error with these preferences!", which is what 1.1.0's row did. Read in
    the libprefs.dylib of the phone's PreferenceLoader 2.3.3 on 22 Nov 2026; a PSLinkListCell
    is left alone (bfdecrypt's AltList entry on the same phone is one).
    """
    return {"cell": "PSLinkListCell", "detail": "ATLApplicationListMultiSelectionController",
            "defaults": D, "key": key, "label": label, "PostNotification": NOTE,
            "sections": [{"sectionType": "Visible"}], "defaultApplicationSwitchValue": False,
            "useSearchBar": True, "hideSearchBarWhileScrolling": False, "alphabeticIndexingEnabled": True}


# The markets a flag can stand for. The hours are in AtelierBand.m (kMarkets); keep the codes in step.
MARKETS = [("IN", "India (NSE, 9:15 to 15:30)"), ("GB", "UK (LSE, 8:00 to 16:30)"),
           ("US", "USA (NYSE, 9:30 to 16:00)"), ("JP", "Japan (TSE, 9:00 to 15:30)"),
           ("HK", "Hong Kong (9:30 to 16:00)"), ("DE", "Germany (Xetra, 9:00 to 17:30)"),
           ("CN", "China (Shanghai, 9:30 to 15:00)"), ("SG", "Singapore (9:00 to 17:00)")]

items = [
    group(None,
          "A workbench of live apps: one big app and up to five mini tiles. Tap a mini and it "
          "changes places with the big one.\n\n"
          "To open it, slide a finger in from the edge of the screen just above the bottom "
          "corner (or up along that edge). Or hold an app's icon on the Home Screen and choose "
          "Open in HyperTrade.\n\n"
          "The pill with three dots above the big app is its menu: Full Screen, Switch Layout, "
          "Replace App, Close App, Save as Set. Hold a mini for its own menu. A swipe up from "
          "the bottom of the screen, the Home gesture, puts the bench away."),
    switch("enabled", "HyperTrade", True),

    group("Layout",
          "Side: minis in a column on the left. Top: minis in a row across the top. "
          "Split: two apps next to each other, both usable at once; drag the handle between "
          "them to give one more room.\n\n"
          "Every app keeps its full size and the bench shows it smaller, so every app works "
          "on it and changing places is instant."),
    choice("layout", "Layout", 0, [(0, "Side"), (1, "Top"), (2, "Split")]),

    group("Mini Tiles",
          "Smart: minis are live while you use the bench, turn into still pictures after the "
          "pause set below, and wake when you touch the bench again. Their apps are suspended "
          "while they are stills, so they cost no battery.\n\n"
          "Always Live: every app on the bench keeps running. Uses the most battery.\n\n"
          "Stills Only: only the big app runs; a mini is refreshed when it comes off the big tile."),
    choice("miniMode", "Minis", 0, [(0, "Smart"), (1, "Always Live"), (2, "Stills Only")]),
    group("Seconds Before Minis Freeze (Smart)"),
    slider("freezeAfter", 5, 60, 20),

    group("Swipes on a Mini",
          "A mini follows your finger and a small label says what letting go will do. A "
          "short swipe is enough, and so is a quick flick.\n\n"
          "Left closes the app. Right makes it the big app. Up locks it, or unlocks it. "
          "Down does what you choose here.\n\n"
          "A locked app shows a padlock. It can't be swiped away, stays when a set is opened, "
          "and stays live however the minis are set above."),
    choice("swipeDown", "Swipe Down", 0, [(0, "Split with the Big App"), (1, "Full Screen"),
                                          (2, "Replace"), (3, "Nothing")]),

    group("Clock and Markets",
          "Above the apps: a clock with seconds, and three market flags. A flag is in colour "
          "with a ring, and shows the time left, while that market's regular session is on; "
          "otherwise it is dimmed. Hours are worked out in each market's own time zone, "
          "Monday to Friday."),
    switch("showClock", "Clock", True),
    switch("showMarkets", "Market Flags", True),
    choice("market1", "First Flag", "IN", MARKETS),
    choice("market2", "Second Flag", "GB", MARKETS),
    choice("market3", "Third Flag", "US", MARKETS),
    group("Market Holidays",
          "India's flag stays dimmed and says Holiday on NSE trading holidays. The built-in "
          "list covers 2026. For later years, or a holiday announced since, type the dates "
          "here as YYYY-MM-DD, separated by commas or spaces, for example 2027-01-26, "
          "2027-03-22. In a year without any list the flag follows weekdays only.\n\n"
          "The other markets have no holiday list: on their holidays the flag lights up all "
          "the same."),
    text("extraHolidays", "Extra India Holidays", "2027-01-26, 2027-03-22"),

    group("Index Numbers",
          "NIFTY and SENSEX above the clock: the last price, and the change since the "
          "previous close in points and per cent, green or red.\n\n"
          "The numbers are Yahoo Finance's public feed and may lag the exchange; when the "
          "newest one is more than a minute old its age is shown beside it. The phone "
          "contacts Yahoo only while the bench is open: every 5 seconds during NSE's session "
          "(holidays as above), once for the closing numbers outside it, never when the "
          "bench is closed or the phone is locked. Nothing about you or the phone is sent."),
    switch("showIndices", "Live Index Numbers", True),

    group("Shortcut Apps",
          "Up to six apps sit as icons above the big app, each with its badge. Tap one and "
          "it opens on the bench as the big app; if it is already there it changes places "
          "with the big one. A full bench says so instead of pushing an app off.\n\n"
          "On the bench itself: the + at the end of the row adds an app, and holding an icon "
          "offers Remove from Shortcuts. The list here shows the same apps."),
    app_list("shortcutApps", "Shortcut Apps"),

    group("Toggles",
          "Round buttons under the apps. A button is filled while its setting is on. Switch "
          "off the ones you do not want.\n\n"
          "Keep Screen Awake holds the screen on only while the bench is open. It switches "
          "itself off when the bench closes or the phone locks, and is off again the next "
          "time the bench opens."),
    switch("toggleWifi", "Wi-Fi", True),
    switch("toggleBluetooth", "Bluetooth", True),
    switch("toggleData", "Mobile Data", True),
    switch("toggleDND", "Do Not Disturb", True),
    switch("toggleAwake", "Keep Screen Awake", True),
    switch("toggleLowPower", "Low Power Mode", True),

    group("Opening",
          "Slide a finger in from the edge, or up along it: the bench comes in with your "
          "finger and opens when you let go. A short swipe or a flick is enough. With the "
          "bench open, the same swipe inward sends it away again.\n\n"
          "The strip is see-through and 22 points wide; the faint pill on the edge shows "
          "where it is. It takes touches where it lies, so keep it only as tall as you need.\n\n"
          "Bring the Current App Along: the app you are in when you open the bench becomes "
          "the big app.\n\n"
          "Icon Menu: Open in HyperTrade, your sets, and HyperTrade Sets… when you hold an app's icon."),
    switch("trigger", "Edge Swipe", True),
    switch("showHandle", "Show Edge Handle", True),
    segments("triggerSide", 1, [(0, "Left Edge"), (1, "Right Edge")]),
    group("Height of the Strip"),
    slider("triggerSize", 60, 220, 110),
    group(),
    switch("addFront", "Bring the Current App Along", True),
    switch("iconMenu", "Icon Menu", True),

    group("Feel"),
    choice("haptics", "Haptics", 1, [(0, "Off"), (1, "Light"), (2, "Medium"), (3, "Firm")]),

    group("Troubleshooting",
          "Records what HyperTrade does in /var/mobile/Library/Logs/Atelier.log, and lets "
          "test commands be sent to it over SSH.\n\n"
          "If SpringBoard restarts right after HyperTrade starts, three times in a row, "
          "HyperTrade stays out of the way. Flip any switch on this page to start it again."),
    switch("debugLog", "Debug Log", True),
]

# The entry's label is no longer the file's name. PreferenceLoader copes: it then notes the file's
# name on the entry (pl_alt_plist_name) and loads the page from that.
page = {
    "entry": {"cell": "PSLinkCell", "label": "HyperTrade", "icon": "Atelier.png"},
    "title": "HyperTrade",
    "items": items,
}

os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "Atelier.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  Atelier.plist      {os.path.getsize(path):6d} bytes  OK  ({len(items)} rows)")

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
        print(f"     {kind:15s} {row.get('label', '(no label)'):28s} key {row.get('key', '-'):16s} default {default!r}{extra}")

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
