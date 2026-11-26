#!/bin/bash
# Why does the test app ("Clips") stay "not asked" for Photos in the iOS 16.4 simulator after
# `simctl privacy grant`? Tries several ways of building and granting, each on a freshly erased
# simulator, and writes what PhotoKit says inside the app (tests/probe/photos_probe.m).
#
# usage: tools/photos_probe.sh [output folder] [iOS version]   (on a Mac with Xcode)
set -u
OUT="${1:-$PWD/probe-out}"
WANT="${2:-16.4}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
HOST=com.adarsh.vidgrabhost
ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS="-arch $ARCH -mios-simulator-version-min=15.0 -isysroot $SDK -O1 -fobjc-arc"

echo "== build"
xcrun --sdk iphonesimulator clang $FLAGS -dynamiclib -framework Foundation -framework Photos \
  -install_name /usr/lib/PhotosProbe.dylib -o "$OUT/PhotosProbe.dylib" tests/probe/photos_probe.m || exit 1
codesign -f -s - "$OUT/PhotosProbe.dylib"
cat > "$OUT/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>ABCDE12345.com.adarsh.vidgrabhost</string>
  <key>com.apple.developer.team-identifier</key><string>ABCDE12345</string>
  <key>get-task-allow</key><true/>
</dict></plist>
EOF
build_app() {                                          # build_app <folder> plain|entitled
  local app="$1/VidGrabHost.app"
  rm -rf "$app"; mkdir -p "$app"
  if [ "$2" = "entitled" ]; then
    # what Xcode does for simulator apps: the entitlements in a section of the program, and in the signature
    xcrun --sdk iphonesimulator clang $FLAGS -framework UIKit -framework Foundation -framework AVFoundation -framework CoreGraphics \
      -Wl,-sectcreate,__TEXT,__entitlements,"$OUT/entitlements.plist" -o "$app/VidGrabHost" tests/host/main.m || return 1
    cp tests/host/Info.plist "$app/Info.plist"
    codesign -f -s - --entitlements "$OUT/entitlements.plist" "$app" || return 1
  else
    xcrun --sdk iphonesimulator clang $FLAGS -framework UIKit -framework Foundation -framework AVFoundation -framework CoreGraphics \
      -o "$app/VidGrabHost" tests/host/main.m || return 1
    cp tests/host/Info.plist "$app/Info.plist"
    codesign -f -s - "$app" || return 1
  fi
  echo "-- $2 app signature:"; codesign -dvv "$app" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier"
}
mkdir -p "$OUT/plain" "$OUT/entitled"
build_app "$OUT/plain" plain || exit 1
build_app "$OUT/entitled" entitled || exit 1

PICK=$(xcrun simctl list -j | python3 tools/pick_sim.py "$WANT")
case "$PICK" in
  USE\|*) IFS='|' read -r _ UDID DEVNAME IOSVER <<< "$PICK" ;;
  CREATE\|*) IFS='|' read -r _ RUNTIME DEVTYPE IOSVER <<< "$PICK"
             UDID=$(xcrun simctl create "Photos probe" "$DEVTYPE" "$RUNTIME") || exit 1 ;;
  *) echo "no simulator"; exit 1 ;;
esac
echo "simulator: iOS $IOSVER ($UDID)"
TCCDB="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db"

fresh() {
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
  xcrun simctl erase "$UDID" || exit 1
  xcrun simctl boot "$UDID" > /dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1
}
rows() { sqlite3 -header "$TCCDB" "SELECT service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags FROM access;" 2>&1 | sed 's/^/     /'; }
run_app() {                                            # run_app <variant> [ask]
  xcrun simctl terminate "$UDID" "$HOST" > /dev/null 2>&1 || true
  sleep 1
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$OUT/PhotosProbe.dylib" SIMCTL_CHILD_PROBE_DIR="$OUT" SIMCTL_CHILD_PROBE_VARIANT="$1" \
    SIMCTL_CHILD_PROBE_ASK="${2:-0}" xcrun simctl launch "$UDID" "$HOST" > /dev/null 2>&1
  sleep 6
  [ "${2:-0}" = "1" ] && xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1
  tail -2 "$OUT/probe.log" 2>/dev/null | grep -F "$1" | sed 's/^/   /'
}
grant() { for s in "$@"; do xcrun simctl privacy "$UDID" grant "$s" "$HOST" && echo "   granted $s" || echo "   could not grant $s"; done; }

echo "== 1. plain app, granted before it ever ran"
fresh; xcrun simctl install "$UDID" "$OUT/plain/VidGrabHost.app"; grant photos photos-add; rows; run_app 1-plain-grant-first

echo "== 2. plain app, ran once, then granted (what sim_test.sh did)"
fresh; xcrun simctl install "$UDID" "$OUT/plain/VidGrabHost.app"; run_app 2a-plain-before-grant; grant photos photos-add; rows; run_app 2b-plain-after-grant

echo "== 3. plain app, granted with \"all\""
fresh; xcrun simctl install "$UDID" "$OUT/plain/VidGrabHost.app"; grant all; rows; run_app 3-plain-grant-all

echo "== 4. app with entitlements (as Xcode builds it), granted before it ran"
fresh; xcrun simctl install "$UDID" "$OUT/entitled/VidGrabHost.app"; grant photos photos-add; rows; run_app 4-entitled-grant-first

echo "== 5. app with entitlements, not granted, asking (does the question come up?)"
fresh; xcrun simctl install "$UDID" "$OUT/entitled/VidGrabHost.app"; run_app 5-entitled-ask 1; rows

echo "== 6. plain app, granted, asking"
fresh; xcrun simctl install "$UDID" "$OUT/plain/VidGrabHost.app"; grant photos photos-add; run_app 6-plain-granted-ask 1; rows

echo "== probe.log"
cat "$OUT/probe.log" 2>/dev/null
for p in "$OUT"/*.png; do [ -f "$p" ] && sips -s format jpeg -Z 1200 "$p" --out "${p%.png}.jpg" > /dev/null 2>&1 && rm -f "$p"; done
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
exit 0
