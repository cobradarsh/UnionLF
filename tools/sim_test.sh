#!/bin/bash
# Runs Chakra inside the SpringBoard of an iOS simulator and photographs it.
#
# Chakra hooks nothing, so the same sources build for the simulator with plain clang (no Theos,
# no ElleKit). The dylib is loaded into the simulator's SpringBoard with DYLD_INSERT_LIBRARIES and
# driven through its command file (ChakraDebug.m); the pictures come from `simctl io screenshot`.
#
# This is not the phone: the simulator runs whatever iOS the runner has, so a system action that
# is "not available" here may still be fine on iOS 16.5 and the other way round. What it does show
# is the real thing in a real SpringBoard: the ball, the wheel in every corner, the column, the
# editor, opening an app, and that nothing crashes.
#
# usage: tools/sim_test.sh [output folder]      (run from the repository root, on a Mac)
set -u
OUT="${1:-$PWD/sim-out}"
mkdir -p "$OUT/run"
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -f "$RUN"/chakra_cmd.txt "$RUN"/Chakra.log "$RUN"/Chakra.boot

ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
echo "== build for the simulator ($ARCH, $SDK)"
xcrun --sdk iphonesimulator clang -arch "$ARCH" -mios-simulator-version-min=15.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O1 -g -Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function \
  -Wno-unused-but-set-variable \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
  -install_name /usr/lib/Chakra.dylib -o "$OUT/Chakra.dylib" Tweak.m Chakra*.m > "$OUT/build.log" 2>&1
cat "$OUT/build.log"
[ -f "$OUT/Chakra.dylib" ] || { echo "simulator build FAILED"; exit 1; }
codesign -f -s - "$OUT/Chakra.dylib"

echo "== pick a simulator"
PICK=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for dev in devs:
        name = dev["name"]
        if not name.startswith("iPhone"):
            continue
        # the oldest iOS on offer is the nearest to 16.5; among phones, the biggest
        score = (-version[0], -version[1], "Pro Max" in name, "Plus" in name, "Pro" in name, name)
        if best is None or score > best[0]:
            best = (score, dev["udid"], name, "%d.%d" % version)
if best:
    print(best[1] + "|" + best[2] + "|" + best[3])
')
UDID="${PICK%%|*}"
[ -n "$UDID" ] || { echo "no iPhone simulator available"; xcrun simctl list devices available; exit 1; }
echo "simulator: ${PICK#*|}" | tee "$OUT/simulator.txt"

xcrun simctl boot "$UDID" 2>&1 | grep -v "current state: Booted" || true
xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1 || { tail -5 "$OUT/boot.log"; echo "simulator did not boot"; exit 1; }
tail -2 "$OUT/boot.log"

echo "== load Chakra into SpringBoard"
# The library goes in through launchd's environment: set DYLD_INSERT_LIBRARIES, restart SpringBoard,
# and take the variable away again so that nothing else started later carries the library.
# (Booting the whole simulator with the library in its environment was tried on 16 Nov 2026: every
#  process then loads UIKit and the boot never finishes.)
touch "$RUN/chakra_test"                              # switches the test commands on
REPORTS=~/Library/Logs/DiagnosticReports
mkdir -p "$REPORTS"
touch "$OUT/.before"                                  # crash reports newer than this are ours
sb_pid() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk '$3 == "com.apple.SpringBoard" { print $1 }'; }
collect_crashes() {                                   # copies new SpringBoard crash reports and prints their gist
  local found=""
  for f in "$REPORTS"/SpringBoard*.ips; do
    [ -f "$f" ] && [ "$f" -nt "$OUT/.before" ] || continue
    cp "$f" "$OUT/" && found="$found $OUT/$(basename "$f")"
  done
  if [ -n "$found" ]; then echo "-- SpringBoard crash reports:"; python3 tools/ips_summary.py $found; else echo "-- no SpringBoard crash report"; fi
}

xcrun simctl spawn "$UDID" launchctl setenv DYLD_INSERT_LIBRARIES "$OUT/Chakra.dylib"
xcrun simctl spawn "$UDID" launchctl setenv CHAKRA_DIR "$RUN"
xcrun simctl spawn "$UDID" launchctl setenv CHAKRA_NO_GUARD 1      # show every start, even after failed ones
OLD=$(sb_pid)
echo "SpringBoard pid $OLD: restarting it"
if [ -n "$OLD" ] && [ "$OLD" != "-" ]; then kill -9 "$OLD" 2>/dev/null || true
else xcrun simctl spawn "$UDID" launchctl stop com.apple.SpringBoard || true; fi

started=""
for i in $(seq 1 90); do                              # up to three minutes: this can be a slow machine
  sleep 2
  if grep -q "started:" "$RUN/Chakra.log" 2>/dev/null; then started=yes; break; fi
done
xcrun simctl spawn "$UDID" launchctl unsetenv DYLD_INSERT_LIBRARIES || true
echo "SpringBoard pid now: $(sb_pid)"
echo "-- Chakra.log so far:"
cat "$RUN/Chakra.log" 2>/dev/null || echo "(no log: the library was not loaded)"
if [ -z "$started" ]; then
  echo "Chakra did NOT finish starting inside SpringBoard"
  collect_crashes
  xcrun simctl spawn "$UDID" log show --last 4m --style compact --predicate 'process == "SpringBoard" AND (eventMessage CONTAINS[c] "chakra" OR eventMessage CONTAINS[c] "dyld")' 2>/dev/null | tail -60 > "$OUT/springboard-log.txt"
  tail -25 "$OUT/springboard-log.txt"
  cp "$RUN/Chakra.log" "$OUT/Chakra.log" 2>/dev/null || true
  xcrun simctl io "$UDID" screenshot "$OUT/00-not-started.png" > /dev/null 2>&1 || true
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
  exit 1
fi
echo "Chakra is running in SpringBoard" | tee -a "$OUT/simulator.txt"
sleep 8

# ---- helpers ----
cmd() {                                               # one or more command lines, run in order by SpringBoard
  printf '%s\n' "$@" > "$RUN/cmd.tmp"
  mv "$RUN/cmd.tmp" "$RUN/chakra_cmd.txt"
}
shot() {                                              # shot <name>: a screenshot, kept as a small JPEG
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || { echo "screenshot $1 failed"; return; }
  sips -s format jpeg -s formatOptions 72 -Z 1500 "$OUT/$1.png" --out "$OUT/$1.jpg" > /dev/null 2>&1 && rm -f "$OUT/$1.png"
  echo "  shot $1"
}
step() {                                              # step <name> <seconds to wait> <command lines…>
  local name="$1" pause="$2"; shift 2
  cmd "$@"
  sleep "$pause"
  shot "$name"
}

APPS="app:com.apple.mobilesafari app:com.apple.Preferences app:com.apple.Maps app:com.apple.mobileslideshow app:com.apple.MobileSMS"
MANY="$APPS app:com.apple.mobilecal app:com.apple.reminders app:com.apple.Health app:com.apple.DocumentsApp app:com.apple.shortcuts action:home action:switcher action:lastapp action:lock action:controlcentre action:notifications"

echo "== scenes"
cmd "actions" "glyphs" "glyphs $(python3 tools/make_prefs.py --glyphs)" "items $APPS action:lastapp action:screenshot action:darkmode" "state"
sleep 5
shot 01-home-ball-resting
step 02-wheel-right 2 "open"
step 03-hover 1.5 "hover 2"
step 04-wheel-left 3 "close" "wait 0.6" "move left 0.5" "wait 0.5" "open"
step 05-wheel-bottom-right 3 "close" "wait 0.6" "move right 0.93" "wait 0.5" "open"
step 06-wheel-top-left 3 "close" "wait 0.6" "move left 0.07" "wait 0.5" "open" "wait 1" "state"
step 07-wheel-16 3.5 "close" "wait 0.6" "items $MANY" "move right 0.46" "wait 0.5" "open" "wait 1" "state"
step 08-wheel-16-corner 3 "close" "wait 0.6" "move right 0.95" "wait 0.5" "open"
step 09-column 3.5 "close" "wait 0.6" "set style 1" "move right 0.46" "wait 0.5" "open"
step 10-column-left-8 3.5 "close" "wait 0.6" "items $APPS action:lastapp action:screenshot action:darkmode" "move left 0.3" "wait 0.5" "open"
step 11-big-icons-no-names 3.5 "close" "wait 0.6" "set style 0" "set labels false" "set iconSize 66" "set accent 4" "set ballSize 60" "move right 0.5" "wait 0.8" "open"
step 12-small 3.5 "close" "wait 0.6" "set labels true" "set iconSize 44" "set accent 2" "set ballSize 38" "set dim false" "wait 0.8" "open"
cmd "close" "wait 0.5" "unset iconSize" "unset accent" "unset ballSize" "unset dim" "unset labels"
sleep 2.5
step 13-editor 2.5 "edit"
step 14-editor-add 2.5 "editadd"
step 15-editor-closed 6 "editclose"
step 16-slot-shortcut 3.5 "set sc1Name Wikipedia" "set sc1URL wikipedia.org" "set sc1Glyph globe" "set sc2Name Morning" "set sc2URL Morning Routine" "set sc2Glyph sun.max.fill" "items $APPS shortcut:1 shortcut:2 shortcut:3 action:darkmode" "wait 0.5" "open" "wait 1" "state"
step 17-toggle-stays-open 3 "tap 7"
step 18-toggle-back 3 "tap 7"
step 19-opened-safari 7 "tap 0"
step 20-wheel-over-app 3 "state" "open"
step 21-last-app 6 "close" "wait 0.6" "launch com.apple.Preferences" "wait 3" "action lastapp"
step 22-home 4 "action home"
step 23-switcher 4 "action switcher"
step 24-control-centre 5 "action home" "wait 1.5" "action controlcentre"
step 25-notification-centre 5 "action home" "wait 1.5" "action notifications"
step 26-shortcut-link 8 "action home" "wait 1.5" "open" "wait 1" "tap 5"
cmd "action home" "wait 1" "state"
sleep 4

cp "$RUN/Chakra.log" "$OUT/Chakra.log" 2>/dev/null || true
echo "== Chakra.log"
cat "$OUT/Chakra.log" 2>/dev/null | tail -170
collect_crashes
ls -la "$OUT" | head -70
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
starts=$(grep -c "start: Chakra" "$OUT/Chakra.log" 2>/dev/null || echo 0)
echo "Chakra started $starts time(s) during the test"
if [ "$starts" != "1" ]; then echo "SpringBoard restarted during the test: see the crash reports"; exit 1; fi
if grep -q "threw" "$OUT/Chakra.log" 2>/dev/null; then echo "an exception was caught: see the log"; exit 1; fi
exit 0
