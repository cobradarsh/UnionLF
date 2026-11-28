#!/bin/bash
# Runs Guest Mode inside the real Photos app of an iOS simulator and photographs it.
#
# Guest Mode hooks nothing, so the same sources build for the simulator with plain clang (no
# Theos, no ElleKit). The library is loaded into Photos with DYLD_INSERT_LIBRARIES and driven
# through its command file (GMDebug.m); the pictures come from `simctl io screenshot`.
#
# What this shows, on the phone's iOS generation (16.4 when the runtime can be had): the button
# over Photos, the picker opening inside Photos, a selection, a failed Face ID changing nothing,
# Guest Mode coming up with the gallery over Photos, a photo and a video full screen, Guest Mode
# surviving a restart of Photos, a failed Face ID keeping it on, and Photos back to normal.
# The test build (-DGM_TEST) can answer the Face ID question itself; the package cannot.
# It cannot send touches: what a finger does (the picker, dragging, swiping) is tried on the phone.
#
# usage: tools/sim_test.sh [output folder] [wanted iOS version, e.g. 16.4]
#        (run from the repository root, on a Mac with Xcode)
set -u
OUT="${1:-$PWD/sim-out}"
WANT="${2:-}"
mkdir -p "$OUT/run"
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"/*
APP=com.apple.mobileslideshow

ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS="-arch $ARCH -mios-simulator-version-min=15.0 -isysroot $SDK -O1 -g -Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable"
SOURCES="GMCore.m GMAuth.m GMButton.m GMGallery.m GMDebug.m"
FRAMEWORKS="-framework UIKit -framework Foundation -framework Photos -framework PhotosUI -framework AVKit -framework AVFoundation -framework LocalAuthentication -framework CoreGraphics -framework QuartzCore"
echo "== build for the simulator ($ARCH)"
(
  xcrun --sdk iphonesimulator clang $FLAGS -DGM_TEST -fobjc-arc -dynamiclib $FRAMEWORKS \
    -install_name /usr/lib/GuestMode.dylib -o "$OUT/GuestMode.dylib" $SOURCES || exit 1
  codesign -f -s - "$OUT/GuestMode.dylib" || exit 1
) > "$OUT/build.log" 2>&1
status=$?
cat "$OUT/build.log"
[ "$status" = "0" ] && [ -f "$OUT/GuestMode.dylib" ] || { echo "simulator build FAILED"; exit 1; }

echo "== pick a simulator (wanted iOS: ${WANT:-the oldest there is})"
PICK=$(xcrun simctl list -j | python3 tools/pick_sim.py "$WANT")
case "$PICK" in
  USE\|*)
    IFS='|' read -r _ UDID DEVNAME IOSVER <<< "$PICK" ;;
  CREATE\|*)
    IFS='|' read -r _ RUNTIME DEVTYPE IOSVER <<< "$PICK"
    DEVNAME="Guest Mode test (${DEVTYPE##*.})"
    UDID=$(xcrun simctl create "$DEVNAME" "$DEVTYPE" "$RUNTIME") || { echo "could not create a simulator for $RUNTIME"; exit 1; } ;;
  *)
    echo "no iPhone simulator runtime available"; xcrun simctl list runtimes; exit 1 ;;
esac
echo "simulator: $DEVNAME, iOS $IOSVER ($UDID)" | tee "$OUT/simulator.txt"
xcrun simctl boot "$UDID" 2>&1 | grep -v "current state: Booted" || true
xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1 || { tail -5 "$OUT/boot.log"; echo "simulator did not boot"; exit 1; }
tail -2 "$OUT/boot.log"
xcrun simctl ui "$UDID" appearance dark > /dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 > /dev/null 2>&1 || true
defaults write com.apple.CrashReporter DialogType none > /dev/null 2>&1 || true

echo "== what Photos says about Face ID in its Info.plist"
APPDIR=$(xcrun simctl get_app_container "$UDID" "$APP" app 2> /dev/null || true)
echo "Photos app: ${APPDIR:-not found}"
if [ -n "$APPDIR" ]; then
  plutil -p "$APPDIR/Info.plist" 2> /dev/null | grep -i -E "FaceID|CFBundleExecutable|CFBundleShortVersion" || echo "(no NSFaceIDUsageDescription key in the simulator's Photos)"
fi

echo "== a video for the library (a few seconds of the simulator's own screen)"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/clip.mp4" > "$OUT/record.log" 2>&1 &
REC=$!
sleep 3
xcrun simctl launch "$UDID" com.apple.Preferences > /dev/null 2>&1 || true
sleep 3
xcrun simctl launch "$UDID" com.apple.mobilesafari > /dev/null 2>&1 || true
sleep 3
kill -INT "$REC" 2> /dev/null
wait "$REC" 2> /dev/null
xcrun simctl terminate "$UDID" com.apple.Preferences > /dev/null 2>&1 || true
xcrun simctl terminate "$UDID" com.apple.mobilesafari > /dev/null 2>&1 || true
ls -la "$OUT/clip.mp4" 2> /dev/null || echo "(no clip recorded)"

echo "== the video goes into the library"
if [ -s "$OUT/clip.mp4" ]; then
  xcrun simctl addmedia "$UDID" "$OUT/clip.mp4" && echo "video added to the library" || echo "(the video could not be added)"
  sleep 8
fi

REPORTS=~/Library/Logs/DiagnosticReports
mkdir -p "$REPORTS"
touch "$OUT/.before"
collect_crashes() {
  local found=""
  for f in "$REPORTS"/*.ips; do
    [ -f "$f" ] && [ "$f" -nt "$OUT/.before" ] || continue
    cp "$f" "$OUT/" && found="$found $OUT/$(basename "$f")"
  done
  if [ -n "$found" ]; then echo "-- crash reports:"; python3 tools/ips_summary.py $found; CRASHED=yes; else echo "-- no crash report"; fi
}
CRASHED=""

LOG="$RUN/guestmode.log"
touch "$RUN/diag"
launch() {                                            # launch <n>: start Photos with Guest Mode in it; n-th start
  xcrun simctl terminate "$UDID" "$APP" > /dev/null 2>&1 || true
  sleep 2
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$OUT/GuestMode.dylib" SIMCTL_CHILD_GUESTMODE_DIR="$RUN" \
    xcrun simctl launch "$UDID" "$APP" > "$OUT/launch.txt" 2>&1 || { cat "$OUT/launch.txt"; return 1; }
  for i in $(seq 1 60); do
    sleep 1
    seen=$(grep -c 'Guest Mode 1\.' "$LOG" 2>/dev/null || true)
    [ "${seen:-0}" -ge "${1:-1}" ] && { sleep 4; return 0; }
  done
  return 1
}

MARKS=0
DEAD=""
cmd() {                                               # command lines, run in order inside Photos; returns when they are done
  local waited=0 mark
  [ -n "$DEAD" ] && return 0
  MARKS=$((MARKS + 1)); mark="done$MARKS-$$"
  printf '%s\n' "token-$mark" "$@" "mark $mark" > "$RUN/cmd.tmp"
  mv "$RUN/cmd.tmp" "$RUN/cmd.txt"
  while ! grep -q -F "mark: $mark" "$LOG" 2>/dev/null && [ "$waited" -lt 90 ]; do sleep 1; waited=$((waited + 1)); done
  if [ "$waited" -ge 90 ]; then DEAD=yes; echo "  Photos did not finish these in 90 s: $*"; fi
  cp "$LOG" "$OUT/guestmode.log" 2>/dev/null || true
  return 0
}
shot() {
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || { echo "screenshot $1 failed"; return; }
  sips -s format jpeg -s formatOptions 80 -Z 1500 "$OUT/$1.png" --out "$OUT/$1.jpg" > /dev/null 2>&1 && rm -f "$OUT/$1.png"
  echo "  shot $1"
}
last() { grep -F "$1" "$LOG" 2>/dev/null | tail -1 | cut -c21-; }
FAILED=0
PASSED=0
check() {                                             # check <what> <the last log line starting so> <text it must hold>
  local line
  line=$(last "$2")
  if printf '%s' "$line" | grep -q -F -- "$3"; then
    PASSED=$((PASSED + 1)); echo "  ok    $1"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL  $1"; echo "        wanted \"$3\" in: ${line:-(no line starting \"$2\")}"
  fi
}

echo "== 1. Photos with Guest Mode loaded"
if ! launch 1; then
  echo "Guest Mode did not report from inside Photos"; cat "$OUT/launch.txt" 2> /dev/null
  shot "01-no-report"
  collect_crashes
  exit 1
fi
cmd "state"
shot "01-photos-with-button"
check "the library is loaded and starts in normal mode" "Guest Mode 1." "saved state: normal"
check "the button's window is shown" "button: window" "window shown"
check "nothing chosen, phase idle" "state: phase" "phase idle, 0 chosen"
check "the gallery is down" "gallery:" "gallery: down"
cmd "menu"
check "hold menu with nothing chosen" "menu:" "menu: Choose Photos and Videos"

echo "== 2. the picker inside Photos"
cmd "pick" "state"
shot "02-picker"
check "the picker is presented" "button: window" "presented PHPickerViewController"
cmd "dismiss" "state"
check "the picker is gone" "button: window" "presented -"

echo "== 3. a selection"
cmd "select 4" "state" "menu"
shot "03-chosen"
check "four items chosen" "state: phase" "phase chosen, 4 chosen, 4 still in the library"
check "the button shows the count" "button: window" "badge 4"
check "hold menu with a selection" "menu:" "menu: Start Guest Mode | Change Selection | Clear Selection"
cmd "clear" "state"
check "Clear forgets the selection" "state: phase" "phase idle, 0 chosen"
cmd "select 30" "state"
check "never more than 10 items" "state: phase" "phase chosen"
if last "state: phase" | grep -q -E "phase chosen, (1[1-9]|[2-9][0-9]) chosen"; then FAILED=$((FAILED + 1)); echo "  FAIL  more than 10 chosen"; fi
cmd "select 4" "state"

echo "== 4. Face ID fails: nothing changes"
cmd "auth fail" "tap" "wait 1" "state"
check "a failed check does not start Guest Mode" "button: Guest Mode" "Guest Mode NOT started"
check "still only chosen" "state: phase" "phase chosen, 4 chosen"
check "the gallery is still down" "gallery:" "gallery: down"

echo "== 5. Face ID passes: Guest Mode"
cmd "auth pass" "tap" "wait 2" "state"
shot "04-guest-gallery"
check "Guest Mode is on" "state: phase" "phase GUEST, 4 chosen"
check "the gallery covers Photos" "gallery:" "gallery: UP"
check "the gallery shows the grid with 4 items" "gallery:" "4 item(s)"
check "the state is saved" "state: Guest Mode ON" "4 item(s), saved"
cmd "menu"
check "hold menu in Guest Mode offers only the way out" "menu:" "menu: End Guest Mode"
cmd "pick" "state"
check "no picker in Guest Mode" "button: window" "presented -"
cmd "clear" "state"
check "Clear does nothing in Guest Mode" "state: phase" "phase GUEST, 4 chosen"

echo "== 6. items full screen"
cmd "open 0" "wait 3" "state"
shot "05-item-0"
check "item 0 is shown" "gallery:" "showing item 0"
cmd "open 1" "wait 2" "state"
shot "06-item-1"
check "item 1 is shown" "gallery:" "showing item 1"
cmd "open 3" "wait 2" "bars" "wait 1" "state"
shot "07-item-3-bars-hidden"
check "a tap hides the bars and the button" "gallery:" "bars hidden"
check "the button is tucked away with them" "button: window" "tucked 1"
cmd "bars" "wait 1" "state"
check "another tap brings them back" "button: window" "tucked 0"
cmd "grid" "state"
check "back on the grid" "gallery:" "showing the grid"

echo "== 7. Photos closed and opened again: still Guest Mode"
if launch 2; then
  cmd "state"
  shot "08-after-restart"
  check "Guest Mode was read back at the start" "Guest Mode 1." "saved state: GUEST with 4 item(s)"
  check "the gallery is up again" "gallery:" "gallery: UP"
  check "still Guest Mode" "state: phase" "phase GUEST, 4 chosen"
else
  FAILED=$((FAILED + 1)); echo "  FAIL  Photos did not come back with Guest Mode loaded"
fi

echo "== 8. Face ID fails: Guest Mode stays"
cmd "auth fail" "tap" "wait 1" "state"
check "a failed check keeps Guest Mode on" "button: Guest Mode" "Guest Mode stays ON"
check "still Guest Mode" "state: phase" "phase GUEST, 4 chosen"
check "the gallery is still up" "gallery:" "gallery: UP"

echo "== 9. Face ID passes: Photos is back to normal"
cmd "auth pass" "tap" "wait 2" "state"
shot "09-normal-again"
check "Guest Mode is off, the selection forgotten" "state: phase" "phase idle, 0 chosen"
check "the gallery is down" "gallery:" "gallery: down"
check "nothing is saved any more" "state: Guest Mode OFF" "nothing saved any more"

echo "== 10. one item: shown straight away"
cmd "select 1" "tap" "wait 2" "state"
shot "10-single-item"
check "a single item opens full screen" "gallery:" "showing item 0"
cmd "tap" "wait 2" "state"
check "and out again" "state: phase" "phase idle"

echo "== 10b. Photos closed and opened again after Guest Mode ended: normal"
if launch 3; then
  cmd "state"
  check "no Guest Mode at the start" "Guest Mode 1." "saved state: normal"
  check "the gallery is down" "gallery:" "gallery: down"
else
  FAILED=$((FAILED + 1)); echo "  FAIL  Photos did not come back with Guest Mode loaded"
fi

echo "== 11. the real Face ID sheet in the simulator (told, not judged)"
xcrun simctl spawn "$UDID" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 > /dev/null 2>&1 || true
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit.enrollmentChanged > /dev/null 2>&1 || true
sleep 1
cmd "auth real" "select 2" "tap"
sleep 2
shot "11-real-face-id-sheet"
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit_Sim.pearl.match > /dev/null 2>&1 || true
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit_Sim.fingerTouch.match > /dev/null 2>&1 || true
sleep 3
cmd "state"
shot "12-after-real-face-id"
echo "  real check said: $(last 'button: start →')"
echo "  $(last 'state: phase')"

collect_crashes
cp "$LOG" "$OUT/guestmode.log" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$APP" > /dev/null 2>&1 || true
echo
echo "== log"
cat "$OUT/guestmode.log" 2> /dev/null | tail -150
echo
echo "== result: $PASSED passed, $FAILED failed${CRASHED:+, Photos CRASHED}${DEAD:+, Photos stopped answering}"
[ "$FAILED" = "0" ] && [ -z "$CRASHED" ] && [ -z "$DEAD" ]
