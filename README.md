# Chakra

A wheel of your apps, parked on the edge of the screen. A SpringBoard tweak for RootHide (iOS 15+,
built and checked for iPhone 14 Pro Max on iOS 16.5).

The idea comes from floating-ball launchers such as TheBall, a TrollStore app that keeps a helper
process running to draw over other apps. Chakra is written from scratch and shares no code or
artwork with it. It lives inside SpringBoard instead: it is there from the moment the phone
starts, there is no app to keep alive, and because it runs where the system's own controls run,
the system actions actually work.

## Using it

| Gesture | What happens |
| --- | --- |
| Tap the ball | The wheel opens. Tap an icon, or anywhere else to close. |
| Slide from the ball | The wheel opens under your finger; lift over an icon to run it. One move. |
| Hold, then drag | Moves the ball. It snaps to the nearer edge and remembers the spot. |
| Hold, then let go | The editor: add, remove and reorder what is on the wheel. |

Left alone for a few seconds the ball fades and tucks part-way into the edge.

Icons sit on rings around the ball. Near a corner the half wheel bends into a quarter wheel, and
more icons add rings rather than shrinking anything (up to 16 entries). While the app in front is
in landscape the icons turn to stay upright.

## What can go on the wheel

- **Apps**: anything with a Home Screen icon, including TrollStore apps.
- **Actions**: Home, App Switcher, Last App, Lock Screen, Screenshot, Control Centre, Notification
  Centre, Reachability, Respring.
- **Switches**: Torch, Rotation Lock, Low Power Mode, Dark Mode, Wi-Fi, Bluetooth, Aeroplane Mode.
  A switch shows whether it is on, and tapping it leaves the wheel open, like Control Centre.
- **Shortcuts**: four of your own, typed in under Settings → Chakra. Each is a web link, an app's
  URL scheme (`upi://pay`, `whatsapp://send?phone=…`) or the name of a shortcut in the Shortcuts
  app, with an icon picked from sixty glyphs.

Actions and shortcuts are drawn as glyph discs (a filled circle with a white symbol); apps keep
their own icons. An action this iOS version can't do is left out of the Add list instead of
sitting there doing nothing.

## Settings → Chakra

Ball size, resting strength, tucking, colour; wheel or column layout, icon size, names under icons,
dimming, haptics; whether the ball shows on the Lock Screen or hides in landscape; the four
shortcuts; the debug log. Everything applies at once, no respring.

## How it is put together

| File | |
| --- | --- |
| `Tweak.m` | start-up, notifications, the start-up guard |
| `ChakraBall.m` | the ball: its window, touches, tucking, dragging |
| `ChakraWheel.m` | the menu: plate, icons, picking by slide or tap |
| `ChakraLayout.m` | where icons go (`tools/layout_check.py` checks the same arithmetic) |
| `ChakraEditor.m` | the add / remove / reorder sheet |
| `ChakraItems.m` | apps, actions and shortcuts as wheel entries |
| `ChakraActions.m` | the system actions |
| `ChakraGlyphs.m` | the drawn icons: wheel mark, glyph discs, Bluetooth rune |
| `ChakraCore.m` | log, settings, SpringBoard helpers |
| `ChakraDebug.m` | test commands |
| `tools/make_prefs.py` | the plist-only Settings page and its icon |

No method is hooked. Every private class and method is looked up at run time and its arguments
are checked before it is called, so a missing one costs that one action, not SpringBoard.

If something restarts SpringBoard four times in a row right after it starts, Chakra stays out of
the way until one of its settings is changed.

## Building and testing

Pushing the `chakra` branch runs `.github/workflows/build.yml`:

- **build**: Theos (roothide fork) with Xcode's clang, then a gate that refuses any package whose
  arm64e slice is not the versioned ptrauth ABI SpringBoard needs. The `.deb` is the artifact.
- **simulator**: `tools/sim_test.sh` builds the same sources for the iOS simulator, loads the dylib
  into the simulator's SpringBoard and photographs the ball, the wheel in each corner, the column,
  the editor and a few actions. The pictures and log are the artifact.

Install: copy the `.deb` to the phone, `dpkg -i` it, respring. The log is
`/var/mobile/Library/Logs/Chakra.log`.

### Test commands

Off unless the file `chakra_test` exists in the log folder. Then lines written to `chakra_cmd.txt`
there run in order (`open`, `tap 2`, `move left 0.3`, `items app:com.apple.mobilesafari action:home`,
`action screenshot`, `state`, `shot name`…). The full list is at the top of `ChakraDebug.m`.
