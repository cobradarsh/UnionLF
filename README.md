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
recovered from the 1.2 binary and confirmed on device with call tracing (`SDPStage.m` documents
each). Everything replays what Dynamic Stage does itself:

| Step | What Dynamic Stage does natively | How Dynamic Stage+ triggers it |
|---|---|---|
| Open an app in the stage | App strip fills a global `@{view, app}` (0xe5c10 arm64e), then calls the card's open method with nil | Fill the same global (checked to be in its `__common`), call open with nil |
| Bring the stage app up | End of its drag-up gesture: `[[pane class] current]` → `DS_llIIIlIIlIIllIllIIIllllIIlIlll` | Same call (`nativeExpand`) |
| Show a hidden stage | Swipe up from the bottom edge | A scripted swipe into its gesture view (`gestureRecognizerShouldBegin:` first, `touchLocation` fed per frame) |
| Fit the top app | Swipe end stores `bundleID + {0,0,W,500}` in its relaunch singleton, then relaunches the app | Same two calls (`fitTopApp:`) |

**Swap** = expand the stage app → open the old top app in the stage once it's in the background
(the case its app strip handles, so its window connects) → reveal → fit. The app moving down is
kept alive (Dynamic Stage's Auto Kill is skipped for it for a few seconds). The app moving up is
only restarted if it's in Dynamic Stage's **iPhone launch mode** (e.g. WhatsApp): those apps can
only take a new size by relaunching. iPad-mode apps (Instagram, Safari) keep their state both ways.

**App Pair** = launch the first app → open the second in the (hidden) stage → reveal → fit.

## When the hide-keyboard button shows

Only while an app that is on screen really has its keyboard up. Nothing is remembered:

- **Lease.** While its keyboard is up, an app stamps the system uptime into its own notify state
  (`com.adarsh.sdplus.kb.state.<pid>`) once a second. SpringBoard believes a stamp for 3 s. A frozen,
  backgrounded or killed app can't stamp, so it drops out by itself.
- **A real keyboard.** iOS also posts `UIKeyboardWillShow` for a chat app's message bar (an input
  accessory view, 60-100 pt, no keys). "Up" means the keyboard minus that bar is at least 150 pt.
- **Active.** Not while the app is behind Control Center, Notification Center or the app switcher.
- **On screen.** SpringBoard only counts the front app, the app in the open stage window, and view
  services drawing inside them (in-app Safari, share sheets). An app that is merely running doesn't count.

Up to 1.0.10 apps posted shown/hidden events and SpringBoard kept a list. iOS posts "shown" again
while an app is being backgrounded, so frozen apps stayed on the list and the button floated over
Camera, Contacts and everything else (the log once showed "3 keyboards up").

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
