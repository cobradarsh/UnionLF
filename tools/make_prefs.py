#!/usr/bin/env python3
"""Build VidGrab's Settings page (a plist, no compiled code) and its icon.

Every control posts com.adarsh.vidgrab/prefs; the apps re-read the settings the moment
something changes, so nothing has to be restarted.

Usage:  python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
        python3 tools/make_prefs.py --icons layout/Library/PreferenceLoader/Preferences
        (the second form also draws VidGrab.png / @2x / @3x and art/vidgrab-icon.png; it needs
         Pillow, so it is run on the PC and the pictures are committed. CI only checks the plist.)
        python3 tools/make_prefs.py --dump <folder>
        (also prints the page as Settings will list it)
"""

import os
import plistlib
import sys

D = "com.adarsh.vidgrab"
NOTE = "com.adarsh.vidgrab/prefs"
VERSION = "2.0.0"

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


# (settings key, name shown). The key is "app-" + the app's program name; where an app's program
# has gone by two names, VGCore.m maps the other one onto the name used here.
APPS = [
    ("Twitter", "X"), ("Instagram", "Instagram"), ("Barcelona", "Threads"), ("Facebook", "Facebook"),
    ("Messenger", "Messenger"), ("TikTok", "TikTok"), ("YouTube", "YouTube"), ("RedditApp", "Reddit"),
    ("Tumblr", "Tumblr"), ("Pinterest", "Pinterest"), ("Twitch", "Twitch"), ("WhatsApp", "WhatsApp"),
    ("LinkedIn", "LinkedIn"), ("Flickr", "Flickr"), ("VKClient", "VK"), ("Jodel", "Jodel"), ("LIKE", "Likee"),
]

items = [
    group(None,
          "VidGrab saves the video you are watching.\n\n"
          "A small download button sits in a corner of every video an app plays. Tap it, or "
          "hold the video, and choose what to do with it. A bar at the top shows the progress "
          "and has a button to cancel.\n\n"
          "It works with videos an app plays through iOS's own player. Where an app draws its "
          "videos itself, no button appears and a hold does nothing."),
    switch("enabled", "VidGrab", True),

    group("Download Button",
          "The corner is the corner of the picture. Choose another one if an app has a button "
          "of its own there."),
    switch("badge", "Show on Videos", True),
    choice("badgeCorner", "Corner", 1, [(0, "Top Left"), (1, "Top Right"), (2, "Bottom Left"), (3, "Bottom Right")]),

    group("Holding a Video",
          "Some apps act on a hold themselves: X plays faster, Instagram pauses. With Stop the "
          "App's Own Hold Action on, VidGrab ends that when it takes the hold. Two Fingers "
          "keeps the one-finger hold for the app."),
    choice("hold", "Hold With", 1, [(0, "Off"), (1, "One Finger"), (2, "Two Fingers")]),
    choice("holdTime", "Hold For", 0.55, [(0.4, "0.4 Seconds"), (0.55, "0.55 Seconds"), (0.8, "0.8 Seconds"), (1.0, "1 Second")]),
    switch("blockAppHold", "Stop the App's Own Hold Action", True),

    group("When Triggered",
          "Show Menu offers Save to Photos, Share, Save to GIF Stash, Choose Quality and Copy "
          "Link. The other choices do that one thing straight away."),
    choice("action", "Do", 0, [(0, "Show Menu"), (1, "Save to Photos"), (2, "Share"), (3, "Save to GIF Stash")]),

    group("Quality",
          "For videos that come in several sizes. The menu's Choose Quality lists them all for "
          "one download. Videos in H.264 are preferred over HEVC at the same size, because "
          "every app can play them."),
    choice("quality", "Download", 0, [(0, "Best"), (2160, "Up to 4K"), (1080, "Up to 1080p"), (720, "Up to 720p"), (480, "Up to 480p")]),

    group("Photos",
          "Saved videos also go into an album named VidGrab. An album needs full access to "
          "Photos, so each app asks for that once; with access to add only, videos are saved "
          "without the album."),
    switch("album", "VidGrab Album", True),

    group("Feedback"),
    switch("haptic", "Haptics", True),

    group("Apps",
          "VidGrab is loaded into these apps when they start. Switched off here, it stays "
          "idle in that app: no button, no hold."),
] + [switch("app-" + key, name, True) for key, name in APPS] + [

    group("Troubleshooting",
          "Writes what VidGrab does into vidgrab.log in each app's temporary folder: which "
          "player was found, what was downloaded and how it ended. Addresses of videos appear "
          "in it; nothing leaves the iPhone.\n\n"
          "VidGrab " + VERSION),
    switch("debug", "Debug Log", False),
]

page = {
    "entry": {"cell": "PSLinkCell", "label": "VidGrab", "icon": "VidGrab.png"},
    "title": "VidGrab",
    "items": items,
}

os.makedirs(OUT, exist_ok=True)
path = os.path.join(OUT, "VidGrab.plist")
with open(path, "wb") as f:
    plistlib.dump(page, f)
with open(path, "rb") as f:
    plistlib.load(f)                               # prove it parses
print(f"  VidGrab.plist      {os.path.getsize(path):6d} bytes  OK  ({len(items)} rows)")

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
        print(f"     {kind:15s} {row.get('label', '(no label)'):34s} key {row.get('key', '-'):16s} default {default!r}{extra}")

if "--icons" in sys.argv:
    from PIL import Image, ImageDraw  # only needed for the pictures

    def icon(px, rounded=True):
        """A white arrow coming down onto a tray, on a blue-to-violet square."""
        big = px * 8 if px < 200 else px * 3        # drawn large, then scaled down for smooth edges
        ground = Image.new("RGBA", (big, big))
        gd = ImageDraw.Draw(ground)
        top, bottom = (58, 150, 255), (118, 74, 232)
        for y in range(big):
            t = y / (big - 1)
            gd.line([(0, y), (big, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
        mask = Image.new("L", (big, big), 0)
        if rounded:
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * 0.225), fill=255)
        else:
            mask.paste(255, [0, 0, big, big])
        img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        img.paste(ground, (0, 0), mask)
        d = ImageDraw.Draw(img)
        white = (255, 255, 255, 255)
        c = big / 2
        w = big * 0.085                               # stroke width
        r = w / 2

        def stroke(a, b):
            d.line([a, b], fill=white, width=int(round(w)))
            for x, y in (a, b):
                d.ellipse([x - r, y - r, x + r, y + r], fill=white)

        tip = (c, big * 0.60)
        stroke((c, big * 0.22), tip)                  # the shaft
        stroke((c - big * 0.15, big * 0.45), tip)     # the head
        stroke((c + big * 0.15, big * 0.45), tip)
        left, right, base, lip = big * 0.25, big * 0.75, big * 0.77, big * 0.66
        stroke((left, base), (right, base))           # the tray
        stroke((left, lip), (left, base))
        stroke((right, lip), (right, base))
        return img.resize((px, px), Image.LANCZOS)

    for name, px in (("VidGrab.png", 29), ("VidGrab@2x.png", 58), ("VidGrab@3x.png", 87)):
        icon(px).save(os.path.join(OUT, name))
        print(f"  {name:18s} {px}x{px}")
    os.makedirs("art", exist_ok=True)
    icon(512).save(os.path.join("art", "vidgrab-icon.png"))
    print("  art/vidgrab-icon.png 512x512")
