# Dynamic Stage+

An add-on for **Dynamic Stage 1.2** (`me.tomt000.stageduo`, by tomt000) on iOS 16.5 / RootHide.
It doesn't modify Dynamic Stage's files; it's a separate tweak that calls into it.

| Feature | How it works |
|---|---|
| **Hide-keyboard button** | A floating button (Wingman-bubble style) shows while any app's keyboard is up. Tap: that app drops its keyboard. Drag: snaps to an edge, remembers the spot. Long-press while two apps are open: swap them. |
| **Auto-swap** (Settings, off by default) | *When Typing*: tapping a text box in the bottom (stage) app moves it to the top and the top app to the bottom, then reopens its keyboard. *Any Tap*: the first touch in the bottom app swaps. |
| **App Pairs** | Long-press an app icon → **App Pairs…** → pick the second app. Long-press either app afterwards → **Open with …** opens the first app on top and the second in the Dynamic Stage window. Swipe a pair in App Pairs… to flip or delete it. |

Settings → **Dynamic Stage+** (plist-only page; changes apply without a respring).

## How it talks to Dynamic Stage

Dynamic Stage's classes and selectors are obfuscated (`DS_lIlIIl…`). The ones used here were
recovered from the 1.2 binary (`SDPStage.m` documents each). The key one is what Dynamic Stage's
own app strip does when you tap an app:

```objc
[[DS_IIllIIIIIIIlllIIIIllllllIllIll DS_IlIIIlIllllllIIIlIIIIlIIlIIIII]
    DS_IIlIIlIIlllIlIIIlIIIIlIlIIlIII:@{ @"app": SBApplication, @"view": originView }];
```

A swap is: bring the stage app to the front (`launchApplicationWithIdentifier:suspended:`), then
open the previous front app in the stage. While that happens, kills of the two apps (Dynamic
Stage's Auto Kill) are skipped for a few seconds.

These names only match **1.2**. Every call checks `respondsToSelector:` and fails soft (a toast and
a log line), so a different version can't crash SpringBoard; the stage features just stop.

## Files

| File | Role |
|---|---|
| `Tweak.m` | Entry point. SpringBoard vs app role; hooks (icon menu, kill guard, `sendEvent:`) installed only if the method exists. |
| `SDPStage.m` | Bridge into Dynamic Stage: open in stage, swap, launch a pair, kill guard, diagnostics. |
| `SDPButtons.m` | The floating buttons: hide-keyboard and swap (shared Wingman-style bubble). |
| `SDPDebug.m` | Debug Log extras: call tracing, screenshots, and test commands from `sdp_cmd.txt`. |
| `SDPPairsSheet.m` | App Pairs sheet + app picker (no text fields, so SpringBoard never needs keyboard focus). |
| `SDPApp.m` | In-app part: reports keyboard up/down, typing, taps; dismisses / refocuses the keyboard. |
| `SDPCore.m` | Log, Darwin-notify helpers, settings, SpringBoard helpers. |
| `tools/make_prefs.py` | Generates the Settings page and icon in `layout/`. |
| `tools/verify_arm64e.py` | CI gate: refuses a build without a versioned arm64e slice. |

App ⇄ SpringBoard messages are Darwin notifications (`com.adarsh.sdplus.*`); the sender stores
its pid (or a config bitmask) in the name's notify state right before posting.

## Build

Push to `stageduo-plus` and GitHub Actions builds it on macOS (artifact
`stageduoplus-roothide-deb`). Locally on a Mac with RootHide Theos + iOS 16.5 SDK:

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

## Debug log

`/var/mobile/Library/Logs/StageDuoPlus.log` (Settings → Dynamic Stage+ → Debug Log). Every
swap and pair launch writes Dynamic Stage's state before and after, which is what's needed
to tune timings or adapt to a new Dynamic Stage version.
