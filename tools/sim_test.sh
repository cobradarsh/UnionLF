#!/bin/bash
# Runs Atelier inside the SpringBoard of an iOS simulator and photographs it.
#
# Atelier hooks with the Objective-C runtime only, so the same sources build for the simulator
# with plain clang (no Theos, no ElleKit). The dylib is loaded into the simulator's SpringBoard
# with DYLD_INSERT_LIBRARIES and driven through its command file (AtelierDebug.m); the pictures
# come from `simctl io screenshot`. A small app of our own (probe/) sits on the bench next to
# Apple's, and writes down what it is given: its size, when it is active, whether its keyboard
# came up, where it is touched.
#
# What this shows: real apps hosted live in a real SpringBoard of the phone's iOS generation
# (16.4 when the runtime can be had), every layout, the swap, freezing, the sheets, and that
# nothing crashes. What it cannot show: fingers. The simulator is not sent any touches here.
#
# usage: tools/sim_test.sh [output folder] [wanted iOS version, e.g. 16.4]
#        (run from the repository root, on a Mac with Xcode)
set -u
OUT="${1:-$PWD/sim-out}"
WANT="${2:-}"
mkdir -p "$OUT/run"
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -f "$RUN"/atelier_cmd.txt "$RUN"/Atelier.log "$RUN"/Atelier.boot
PROBE=com.adarsh.atelierprobe

ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS="-arch $ARCH -mios-simulator-version-min=15.0 -isysroot $SDK -fobjc-arc -O1 -g -Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable"
echo "== build for the simulator ($ARCH, $SDK)"
(
  xcrun --sdk iphonesimulator clang $FLAGS -dynamiclib \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    -install_name /usr/lib/Atelier.dylib -o "$OUT/Atelier.dylib" Tweak.m Atelier*.m || exit 1
  codesign -f -s - "$OUT/Atelier.dylib" || exit 1
  APP="$OUT/AtelierProbe.app"
  rm -rf "$APP"
  mkdir -p "$APP"
  xcrun --sdk iphonesimulator clang $FLAGS -framework UIKit -framework Foundation -framework CoreGraphics \
    -o "$APP/AtelierProbe" probe/main.m || exit 1
  cp probe/Info.plist "$APP/Info.plist"
  codesign -f -s - "$APP" || exit 1
) > "$OUT/build.log" 2>&1
status=$?
cat "$OUT/build.log"
[ "$status" = "0" ] && [ -f "$OUT/Atelier.dylib" ] || { echo "simulator build FAILED"; exit 1; }

echo "== pick a simulator (wanted iOS: ${WANT:-the oldest there is})"
PICK=$(xcrun simctl list -j | WANT="$WANT" python3 -c '
import json, os, re, sys
data = json.load(sys.stdin)
want = os.environ.get("WANT", "")
runtimes = []
for rt in data.get("runtimes", []):
    ident = rt.get("identifier", "")
    if "SimRuntime.iOS-" not in ident or not rt.get("isAvailable", False):
        continue
    version = tuple(int(x) for x in re.findall(r"\d+", rt.get("version", "0"))[:2])
    runtimes.append((version, ident, rt))
if not runtimes:
    sys.exit(0)
runtimes.sort()
chosen = None
if want:
    wanted = tuple(int(x) for x in re.findall(r"\d+", want)[:2])
    for version, ident, rt in runtimes:
        if version[:len(wanted)] == wanted:
            chosen = (version, ident, rt)
if chosen is None:
    chosen = runtimes[0]                       # the oldest iOS on offer is the nearest to 16.5
version, ident, rt = chosen
best = None
for dev in data.get("devices", {}).get(ident, []):
    name = dev.get("name", "")
    if not name.startswith("iPhone") or not dev.get("isAvailable", True):
        continue
    score = (name == "iPhone 14 Pro Max", "Pro Max" in name, "Plus" in name, "Pro" in name, name)
    if best is None or score > best[0]:
        best = (score, dev["udid"], name)
label = "%d.%d" % (version[0], version[1])
if best and best[0][0]:
    print("USE|%s|%s|%s" % (best[1], best[2], label))
else:
    types = [t.get("identifier", "") for t in rt.get("supportedDeviceTypes", [])] or [t.get("identifier", "") for t in data.get("devicetypes", [])]
    phones = [t for t in types if "iPhone" in t]
    pick = "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro-Max"
    if pick not in phones:
        if best:
            print("USE|%s|%s|%s" % (best[1], best[2], label))
            sys.exit(0)
        if phones:
            pick = sorted(phones, key=lambda t: ("Pro-Max" in t, t))[-1]
    print("CREATE|%s|%s|%s" % (ident, pick, label))
')
case "$PICK" in
  USE\|*)
    IFS='|' read -r _ UDID DEVNAME IOSVER <<< "$PICK" ;;
  CREATE\|*)
    IFS='|' read -r _ RUNTIME DEVTYPE IOSVER <<< "$PICK"
    DEVNAME="Atelier test (${DEVTYPE##*.})"
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
xcrun simctl install "$UDID" "$OUT/AtelierProbe.app" || echo "the probe app did not install"

echo "== load Atelier into SpringBoard"
# The library goes in through launchd's environment: set DYLD_INSERT_LIBRARIES, restart SpringBoard,
# and take the variable away again so that nothing else started later carries the library.
# (Booting the whole simulator with the library in its environment never finishes: Chakra, 16 Nov 2026.)
REPORTS=~/Library/Logs/DiagnosticReports
mkdir -p "$REPORTS"
touch "$OUT/.before"                                  # crash reports newer than this are ours
sb_pid() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk '$3 == "com.apple.SpringBoard" { print $1 }'; }
collect_crashes() {                                   # copies new crash reports and prints their gist
  local found=""
  for f in "$REPORTS"/*.ips; do
    [ -f "$f" ] && [ "$f" -nt "$OUT/.before" ] || continue
    cp "$f" "$OUT/" && found="$found $OUT/$(basename "$f")"
  done
  if [ -n "$found" ]; then echo "-- crash reports:"; python3 tools/ips_summary.py $found; else echo "-- no crash report"; fi
}

xcrun simctl spawn "$UDID" launchctl setenv DYLD_INSERT_LIBRARIES "$OUT/Atelier.dylib"
xcrun simctl spawn "$UDID" launchctl setenv ATELIER_DIR "$RUN"
xcrun simctl spawn "$UDID" launchctl setenv ATELIER_NO_GUARD 1      # show every start, even after failed ones
OLD=$(sb_pid)
echo "SpringBoard pid $OLD: restarting it"
if [ -n "$OLD" ] && [ "$OLD" != "-" ]; then kill -9 "$OLD" 2>/dev/null || true
else xcrun simctl spawn "$UDID" launchctl stop com.apple.SpringBoard || true; fi

started=""
for i in $(seq 1 90); do                              # up to three minutes: this can be a slow machine
  sleep 2
  if grep -q "started:" "$RUN/Atelier.log" 2>/dev/null; then started=yes; break; fi
done
xcrun simctl spawn "$UDID" launchctl unsetenv DYLD_INSERT_LIBRARIES || true
echo "SpringBoard pid now: $(sb_pid)"
echo "-- Atelier.log so far:"
cat "$RUN/Atelier.log" 2>/dev/null || echo "(no log: the library was not loaded)"
if [ -z "$started" ]; then
  echo "Atelier did NOT finish starting inside SpringBoard"
  collect_crashes
  xcrun simctl spawn "$UDID" log show --last 4m --style compact --predicate 'process == "SpringBoard" AND (eventMessage CONTAINS[c] "atelier" OR eventMessage CONTAINS[c] "dyld")' 2>/dev/null | tail -60 > "$OUT/springboard-log.txt"
  tail -25 "$OUT/springboard-log.txt"
  cp "$RUN/Atelier.log" "$OUT/Atelier.log" 2>/dev/null || true
  xcrun simctl io "$UDID" screenshot "$OUT/00-not-started.png" > /dev/null 2>&1 || true
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
  exit 1
fi
echo "Atelier is running in SpringBoard" | tee -a "$OUT/simulator.txt"
sleep 8

# ---- helpers ----
cmd() {                                               # one or more command lines, run in order by SpringBoard
  printf '%s\n' "$@" > "$RUN/cmd.tmp"
  mv "$RUN/cmd.tmp" "$RUN/atelier_cmd.txt"
}
shot() {                                              # shot <name>: a screenshot, kept as a small JPEG
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || { echo "screenshot $1 failed"; return; }
  sips -s format jpeg -s formatOptions 75 -Z 1500 "$OUT/$1.png" --out "$OUT/$1.jpg" > /dev/null 2>&1 && rm -f "$OUT/$1.png"
  echo "  shot $1"
}
step() {                                              # step <name> <seconds to wait> <command lines…>
  local name="$1" pause="$2"; shift 2
  cmd "$@"
  sleep "$pause"
  shot "$name"
}

SET=com.apple.Preferences
MAPS=com.apple.Maps
SAFARI=com.apple.mobilesafari
PHOTOS=com.apple.mobileslideshow
CAL=com.apple.mobilecal
FILES=com.apple.DocumentsApp

echo "== what this SpringBoard has"
cmd "windows" "scenes" "classes KeyboardFocus" "classes SystemGesture" "classes ScenePresent" \
    "methods FBScene FBSceneManager UIScenePresentationManager SBWorkspaceKeyboardFocusController SBSceneManager SBMainDisplaySceneManager SBApplicationSceneHandle SBDeviceApplicationSceneHandle SBDeviceApplicationSceneEntity SBApplication UIScenePresentationContext _UISystemGestureManager" \
    "iconmenu $MAPS" "state"
sleep 6
shot 01-home

echo "== the bench"
step 02-side-three 16 "apps $SET $MAPS $SAFARI" "wait 11" "scenes" "state" "windows"
step 03-side-five 16 "apps $SET $MAPS $SAFARI $PHOTOS $PROBE" "wait 11" "state"
step 04-side-swap 5 "main 2" "wait 2" "state"
step 05-top 5 "layout top" "wait 2" "state"
step 06-top-probe-main 7 "main 4" "wait 4" "state"
step 07-menu 3 "menu 0" "wait 1" "state"
step 08-mini-menu 3 "hidemenu" "wait 0.4" "menu 2"
step 09-split 6 "hidemenu" "layout split" "wait 3" "state"
step 10-split-wide 4 "split 0.68" "wait 1" "state"
step 11-side-again 6 "layout side" "wait 3" "state"

echo "== freezing"
step 12-frozen 7 "freeze" "wait 3" "state" "scenes"
step 13-thawed 5 "touch" "wait 2" "state"
step 14-stills-only 9 "set miniMode 2" "wait 6" "state"
step 15-stills-swap 8 "main 1" "wait 5" "state"
cmd "set miniMode 0" "touch"
sleep 3

echo "== sheets and sets"
step 16-closed-one 4 "closeapp 4" "wait 2" "state"
step 17-picker 4 "plus"
step 18-picked 8 "pick 4" "wait 5" "state"
step 19-sets-empty 4 "sets"
step 20-set-saved 5 "sheetclose" "wait 0.6" "saveset" "wait 3" "sets"
step 21-icon-menu 3 "sheetclose" "iconmenu $MAPS" "iconmenu $CAL" "state"

echo "== resize (beta)"
step 22-resize-side 9 "set resizeApps true" "wait 6" "state" "scenes"
step 23-resize-top 8 "layout top" "wait 5" "state"
step 24-resize-split 8 "layout split" "wait 5" "state"
step 25-resize-off 8 "set resizeApps false" "layout side" "wait 5" "state" "scenes"

echo "== leaving and coming back"
step 26-full-screen 8 "full 0" "wait 5" "state" "scenes"
step 27-open-over-app 10 "open" "wait 7" "state"
step 28-closed 6 "close" "wait 3" "state" "scenes"
step 29-home-edge-strip 6 "home" "wait 2" "set triggerTint 1" "wait 1" "state"
step 30-reopened-from-home 12 "set triggerTint 0" "trigger" "wait 8" "state"
step 31-icon-menu-open 10 "close" "wait 2" "iconrun com.adarsh.atelier.open $CAL" "wait 6" "state"
step 32-top-final 6 "layout top" "wait 3" "state" "windows"
cmd "close" "wait 2" "state" "scenes"
sleep 5

cp "$RUN/Atelier.log" "$OUT/Atelier.log" 2>/dev/null || true
DATA=$(xcrun simctl get_app_container "$UDID" "$PROBE" data 2>/dev/null)
[ -n "$DATA" ] && cp "$DATA/Documents/probe.log" "$OUT/probe.log" 2>/dev/null
echo "== probe.log (what the probe app was given)"
cat "$OUT/probe.log" 2>/dev/null || echo "(none)"
echo "== Atelier.log"
cat "$OUT/Atelier.log" 2>/dev/null
collect_crashes
ls -la "$OUT" | head -80
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
starts=$(grep -c "start: Atelier" "$OUT/Atelier.log" 2>/dev/null || echo 0)
echo "Atelier started $starts time(s) during the test"
if [ "$starts" != "1" ]; then echo "SpringBoard restarted during the test: see the crash reports"; exit 1; fi
if grep -q "threw" "$OUT/Atelier.log" 2>/dev/null; then echo "an exception was caught: see the log"; grep "threw" "$OUT/Atelier.log" | head; exit 1; fi
if ! grep -q "hosted sceneID" "$OUT/Atelier.log" 2>/dev/null; then echo "no app was ever hosted"; exit 1; fi
exit 0
