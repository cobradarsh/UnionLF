#!/bin/bash
# Runs HyperTrade (Atelier) inside the SpringBoard of an iOS simulator and photographs it.
#
# Atelier hooks with the Objective-C runtime only, so the same sources build for the simulator
# with plain clang (no Theos, no ElleKit). The dylib is loaded into the simulator's SpringBoard
# with DYLD_INSERT_LIBRARIES and driven through its command file (AtelierDebug.m); the pictures
# come from `simctl io screenshot`. A small app of our own (probe/) sits on the bench next to
# Apple's, and writes down what it is given: its size, when it is active, whether its keyboard
# came up, where it is touched.
#
# What this shows: real apps hosted live in a real SpringBoard of the phone's iOS generation
# (16.4 when the runtime can be had), every layout, the swap, freezing, the sheets, the band
# (index numbers, clock, flags, shortcuts), the dock (switches, credit), and that nothing
# crashes; then real touches (clicks and drags on the Simulator's window): swipes, taps, the
# picker's search field typed into with clicks on the keys.
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

defaults write com.apple.CrashReporter DialogType none > /dev/null 2>&1 || true     # no "quit unexpectedly" windows over the simulator

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
MARKS=0
cmd() {                                               # one or more command lines, run in order by SpringBoard; returns when they are done
  local waited=0 mark
  while [ -e "$RUN/atelier_cmd.txt" ] && [ "$waited" -lt 120 ]; do sleep 1; waited=$((waited + 1)); done
  MARKS=$((MARKS + 1)); mark="done$MARKS-$$"
  printf '%s\n' "$@" "mark $mark" > "$RUN/cmd.tmp"
  mv "$RUN/cmd.tmp" "$RUN/atelier_cmd.txt"
  # SpringBoard logs the mark after the last line (and its waits): a simulator on a busy Mac can
  # take a minute over one command, and a picture taken on a guess would show the wrong moment
  waited=0
  while ! grep -q -F "mark: $mark" "$RUN/Atelier.log" 2>/dev/null && [ "$waited" -lt 300 ]; do sleep 1; waited=$((waited + 1)); done
  [ "$waited" -ge 300 ] && echo "  (SpringBoard did not finish these in 5 minutes: $1 …)"
  return 0
}
shot() {                                              # shot <name>: a screenshot, kept as a small JPEG
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || { echo "screenshot $1 failed"; return; }
  cp "$OUT/$1.png" "$RUN/last.png" 2>/dev/null       # the full-size picture, for crop
  sips -s format jpeg -s formatOptions 75 -Z 1500 "$OUT/$1.png" --out "$OUT/$1.jpg" > /dev/null 2>&1 && rm -f "$OUT/$1.png"
  echo "  shot $1"
}
crop() {                                              # crop <the shot just taken> <name> <left> <top> <width> <height>: that part of it (fractions of the screen) at full size
  local w h
  [ -f "$RUN/last.png" ] || return 0
  w=$(sips -g pixelWidth "$RUN/last.png" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
  h=$(sips -g pixelHeight "$RUN/last.png" 2>/dev/null | awk '/pixelHeight/ { print $2 }')
  [ -n "$w" ] && [ -n "$h" ] || return 0
  sips -s format jpeg -s formatOptions 88        -c "$(python3 -c "print(int($h * $6))")" "$(python3 -c "print(int($w * $5))")"        --cropOffset "$(python3 -c "print(int($h * $4))")" "$(python3 -c "print(int($w * $3))")"        "$RUN/last.png" --out "$OUT/$2.jpg" > /dev/null 2>&1 || echo "  (no crop $2 on this macOS)"
}
step() {                                              # step <name> <ignored> <command lines…>: run them, then take the picture
  local name="$1"; shift 2
  cmd "$@"
  sleep 1.5
  shot "$name"
}

SET=com.apple.Preferences
MAPS=com.apple.Maps
SAFARI=com.apple.mobilesafari
CAL=com.apple.mobilecal
FILES=com.apple.DocumentsApp
REM=com.apple.MobileAddressBook        # Contacts: the second shortcut app (no permission alert of its own)
HEALTH=com.apple.Health

# three moments for the market flags (the band's clock is told the time; it runs on from there)
INDIA_OPEN=2026-11-23T10:00:00+05:30        # Monday 10:00 in India: NSE open, London and New York closed
WEST_OPEN=2026-11-23T21:00:00+05:30         # 15:30 in London and 10:30 in New York: both open, India closed
ALL_CLOSED=2026-11-22T12:00:00+05:30        # a Sunday
INDIA_HOLIDAY=2026-11-24T10:00:00+05:30     # Tuesday, Guru Nanak Jayanti: NSE is shut

echo "== the Settings page, as the generator makes it"
python3 tools/make_prefs.py --dump "$OUT/prefs-check" > "$OUT/settings-page.txt" 2>&1 || echo "the Settings page could not be dumped"
head -4 "$OUT/settings-page.txt"
rm -rf "$OUT/prefs-check"

echo "== what this SpringBoard has"
cmd "windows" "scenes" "iconmenu $MAPS" "hooks" "state" "where"
sleep 5
shot 01-home
crop 01-home 01b-edge-handle-shown 0.78 0.80 0.22 0.17          # the faint pill on the right edge, above the Home bar
step 01c-edge-handle-hidden 4 "set showHandle false" "wait 1" "state"
crop 01c-edge-handle-hidden 01d-edge-handle-hidden-close-up 0.78 0.80 0.22 0.17
cmd "set showHandle true" "wait 0.5"
echo "-- the Home gesture: what is watched and what is in place"
grep -E "Home: |Home gesture: |hook skipped" "$RUN/Atelier.log" | cut -c21- | head -20
awk '/cmd> hooks/{f=1;next} /cmd> /{f=0} f' "$RUN/Atelier.log" | head -14

echo "== the bench: the band, the dock and six apps"
# the index numbers are test numbers from the start, so that nothing is fetched until the step that says so
step 02-side-three 26 "quotes rise" "clock $INDIA_OPEN" "shortcuts $CAL $REM $HEALTH $MAPS" "badge $REM 3" "apps $SET $MAPS $SAFARI" "wait 21" "scenes" "state" "where"
step 03-side-six 32 "apps $SET $MAPS $SAFARI $FILES $PROBE $CAL" "wait 26" "state" "where"
crop 03-side-six 03b-top-band 0 0.060 1 0.100          # the band, at full size
crop 03-side-six 03c-dock 0 0.925 1 0.045              # the dock: the switches and the credit line
step 04-markets-west-open 4 "clock $WEST_OPEN" "wait 1.5" "state"
step 05-markets-all-closed 4 "clock $ALL_CLOSED" "wait 1.5" "state"
step 06-markets-india-holiday 4 "clock $INDIA_HOLIDAY" "wait 1.5" "state"
step 06b-markets-extra-holiday 5 "set extraHolidays 2027-01-26, 2026-11-23" "clock $INDIA_OPEN" "wait 1.5" "state"     # a typed date: Monday becomes a holiday too
step 06c-markets-india-open 5 "unset extraHolidays" "clock $INDIA_OPEN" "wait 1.5" "state"
step 07-side-swap 5 "main 2" "wait 2" "state"
step 08-top 6 "layout top" "wait 3" "state" "where"
step 09-top-probe-main 7 "main 4" "wait 4" "state"
step 10-menu 3 "menu 0" "wait 1" "state"
step 11-mini-menu 3 "hidemenu" "wait 0.4" "menu 2"
step 12-split 6 "hidemenu" "layout split" "wait 3" "state" "where"
step 13-side-again 6 "layout side" "wait 3" "state"

echo "== index numbers (test numbers, then one real fetch)"
step 60-indices-up 3 "clock $INDIA_OPEN" "quotes rise" "wait 1" "state"
crop 60-indices-up 60b-indices-up-band 0 0.060 1 0.100
step 61-indices-down 3 "quotes fall" "wait 1" "state"
crop 61-indices-down 61b-indices-down-band 0 0.060 1 0.100
step 62-indices-one-up-one-down 3 "quotes mixed" "wait 1" "state"        # SENSEX above a lakh: 1,00,412.05
crop 62-indices-one-up-one-down 62b-indices-mixed-band 0 0.060 1 0.100
step 63-indices-stale 3 "quotes stale" "wait 1" "state"                  # 2 and 15 minutes old during the session
crop 63-indices-stale 63b-indices-stale-band 0 0.060 1 0.100
step 64-indices-feed-failing 3 "quotes error" "wait 1" "state"           # the last numbers, dimmed
crop 64-indices-feed-failing 64b-indices-failing-band 0 0.060 1 0.100
step 65-indices-closed 3 "clock $ALL_CLOSED" "quotes rise" "wait 1" "state"
crop 65-indices-closed 65b-indices-closed-band 0 0.060 1 0.100
step 66-indices-top 5 "layout top" "wait 3" "state" "where"              # the compact form
step 67-indices-split 5 "layout split" "wait 3" "state" "where"
cmd "layout side" "wait 2"
# the real thing, once: Yahoo's public feed, at the real time of day
step 68-indices-real-fetch 14 "clock off" "quotes fetch" "wait 10" "state"
crop 68-indices-real-fetch 68b-indices-real-band 0 0.060 1 0.100
echo "-- the real fetch:"; grep "quotes: " "$RUN/Atelier.log" | tail -4 | cut -c21-
step 69-indices-off 4 "quotes rise" "set showIndices false" "wait 2" "state" "where"       # the switch in Settings: no lines, a bigger main
cmd "set showIndices true" "clock $INDIA_OPEN" "wait 2"

echo "== toggles"
step 70-toggles-all-off 4 "togglefake wifi off" "togglefake bluetooth off" "togglefake data off" "togglefake dnd off" "togglefake lowpower off" "wait 1.5" "state" "where"
crop 70-toggles-all-off 70b-toggles-all-off-dock 0 0.925 1 0.045
step 71-toggles-all-on 5 "togglefake wifi on" "togglefake bluetooth on" "togglefake data on" "togglefake dnd on" "togglefake lowpower on" "switch awake" "wait 2.5" "state"
crop 71-toggles-all-on 71b-toggles-all-on-dock 0 0.925 1 0.045
step 72-toggles-some 4 "togglefake bluetooth off" "togglefake dnd off" "togglefake lowpower off" "wait 1.5" "state"
crop 72-toggles-some 72b-toggles-some-dock 0 0.925 1 0.045
# Keep Awake is on: the bench's clock resets the idle timer; closing the bench ends it
cmd "wait 12" "state" "close" "wait 2" "state" "open" "wait 6" "state"
echo "-- Keep Awake:"; grep -E "Keep Awake|idle timer" "$RUN/Atelier.log" | tail -5 | cut -c21-
# what the simulator's own switches say, and each one flipped for real and back (logged before and after)
cmd "togglefake clear" "wait 2" "state"
for t in wifi bluetooth lowpower dnd data; do cmd "switch $t" "wait 3" "switch $t" "wait 3"; done
step 73-toggles-real 4 "state"
echo "-- toggles flipped for real in the simulator:"; grep "toggle " "$RUN/Atelier.log" | grep -v "cmd>" | tail -14 | cut -c21-
step 74-toggles-three-off-in-settings 5 "set toggleData false" "set toggleDND false" "set toggleLowPower false" "wait 2" "state" "where"
step 74b-top-with-dock 5 "layout top" "wait 3" "state"
cmd "set toggleData true" "set toggleDND true" "set toggleLowPower true" "layout side" "wait 2"

echo "== shortcut apps"
step 14-shortcut-already-on-the-bench 5 "shortcut 0" "wait 2" "state"       # Calendar is there: it becomes the main
step 15-shortcut-bench-full 4 "shortcut 1" "wait 1" "state"                 # Contacts is not, and there is no room
step 16-closed-one 5 "closeapp 5" "wait 2" "state" "where"
step 17-shortcut-opened 14 "shortcut 1" "wait 10" "state"                   # now Contacts opens as the main
step 17b-shortcut-menu 4 "shortcuthold 2" "wait 1" "state" "where"          # a hold: Open, Remove from Shortcuts
step 17c-shortcut-removed 4 "menutap 1" "wait 1.5" "state" "where"          # Health leaves the row
step 17d-shortcut-plus-picker 5 "shortcutplus" "wait 2.5" "sheet" "where" "windows"      # the "+": the picker, its field focused
step 17e-shortcut-search 4 "type héa" "wait 1" "sheet"                      # accents and case don't matter: Health
step 17f-shortcut-added-by-return 5 "return" "wait 2" "state" "where"
step 17g-no-shortcuts 4 "shortcuts none" "wait 1.5" "state" "where"         # just the "+"
cmd "shortcuts $CAL $REM $HEALTH $MAPS" "wait 1"

echo "== locks, swipes and freezing, by command"
step 18-locked 4 "lock 2" "wait 1.5" "state"
step 19-swipe-left-refused 4 "swipe 2 left" "wait 1.5" "state"
step 20-frozen-locked-stays-live 8 "freeze" "wait 4" "state" "scenes"
step 21-thawed 5 "touch" "wait 2" "state"
step 22-stills-only 9 "set miniMode 2" "wait 6" "state"
cmd "set miniMode 0" "touch"
sleep 3
step 23-swipe-down-pairs 6 "swipe 3 down" "wait 3" "state"
step 24-side-again 6 "layout side" "wait 3" "state"

echo "== sheets and sets"
step 25-closed-two 5 "closeapp 5" "wait 1.5" "closeapp 4" "wait 2" "state"
step 26-picker 5 "plus" "wait 2.5" "sheet" "where"
step 26b-picker-search 4 "type ma" "wait 1" "sheet"
step 26c-picker-search-nothing 4 "type zzq" "wait 1" "sheet"
step 26d-picker-cleared 4 "type" "wait 1" "sheet"
step 27-picked 9 "pick 4" "wait 6" "state" "windows"
step 28-set-saved 6 "saveset" "wait 3" "sets"
step 29-set-opened-lock-kept 9 "pick 0" "wait 6" "state"
step 30-icon-menu 3 "sheetclose" "iconmenu $MAPS" "state"

echo "== apps hidden by SporeX (a test list written in the simulator)"
# the bench: Settings, Maps, Safari, Files · shortcuts: Calendar, Contacts, Health, Maps · a set with Maps in it
cmd "unlockall" "spore off" "apps $SET $MAPS $SAFARI $FILES" "layout side" "wait 8" "saveset" "wait 3" "state"
shot 80-spore-before
step 81-spore-maps-and-health-hidden 6 "spore $MAPS $HEALTH" "wait 3" "state" "where"       # Maps leaves the bench, both leave the shortcut row
step 82-spore-picker 5 "plus" "wait 2.5" "sheet"
step 83-spore-search-maps 4 "type map" "wait 1" "sheet"                    # no Maps
step 84-spore-sets 5 "sheetclose" "wait 0.6" "sets" "wait 1.5" "sheet"     # the set's names leave Maps out
step 85-spore-set-opened 8 "pick 0" "wait 5" "state"                       # and opening it does not bring Maps
cmd "sheetclose" "apps $SET $MAPS $HEALTH $SAFARI" "wait 4" "state"        # asked for by name: still not put on the bench
cmd "iconmenu $MAPS" "iconmenu $SAFARI"
# a saved bench with a hidden app in it: saved while nothing was hidden, opened after
cmd "spore off" "wait 1" "apps $SET $MAPS $SAFARI" "wait 5" "close" "wait 2" "spore dict $MAPS" "wait 1"       # the dictionary form of the list
step 86-spore-saved-bench-opened 8 "open" "wait 6" "state"
step 87-spore-off 6 "spore off" "wait 1" "plus" "wait 2.5" "type map" "wait 1" "sheet"       # nothing hidden: Maps is found again
cmd "sheetclose" "wait 1" "state"
echo "-- what the log says about hidden apps:"; grep -E "hidden apps|leave the bench|spore:" "$RUN/Atelier.log" | tail -12 | cut -c21-

echo "== coming and going, held part-way (by command: a hand that holds the bench a part of the way in)"
cmd "close" "wait 2" "state"
step 90-open-held-a-third-in 3 "drag open 0.33" "wait 0.8" "state"
step 91-open-held-two-thirds-in 3 "drag open 0.66" "wait 0.8" "state"
step 92-open-let-go-early-sprang-back 4 "drag open 0.2" "wait 0.3" "drag end 0" "wait 1.5" "state"       # gone again
step 93-open-held-half-in 3 "drag open 0.5" "wait 0.8"
step 94-open-let-go-opened 4 "drag end 1" "wait 1.5" "state"
step 95-close-held-half-up 3 "drag close 0.5" "wait 0.8" "state"
step 96-close-let-go-early-sprang-back 4 "drag end 0" "wait 1.5" "state"                                 # still there
step 97-close-held-mostly-gone 3 "drag close 0.25" "wait 0.8"
step 98-close-let-go-closed 4 "drag end 1" "wait 1.5" "state"
echo "-- the bench coming and going:"; grep -E "bench open|bench close|drag: " "$RUN/Atelier.log" | tail -8 | cut -c21-150

echo "== a Home action puts the bench away"
step 99-bench-up-on-the-home-screen 8 "open" "wait 6" "state"
step 99b-home-closed-the-bench 6 "home" "wait 3" "state"
cmd "launch $SET" "wait 5" "open" "wait 6" "state"                         # and with an app in front
step 99c-home-closed-the-bench-over-an-app 7 "home" "wait 4" "state"
echo "-- what the log says:"; grep -E "Home: |Home gesture: |bench close \(Home" "$RUN/Atelier.log" | tail -10 | cut -c21-

echo "== leaving and coming back"
cmd "open" "wait 6"
step 31-full-screen 8 "full 0" "wait 5" "state" "scenes"
step 32-open-over-app 10 "open" "wait 7" "state"
step 33-closed 6 "close" "wait 3" "state" "scenes"
step 34-edge-strip 5 "set triggerTint 1" "wait 1" "state"
step 35-reopened 12 "trigger" "wait 8" "state"                              # the strip, still tinted: it ends above the dock now
step 36-bare 6 "set triggerTint 0" "set showClock false" "set showMarkets false" "set showIndices false" "shortcuts none" "set toggleWifi false" "set toggleBluetooth false" "set toggleData false" "set toggleDND false" "set toggleAwake false" "set toggleLowPower false" "wait 3" "state" "where"
step 37-top-bare 6 "layout top" "wait 3" "state"
cmd "set showClock true" "set showMarkets true" "set showIndices true" "set toggleWifi true" "set toggleBluetooth true" "set toggleData true" "set toggleDND true" "set toggleAwake true" "set toggleLowPower true" "shortcuts $CAL $REM $HEALTH $MAPS" "layout side" "wait 2" "close" "wait 2" "state" "scenes"
sleep 8

# ---- fingers: clicks and drags on the Simulator's window become touches on the simulated screen ----
# Nothing here can fail the test: a runner where the Mac's screen can't be clicked just reports that.
touch_test() {
  local DATA PLOG GEO WX WY WW WH METHOD before X1 Y1 X2 Y2 M1X M1Y M2X M2Y WHERE KB
  WHERE="$RUN/atelier_where.txt"
  DATA=$(xcrun simctl get_app_container "$UDID" "$PROBE" data 2>/dev/null) || { echo "no probe app"; return 0; }
  PLOG="$DATA/Documents/probe.log"
  xcrun clang -O1 -o "$OUT/click" tools/click.c -framework ApplicationServices > "$OUT/click-build.log" 2>&1 || { cat "$OUT/click-build.log"; echo "the clicker did not build"; return 0; }
  open -a Simulator --args -CurrentDeviceUDID "$UDID"
  sleep 25
  osascript -e 'tell application "Simulator" to activate' > /dev/null 2>&1 || true
  sleep 3
  GEO=$(osascript -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of front window' 2>&1)
  echo "simulator window: $GEO"
  screencapture -x "$OUT/40-mac-screen.png" > /dev/null 2>&1 && sips -s format jpeg -s formatOptions 60 -Z 1600 "$OUT/40-mac-screen.png" --out "$OUT/40-mac-screen.jpg" > /dev/null 2>&1 && rm -f "$OUT/40-mac-screen.png"
  read -r WX WY WW WH <<< "$(echo "$GEO" | tr -d ' ' | tr ',' ' ')"
  case "$WX$WY$WW$WH" in *[!0-9.-]*|"") echo "no window geometry: touches not tested"; return 0 ;; esac

  touches() { grep -c "touch " "$PLOG" 2>/dev/null || echo 0; }
  last_touch() { grep "touch " "$PLOG" 2>/dev/null | tail -1 | sed -E 's/.* at (-?[0-9]+),(-?[0-9]+).*/\1 \2/'; }
  mac_click() {
    if [ "$METHOD" = "cg" ]; then "$OUT/click" "$1" "$2"
    else osascript -e "tell application \"System Events\" to click at {$(printf '%.0f' "$1"), $(printf '%.0f' "$2")}" > /dev/null 2>&1; fi
  }
  calc() { python3 -c "print($1)"; }
  SKIP=$(wc -l < "$RUN/Atelier.log" | tr -d ' ')       # only what the log says from here on counts as an answer
  last() { tail -n +"$((SKIP + 1))" "$RUN/Atelier.log" | grep "$1" | tail -1 | cut -c21-190; }      # the last such line, without the date
  count() { tail -n +"$((SKIP + 1))" "$RUN/Atelier.log" | grep -c "$1"; }

  # 1. the probe app on its own, full screen: two clicks tell how Mac points map to phone points
  xcrun simctl launch "$UDID" "$PROBE" > /dev/null 2>&1
  sleep 6
  M1X=$(calc "$WX + $WW * 0.50"); M1Y=$(calc "$WY + $WH * 0.42")
  M2X=$(calc "$WX + $WW * 0.36"); M2Y=$(calc "$WY + $WH * 0.54")
  "$OUT/click" "$M1X" "$(calc "$WY + $WH * 0.30")"; sleep 1          # the first click may only wake the window
  METHOD=cg
  before=$(touches); mac_click "$M1X" "$M1Y"; sleep 2
  if [ "$(touches)" = "$before" ]; then METHOD=as; mac_click "$M1X" "$M1Y"; sleep 2; fi
  if [ "$(touches)" = "$before" ]; then echo "clicks on the Mac's screen do not reach the simulator here: touches not tested"; return 0; fi
  read -r X1 Y1 <<< "$(last_touch)"
  mac_click "$M2X" "$M2Y"; sleep 2
  read -r X2 Y2 <<< "$(last_touch)"
  echo "click method $METHOD · Mac $M1X,$M1Y -> phone $X1,$Y1 · Mac $M2X,$M2Y -> phone $X2,$Y2"
  if [ "$X1" = "$X2" ] || [ "$Y1" = "$Y2" ]; then echo "could not work out the scale: touches not tested"; return 0; fi
  mx() { calc "$M1X + ($1 - $X1) * ($M2X - $M1X) / ($X2 - $X1)"; }
  my() { calc "$M1Y + ($1 - $Y1) * ($M2Y - $M1Y) / ($Y2 - $Y1)"; }
  phone() { mac_click "$(mx "$1")" "$(my "$2")"; }                    # phone <x> <y>: click that point of the phone's screen
  phone_hold() { "$OUT/click" "$(mx "$1")" "$(my "$2")" "$3"; }       # phone_hold <x> <y> <seconds>: a finger held there
  phone_drag() { "$OUT/click" drag "$(mx "$1")" "$(my "$2")" "$(mx "$3")" "$(my "$4")" "${5:-0.5}"; }
  phone_flick() { "$OUT/click" flick "$(mx "$1")" "$(my "$2")" "$(mx "$3")" "$(my "$4")" "${5:-0.05}"; }
  drag_shot() {                                       # drag_shot <x1> <y1> <x2> <y2> <picture>: the picture is taken with the finger still down
    "$OUT/click" drag "$(mx "$1")" "$(my "$2")" "$(mx "$3")" "$(my "$4")" 0.5 4.5 &
    sleep 1.5
    shot "$5"
    wait
  }
  # where things are on the phone's screen, from the bench itself (the "where" command)
  where() {
    rm -f "$WHERE"
    cmd "where"
    for i in 1 2 3 4 5 6 7 8; do [ -s "$WHERE" ] && break; sleep 1; done
  }
  cx() { awk -v n="$1" '$1 == n { printf "%.1f", $2 + $4 / 2 }' "$WHERE"; }
  cy() { awk -v n="$1" '$1 == n { printf "%.1f", $3 + $5 / 2 }' "$WHERE"; }
  lx() { awk -v n="$1" '$1 == n { printf "%.1f", $2 }' "$WHERE"; }                    # its left edge
  ax() { awk -v a="$1" '$1 == "main" { printf "%.1f", $2 + a * $6 }' "$WHERE"; }      # a point of the main app -> the screen
  ay() { awk -v a="$1" '$1 == "main" { printf "%.1f", $3 + a * $6 }' "$WHERE"; }
  # a key of SpringBoard's own keyboard (the picker's): key <letter|return>. Rows are counted up from the
  # keyboard's bottom edge, as measured on this screen size with the probe's keyboard (G is 214 pt above it).
  key() {
    local kb_bottom kb_w row col
    kb_bottom=$(awk '$1 == "keyboard" { printf "%.1f", $3 + $5 }' "$WHERE")
    kb_w=$(awk '$1 == "keyboard" { printf "%.1f", $4 }' "$WHERE")
    [ -n "$kb_bottom" ] || return 1
    case "$1" in
      q|w|e|r|t|y|u|i|o|p) row=268; col=$(python3 -c "print('qwertyuiop'.index('$1') + 0.5)") ;;
      a|s|d|f|g|h|j|k|l)   row=214; col=$(python3 -c "print('asdfghjkl'.index('$1') + 1.0)") ;;
      z|x|c|v|b|n|m)       row=160; col=$(python3 -c "print('zxcvbnm'.index('$1') + 2.0)") ;;
      return)              row=106; col=8.72 ;;
      *) return 1 ;;
    esac
    phone "$(calc "$kb_w / 10.0 * $col")" "$(calc "$kb_bottom - $row")"
    sleep 0.8
  }
  have_keyboard() { grep -q "^keyboard " "$WHERE"; }
  phone 300 250; sleep 2
  echo "T0 full screen: clicked phone 300,250 · the probe got $(last_touch)"

  # 2. the probe as the main of a full bench (Side), minis kept live so nothing freezes mid-test
  cmd "unlockall" "quotes rise" "set miniMode 1" "set swipeDown 0" "clock $INDIA_OPEN" "apps $PROBE $SET $MAPS $SAFARI $FILES $CAL" "layout side" "wait 8" "state"
  sleep 8
  where
  cat "$WHERE"
  shot 41-touch-bench
  phone "$(ax 200)" "$(ay 300)"; sleep 2
  echo "T1 scaled main: clicked the app's 200,300 at phone $(ax 200),$(ay 300) · the probe got $(last_touch)"
  phone "$(ax 40)" "$(ay 30)"; sleep 2
  echo "T1b scaled main: clicked the app's 40,30 · the probe got $(last_touch)"
  phone "$(ax 215)" "$(ay 718)"; sleep 2                # the G key of the app's keyboard
  echo "T2 keyboard: $(grep 'text ' "$PLOG" | tail -1)"
  shot 42-touch-key

  # 3. swipes on a mini (mini0 Settings, mini1 Maps, mini2 Safari, mini3 Files, mini4 Calendar)
  drag_shot "$(cx mini1)" "$(cy mini1)" "$(calc "$(cx mini1) + 80")" "$(cy mini1)" 43-swipe-right-held
  sleep 3
  echo "T3 swipe right on Maps: $(last 'swipe right') · $(last 'swap:')"
  shot 44-swipe-right-done
  where                                                 # now: main Maps · mini0 Settings, mini1 the probe, mini2 Safari, mini3 Files, mini4 Calendar
  drag_shot "$(cx mini0)" "$(cy mini0)" "$(cx mini0)" "$(calc "$(cy mini0) - 75")" 45-swipe-up-held
  sleep 2
  echo "T4 swipe up on Settings: $(last 'swipe up') · $(last 'lock com')"
  shot 46-swipe-up-locked
  # Short swipes to the left. The column lies against the left edge: the finger comes down 30 pt
  # into the tile (about 40 pt from the edge) and goes 28 pt, which 1.1.0's fixed 40 pt never saw.
  echo "   minis start at x $(lx mini0); the finger comes down at x $(calc "$(lx mini0) + 30") and travels 28 pt to the left"
  drag_shot "$(calc "$(lx mini0) + 30")" "$(cy mini0)" "$(calc "$(lx mini0) + 2")" "$(cy mini0)" 47-short-swipe-left-locked-held
  sleep 2
  echo "T5 short swipe left (28 pt) on locked Settings: $(last 'swipe left on com.apple.Preferences')"
  shot 48-short-swipe-left-locked-after
  drag_shot "$(calc "$(lx mini3) + 30")" "$(cy mini3)" "$(calc "$(lx mini3) + 2")" "$(cy mini3)" 49-short-swipe-left-held
  sleep 3
  echo "T6 short swipe left (28 pt) on Files: $(last 'swipe left on com.apple.DocumentsApp armed') · $(last 'close app')"
  shot 50-short-swipe-left-closed
  where                                                 # main Maps · mini0 Settings (locked), mini1 the probe, mini2 Safari, mini3 Calendar
  phone_drag "$(calc "$(lx mini2) + 30")" "$(cy mini2)" "$(calc "$(lx mini2) + 19")" "$(cy mini2)" 0.6; sleep 2
  echo "T6b 11 pt, slowly, on Safari: $(last 'swipe left on com.apple.mobilesafari')"
  shot 50a-after-11pt
  phone_flick "$(calc "$(lx mini3) + 55")" "$(cy mini3)" "$(calc "$(lx mini3) + 37")" "$(cy mini3)" 0.04; sleep 3
  echo "T6c a flick left (18 pt in 0.04 s, 65 pt from the edge) on Calendar: $(last 'swipe left on com.apple.mobilecal')"
  shot 50b-after-flick
  where
  drag_shot "$(cx mini2)" "$(cy mini2)" "$(cx mini2)" "$(calc "$(cy mini2) + 80")" 51-swipe-down-held
  sleep 4
  echo "T7 swipe down on Safari: $(last 'swipe down') · $(last 'pair:') · $(last '  layout [0-9]')"
  shot 52-swipe-down-split
  echo "   every swipe that ended without acting, as the log has it:"
  tail -n +"$((SKIP + 1))" "$RUN/Atelier.log" | grep "did not arm" | cut -c21- | sed 's/^/     /'

  # 4. taps: a mini, the pill, a menu row, a shortcut
  cmd "layout side" "wait 3" "state"; sleep 6
  where
  phone "$(cx mini1)" "$(cy mini1)"; sleep 3
  echo "T8 tap on a mini: $(last 'swap:')"
  shot 53-tap-swap
  where
  phone "$(cx pill)" "$(cy pill)"; sleep 2
  where
  echo "T9 pill: $(grep 'menu ' "$WHERE" || echo 'no menu')"
  shot 54-tap-menu
  phone "$(cx menu)" "$(calc "$(awk '$1 == "menu" { print $3 }' "$WHERE") + 46 + 23")"; sleep 3      # its second row: Switch Layout
  echo "T9b menu row: $(last '  layout [0-9]')"
  shot 55-tap-layout
  cmd "layout side" "wait 3"; sleep 5
  where
  phone "$(cx shortcut1)" "$(cy shortcut1)"; sleep 4                       # Contacts: not on the bench, and there is room
  echo "T10 tap on a shortcut: $(last 'shortcut com')"
  shot 56-tap-shortcut

  # 5. the picker's search field, with clicks on the keys of SpringBoard's own keyboard
  cmd "apps $PROBE $SET $MAPS" "layout side" "wait 7" "state"; sleep 4
  where
  phone "$(cx plus)" "$(cy plus)"; sleep 4                                 # the "+" tile
  where
  echo "T13 the + tile: $(last 'picker: window key') · $(last 'picker keyboard')"
  shot 60-picker-open-keyboard
  if have_keyboard; then
    key q
    echo "T13b the Q key: $(last 'picker search')"
    where
    phone "$(cx fieldclear)" "$(cy fieldclear)"; sleep 1.5                 # the clear button
    echo "T13c the clear button: $(last 'picker search')"
    key c; key a; key l
    cmd "sheet"; where
    echo "T13d the keys C, A, L: $(last 'picker search') · $(last 'sheet:' | cut -c1-150)"
    shot 61-picker-typed-cal
    phone "$(cx row0)" "$(cy row0)"; sleep 5                               # the first match
    echo "T13e a tap on the first match: $(last 'picker: a tap') · $(last 'keyboard: given back')"
  else
    echo "T13b SpringBoard's keyboard did not come up here: the text is put in by command instead"
    cmd "type cal" "wait 1" "sheet"; shot 61-picker-typed-cal
    cmd "pick 0" "wait 4"
    echo "T13e by command: $(last 'picker:')"
  fi
  cmd "state"; where
  shot 62-picker-picked
  # the keyboard goes back to the bench's main app: its field is tapped and a key of its own keyboard pressed
  before=$(grep -c 'text ' "$PLOG" 2>/dev/null || echo 0)
  phone "$(ax 170)" "$(ay 152)"; sleep 2
  phone "$(ax 215)" "$(ay 718)"; sleep 2
  echo "T14 after the picker, the main app's own keyboard: $(grep 'text ' "$PLOG" | tail -1) ($(( $(grep -c 'text ' "$PLOG" 2>/dev/null || echo 0) - before )) new line(s) of text)"
  shot 63-main-app-types-again

  # 6. the shortcut row: its "+" (search, then Return), a hold, Remove
  cmd "shortcuts $CAL $REM" "wait 1.5"; where
  phone "$(cx shortcut-plus)" "$(cy shortcut-plus)"; sleep 4
  where
  echo "T15 the + of the shortcut row: $(last 'picker: window key')"
  if have_keyboard; then
    key s; key a; key f
    cmd "sheet"
    echo "T15b the keys S, A, F: $(last 'picker search')"
    shot 64-shortcut-picker-typed-saf
    key return; sleep 3
    echo "T15c the Return key: $(last 'picker: Return') · $(last 'shortcut added')"
  else
    cmd "type saf" "wait 1" "return" "wait 2"
    echo "T15c by command: $(last 'picker:') · $(last 'shortcut added')"
  fi
  where
  shot 65-shortcut-added
  phone_hold "$(cx shortcut2)" "$(cy shortcut2)" 0.9; sleep 2              # a hold on the new icon
  where
  echo "T16 a hold on the new shortcut: $(last 'shortcut com.apple.mobilesafari: menu') · $(grep 'menu ' "$WHERE" || echo 'no menu')"
  shot 66-shortcut-menu
  phone "$(cx menu)" "$(calc "$(awk '$1 == "menu" { print $3 }' "$WHERE") + 46 + 23")"; sleep 2      # its second row: Remove from Shortcuts
  echo "T16b Remove from Shortcuts: $(last 'shortcut removed')"
  where
  shot 67-shortcut-removed

  # 7. the dock: a switch tapped, and a swipe up that starts on a switch
  phone "$(cx toggle-awake)" "$(cy toggle-awake)"; sleep 3
  echo "T17 a tap on Keep Awake: $(last 'toggle Keep Awake')"
  shot 68-toggle-tapped
  crop 68-toggle-tapped 68b-toggle-tapped-dock 0 0.925 1 0.045
  before=$(count 'toggle Wi-Fi')
  phone_drag "$(cx toggle-wifi)" "$(cy toggle-wifi)" "$(cx toggle-wifi)" "$(calc "$(cy toggle-wifi) - 120")"; sleep 4
  echo "T18 swipe up that starts on the Wi-Fi switch: $(last 'bench close') · $(last 'Keep Awake: off') · Wi-Fi flipped $(( $(count 'toggle Wi-Fi') - before )) time(s)"
  shot 69-swipe-up-from-switch

  # 8. coming and going with a finger: the edge strip, the swipe up, the Home gesture
  cmd "close" "wait 2"; sleep 2
  where
  EX=$(awk '$1 == "edge" { printf "%.1f", $2 + $4 - 4 }' "$WHERE"); EY=$(cy edge)
  echo "   the edge strip, bench closed: $(grep '^edge ' "$WHERE") · the handle: $(grep '^handle ' "$WHERE" || echo none)"
  drag_shot "$EX" "$EY" "$(calc "$EX - 70")" "$EY" g01-edge-open-held-70pt        # 70 pt in from the edge, finger still down
  sleep 3
  echo "T20 edge strip, 70 pt in, then let go: $(last 'strip touch') · $(last 'bench open' | cut -c1-40)"
  shot g02-edge-open-let-go-opened
  cmd "close" "wait 2"; sleep 2
  drag_shot "$EX" "$EY" "$(calc "$EX - 9")" "$EY" g03-edge-open-held-9pt          # too little: it springs back
  sleep 3
  echo "T21 edge strip, 9 pt in, then let go: $(last 'strip touch') · $(last 'bench close')"
  shot g04-edge-open-sprang-back
  cmd "close" "wait 2"; sleep 2
  phone_flick "$EX" "$EY" "$(calc "$EX - 12")" "$EY" 0.04; sleep 5
  echo "T22 edge strip, a flick of 12 pt: $(last 'strip touch')"
  shot g05-edge-flick
  cmd "open" "wait 6" "state"; sleep 3
  where
  EX=$(awk '$1 == "edge" { printf "%.1f", $2 + $4 - 3 }' "$WHERE"); EY=$(cy edge)
  echo "   the edge strip, bench up: $(grep '^edge ' "$WHERE")"
  drag_shot "$EX" "$EY" "$(calc "$EX - 80")" "$EY" g06-edge-close-held-80pt
  sleep 3
  echo "T23 edge strip with the bench up, 80 pt in: $(last 'strip touch') · $(last 'bench close')"
  shot g07-edge-close-let-go-closed
  cmd "open" "wait 6"; sleep 3
  drag_shot 215 915 215 765 g08-swipe-up-held-150pt                                 # from under the dock, 150 pt up, finger still down
  sleep 3
  echo "T24 swipe up from the bottom, 150 pt, then let go: $(last 'bottom swipe') · $(last 'bench close')"
  shot g09-swipe-up-let-go-closed
  cmd "open" "wait 6"; sleep 3
  drag_shot 215 915 215 890 g10-swipe-up-held-25pt                                  # too little: it springs back
  sleep 3
  echo "T25 swipe up, 25 pt, then let go: $(last 'bottom swipe')"
  shot g11-swipe-up-sprang-back
  cmd "open" "wait 5"; sleep 2
  phone_flick 215 915 215 895 0.04; sleep 4
  echo "T26 a flick up of 20 pt: $(last 'bottom swipe') · $(last 'bench close')"
  shot g12-flick-up
  cmd "open" "wait 6"; sleep 3
  before=$(count 'Home')
  phone_drag 215 931.5 215 520 0.35; sleep 5          # from the very bottom edge: where SpringBoard's Home gesture lives
  echo "T27 from the very bottom edge: $(( $(count 'Home') - before )) Home line(s) · $(last 'Home gesture') · $(last 'Home: ') · $(last 'bottom swipe') · $(last 'bench close')"
  shot g13-from-the-bottom-edge
  echo "   every strip touch and bottom swipe, as the log has it:"
  tail -n +"$((SKIP + 1))" "$RUN/Atelier.log" | grep -E "strip touch|bottom swipe|Home gesture|Home: " | cut -c21- | sed 's/^/     /'

  # 9. out and in again, as before
  cmd "open" "wait 6"; sleep 3
  phone_drag 215 921 215 560; sleep 4                 # up from the bottom of the screen
  echo "T11 swipe up from the bottom: $(last 'bench close')"
  shot 57-swipe-up-closed
  cmd "close" "wait 1"; sleep 3
  phone_drag 426 840 300 815; sleep 5                 # in from the right edge, on the strip
  echo "T12 edge strip: $(last 'strip touch') · $(last 'bench open' | cut -c1-60)"
  shot 58-edge-swipe-opened
  cmd "state" "set miniMode 0" "clock off" "quotes off" "close" "wait 2" "state"
  sleep 6
}
echo "== touches (clicks and drags on the Simulator window)"
touch_test 2>&1 | tee "$OUT/touch.txt"

cp "$RUN/Atelier.log" "$OUT/Atelier.log" 2>/dev/null || true
DATA=$(xcrun simctl get_app_container "$UDID" "$PROBE" data 2>/dev/null)
[ -n "$DATA" ] && cp "$DATA/Documents/probe.log" "$OUT/probe.log" 2>/dev/null
echo "== probe.log (what the probe app was given)"
cat "$OUT/probe.log" 2>/dev/null || echo "(none)"
echo "== Atelier.log"
cat "$OUT/Atelier.log" 2>/dev/null
collect_crashes
ls -la "$OUT" | head -150
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
if ls "$OUT"/SpringBoard*.ips > /dev/null 2>&1; then echo "SpringBoard crashed during the test: see the crash reports"; exit 1; fi
starts=$(grep -c "in SpringBoard (pid" "$OUT/Atelier.log" 2>/dev/null || echo 0)
echo "HyperTrade started $starts time(s) during the test"
if [ "$starts" != "1" ]; then echo "SpringBoard restarted during the test: see the crash reports"; exit 1; fi
if grep -q "threw" "$OUT/Atelier.log" 2>/dev/null; then echo "an exception was caught: see the log"; grep "threw" "$OUT/Atelier.log" | head; exit 1; fi
if ! grep -q "hosted sceneID" "$OUT/Atelier.log" 2>/dev/null; then echo "no app was ever hosted"; exit 1; fi
exit 0
