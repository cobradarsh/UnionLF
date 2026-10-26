# Wingman 1.6.0 — Build & Source Guide

Personal AI reply assistant tweak for iPhone 14 Pro Max, iOS 16.5, **RootHide + ElleKit**.

## What's in this folder

| Path | What it is |
|---|---|
| `Tweak.x` | Entry point. Watches the app coming to the foreground and shows or hides the bubble. |
| `Wingman.h` | Master header: every class, enum and shared helper. |
| `WMBubble.m` | Floating bubble: tap / long-press / drag, per-app position, hidden from your screenshots. |
| `WMCapture.m` | Screen capture and 3-screen scroll capture. |
| `WMOCR.m` | On-device chat reading (Apple Vision), ME/THEM labels, ignore rules for encryption banners and system rows. |
| `WMSheet.m` / `WMSheet.h` | The Wingman sheet: quick replies, Write with AI, API keys & model page. |
| `WMAPIClient.m` | Claude + DeepSeek reply calls (one call returns 3 replies). |
| `WMModels.m` | Fetches the model list your key can use (also the Verify button). |
| `WMPrompts.m` | **All prompt wording.** Edit this to change how replies sound. |
| `WMSettings.m` | Settings storage that survives the app sandbox. |
| `WMApps.m` | Which apps get the bubble (auto-detected chat + dating apps, plus your picks). |
| `WMQuickReplies.m` | The 5 editable quick replies per app, and their defaults. |
| `Wingman.plist` | ElleKit filter: load into UIKit apps. |
| `control` | Package metadata. Depends: `ellekit`, `preferenceloader`, `com.opa334.altlist`. |
| `layout/Library/PreferenceLoader/Preferences/` | Plist-only Settings pages + icons (see below). |
| `tools/build_roothide_linux.sh` | **The exact script that built 1.6.0.** |
| `tools/make_prefs.py` | Generates the four Settings plists in `layout/`. |
| `tests/test_wingman.py` | 46 logic checks (settings memory, reply parsing, URLs, chat-reading rules). |

## Why the Settings pages have no code

Preferences.app on this iPhone runs as **arm64e**. A normal preference *bundle* contains a
compiled binary, and an arm64 one is refused ("incompatible architecture"). So every Settings
page here is a **plist only**, read by PreferenceLoader:

- `Wingman.plist`: main page (top-level row "Wingman")
- `WingmanClaude.plist`, `WingmanDeepSeek.plist`: sub-pages (no `entry` key, so no extra row)
- `WingmanApps.plist`: app picker using AltList. It **must** stay a top-level entry: RootHide's
  PreferenceLoader only resolves a `bundle` to the jailbreak root for top-level entries.

To change Settings, edit `tools/make_prefs.py` and run:

```bash
python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
```

## Build option A — Linux (how 1.6.0 was actually built)

Needs: Theos with the iPhoneOS16.5 SDK, clang 18, `ld64.lld-18`, a real `ldid`
(ProcursusTeam/ldid, built against libplist 2.x), `dpkg-deb`, Python 3 with Pillow.

```bash
export THEOS=~/theos        # Theos checkout containing sdks/iPhoneOS16.5.sdk
bash tools/build_roothide_linux.sh
```

Output: `com.adarsh.wingman_1.6.0_iphoneos-arm64e.deb` in this folder. The script:
1. runs Logos on `Tweak.x`
2. compiles everything for arm64
3. links with the RootHide install name `@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/Wingman.dylib`
4. ad-hoc signs with `ldid -S` (an unsigned dylib won't load)
5. generates icons, then packages with root paths (`/Library/...`, no `/var/jb`) and `Architecture: iphoneos-arm64e`

## Build option B — macOS + Theos (not tested for this project)

Use the **RootHide fork** of Theos, not upstream:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
cd $THEOS/sdks && curl -sLO https://github.com/theos/sdks/releases/latest/download/iPhoneOS16.5.sdk.tar.xz && tar xf iPhoneOS16.5.sdk.tar.xz
cd /path/to/Wingman && make package FINALPACKAGE=1
```

The Makefile sets `THEOS_PACKAGE_SCHEME=roothide`, which handles the arm64e package arch and the
`.jbroot` install name. The `.deb` lands in `packages/`.

## Install

1. Install the `.deb` in Sileo (or `dpkg -i`), respring.
2. Needs **AltList** for the "Wingman Apps" picker (opa334's repo: `https://opa334.github.io`).

## Set up (inside Wingman, not Settings)

A tweak inside a sandboxed app often can't read values typed into the Settings app, so keys
are entered in Wingman itself:

1. Open any chat, tap the **W** bubble → **🔑 API keys & model**.
2. Paste your Claude or DeepSeek key → **Verify & load models** → pick a model.
3. Claude vs DeepSeek is remembered until you switch it.

**Settings → Wingman Apps**: add apps that aren't auto-detected (e.g. Hopr).
**Settings → Wingman**: auto-detect, Sound Like Me, bubble side and opacity.

## Known limits

- Apple's **Messages** app runs as arm64e, so the bubble can't load there. App Store chat and
  dating apps are arm64 and work.
- **DeepSeek** can't see images. It works from the on-device transcript (and your context).
