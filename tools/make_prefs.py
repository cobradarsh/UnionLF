#!/usr/bin/env python3
"""Build Wingman's plist-only settings pages.

Why plist-only: a preference *bundle* has an executable, and Preferences.app is
arm64e, so an arm64 bundle fails to load. Plists have no executable.

Files written into /Library/PreferenceLoader/Preferences/ :
  Wingman.plist          main page                (top-level Settings row)
  WingmanClaude.plist    Claude API sub-page      (no "entry" -> not top-level)
  WingmanDeepSeek.plist  DeepSeek API sub-page    (no "entry")
  WingmanApps.plist      app picker via AltList   (top-level row "Wingman Apps")

Sub-pages are reached with pl_alt_plist_name, and the same items are ALSO
embedded inline in the link cell: PreferenceLoader falls back to the cell's own
"items" if the file lookup returns nothing.

AltList has to be its own top-level entry. PreferenceLoader only resolves a
"bundle" key (to the RootHide jbroot) for top-level entries; nested link cells
never get PSLazilyLoadedBundleKey, which is why the nested picker failed with
"There was an error loading the preference bundle ...: (null)".
"""

import plistlib, os, sys

OUT = sys.argv[1]
D = "com.adarsh.wingman"


def group(label=None, footer=None):
    g = {"cell": "PSGroupCell"}
    if label:
        g["label"] = label
    if footer:
        g["footerText"] = footer
    return g


def field(key, label, placeholder, secure=False, url=False):
    c = {
        "cell": "PSSecureEditTextCell" if secure else "PSEditTextCell",
        "defaults": D,
        "key": key,
        "label": label,
        "placeholder": placeholder,
        "noAutoCorrect": True,
        "autoCaps": "None",
    }
    if url:
        c["isURL"] = True
    return c


def segment(key, titles, default=0):
    return {
        "cell": "PSSegmentCell",
        "defaults": D,
        "key": key,
        "default": default,
        "validValues": list(range(len(titles))),
        "validTitles": titles,
    }


def switch(key, label, default=True):
    return {"cell": "PSSwitchCell", "defaults": D, "key": key,
            "label": label, "default": default}


def slider(key, label, default, lo, hi):
    return {"cell": "PSSliderCell", "defaults": D, "key": key,
            "label": label, "default": default, "min": lo, "max": hi,
            "showValue": True}


def link(label, plist_name, items):
    """Sub-page link: by file name, with the items inline as a fallback."""
    return {"cell": "PSLinkCell", "label": label,
            "pl_alt_plist_name": plist_name, "items": items}


# ── Claude sub-page ───────────────────────────────────────
claude_items = [
    group("Claude API Key",
          "Get one at console.anthropic.com. Claude can read screenshots, so it "
          "works even when the phone cannot read the text on screen."),
    field("claudeAPIKey", "API Key", "sk-ant-...", secure=True),

    group("Model",
          "Easiest: open Wingman in any chat, tap Write with AI, then tap the "
          "Model row. It lists the models your key can use and saves your pick "
          "here. You can also type a model ID. Blank = claude-sonnet-4-5-20250929."),
    field("claudeModel", "Model", "claude-sonnet-4-5-20250929"),

    group("What To Send",
          "Text only: Wingman reads the chat on your phone and sends just the "
          "text. Cheapest. Text + Screenshot also sends the picture, which helps "
          "with photos, stickers and emoji-only messages. If the phone cannot "
          "read a screen, the screenshot is sent automatically either way."),
    segment("claudeReads", ["Text only", "Text + Screenshot"]),
]

# ── DeepSeek sub-page ─────────────────────────────────────
deepseek_items = [
    group("DeepSeek API Key",
          "Get one at platform.deepseek.com. DeepSeek is text only: it cannot "
          "see screenshots, so it uses the chat text read on your phone."),
    field("deepseekAPIKey", "API Key", "sk-...", secure=True),

    group("Model",
          "Easiest: open Wingman in any chat, tap Write with AI, switch to "
          "DeepSeek and tap the Model row. It lists the models your key can use "
          "and saves your pick here. You can also type one. Blank = deepseek-chat."),
    field("deepseekModel", "Model", "deepseek-chat"),

    group("Base URL",
          "Default https://api.deepseek.com. Wingman adds /chat/completions for "
          "replies and /models for the model list, so enter just the base. A full "
          "/chat/completions URL also works."),
    field("deepseekBaseURL", "Base URL", "https://api.deepseek.com", url=True),
]

# ── main page ─────────────────────────────────────────────
main_items = [
    group("Apps",
          "Auto-detect covers WhatsApp, WhatsApp Business, Telegram, Instagram, "
          "Messenger, Snapchat, Signal, Discord, X, LinkedIn, LINE, Viber, "
          "WeChat, Slack and Teams, plus dating apps including Tinder, Bumble, "
          "Hinge, OkCupid, Badoo, happn, Grindr, Aisle, TrulyMadly and Feeld.\n\n"
          "To add anything else (Hopr, for example), open the \"Wingman Apps\" "
          "row in the main Settings list, just below Wingman."),
    switch("autoDetectApps", "Auto-detect Chat & Dating Apps", True),

    group(None,
          "Optional. Only needed if an app is missing from the Wingman Apps "
          "list. Type bundle IDs separated by commas, e.g. com.hopr.app"),
    field("otherAppIDs", "Extra Bundle IDs", "com.example.app, com.other.app"),

    group("Default AI",
          "You can switch between Claude and DeepSeek for any single reply "
          "inside Wingman. This only picks which one is selected first."),
    segment("apiProvider", ["Claude", "DeepSeek"]),

    group("API Keys", "Each service has its own page."),
    link("Claude API", "WingmanClaude", claude_items),
    link("DeepSeek API", "WingmanDeepSeek", deepseek_items),

    group("Sound Like Me",
          "Describe how you text, e.g. \"lots of Hinglish, short sentences, no "
          "caps, say bro and yaar a lot, sarcastic\"."),
    {"cell": "PSEditTextCell", "defaults": D, "key": "soundLikeMe",
     "label": "Style", "placeholder": "Describe your texting style..."},

    group("Bubble",
          "Tap the bubble to capture the screen, long-press to capture 3 screens "
          "of history. Drag it anywhere and each app remembers its spot. If you "
          "hide it from inside Wingman, it returns next time you open the app.\n\n"
          "Quick replies are edited inside the Wingman sheet and saved per app."),
    switch("bubbleOnRight", "Start on Right Edge", True),
    slider("bubbleAlpha", "Bubble Opacity", 0.85, 0.3, 1.0),
]

main = {
    "entry": {"cell": "PSLinkCell", "label": "Wingman", "icon": "Wingman.png"},
    "title": "Wingman",
    "items": main_items,
}

# ── app picker (top-level, AltList) ───────────────────────
apps = {
    "entry": {
        "cell": "PSLinkListCell",
        "label": "Wingman Apps",
        "icon": "WingmanApps.png",
        "bundle": "AltList",
        "detail": "ATLApplicationListMultiSelectionController",
        "isController": True,
        "defaults": D,
        "key": "manualApps",
        "defaultApplicationSwitchValue": False,
        "useSearchBar": True,
        "hideSearchBarWhileScrolling": False,
        "alphabeticIndexingEnabled": True,
        "sections": [
            {"sectionType": "User"},
            {"sectionType": "System"},
        ],
    }
}

pages = {
    "Wingman.plist": main,
    "WingmanClaude.plist": {"title": "Claude API", "items": claude_items},
    "WingmanDeepSeek.plist": {"title": "DeepSeek API", "items": deepseek_items},
    "WingmanApps.plist": apps,
}

os.makedirs(OUT, exist_ok=True)
for name, obj in pages.items():
    path = os.path.join(OUT, name)
    with open(path, "wb") as f:
        plistlib.dump(obj, f)
    # re-read to prove it parses
    with open(path, "rb") as f:
        plistlib.load(f)
    print(f"  {name:24} {os.path.getsize(path):6d} bytes  OK")
