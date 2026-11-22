# Atelier

A workbench of live apps for the iPhone (iOS 16.5, RootHide, ElleKit). One big **main** app and up
to four **mini** tiles of other apps on one screen; tap a mini and it changes places with the main.
The idea is vivo's Origin Workbench; nothing of vivo's is used.

| | |
|---|---|
| **Layouts** | **Side**: minis in a column on the left, the main at 80 % on the right. **Top**: minis in a row across the top, the main below. **Split**: two apps next to each other, both usable at once, with a handle between them. |
| **Open** | Slide a finger in from the edge of the screen just above the bottom corner (or up along that edge). Or hold an app's icon → **Open in Atelier**. Or post the Darwin notification `com.adarsh.atelier.open` / `.close` / `.toggle`. |
| **Menu** | The pill with three dots above the main: Full Screen, Switch Layout, Replace App, Close App, Save as Set, Sets…, Close Atelier. Hold a mini for its own menu (Make Main, Full Screen, Replace App, Close App). |
| **Sets** | Save the two to five apps on the bench, with their layout, as a set. A set opens from the Sets sheet, or from the icon menu of any app in it. Swipe a set to name it (from a list; no typing), move it up or delete it. |
| **Minis** | **Smart** (default): live while the bench is being used, stills after 20 s without a touch, live again at the next touch. **Always Live**. **Stills Only**: only the main runs. A mini that is a still has its app in the background, where iOS suspends it. |
| **Close** | Swipe up from the bottom of the screen, the edge swipe again, or Close Atelier. The bench also goes away by itself when the phone locks, the screen turns off, the App Switcher opens or another app comes to the front. |

Settings → **Atelier** (a plist-only page; changes apply without a respring).

## How it works

Everything is in SpringBoard; there is no helper app and nothing is loaded into apps.

1. **The app's scene.** SpringBoard keeps a FrontBoard scene per running app, named
   `sceneID:<bundle id>-default`, or `sceneID:<bundle id>-<UUID>` for apps that can have several
   windows (Safari, Maps, Files). `+[FBSceneManager sharedInstance] -sceneWithIdentifier:` finds
   the first kind; the second is found by looking through every scene for the app's bundle id
   (the foreground one first, then the one the App Switcher knows). If the app isn't running,
   `-[SpringBoard launchApplicationWithIdentifier:suspended:YES]` starts it in the background (the
   way a notification would) and SpringBoard makes the scene.
2. **The picture.** `-[FBScene uiPresentationManager] -createPresenterWithIdentifier:priority:`
   gives a scene presenter; activated, its `-presentationView` shows the app's layers. This is the
   mechanism SpringBoard itself uses for the app in front, so a touch inside that view goes to the
   app, not to SpringBoard, and lands at the right place even though the picture is scaled.
3. **Live or still.** `-[FBScene updateSettingsWithBlock:]` with `setForeground:YES` makes the app
   run as a foreground app; `NO` lets iOS suspend it again. When the bench closes, every app it
   brought to the foreground goes back to the background (except the one that is in front anyway).
4. **Scale, don't resize.** Every app keeps the size of the whole screen; a tile is that picture
   scaled down (`AtelierTile`, `AtelierLayout.m`). Nothing has to be relaunched to change places,
   which is why a swap is instant and keeps each app's state.
5. **Minis don't take touches.** A mini has a shield view over it (its layer marked
   `hitTestsAsOpaque`), so the window server hands the touch to SpringBoard: a tap swaps, a hold
   opens the menu.
6. **Stills.** When the freeze clock runs out, the bench takes one picture of the screen
   (`_UICreateScreenUIImage`), cuts each mini's rectangle out of it, shows that over the tile and
   sends the mini's scene to the background.
7. **Full Screen** opens the very scene that was on the bench: its `SBDeviceApplicationSceneHandle`
   wrapped in an `SBDeviceApplicationSceneEntity`, in an activation request to `SBMainWorkspace`.
   (Opening the app by bundle id instead gave Maps and Files a second scene in the simulator.)
8. **Zero cost while hidden.** No timer, no polling. The half-second clock that looks after the
   bench (freeze, "has SpringBoard moved on?", restart an app that was closed underneath) and the
   touch listener exist only while the bench is on screen. The edge strip is a passive window.

## What was checked, and where

**On the phone (read-only, over SSH):** every private class and selector below is in the iOS 16.5
(20F66) shared cache. Nothing was installed and SpringBoard was not touched.

**In the iOS 16.4 simulator** (iPhone 14 Pro Max, the tweak loaded into the simulator's own
SpringBoard by `tools/sim_test.sh`, on GitHub's arm64 and Intel Macs). The pictures and logs of the
last run (commit `ffa588a`, the code in the 1.0.0 package) are in `deb_out/atelier-1.0.0/sim/`: the
Intel Mac's run in full, and the arm64 Mac's logs under `arm64-run/`. Touches are real ones: mouse
clicks on the Simulator's window (`tools/click.c`), which the simulator turns into fingers.

| Checked | Result |
|---|---|
| Five apps hosted live at once (Settings, Maps, Safari, Files, the probe app) | yes: `03-side-five`, `05-top` |
| An app that isn't running is started in the background and gets a scene | yes (it takes up to 20 s on the CI Macs; the pane waits that long) |
| Side, Top and Split layouts, the swap, the split handle's share | yes: `04`–`11` |
| A real touch on the scaled main reaches the app at the right point | yes: a click at screen 236,360 arrived in the app as 200,300, the expected point at scale 0.80 (`touch.txt` T1, T1b) |
| The app's keyboard comes up on the bench and typing lands | yes: the probe's text field got its keyboard (346 pt) and a tap on the G key typed "G" (T2 in `arm64-run/touch.txt` and in `earlier-run-typing/`; in the last Intel run the keyboard was showing iOS's "slide to type" tip instead of keys, so that click typed nothing) |
| A tap on a mini swaps; the pill opens the menu; a menu row works | yes (T3, T4, T4b) |
| The edge strip opens the bench on a real drag | yes (T6) |
| A swipe up from the bottom of the screen closes the bench | yes (T5), through the backdrop's own swipe recogniser; the screen-edge recogniser never fired for a mouse drag |
| Freezing sends the minis' apps to the background, a touch brings them back | yes: the probe logged `DidEnterBackground` / `WillEnterForeground` each time; stills in `12-frozen` |
| Full Screen keeps the app's one scene | yes: Maps had one scene before and after |
| Picker sheet, Sets sheet, saving a set, icon-menu rows | yes: `17`–`21` (the icon-menu rows were built and run by test command, not by holding an icon) |
| No SpringBoard crash | none in the last run on either Mac. Two in earlier runs: one was Atelier's (a struct returned through `objc_msgSend`, Intel only, fixed), one the test's own (it asked SpringBoard to "launch" itself) |
| An app that dies under the bench is started again | yes: in the last arm64 run FrontBoard's scene-update watchdog killed four apps at once when the minis were woken (the Mac was starved: the reports show 10 s without an answer); the bench noticed, started them again and showed them |

**Not checked anywhere yet** (needs the phone):

- anything about ElleKit loading the library, RootHide paths, the real `Atelier.log` location;
- the real Home gesture with the bench up (SpringBoard acts on it underneath; the bench should
  then close by itself, either through its own swipe-up or because the app in front changed);
- holding an icon and choosing the rows (the rows were built and run by test command);
- the touch listener that keeps minis awake while you use the main app (`IOHIDEventSystemClient`;
  it is compiled out of the simulator build);
- living next to Dynamic Stage, Dynamic Stage+ and Chakra; third-party apps; apps that block
  screenshots; landscape; heat and battery with five live apps;
- the window level (999: above apps, below Control Centre and the lock screen) against the
  phone's own windows, e.g. whether Dynamic Stage's window lies over the bench.

## Known limits

- **The status bar is hidden by the bench**, and the apps' pictures have an empty band where it
  would be: on iOS the status bar is SpringBoard's, drawn in windows that lie under the bench.
- **Apps that can have several windows** (Safari, Maps, Files, Notes…) and that the bench itself
  started: if you later open such an app from the Home Screen, SpringBoard gives it a second
  window instead of the bench's, because the App Switcher doesn't know the bench's one. From then
  on the bench shows the App Switcher's window. Full Screen from the bench does not have this
  problem, and an app that was already running when it was put on the bench never has it.
- **Split is two scaled pictures**, each smaller than half the screen, not two half-screen apps.
  Making apps lay out at the size of their tile works (key `resizeApps`, from the test file only:
  `set resizeApps true`; pictures `50`–`53`), but in one arm64 simulator run SpringBoard's main
  thread stood still for 25 s and 42 s while scenes were being resized (not seen in the other
  runs). It has no Settings switch until that is understood on the phone.
- **Waking minis depends on the apps answering.** FrontBoard kills an app that does not answer a
  scene update within 10 s. That happened once, on an overloaded CI Mac (see the table above); on
  the phone it would show as a mini reloading.
- **Minis freeze 20 s after the last touch**, counted from touches on the bench itself; touches
  inside the main app count only if the touch listener works on the phone (not checked).
- The edge strip takes taps where it lies (16 pt wide, 110 pt tall, just above the Home bar on the
  right edge). `set triggerMode 1` from the test file tries a system gesture recogniser instead,
  which blocks nothing; not checked on the phone.

## Private API used

All found in the phone's iOS 16.5 cache; "sim" = exercised in the iOS 16.4 simulator's SpringBoard.

| What | Where it is used | sim |
|---|---|---|
| `FBSceneManager` `+sharedInstance`, `-sceneWithIdentifier:`, `-enumerateScenesWithBlock:` | finding the app's scene | yes |
| `FBScene` `-identifier`, `-settings`, `-clientProcess`, `-isValid`, `-uiPresentationManager`, `-updateSettingsWithBlock:` | hosting, live / still | yes |
| scene settings `-isForeground`, `-setForeground:`, `-setDeactivationReasons:`, `-setUnderLock:`, `-frame`, `-setFrame:` | live / still, (resize) | yes |
| `UIScenePresentationManager` `-createPresenterWithIdentifier:priority:`; presenter `-modifyPresentationContext:`, `-activate`, `-presentationView`, `-invalidate`; context `-setAppearanceStyle:` | the picture | yes |
| `-[SpringBoard launchApplicationWithIdentifier:suspended:]` | starting an app in the background | yes |
| `SBApplicationController` `-applicationWithBundleIdentifier:`; `SBApplication` `-processState`, `-displayName`, `-info` | app lookup | yes |
| `SBSceneManagerCoordinator` `+mainDisplaySceneManager`, `-existingSceneHandleForScene:`; `SBDeviceApplicationSceneEntity` `-initWithApplicationSceneHandle:`; `SBMainWorkspace` `-createRequestForApplicationActivation:options:`, `-executeTransitionRequest:` | Full Screen | yes |
| `SBMainSwitcherControllerCoordinator` `-isAnySwitcherVisible`, `-recentAppLayouts` (items' `bundleIdentifier`, `uniqueIdentifier`) | closing when the switcher opens, recents in the picker, scene choice | yes |
| `-[UIApplication _accessibilityFrontMostApplication]`, `SBLockScreenManager -isUILocked` | which app is in front, locked | yes |
| `SBIconView` `-applicationShortcutItems`, `+activateShortcut:withBundleIdentifier:forIconView:` (replaced), `SBSApplicationShortcutItem`, `SBSApplicationShortcutSystemPrivateIcon` | icon menu | rows built: yes; shown in a real icon menu: no |
| `CALayer -setHitTestsAsOpaque:` | mini shields, edge strip | yes |
| `_UICreateScreenUIImage(WithRotation)` | stills | yes |
| `UIWindow -_canBecomeKeyWindow` (overridden) | the bench never takes the keyboard from the app | yes |
| `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]`, `LSApplicationWorkspace` | icons, app list | yes |
| `IOHIDEventSystemClient…` (create, schedule, register callback) | touch listener while the bench is up | no (phone only) |
| `_UISystemGestureManager -addGestureRecognizer:toDisplayWithIdentity:` | only with `triggerMode 1` | no |

Shared with other tweaks on the phone: Dynamic Stage+ replaces the same two `SBIconView` methods
for its App Pairs rows. Both keep the earlier code and call it, so each adds its own rows.
Atelier's are replaced with the Objective-C runtime (`AtelierHook`), not through ElleKit, and the
library links nothing but iOS's own frameworks.

## Safety

- Nothing starts until SpringBoard has finished starting, plus four seconds.
- Start-up guard: three starts in a row that did not last 25 s, and Atelier stays out of the way
  until a setting is changed (`Atelier.boot` in the log folder holds the count).
- Every private call is looked up first and skipped with a log line if this iOS doesn't have it.
- If the first install goes wrong: `tools/phone.sh remove`, or `dpkg -r com.adarsh.atelier` and
  `sbreload` over SSH.

## Testing on the phone

`tools/phone.sh` (USB SSH, host `iphone-root`):

```bash
tools/phone.sh install deb_out/atelier-1.0.0/com.adarsh.atelier_1.0.0_iphoneos-arm64e.deb
tools/phone.sh log                      # "started: …" means it is running in SpringBoard
tools/phone.sh run "apps com.apple.Preferences com.apple.mobilesafari com.apple.Maps" "wait 4" "state" "shot bench"
tools/phone.sh fetch bench .            # the picture SpringBoard took
tools/phone.sh run "main 1" "wait 1" "layout top" "wait 1" "state"
tools/phone.sh run "freeze" "wait 2" "state" "scenes"      # minis: frozen, their scenes fg=0
tools/phone.sh run "windows"            # every SpringBoard window with its level
tools/phone.sh run "close"
```

The commands are listed at the top of `AtelierDebug.m`. They work while Settings → Atelier →
Debug Log is on (it is by default). Knobs without a Settings row, all through `set <key> <value>`:
`windowLevel` (999), `sideScale` (0.80), `triggerWidth` (16), `triggerTint` (1 shows the strip in
red), `triggerMode` (0 strip, 1 system gesture), `touchWatch` (1), `presenterPriority` (100),
`resizeApps` (false), `stillAfter` (1.6).

## Files

| File | Role |
|---|---|
| `Tweak.m` | Entry point, start-up guard, notifications, the two icon-menu replacements. |
| `AtelierScenes.m` | `AtelierPane`: one hosted app (find or start the scene, presenter, foreground / background, size). |
| `AtelierBench.m` | The window: tiles, the swap, menus, the freeze clock, open and close. |
| `AtelierLayout.m` | Where the tiles go (arithmetic only; `tools/layout_check.py` repeats and checks it). |
| `AtelierSheets.m` | App picker and Sets list (bottom sheets, lists only). |
| `AtelierTrigger.m` | The edge strip. |
| `AtelierDebug.m` | Test commands from a file. |
| `AtelierCore.m` | Log, careful messaging, settings, SpringBoard helpers. |
| `probe/` | A small app for the simulator test: reports its size, life cycle, keyboard and touches. |
| `tools/sim_test.sh`, `tools/click.c` | Loads Atelier into a simulator's SpringBoard, drives it, clicks on the Simulator window as touches, takes the pictures. |
| `tools/phone.sh` | Install, log and test commands over USB SSH. |
| `tools/make_prefs.py` | Generates the Settings page and its icon. |
| `tools/verify_dylib.py` | CI gate: versioned arm64e slice, system libraries only. |

## Build

Push to the `atelier` branch and GitHub Actions builds it on macOS (artifact
`atelier-roothide-deb-<runner>`), after a syntax check on Linux, and runs the simulator test
(`atelier-simulator-<runner>`). Locally on a Mac with RootHide Theos and the iOS 16.5 SDK:

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```
