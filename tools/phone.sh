#!/bin/bash
# tools/phone.sh — Guest Mode on the phone, over USB SSH (host "iphone-root", RootHide).
#
#   status            is the package installed, is the library there, is Photos running with it
#   install <deb>     copy the package over and dpkg -i (its postinst closes Photos; no respring needed)
#   remove            dpkg -r com.adarsh.guestmode, close Photos
#   facekey           what Photos' Info.plist says about Face ID (it needs a usage description to ask)
#   diag on|off       make / remove the marker that switches the log and the test commands on
#                     (Photos notices "on" at its next start, "off" at once)
#   open              bring Photos to the front (the phone must be unlocked)
#   close             end Photos, so that its next start loads the installed library
#   run <line>…       run test command lines in Photos (see the top of GMDebug.m); none gets past Face ID
#   log [n]           the last n lines of guestmode.log (default 40)
#   saved             is a Guest Mode state file in Photos' data folder (= Guest Mode is on)
#   prefs             the settings as stored
#   clean             delete guestmode.log and leftover command files
#
# The SSH shell sees the jailbreak root as /; the real file system is under /rootfs.
set -u
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 iphone-root"
SHARED=/var/mobile/Library/GuestMode                  # in the jailbreak root: Photos can read it
APPS=/rootfs/var/mobile/Containers/Data/Application
ID=com.apple.mobileslideshow

container() {                                         # Photos' data folder (exactly that id, not an extension's)
  $SSH "for d in $APPS/*/; do m=\"\$d.com.apple.mobile_container_manager.metadata.plist\"; if grep -a -o '$ID[A-Za-z0-9._-]*' \"\$m\" 2>/dev/null | grep -q -x -F '$ID'; then echo \"\$d\"; fi; done | head -1"
}

case "${1:-}" in
  status)
    $SSH "dpkg-query -W -f='\${Package} \${Version} [\${Status}]\n' com.adarsh.guestmode 2>/dev/null || echo 'com.adarsh.guestmode: not installed'; ls -la /Library/MobileSubstrate/DynamicLibraries/ | grep -i guestmode; ls -la $SHARED 2>/dev/null; true" ;;
  install)
    deb="${2:?usage: phone.sh install <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/guestmode.deb' < "$deb" || exit 1
    $SSH 'dpkg -i /tmp/guestmode.deb; rc=$?; rm -f /tmp/guestmode.deb; echo "dpkg exit $rc"; dpkg -s com.adarsh.guestmode | grep -E "^(Version|Status)"; exit $rc' || exit 1 ;;
  remove)
    $SSH 'dpkg -r com.adarsh.guestmode; killall -9 MobileSlideShow 2>/dev/null; true' ;;
  facekey)
    $SSH "plutil -p /rootfs/Applications/MobileSlideShow.app/Info.plist 2>/dev/null | grep -i -E 'FaceID|CFBundleExecutable\"|CFBundleShortVersion' || echo 'no NSFaceIDUsageDescription in Photos Info.plist'" ;;
  diag)
    if [ "${2:-}" = "on" ]; then
      $SSH "mkdir -p $SHARED && touch $SHARED/diag && chown -R mobile:mobile $SHARED && chmod 755 $SHARED && ls -la $SHARED"
    else
      $SSH "rm -f $SHARED/diag; find $SHARED -name 'cmd*' -delete; ls -la $SHARED 2>/dev/null; true"
    fi ;;
  open)
    $SSH "uiopen --bundleid $ID" ;;
  close)
    $SSH "killall -9 MobileSlideShow 2>/dev/null; true" ;;
  run)
    shift
    [ $# -gt 0 ] || { echo "usage: phone.sh run <line>…"; exit 1; }
    { echo "token-$(date +%s)-$$"; printf '%s\n' "$@"; } | $SSH "cat > $SHARED/cmd.tmp && chown mobile:mobile $SHARED/cmd.tmp && chmod 644 $SHARED/cmd.tmp && mv $SHARED/cmd.tmp $SHARED/cmd.txt" ;;
  log)
    dir=$(container)
    [ -n "$dir" ] || { echo "no data folder found for Photos"; exit 1; }
    $SSH "tail -n ${2:-40} \"${dir}tmp/guestmode.log\" 2>/dev/null || echo 'no guestmode.log yet'" ;;
  saved)
    dir=$(container)
    [ -n "$dir" ] || { echo "no data folder found for Photos"; exit 1; }
    $SSH "ls -la \"${dir}Library/GuestMode/\" 2>/dev/null || echo 'no GuestMode folder in Photos yet (never switched on, button never moved)'" ;;
  prefs)
    $SSH "plutil -p /var/mobile/Library/Preferences/com.adarsh.guestmode.plist 2>/dev/null || echo 'no settings stored yet (everything at its default)'" ;;
  clean)
    dir=$(container)
    [ -n "$dir" ] || { echo "no data folder found for Photos"; exit 1; }
    $SSH "rm -f \"${dir}tmp/guestmode.log\"; find $SHARED -name 'cmd*' -delete 2>/dev/null; echo cleaned" ;;
  *)
    sed -n '2,17p' "$0" ;;
esac
