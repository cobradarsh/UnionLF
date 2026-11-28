#!/bin/bash
# tools/phone.sh — Guest Mode on the phone, over USB SSH (host "iphone-root", RootHide).
#
#   status            is the package installed, is the library there, is Photos running with it
#   install <deb>     copy the package over, dpkg -i (its postinst closes Photos), respring for the part in SpringBoard
#   remove            dpkg -r com.adarsh.guestmode, close Photos
#   facekey           whether Photos' entitlements let it ask for Face ID (it has no usage description)
#   diag on|off       make / remove the marker that switches the log and the test commands on
#                     (Photos notices "on" at its next start, "off" at once)
#   open              bring Photos to the front (the phone must be unlocked)
#   close             end Photos, so that its next start loads the installed library
#   run <line>…       run test command lines in Photos (see the top of GMDebug.m); none gets past Face ID
#   log [n]           the last n lines of guestmode.log (default 40)
#   sbrun <line>…     test command lines for the part in SpringBoard (see GMSpringBoard.m): state, testlock <s>, release
#   sblog [n]         the last n lines of SpringBoard's GuestMode.log (default 30)
#   saved             the saved Guest Mode state in Photos' preferences (there = Guest Mode is on)
#   prefs             the settings as stored
#   clean             delete guestmode.log and leftover command files
#
# The SSH shell sees the jailbreak root as /; the real file system is under /rootfs.
set -u
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 iphone-root"
SHARED=/var/mobile/Library/GuestMode                  # in the jailbreak root: Photos can read it
# Photos runs without a data folder of its own; the log is in the first of these it may write to
ID=com.apple.mobileslideshow
LOGS="/rootfs/var/mobile/tmp/guestmode.log /rootfs/private/var/tmp/guestmode.log /rootfs/var/tmp/guestmode.log /rootfs/var/mobile/Media/PhotoData/Caches/guestmode.log /rootfs/var/mobile/Library/Caches/guestmode.log"

case "${1:-}" in
  status)
    $SSH "dpkg-query -W -f='\${Package} \${Version} [\${Status}]\n' com.adarsh.guestmode 2>/dev/null || echo 'com.adarsh.guestmode: not installed'; ls -la /Library/MobileSubstrate/DynamicLibraries/ | grep -i guestmode; ls -la $SHARED 2>/dev/null; true" ;;
  install)
    deb="${2:?usage: phone.sh install <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/guestmode.deb' < "$deb" || exit 1
    $SSH 'dpkg -i /tmp/guestmode.deb; rc=$?; rm -f /tmp/guestmode.deb; echo "dpkg exit $rc"; dpkg -s com.adarsh.guestmode | grep -E "^(Version|Status)"; exit $rc' || exit 1
    echo "respringing…"
    $SSH 'sbreload' || true ;;
  remove)
    $SSH 'dpkg -r com.adarsh.guestmode; killall -9 MobileSlideShow 2>/dev/null; true' ;;
  facekey)
    # Photos has no NSFaceIDUsageDescription; it may ask for Face ID because its entitlements allow it
    $SSH "ldid -e /rootfs/Applications/MobileSlideShow.app/MobileSlideShow 2>/dev/null | grep -c kTCCServiceFaceID | sed 's/^0$/Photos has NO Face ID entitlement/; s/^[1-9].*/Photos is entitled to Face ID (com.apple.private.tcc.allow: kTCCServiceFaceID)/'" ;;
  diag)
    if [ "${2:-}" = "on" ]; then
      $SSH "mkdir -p $SHARED && touch $SHARED/diag && chown -R mobile:mobile $SHARED && chmod 755 $SHARED && ls -la $SHARED"
    else
      $SSH "rm -f $SHARED/diag; find $SHARED -name '*cmd*' -delete; ls -la $SHARED 2>/dev/null; true"
    fi ;;
  open)
    $SSH "uiopen --bundleid $ID" ;;
  close)
    $SSH "killall -9 MobileSlideShow 2>/dev/null; true" ;;
  run)
    shift
    [ $# -gt 0 ] || { echo "usage: phone.sh run <line>…"; exit 1; }
    { echo "token-$(date +%s)-$$"; printf '%s\n' "$@"; } | $SSH "cat > $SHARED/cmd.tmp && chown mobile:mobile $SHARED/cmd.tmp && chmod 644 $SHARED/cmd.tmp && mv $SHARED/cmd.tmp $SHARED/cmd.txt" ;;
  sbrun)
    shift
    [ $# -gt 0 ] || { echo "usage: phone.sh sbrun <line>…"; exit 1; }
    { echo "token-$(date +%s)-$$"; printf '%s\n' "$@"; } | $SSH "cat > $SHARED/sbcmd.tmp && chown mobile:mobile $SHARED/sbcmd.tmp && chmod 644 $SHARED/sbcmd.tmp && mv $SHARED/sbcmd.tmp $SHARED/sbcmd.txt" ;;
  sblog)
    $SSH "tail -n ${2:-30} /rootfs/var/mobile/Library/Logs/GuestMode.log 2>/dev/null || echo 'no GuestMode.log yet'" ;;
  log)
    $SSH "f=\$(ls -t $LOGS 2>/dev/null | head -1); if [ -n \"\$f\" ]; then echo \"\$f\"; tail -n ${2:-40} \"\$f\"; else echo 'no guestmode.log yet'; fi" ;;
  saved)
    $SSH "cat /rootfs/var/mobile/Library/Preferences/com.apple.mobileslideshow.plist" | python -c "import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print('Guest Mode state:', d.get('GuestModeState', 'none saved (Guest Mode is off)')); print('button place:', d.get('GuestModeButton', 'default'))" ;;
  prefs)
    $SSH "plutil -p /var/mobile/Library/Preferences/com.adarsh.guestmode.plist 2>/dev/null || echo 'no settings stored yet (everything at its default)'" ;;
  clean)
    $SSH "rm -f $LOGS /rootfs/var/mobile/Library/Logs/GuestMode.log; find $SHARED -name '*cmd*' -delete 2>/dev/null; echo cleaned" ;;
  *)
    sed -n '2,19p' "$0" ;;
esac
