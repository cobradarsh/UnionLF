#!/bin/bash
# Measures the original IWantTranslucent 0.9.4 against the lean rebuild in an iOS simulator.
#
# Three libraries' worth of hooks are compared in one small app (bench/harness.m):
#   none   nothing loaded: the yardstick
#   orig   upstream/Tweak.m exactly as Luki120 wrote it; only its import of the hooking library is
#          swapped for bench/substrate_shim.h, because a simulator has no ElleKit
#   opt    Tweak.m, the rebuild
# Each is started twice. The app times the hooks, opens a context menu, reports what is on screen
# and asks this script for a screenshot. tools/bench_report.py then puts the runs side by side.
#
# What this cannot show: anything about RootHide (the patch loader, the JIT flag), ElleKit, or
# the phone's own chip. Those are looked at on the phone with diag/iwtdiag.c.
#
# usage: tools/sim_bench.sh [output folder] [wanted iOS version, e.g. 16.4]
#        (run from the repository root, on a Mac with Xcode)
set -u
OUT="${1:-$PWD/sim-out}"
WANT="${2:-}"
mkdir -p "$OUT/run"
OUT="$(cd "$OUT" && pwd)"
RUN="$OUT/run"
BUNDLE=com.adarsh.iwtharness

ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS="-arch $ARCH -mios-simulator-version-min=15.0 -isysroot $SDK -fobjc-arc -O2 -g -Wall -Wno-deprecated-declarations"
echo "== build for the simulator ($ARCH, $SDK)"
(
  set -x
  # the rebuild, from the very file that goes to the phone
  xcrun --sdk iphonesimulator clang $FLAGS -dynamiclib -framework UIKit -framework Foundation \
    -install_name @rpath/opt.dylib -o "$OUT/opt.dylib" Tweak.m || exit 1
  # the original: one line changed, and the build stops unless exactly that one line was changed
  sed 's/^@import CydiaSubstrate;$/#import "substrate_shim.h"/' upstream/Tweak.m > "$OUT/orig_Tweak.m"
  [ "$(diff upstream/Tweak.m "$OUT/orig_Tweak.m" | grep -c '^[<>]')" = "2" ] || { echo "the import line of upstream/Tweak.m was not found"; exit 1; }
  xcrun --sdk iphonesimulator clang $FLAGS -fmodules -Ibench -dynamiclib -framework UIKit -framework Foundation \
    -install_name @rpath/orig.dylib -o "$OUT/orig.dylib" "$OUT/orig_Tweak.m" bench/substrate_shim.m || exit 1
  APP="$OUT/IWTHarness.app"
  rm -rf "$APP"
  mkdir -p "$APP"
  xcrun --sdk iphonesimulator clang $FLAGS -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore \
    -o "$APP/IWTHarness" bench/harness.m || exit 1
  cp bench/Info.plist "$APP/Info.plist"
  cp "$OUT/orig.dylib" "$OUT/opt.dylib" "$APP/"
  codesign -f -s - "$APP/orig.dylib" "$APP/opt.dylib" || exit 1
  codesign -f -s - "$APP" || exit 1
) > "$OUT/build.log" 2>&1
status=$?
cat "$OUT/build.log"
[ "$status" = "0" ] && [ -f "$OUT/IWTHarness.app/IWTHarness" ] || { echo "simulator build FAILED"; exit 1; }
APP="$OUT/IWTHarness.app"

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
if best:
    print("USE|%s|%s|%s" % (best[1], best[2], label))
else:
    types = [t.get("identifier", "") for t in rt.get("supportedDeviceTypes", [])] or [t.get("identifier", "") for t in data.get("devicetypes", [])]
    phones = [t for t in types if "iPhone" in t]
    pick = "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro-Max"
    if pick not in phones and phones:
        pick = sorted(phones, key=lambda t: ("Pro-Max" in t, t))[-1]
    print("CREATE|%s|%s|%s" % (ident, pick, label))
')
case "$PICK" in
  USE\|*)
    IFS='|' read -r _ UDID DEVNAME IOSVER <<< "$PICK" ;;
  CREATE\|*)
    IFS='|' read -r _ RUNTIME DEVTYPE IOSVER <<< "$PICK"
    DEVNAME="IWT bench (${DEVTYPE##*.})"
    UDID=$(xcrun simctl create "$DEVNAME" "$DEVTYPE" "$RUNTIME") || { echo "could not create a simulator for $RUNTIME"; exit 1; } ;;
  *)
    echo "no iPhone simulator runtime available"; xcrun simctl list runtimes; exit 1 ;;
esac
echo "simulator: $DEVNAME, iOS $IOSVER ($UDID)" | tee "$OUT/simulator.txt"

xcrun simctl boot "$UDID" 2>&1 | grep -v "current state: Booted" || true
xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1 || { tail -5 "$OUT/boot.log"; echo "simulator did not boot"; exit 1; }
tail -2 "$OUT/boot.log"
# the same picture every time: dark like the phone, and a clock that stands still
xcrun simctl ui "$UDID" appearance dark > /dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 > /dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP" || { echo "install failed"; exit 1; }

REPORTS=~/Library/Logs/DiagnosticReports
mkdir -p "$REPORTS"
touch "$OUT/.before"
app_running() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE"; }

run_variant() {                                       # run_variant <variant> <round>
  local variant="$1" round="$2" finished="" i req name
  rm -f "$RUN"/done-* "$RUN"/shot-request-* "$RUN/result-$variant.txt"
  xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1 || true
  sleep 1
  SIMCTL_CHILD_IWT_VARIANT="$variant" SIMCTL_CHILD_IWT_OUT="$RUN" xcrun simctl launch "$UDID" "$BUNDLE" > /dev/null 2>&1 \
    || { echo "  $variant: launch failed"; return 1; }
  for i in $(seq 1 480); do                           # up to four minutes
    for req in "$RUN"/shot-request-*; do
      [ -e "$req" ] || continue
      name="${req##*/shot-request-}"
      xcrun simctl io "$UDID" screenshot "$OUT/shot-r$round-$name.png" > /dev/null 2>&1 || echo "  screenshot $name failed"
      rm -f "$req"
    done
    if [ -e "$RUN/done-$variant" ]; then finished=yes; break; fi
    if [ $((i % 10)) = 0 ] && ! app_running; then
      sleep 1
      [ -e "$RUN/done-$variant" ] && finished=yes
      break
    fi
    sleep 0.5
  done
  cp "$RUN/result-$variant.txt" "$OUT/result-r$round-$variant.txt" 2> /dev/null || true
  if [ -z "$finished" ]; then
    echo "  $variant (round $round): did NOT finish"
    tail -5 "$OUT/result-r$round-$variant.txt" 2> /dev/null
    return 1
  fi
  echo "  $variant (round $round): finished, $(grep -c . "$OUT/result-r$round-$variant.txt") lines"
  return 0
}

echo "== runs"
failed=0
for round in 1 2; do
  for variant in none orig opt; do
    run_variant "$variant" "$round" || failed=1
  done
done
xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1 || true

crashes=""
for f in "$REPORTS"/IWTHarness*.ips; do
  [ -f "$f" ] && [ "$f" -nt "$OUT/.before" ] || continue
  cp "$f" "$OUT/" && crashes="$crashes $OUT/$(basename "$f")"
done
if [ -n "$crashes" ]; then
  echo "== crash reports"
  python3 tools/ips_summary.py $crashes
  failed=1
else
  echo "== no crash report"
fi

# small copies of the pictures for comparing (sips is part of macOS)
for f in "$OUT"/shot-*.png; do
  [ -f "$f" ] || continue
  sips -s format bmp -Z 900 "$f" --out "${f%.png}.bmp" > /dev/null 2>&1 || true
done

echo "== report"
python3 tools/bench_report.py "$OUT" | tee "$OUT/report.txt"
verdict=${PIPESTATUS[0]}
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
rm -f "$OUT"/shot-*.bmp
if [ "$failed" != "0" ]; then echo "a run did not finish or crashed"; exit 1; fi
exit "$verdict"
