# BluetoothNoClicks

An iOS 16.5 / RootHide take on [MiRO's BluetoothNoClicks](https://github.com/MiRO92/BluetoothNoClicks)
(iOS 13-14), plus one more thing for calls. It loads into SpringBoard only.

| Feature | What it does |
|---|---|
| **Mute Clicks on Bluetooth** | While sound goes to AirPods or any other Bluetooth device, Settings → Sounds & Haptics → Keyboard Feedback → **Sound** is switched off. When the sound leaves Bluetooth it goes back to how you had it. If you keep keyboard sounds off yourself, they stay off. |
| **Mute Notification Sounds** (on calls) | While you're on a call, notifications arrive without their sound, in Ring and in Silent mode. **Only on the Earpiece** keeps the sounds when the call is on speaker, AirPods or the car. **Vibrate Instead** replaces the muted sound with a short buzz. Alarms, timers, critical alerts and Emergency Bypass contacts still play. |

Settings → **BluetoothNoClicks** (plist-only page; changes apply without a respring).

## Why the original does nothing on iOS 16

The original flips the `KEYBOARD_SOUND_SWITCH` row of `SHSSoundsPrefController`. On a phone with
keyboard haptics, iOS 16 replaces that row with the **Keyboard Feedback** page
(`SHSKeyboardClicksControllerViewController`), so the row is never found.

This version writes what that page's Sound switch writes: `keyboard-audio` in
`com.apple.preferences.sounds`, followed by the Darwin notifications
`com.apple.preferences.sounds.changed` and `com.apple.preferences.sounds.keyboard-audio.changed`.
It also remembers that it was the one to turn the sound off (`clicksTurnedOffByTweak`), so it only
ever undoes its own change.

"On Bluetooth" means the current audio route has a Bluetooth output (A2DP, hands-free or LE).
AirPods that are connected but still in their case don't count, because the sound isn't going to
them. The route is read again on every route change, on every lock and unlock, and at respring.

## How notification sounds are muted

Every notification sound goes through SpringBoard's `SBNCSoundController`. Three methods are
hooked (each only if it exists with the expected signature; otherwise it is skipped and logged):

| Method | Hook |
|---|---|
| `canPlaySoundForNotificationRequest:` | Answers no while a call is up |
| `playSoundIfPossibleForNotificationRequest:presentingDestination:` | Skips the sound, buzzes once if a sound was due |
| `playSoundForNotificationRequest:presentingDestination:` | Same, for anything that asks directly |

"On a call" comes from CallKit (`CXCallObserver`): a call that is answered or being dialled, on the
phone line, FaceTime or any app that uses the system call screen. The list is rebuilt from CallKit
each time a sound is muted, so a lost "call ended" can cost one notification sound at most.

## Check it on the phone

1. Keyboard Feedback → Sound on. Put AirPods in: the switch turns off within a second and typing
   is silent. Take them out: the switch is back on.
2. Call your voicemail and have someone message you: no ding, one buzz.
3. `/var/mobile/Library/Logs/BluetoothNoClicks.log` shows each step (`route:`, `keyboard clicks:`,
   `call:`, `muted notification sound from …`). The first line after a respring lists the hooks:
   `notification sound hooks: gate=1 ask=1 play=1`.

## Build

GitHub Actions (`.github/workflows/build.yml`) on macOS: the roothide fork of Theos, the iOS 16.5
SDK, Xcode's clang. The `.deb` is the `bluetoothnoclicks-roothide-deb` artifact.

To change the Settings page, edit `tools/make_prefs.py` and run it (standard library only):

```bash
python3 tools/make_prefs.py layout/Library/PreferenceLoader/Preferences
```

## Uninstalling

If you remove the tweak while Bluetooth audio is connected, turn Keyboard Feedback → Sound back on
yourself; nothing is left running to do it.
