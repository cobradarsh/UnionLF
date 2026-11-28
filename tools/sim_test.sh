#!/bin/bash
# Runs VidGrab inside a stand-in app ("Clips", tests/host) in an iOS simulator and photographs it.
#
# VidGrab hooks with the Objective-C runtime only, so the same sources build for the simulator
# with plain clang (no Theos, no ElleKit). The library is loaded into the app with
# DYLD_INSERT_LIBRARIES and driven through its command file (VGDebug.m); the pictures come from
# `simctl io screenshot`.
#
# What this shows, on the phone's iOS generation (16.4 when the runtime can be had): the download
# button on a playing video, the menu, a real download of a real stream into Photos and the
# VidGrab album, the quality list, cancelling, the share sheet, the button's corner and switch,
# and that a solid panel of the app over the video keeps VidGrab away from touches there.
# It cannot send real touches: what a finger does is tried on the phone.
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
HOST=com.adarsh.vidgrabhost

ARCH=$(uname -m)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS="-arch $ARCH -mios-simulator-version-min=15.0 -isysroot $SDK -O1 -g -Wall -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable"
SOURCES="VGMain.m VGCore.m VGPlaylist.m VGFetch.m VGTS.m VGMux.m VGJob.m VGCapture.m VGUI.m VGDeliver.m VGPicture.m VGDebug.m VGFinger.m VGSGifMaker.m VGSCommon.m"
FRAMEWORKS="-framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox -framework CoreGraphics -framework QuartzCore -framework Photos -framework ImageIO -framework Accelerate"
echo "== build for the simulator ($ARCH)"
(
  xcrun --sdk iphonesimulator clang $FLAGS -c -o "$OUT/VGSGifWriter.o" VGSGifWriter.c || exit 1
  xcrun --sdk iphonesimulator clang $FLAGS -fobjc-arc -dynamiclib $FRAMEWORKS \
    -install_name /usr/lib/VidGrab.dylib -o "$OUT/VidGrab.dylib" $SOURCES "$OUT/VGSGifWriter.o" || exit 1
  codesign -f -s - "$OUT/VidGrab.dylib" || exit 1
  APP="$OUT/VidGrabHost.app"
  rm -rf "$APP"
  mkdir -p "$APP"
  xcrun --sdk iphonesimulator clang $FLAGS -fobjc-arc -framework UIKit -framework Foundation -framework AVFoundation -framework CoreGraphics \
    -o "$APP/VidGrabHost" tests/host/main.m || exit 1
  cp tests/host/Info.plist "$APP/Info.plist"
  codesign -f -s - "$APP" || exit 1
) > "$OUT/build.log" 2>&1
status=$?
cat "$OUT/build.log"
[ "$status" = "0" ] && [ -f "$OUT/VidGrab.dylib" ] || { echo "simulator build FAILED"; exit 1; }

echo "== pick a simulator (wanted iOS: ${WANT:-the oldest there is})"
PICK=$(xcrun simctl list -j | python3 tools/pick_sim.py "$WANT")
case "$PICK" in
  USE\|*)
    IFS='|' read -r _ UDID DEVNAME IOSVER <<< "$PICK" ;;
  CREATE\|*)
    IFS='|' read -r _ RUNTIME DEVTYPE IOSVER <<< "$PICK"
    DEVNAME="VidGrab test (${DEVTYPE##*.})"
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
xcrun simctl install "$UDID" "$OUT/VidGrabHost.app" || { echo "the host app did not install"; exit 1; }
# A grant made before the app has ever run did not take on the 16.4 runtime (the permission
# question came up anyway): start the app once without VidGrab, then grant.
xcrun simctl launch "$UDID" "$HOST" > /dev/null 2>&1 || true
sleep 4
xcrun simctl terminate "$UDID" "$HOST" > /dev/null 2>&1 || true
for service in photos photos-add; do
  xcrun simctl privacy "$UDID" grant "$service" "$HOST" && echo "granted $service" || echo "(could not grant $service)"
done
# The grant alone did not keep iOS 16.4 from asking (the question then held every save): the
# permission is also written into the simulator's privacy database while it is shut down.
TCCDB="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db"
if [ -f "$TCCDB" ]; then
  echo "privacy database before: $(sqlite3 "$TCCDB" "SELECT service || '=' || auth_value FROM access WHERE client='$HOST';" 2>&1 | tr '\n' ' ')"
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
  for service in kTCCServicePhotos kTCCServicePhotosAdd; do
    sqlite3 "$TCCDB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) VALUES ('$service', '$HOST', 0, 2, 2, 1, 0, CAST(strftime('%s','now') AS INTEGER));" \
      && echo "privacy database: $service allowed" || echo "privacy database: could not write $service"
  done
  echo "privacy database after: $(sqlite3 "$TCCDB" "SELECT service || '=' || auth_value FROM access WHERE client='$HOST';" 2>&1 | tr '\n' ' ')"
  xcrun simctl boot "$UDID" 2>&1 | grep -v "current state: Booted" || true
  xcrun simctl bootstatus "$UDID" -b > "$OUT/boot2.log" 2>&1 || { tail -5 "$OUT/boot2.log"; echo "simulator did not boot again"; exit 1; }
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 > /dev/null 2>&1 || true
else
  echo "no privacy database at $TCCDB"
fi
defaults write com.apple.CrashReporter DialogType none > /dev/null 2>&1 || true

REPORTS=~/Library/Logs/DiagnosticReports
mkdir -p "$REPORTS"
touch "$OUT/.before"
collect_crashes() {
  local found=""
  for f in "$REPORTS"/*.ips; do
    [ -f "$f" ] && [ "$f" -nt "$OUT/.before" ] || continue
    cp "$f" "$OUT/" && found="$found $OUT/$(basename "$f")"
  done
  if [ -n "$found" ]; then echo "-- crash reports:"; python3 tools/ips_summary.py $found; else echo "-- no crash report"; fi
}

LOG="$RUN/vidgrab.log"
touch "$RUN/diag"
launch() {                                            # launch [mode]: start the host app with VidGrab in it
  xcrun simctl terminate "$UDID" "$HOST" > /dev/null 2>&1 || true
  sleep 1
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$OUT/VidGrab.dylib" SIMCTL_CHILD_VIDGRAB_DIR="$RUN" SIMCTL_CHILD_VG_HOST_MODE="${1:-}" \
    xcrun simctl launch "$UDID" "$HOST" > "$OUT/launch.txt" 2>&1 || { cat "$OUT/launch.txt"; return 1; }
  for i in $(seq 1 30); do
    sleep 1
    [ "$(grep -c 'VidGrab 2' "$LOG" 2>/dev/null || true)" -ge "${2:-1}" ] && return 0
  done
  return 1
}

MARKS=0
DEAD=""
cmd() {                                               # command lines, run in order inside the app; returns when they are done
  local waited=0 mark
  [ -n "$DEAD" ] && return 0
  MARKS=$((MARKS + 1)); mark="done$MARKS-$$"
  printf '%s\n' "token-$mark" "$@" "mark $mark" > "$RUN/cmd.tmp"
  mv "$RUN/cmd.tmp" "$RUN/cmd.txt"
  while ! grep -q -F "mark: $mark" "$LOG" 2>/dev/null && [ "$waited" -lt 150 ]; do sleep 1; waited=$((waited + 1)); done
  if [ "$waited" -ge 150 ]; then DEAD=yes; echo "  the app did not finish these in 150 s: $*"; fi
  cp "$LOG" "$OUT/vidgrab.log" 2>/dev/null || true
  return 0
}
shot() {
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || { echo "screenshot $1 failed"; return; }
  sips -s format jpeg -s formatOptions 80 -Z 1500 "$OUT/$1.png" --out "$OUT/$1.jpg" > /dev/null 2>&1 && rm -f "$OUT/$1.png"
  echo "  shot $1"
}
last() { grep -F "$1" "$LOG" 2>/dev/null | tail -1 | cut -c21-; }
wait_result() {                                       # wait_result <seconds>: until the running download has ended
  local n=0
  while [ "$n" -lt "$1" ]; do
    cmd "result"
    last "result:" | grep -q "download idle" && return 0
    sleep 3; n=$((n + 4))
  done
  return 1
}
FAILED=0
check() {                                             # check <what> <text that must be in the log>
  if grep -q -F -- "$2" "$LOG" 2>/dev/null; then echo "PASS  $1"; else echo "FAIL  $1   (no \"$2\" in the log)"; FAILED=$((FAILED + 1)); fi
}
check_re() {                                          # check_re <what> <extended regular expression a log line must match>
  if grep -q -E -- "$2" "$LOG" 2>/dev/null; then echo "PASS  $1"; else echo "FAIL  $1   (no line matching /$2/ in the log)"; FAILED=$((FAILED + 1)); fi
}
check_none() {                                        # check_none <what> <extended regular expression no log line may match>
  if grep -q -E -- "$2" "$LOG" 2>/dev/null; then echo "FAIL  $1   ($(grep -E -- "$2" "$LOG" | head -1 | cut -c21-200))"; FAILED=$((FAILED + 1)); else echo "PASS  $1"; fi
}
check_last() {                                        # check_last <what> <line marker> <text the newest such line must hold>
  if last "$2" | grep -q -F -- "$3"; then echo "PASS  $1"; else echo "FAIL  $1   (\"$(last "$2")\")"; FAILED=$((FAILED + 1)); fi
}

echo "== start the app with VidGrab"
if ! launch ""; then
  echo "VidGrab did not start inside the app"
  cat "$LOG" 2>/dev/null
  collect_crashes
  xcrun simctl io "$UDID" screenshot "$OUT/00-not-started.png" > /dev/null 2>&1 || true
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
  exit 1
fi
cat "$LOG"

echo "== 1. a video plays: the download button"
for i in 1 2 3 4 5 6 7 8; do                          # the stream needs a moment to start
  sleep 4
  cmd "layers"
  last "    0:" | grep -q "button {{" && break
done
cmd "state" "layers full" "hit"
shot 01-button-on-video
echo "  $(last 'state:')"; echo "  $(last '    0:')"; echo "  $(last 'hit ')"
BUTTON1=$(last "    0:" | sed 's/.*button //; s/;.*//')

echo "== 2. a hold on the video: the menu"
cmd "press" "wait 1.5" "menu" "state"
shot 02-menu
echo "  $(last 'press ')"; echo "  $(last 'menu:')"; echo "  $(last 'state:')"

echo "== 3. Save to Photos (smallest quality, the whole stream)"
# In the 16.4 simulator only the "add only" permission can be granted (tools/photos_probe.sh: full
# access stays "not asked" however it is granted). The album needs full access, so here it is off
# and saves go in with add-only access; the album itself is checked on the phone.
cmd "set album 0" "photos"
echo "  Photos access before: $(last 'photos:')"
cmd "dismiss" "wait 1" "set quality 240" "photos" "press" "wait 1" "choose Save to Photos" "wait 2.5" "result"
shot 03-progress
echo "  before: $(last 'photos:')"; echo "  $(last 'result:')"
wait_result 240 || echo "  the download did not end in four minutes"
cmd "wait 0.6" "photos" "state"
shot 04-saved
echo "  $(last 'result:')"; echo "  after: $(last 'photos:')"
cmd "wait 4" "state"
echo "  a little later: $(last 'state:')"

echo "== 4. a hold on the button: the menu, the quality list, cancelling"
cmd "buttonhold" "wait 1.2" "menu" "choose Choose Quality" "wait 6" "menu"
shot 05-qualities
echo "  $(last 'tap ')"; echo "  $(last 'menu:')"
cmd "choose 1080p" "wait 3" "result"
shot 06-downloading-1080p
echo "  $(last 'result:')"
cmd "cancel" "wait 2.5" "result" "state"
shot 07-cancelled
echo "  $(last 'result:')"

echo "== 5. Share"
cmd "wait 3" "set quality 240" "press" "wait 1" "choose Share" "wait 2" "result"
wait_result 240 || true
cmd "wait 3" "state"
shot 08-share-sheet
echo "  $(last 'result:')"; echo "  $(last 'state:')"
cmd "dismiss" "wait 2.5" "state"
echo "  after closing: $(last 'state:')"

echo "== 5b. the queue: three downloads asked for at once, and the first one again"
A=https://test-streams.mux.dev/x36xhzz/url_2/193039199_mp4_h264_aac_ld_7.m3u8
B=https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4
C=https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8
cmd "set quality 240" "fetch $A" "fetch $B" "fetch $C" "fetch $A" "wait 0.5" "result" "shot 08b-queue"
echo "  $(last 'result:')"
for i in $(seq 1 40); do
  sleep 3
  [ "$(grep -c 'download ok: Fetched' "$LOG" 2>/dev/null || true)" -ge 3 ] && break
done
cmd "result"
grep -E "queue:|download ok: Fetched" "$LOG" | cut -c21- | sed 's/^/  /'

echo "== 6. the button's corner and switch"
cmd "set badgeCorner 2" "wait 1" "layers"
shot 09-button-bottom-left
BUTTON2=$(last "    0:" | sed 's/.*button //; s/;.*//')
echo "  top right: $BUTTON1   bottom left: $BUTTON2"
cmd "set badge 0" "wait 1" "layers"
shot 10-button-off
echo "  switched off: $(last '    0:')"
OFFLINE=$(last "    0:")
cmd "set badge 1" "set badgeCorner 1" "wait 1" "layers"

echo "== 6b. pictures: a button on each, none on the small face; one saved as shown, one from its address"
cmd "set badgeCorner -1" "wait 1" "state" "pictures" "scan"
shot 10b-picture-buttons
grep -F "    picture " "$LOG" | tail -4 | cut -c21- | sed 's/^/  /'
echo "  $(last 'pictures:')"; echo "  $(last 'state:')"
PICTURES=$(last "pictures:")
cmd "pichold 0" "wait 1.2" "menu"
shot 10c-picture-menu
echo "  $(last 'pictap ')"; echo "  $(last 'menu:')"
cmd "dismiss" "wait 1" "pictap 0" "wait 1"      # a tap on the button saves at once
wait_result 60 || echo "  the first picture did not end in a minute"
echo "  $(last 'result:')"
cmd "pictap 1" "wait 1"
wait_result 60 || echo "  the second picture did not end in a minute"
cmd "photos"
echo "  $(last 'pictap ')"; echo "  $(last 'result:')"; echo "  $(last 'photos:')"
cmd "set pictures 0" "wait 1" "pictures"
PICTURESOFF=$(last "pictures:")
echo "  switched off: $PICTURESOFF"
cmd "set pictures 1" "wait 1"

echo "== 6c. real touches, made inside the app as KIF makes them (VGFinger.m): taps and holds"
# "Hold For" at 0.8 s as on the phone: the button's own hold (0.45 s) must still give the menu, a tap must save,
# and a long hold must give the menu only (2.2.2 also saved when the finger stayed down for over two seconds).
cmd "set tapAction 1" "set holdTime 0.8" "set quality 240" "wait 1" "layers"     "finger button 0.1" "cancel" "wait 2.5" "dismiss" "wait 1"     "finger button 0.6" "wait 0.3" "dismiss" "wait 1"     "finger button 3.0" "wait 0.3" "dismiss" "wait 1"     "finger video 1.2" "wait 0.3" "dismiss" "wait 1"
shot 10d-after-touches
cmd "finger picture0 0.1"
wait_result 60 || echo "  the picture did not end in a minute"
cmd "finger picture0 1.0" "wait 0.3" "dismiss" "wait 1" "set holdTime 0.55" "result"
grep -F "finger " "$LOG" | cut -c21- | sed 's/^/  /'

echo "== 7. a hold away from the video (on a picture: VidGrab leaves holds on pictures to the app)"
cmd "press 200 760"
echo "  $(last 'press ')"

echo "== 8. a solid panel of the app over the right half of the video"
launch "cover" 2 || echo "the app did not start again"
for i in 1 2 3 4 5 6 7 8; do
  sleep 4
  cmd "layers"
  last "    0:" | grep -q "button {{" && break
done
cmd "hit" "tap" "wait 1" "menu" "press 110 250" "wait 1" "menu"
shot 11-covered
echo "  $(last '    0:')"; echo "  $(last 'hit ')"; echo "  $(last 'tap ')"; echo "  $(last 'press ')"; echo "  $(last 'menu:')"
cmd "dismiss" "state"

echo "== checks"
check "three hooks are in"                               "3 of 3 hooks"
check "a button is on the playing video"                 "button {{"
check "a hold on the video finds its stream"             "press {"
check "the menu has its entries"                         "menu: Save to Photos | Share… | Save to GIF Stash | Choose Quality… | Copy Link"
check "the stream was saved into Photos"                "ok: Saved to Photos ["
check "the quality list shows the stream's sizes"        "menu: 1080p · H.264"
check "cancelling ends a download"                       "result: cancelled"
check "the share sheet came up and was closed"           "share sheet closed"
check "a hold away from the video is left alone"         "no video there: VidGrab stays out of it"
check "a download asked for while one runs waits"        "queue: Added to the queue · 2 waiting"
check "the same download twice is not queued twice"      "queue: Already in the queue"
check "the queue starts the next one by itself"          "queue: starting the next one, 0 left"
if [ "$(grep -c 'download ok: Fetched' "$LOG" 2>/dev/null || true)" -ge 3 ]; then echo "PASS  all three queued downloads finished"; else echo "FAIL  all three queued downloads finished ($(grep -c 'download ok: Fetched' "$LOG" 2>/dev/null) of 3)"; FAILED=$((FAILED + 1)); fi
check "under a solid panel the button takes no tap"      "no download button there"
check "the picture hooks are in"                         "pictures: 2 hooks"
check_re "a real tap on a video's button saves at once"     "finger button 0\.10 s at .*: sent → save;"
check_re "a 0.6 s hold on it opens the menu (Hold For 0.8)" "finger button 0\.60 s at .*: sent → menu;"
check_re "a 3 s hold on it opens the menu"                  "finger button 3\.00 s at .*: sent → menu;"
check_none "a hold on the button never also saves"          "finger button .*(menu \+ save|save \+ menu)"
check_re "a real hold on the video opens the menu"          "finger video 1\.20 s at .*: sent → menu;"
check_re "a real tap on a picture's button saves it"        "finger picture0 0\.10 s at .*: sent → save;"
check_re "a real hold on a picture's button opens the menu" "finger picture0 1\.00 s at .*: sent → menu;"
check "a picture's menu has its entries"                 "menu: Save to Photos | Share… | Copy Picture"
check "a picture was saved as shown"                    "ok: Saved to Photos [as shown: 600x900"
check "a picture was fetched again from its address"  "ok: Saved to Photos [jpg 600x800"
if echo "$PICTURES" | grep -q ", 2 with a button"; then echo "PASS  both pictures have a button, the small face none"; else echo "FAIL  both pictures have a button, the small face none ($PICTURES)"; FAILED=$((FAILED + 1)); fi
if echo "$PICTURESOFF" | grep -q ", 0 with a button"; then echo "PASS  the switch takes the picture buttons away"; else echo "FAIL  the switch takes the picture buttons away ($PICTURESOFF)"; FAILED=$((FAILED + 1)); fi
if [ "$BUTTON1" != "$BUTTON2" ] && [ -n "$BUTTON2" ]; then echo "PASS  the corner setting moves the button"; else echo "FAIL  the corner setting moves the button ($BUTTON1 / $BUTTON2)"; FAILED=$((FAILED + 1)); fi
if echo "$OFFLINE" | grep -q "button hidden"; then echo "PASS  the switch takes the button away"; else echo "FAIL  the switch takes the button away ($OFFLINE)"; FAILED=$((FAILED + 1)); fi

cp "$LOG" "$OUT/vidgrab.log" 2>/dev/null || true
echo "== vidgrab.log"
cat "$OUT/vidgrab.log" 2>/dev/null
collect_crashes
ls -la "$OUT" | head -60
xcrun simctl terminate "$UDID" "$HOST" > /dev/null 2>&1 || true
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
if ls "$OUT"/VidGrabHost*.ips > /dev/null 2>&1; then echo "the app crashed during the test: see the crash reports"; exit 1; fi
if [ -n "$DEAD" ]; then echo "the app stopped answering test commands part of the way through"; exit 1; fi
if grep -q "threw" "$OUT/vidgrab.log" 2>/dev/null; then echo "an exception was caught: see the log"; grep "threw" "$OUT/vidgrab.log" | head; exit 1; fi
if [ "$FAILED" != "0" ]; then echo "$FAILED check(s) failed"; exit 1; fi
echo "all checks passed"
exit 0
