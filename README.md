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
| **Close** | Swipe up from the bottom edge (the Home gesture), the edge swipe again, or Close Atelier. The bench also goes away by itself when the phone locks, the screen turns off, the App Switcher opens or another app comes to the front. |

Settings → **Atelier** (a plist-only page; changes apply without a respring).

## How it works

Everything is in SpringBoard; there is no helper app and nothing is loaded into apps.

1. **The app's scene.** SpringBoard keeps one FrontBoard scene per running app, named
   `sceneID:<bundle id>-default`. `+[FBSceneManager sharedInstance] -sceneWithIdentifier:` finds it.
   If the app isn't running, `-[SpringBoard launchApplicationWithIdentifier:suspended:YES]` starts
   it in the background (the way a notification would) and SpringBoard makes the scene.
2. **The picture.** `-[FBScene uiPresentationManager] -createPresenterWithIdentifier:priority:`
   gives a scene presenter; activated, its `-presentationView` shows the app's layers. This is the
   mechanism SpringBoard itself uses for the app in front, so a touch inside that view goes to the
   app, not to SpringBoard.
3. **Live or still.** `-[FBScene updateSettingsWithBlock:]` with `setForeground:YES` makes the app
   run as a foreground app; `NO` lets iOS suspend it again. When the bench closes, every app it
   brought to the foreground goes back to the background (except the one that is in front anyway).
4. **Scale, don't resize.** Every app keeps the size of the whole screen; a tile is that picture
   scaled down (`AtelierTile`, `AtelierLayout.m`). Nothing has to be relaunched to change places,
   which is why a swap is instant and keeps each app's state. *Resize Apps to Fit (Beta)* instead
   sets the scene's frame to the tile's size (`setFrame:` on the scene settings).
5. **Minis don't take touches.** A mini has a shield view over it (its layer marked
   `hitTestsAsOpaque`), so the window server hands the touch to SpringBoard: a tap swaps, a hold
   opens the menu.
6. **Stills.** When the freeze clock runs out, the bench takes one picture of the screen
   (`_UICreateScreenUIImage`), cuts each mini's rectangle out of it, shows that over the tile and
   sends the mini's scene to the background.
7. **Zero cost while hidden.** No timer, no polling. The half-second clock that looks after the
   bench (freeze, "has SpringBoard moved on?", restart an app that was closed underneath) and the
   touch listener exist only while the bench is on screen.

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
| `tools/sim_test.sh` | Loads Atelier into a simulator's SpringBoard, drives it, takes the pictures. |
| `tools/phone.sh` | Install, log and test commands over USB SSH. |
| `tools/make_prefs.py` | Generates the Settings page and its icon. |
| `tools/verify_dylib.py` | CI gate: versioned arm64e slice, system libraries only. |
