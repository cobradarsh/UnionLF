#!/bin/bash
# Builds tests/engine_test.m with the download engine and runs it.
#
#   tools/engine_test.sh mac <output folder>             on the Mac itself (fast)
#   tools/engine_test.sh sim <output folder> [iOS]       inside an iOS simulator (16.4 is the nearest to the phone)
#
# Run from the repository root, on a Mac with Xcode.
set -u
MODE="${1:-mac}"
OUT="${2:-$PWD/engine-out}"
WANT="${3:-}"
mkdir -p "$OUT/files"
OUT="$(cd "$OUT" && pwd)"
SOURCES="tests/engine_test.m VGCore.m VGPlaylist.m VGFetch.m VGTS.m VGMux.m VGJob.m"
FRAMEWORKS="-framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox -framework CoreGraphics"
WARN="-Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable"

if [ "$MODE" = "mac" ]; then
  echo "== build for the Mac ($(uname -m))"
  xcrun clang -fobjc-arc -O1 -g $WARN $FRAMEWORKS -o "$OUT/engine_test" $SOURCES 2>&1 | tee "$OUT/build.log"
  [ -x "$OUT/engine_test" ] || { echo "build FAILED"; exit 1; }
  VIDGRAB_DIR="$OUT" VIDGRAB_STDERR=1 "$OUT/engine_test" "$OUT/files" 2> "$OUT/engine.log" | tee "$OUT/result.txt"
  status=${PIPESTATUS[0]}
  echo "== the engine's own log"
  tail -80 "$OUT/engine.log"
  ls -la "$OUT/files" 2>/dev/null
  echo "exit status $status"
  exit "$status"
fi

ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
echo "== build for the simulator ($ARCH)"
xcrun --sdk iphonesimulator clang -arch "$ARCH" -mios-simulator-version-min=15.0 -isysroot "$SDK" -fobjc-arc -O1 -g $WARN $FRAMEWORKS \
  -o "$OUT/engine_test_sim" $SOURCES 2>&1 | tee "$OUT/build.log"
[ -x "$OUT/engine_test_sim" ] || { echo "build FAILED"; exit 1; }
codesign -f -s - "$OUT/engine_test_sim" || true

PICK=$(xcrun simctl list -j | python3 tools/pick_sim.py "$WANT")
case "$PICK" in
  USE\|*)
    IFS='|' read -r _ UDID DEVNAME IOSVER <<< "$PICK" ;;
  CREATE\|*)
    IFS='|' read -r _ RUNTIME DEVTYPE IOSVER <<< "$PICK"
    DEVNAME="VidGrab test"
    UDID=$(xcrun simctl create "$DEVNAME" "$DEVTYPE" "$RUNTIME") || { echo "could not create a simulator"; exit 1; } ;;
  *)
    echo "no iPhone simulator runtime available"; xcrun simctl list runtimes; exit 1 ;;
esac
echo "simulator: $DEVNAME, iOS $IOSVER ($UDID)" | tee "$OUT/simulator.txt"
xcrun simctl boot "$UDID" 2>&1 | grep -v "current state: Booted" || true
xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1 || { tail -5 "$OUT/boot.log"; echo "simulator did not boot"; exit 1; }
SIMCTL_CHILD_VIDGRAB_DIR="$OUT" SIMCTL_CHILD_VIDGRAB_STDERR=1 xcrun simctl spawn "$UDID" "$OUT/engine_test_sim" "$OUT/files" 2> "$OUT/engine.log" | tee "$OUT/result.txt"
status=${PIPESTATUS[0]}
echo "== the engine's own log"
tail -80 "$OUT/engine.log"
ls -la "$OUT/files" 2>/dev/null
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
echo "exit status $status"
exit "$status"
