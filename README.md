# Shani

A tweak for iOS 16 (built for an iPhone 14 Pro Max on 16.5, RootHide) that makes an app's
notifications wait. Shani is Saturn, the slow planet.

Every notification gets one more button, **Shani**:

- behind a swipe to the left, next to Clear, in Notification Centre and on the Lock Screen
- among the notification's actions when you hold it down or pull a banner down

Tap it and the notification's app goes on Shani's list. From then on that app's notifications
are kept back, with no banner, no sound and no screen wake, for the time chosen under
Settings → Shani, and come up when the time is over. On a notification of an app that is
being silenced the button reads **Shani Off**.

## Settings → Shani

| Setting | What it does |
| --- | --- |
| Silence For | 5 minutes to 1 day, or a number of minutes typed in |
| Silence Starts | *With Each New Notification*: the app stays on the list; a new notification starts the clock, everything arriving meanwhile joins it, all come up together, the next one starts a new round. *When I Tap Shani*: one silence per tap, from the tap |
| Kept Notifications | when the time is over: show all with one alert, with an alert each, silently, or keep them in the log only |
| The Shani Button | where it appears, whether a tap also clears the notification, confirmation pill, haptic |
| Apps & Log | the apps on the list, what is held for each and until when; add or remove apps; show what is held now; one notification log per app |

The log exists only for apps on the list. It holds each notification's title and text, when it
came and what Shani did with it, and stays on the phone in `/var/mobile/Library/Shani`.

## How it works

Two libraries, no daemon, no hooking library (method replacement with the Objective-C runtime):

- `Shani.dylib` in SpringBoard
  - `ShaniHooks.m`: six methods. Three on `NCNotificationDispatcher` (post, modify, withdraw),
    where every notification passes on its way to banner, Lock Screen and Notification Centre;
    `-[NCNotificationGroupList supplementaryActionsForNotificationListCell:]` for the swipe
    buttons; `-[NCNotificationRequestContentProvider currentActions]` and
    `_iconImageForNotificationAction:` for the long-press action and its Saturn glyph.
  - `ShaniEngine.m`: the list, the holds, the timer (a `PCPersistentTimer`, so held
    notifications come up on time even if the phone has to wake for it), the log files.
  - `ShaniUI.m`: the glyph and the confirmation pill. `ShaniDebug.m`: test commands.
- `ShaniPrefs.dylib` in the Settings app (`PrefsHelper.m`): the Apps & Log screens. The rest of
  the Settings page is a plist made by `tools/make_prefs.py`.

Held notifications live in SpringBoard's memory. After a respring SpringBoard hands every
stored notification out again, and the ones whose hold is still running are held again.
Critical alerts are never held. A start-up guard keeps Shani out of the way if SpringBoard
restarts three times in a row right after it loads.

Limits: an app's badge and anything it does outside notifications are untouched; an Apple
Watch or CarPlay gets its copy of a notification from iOS directly, not through SpringBoard.

## Build and test

GitHub Actions (`.github/workflows/build.yml`): a compile check on Linux, the package on macOS
with `roothide/theos` and the iOS 16.5 SDK, a gate for the versioned arm64e slice
(`tools/verify_dylib.py`), and `tools/sim_test.sh`, which loads Shani into the SpringBoard of
an iOS 16.4 simulator and sends real push notifications to a small test app (`probe/`).

`tools/phone.sh` installs and drives it on the phone over SSH.
