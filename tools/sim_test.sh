#!/bin/bash
# Runs Shani inside the SpringBoard of an iOS simulator and photographs it.
#
# Shani hooks with the Objective-C runtime only, so the same sources build for the simulator
# with plain clang (no Theos, no ElleKit). The dylib is loaded into the simulator's SpringBoard
# with DYLD_INSERT_LIBRARIES and driven through its command file (ShaniDebug.m); the pictures
# come from `simctl io screenshot`.
#
# The notifications are real ones: a small app of our own (probe/, "PayDemo") is installed and
# sent push notifications with `xcrun simctl push`, which travel the same road through
# SpringBoard as any app's. A few more are made inside SpringBoard for an Apple app.
#
# What this shows, on the phone's iOS generation (16.4 when the runtime can be had): the Shani
# button behind a swipe and among the long-press actions, a tap on each, an app's notifications
# being held and coming up when the time is over, both ways of silencing, the log, and that
# nothing crashes.
#
# usage: tools/sim_test.sh [output folder] [wanted iOS version, e.g. 16.4]
#        (run from the repository root, on a Mac with Xcode)
set -u
OUT="${1:-$PWD/sim-out}"
WANT="${2:-}"
mkdir -p "$OUT/run"
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
rm -rf "$RUN"/shani_cmd.txt "$RUN"/Shani.log "$RUN"/Shani.boot "$RUN"/Shani
PROBE=com.adarsh.shaniprobe
SAFARI=com.apple.mobilesafari

ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS="-arch $ARCH -mios-simulator-version-min=15.0 -isysroot $SDK -fobjc-arc -O1 -g -Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable"
echo "== build for the simulator ($ARCH, $SDK)"
(
  xcrun --sdk iphonesimulator clang $FLAGS -dynamiclib \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    -install_name /usr/lib/Shani.dylib -o "$OUT/Shani.dylib" \
    Tweak.m ShaniCore.m ShaniStore.m ShaniEngine.m ShaniHooks.m ShaniUI.m ShaniDebug.m || exit 1
  codesign -f -s - "$OUT/Shani.dylib" || exit 1
  APP="$OUT/ShaniProbe.app"
  rm -rf "$APP"
  mkdir -p "$APP"
  xcrun --sdk iphonesimulator clang $FLAGS -framework UIKit -framework Foundation -framework CoreGraphics -framework UserNotifications \
    -o "$APP/ShaniProbe" probe/main.m || exit 1
  cp probe/Info.plist "$APP/Info.plist"
  codesign -f -s - "$APP" || exit 1
) > "$OUT/build.log" 2>&1
status=$?
cat "$OUT/build.log"
[ "$status" = "0" ] && [ -f "$OUT/Shani.dylib" ] || { echo "simulator build FAILED"; exit 1; }

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
    DEVNAME="Shani test (${DEVTYPE##*.})"
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
xcrun simctl install "$UDID" "$OUT/ShaniProbe.app" || echo "the probe app did not install"

defaults write com.apple.CrashReporter DialogType none > /dev/null 2>&1 || true     # no "quit unexpectedly" windows over the simulator

echo "== load Shani into SpringBoard"
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

xcrun simctl spawn "$UDID" launchctl setenv DYLD_INSERT_LIBRARIES "$OUT/Shani.dylib"
xcrun simctl spawn "$UDID" launchctl setenv SHANI_DIR "$RUN"
xcrun simctl spawn "$UDID" launchctl setenv SHANI_NO_GUARD 1        # show every start, even after failed ones
OLD=$(sb_pid)
echo "SpringBoard pid $OLD: restarting it"
if [ -n "$OLD" ] && [ "$OLD" != "-" ]; then kill -9 "$OLD" 2>/dev/null || true
else xcrun simctl spawn "$UDID" launchctl stop com.apple.SpringBoard || true; fi

started=""
for i in $(seq 1 90); do                              # up to three minutes: this can be a slow machine
  sleep 2
  if grep -q "started:" "$RUN/Shani.log" 2>/dev/null; then started=yes; break; fi
done
xcrun simctl spawn "$UDID" launchctl unsetenv DYLD_INSERT_LIBRARIES || true
echo "SpringBoard pid now: $(sb_pid)"
echo "-- Shani.log so far:"
cat "$RUN/Shani.log" 2>/dev/null || echo "(no log: the library was not loaded)"
if [ -z "$started" ]; then
  echo "Shani did NOT finish starting inside SpringBoard"
  collect_crashes
  xcrun simctl spawn "$UDID" log show --last 4m --style compact --predicate 'process == "SpringBoard" AND (eventMessage CONTAINS[c] "shani" OR eventMessage CONTAINS[c] "dyld")' 2>/dev/null | tail -60 > "$OUT/springboard-log.txt"
  tail -25 "$OUT/springboard-log.txt"
  cp "$RUN/Shani.log" "$OUT/Shani.log" 2>/dev/null || true
  xcrun simctl io "$UDID" screenshot "$OUT/00-not-started.png" > /dev/null 2>&1 || true
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
  exit 1
fi
echo "Shani is running in SpringBoard" | tee -a "$OUT/simulator.txt"
sleep 15                                              # let SpringBoard finish starting

# ---- helpers ----
MARKS=0
cmd() {                                               # one or more command lines, run in order by SpringBoard; returns when they are done
  local waited=0 mark
  while [ -e "$RUN/shani_cmd.txt" ] && [ "$waited" -lt 120 ]; do sleep 1; waited=$((waited + 1)); done
  MARKS=$((MARKS + 1)); mark="done$MARKS-$$"
  printf '%s\n' "$@" "mark $mark" > "$RUN/cmd.tmp"
  mv "$RUN/cmd.tmp" "$RUN/shani_cmd.txt"
  waited=0
  while ! grep -q -F "mark: $mark" "$RUN/Shani.log" 2>/dev/null && [ "$waited" -lt 300 ]; do sleep 1; waited=$((waited + 1)); done
  [ "$waited" -ge 300 ] && echo "  (SpringBoard did not finish these in 5 minutes: $1 …)"
  return 0
}
shot() {                                              # shot <name>: a screenshot, kept as a small JPEG
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || { echo "screenshot $1 failed"; return; }
  sips -s format jpeg -s formatOptions 78 -Z 1500 "$OUT/$1.png" --out "$OUT/$1.jpg" > /dev/null 2>&1 && rm -f "$OUT/$1.png"
  echo "  shot $1"
}
last() { grep -F "$1" "$RUN/Shani.log" 2>/dev/null | tail -1 | cut -c21-; }      # the newest log line containing a text, without its date
count() { grep -c -F "$1" "$RUN/Shani.log" 2>/dev/null || true; }
PUSHES=0
push() {                                              # push <title> <body>: a real push notification to the probe app
  PUSHES=$((PUSHES + 1))
  cat > "$RUN/push.json" <<EOF
{ "aps": { "alert": { "title": "$1", "body": "$2" }, "sound": "default", "category": "offer" } }
EOF
  xcrun simctl push "$UDID" "$PROBE" "$RUN/push.json" > /dev/null 2>&1 || echo "  (simctl push failed)"
  sleep 4
}
check() {                                             # check <what> <text that must be in the log>
  if grep -q -F "$2" "$RUN/Shani.log" 2>/dev/null; then echo "PASS  $1"; else echo "FAIL  $1   (no \"$2\" in the log)"; FAILED=$((FAILED + 1)); fi
}
FAILED=0

echo "== what this SpringBoard has"
cmd "state" "impl supplementaryActionsForNotificationListCell:" "impl currentActions" "impl _iconImageForNotificationAction:" "impl postNotificationWithRequest:"
grep -E "hooks:|classes implementing|    [A-Z]" "$RUN/Shani.log" | cut -c21- | tail -12

echo "== the probe app gets permission to notify"
xcrun simctl launch "$UDID" "$PROBE" > /dev/null 2>&1 || echo "the probe app did not launch"
sleep 6
cmd "allow $PROBE" "wait 2"
echo "  $(last 'allow ')"
xcrun simctl terminate "$UDID" "$PROBE" > /dev/null 2>&1 || true
sleep 2
DATA=$(xcrun simctl get_app_container "$UDID" "$PROBE" data 2>/dev/null)
[ -n "$DATA" ] && cat "$DATA/Documents/probe.log" 2>/dev/null | sed 's/^/  probe: /'

echo "== 1. a notification arrives; the buttons behind a swipe"
cmd "set minutes 60" "set mode 0" "set release 0"
push "Recharge offer" "Flat 50 back on your next mobile recharge. Today only."
shot 01-banner-or-home
cmd "cover on" "wait 2" "cells"
shot 02-list
echo "  $(last 'cells:')"; grep -F "    0: " "$RUN/Shani.log" | tail -1 | cut -c21-
cmd "dests $PROBE" "reveal 0" "wait 1.5"
shot 03-swipe-buttons
echo "  $(last 'swipe buttons as iOS makes them')"
echo "  $(last 'dests ')"

echo "== 2. the actions when it is held down"
cmd "hide 0" "wait 1" "actions 0" "longlook 0" "wait 3"
shot 04-long-press-actions
grep -F "    current: " "$RUN/Shani.log" | tail -4 | cut -c21-
grep -F "    interface: " "$RUN/Shani.log" | tail -4 | cut -c21-

echo "== 3. Shani tapped among those actions"
cmd "runaction 0" "wait 3" "state" "cells"
shot 05-after-shani
echo "  $(last 'tap (')"; echo "  $(last 'state:')"; echo "  $(last 'cells:')"

echo "== 4. the app's next notifications are held"
push "Cashback credited" "20 was added to your wallet."
push "Bill reminder" "Your electricity bill is due tomorrow."
cmd "state" "cells" "wait 1" "notelog $PROBE"
shot 06-held-nothing-new
echo "  $(last 'hold ')"; echo "  $(last 'state:')"; echo "  $(last 'cells:')"; echo "  $(last 'notelog ')"

echo "== 5. the time is over: they come up"
cmd "clock 3700" "tick" "wait 3" "state" "cells" "wait 1" "notelog $PROBE"
shot 07-released
echo "  $(last 'release ')"; echo "  $(last 'state:')"; echo "  $(last 'cells:')"; echo "  $(last 'notelog ')"
cmd "reveal 0" "wait 1.5"
shot 08-swipe-buttons-shani-off

echo "== 6. Shani Off behind the swipe"
cmd "swipetap 0" "wait 2" "state" "cells"
shot 09-shani-off
echo "  $(last 'tap (')"; echo "  $(last 'state:')"
push "Weekend deal" "Movie tickets at half price."
cmd "state" "cells"
shot 10-arrives-as-usual
echo "  after Shani Off, a new one: $(last 'cells:') · $(last 'state:')"

echo "== 7. silence once per tap"
cmd "set mode 1" "wait 1" "cells" "reveal 0" "wait 1.5"
shot 11-once-swipe-buttons
cmd "swipetap 0" "wait 2" "state"
shot 12-once-tapped
echo "  $(last 'tap (')"; echo "  $(last 'state:')"
push "Flash sale" "Starts in ten minutes."
cmd "state" "cells"
echo "  held inside the hour: $(last 'hold ') · $(last 'cells:')"
cmd "clock 3700" "tick" "wait 3" "state" "cells"
shot 13-once-released
echo "  $(last 'release ')"; echo "  $(last 'state:')"
push "After the hour" "This one is not held."
cmd "state" "cells"
shot 14-once-after
echo "  after the hold, a new one: $(last 'pass ') · $(last 'cells:')"

echo "== 8. an Apple app, three held, shown with one alert"
cmd "cover off" "wait 2" "set mode 0" "apps $SAFARI" "notify $SAFARI First | One of three." "notify $SAFARI Second | Two of three." "notify $SAFARI Third | Three of three." "wait 1" "state"
shot 15-three-held
echo "  $(last 'state:')"
cmd "clock 3700" "tick" "wait 2"
shot 16-three-released-banner
cmd "wait 6" "cover on" "wait 2" "cells"
shot 17-three-released-list
echo "  $(last 'release ')"; echo "  $(last 'cells:')"

echo "== 9. the pill, the Lock Screen"
cmd "cover off" "wait 2" "toast PayDemo | Shani on · held 1 hour at a time" "wait 1"
shot 18-pill
cmd "wait 3" "lockscreen" "wait 3" "cells" "reveal 0" "wait 1.5"
shot 19-lock-screen-swipe
echo "  on the Lock Screen: $(last 'cells:')"
cmd "state"

echo "== checks"
check "hooks are in"                                  "hooks: post 1, modify 1, withdraw 1, swipe buttons 1, long-press actions 1, action icon 1"
check "iOS's swipe buttons were seen"                 "swipe buttons as iOS makes them"
check "Shani's long-press action ran"                 "long-press action tapped"
check "a tap put the probe app on the list"           "tap (long press): $PROBE on"
check "the probe app's notification was held"         "hold $PROBE until"
check "held notifications came up when time was over" "release $PROBE: 2 of 2 shown (time is up"
check "Shani Off behind the swipe"                    "tap (swipe): $PROBE off"
check "once per tap: silent from the tap"             "tap (swipe): $PROBE on, silent until"
check "three of Safari's were shown"                  "release $SAFARI: 3 of 3 shown"

cp "$RUN/Shani.log" "$OUT/Shani.log" 2>/dev/null || true
mkdir -p "$OUT/data" && cp -R "$RUN/Shani" "$OUT/data/" 2>/dev/null || true
echo "== the probe app's notification log, as Settings would show it"
python3 - "$RUN/Shani/log/$PROBE.plist" <<'EOF' || true
import plistlib, sys, time
try:
    rows = plistlib.load(open(sys.argv[1], "rb"))
except Exception as e:
    print("  (no log file: %s)" % e); sys.exit(0)
names = {0: "shown at once", 1: "HELD", 2: "held, then shown", 3: "held, log only", 4: "held, taken back", 5: "Shani tapped here", 6: "critical"}
for r in rows:
    print("  %s  %-18s %s" % (time.strftime("%H:%M:%S", time.localtime(r.get("t", 0))), names.get(r.get("st"), r.get("st")), r.get("title", "")))
EOF
echo "== Shani.log"
cat "$OUT/Shani.log" 2>/dev/null
collect_crashes
ls -la "$OUT" | head -80
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
if ls "$OUT"/SpringBoard*.ips > /dev/null 2>&1; then echo "SpringBoard crashed during the test: see the crash reports"; exit 1; fi
starts=$(grep -c "in SpringBoard (pid" "$OUT/Shani.log" 2>/dev/null || echo 0)
echo "Shani started $starts time(s) during the test"
if [ "$starts" != "1" ]; then echo "SpringBoard restarted during the test: see the crash reports"; exit 1; fi
if grep -q "threw" "$OUT/Shani.log" 2>/dev/null; then echo "an exception was caught: see the log"; grep "threw" "$OUT/Shani.log" | head; exit 1; fi
if [ "$FAILED" != "0" ]; then echo "$FAILED check(s) failed"; exit 1; fi
echo "all checks passed"
exit 0
