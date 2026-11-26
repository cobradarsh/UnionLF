#!/bin/bash
# tools/phone.sh — VidGrab on the phone, over USB SSH (host "iphone-root", RootHide).
#
#   status                 is the package installed, are the libraries there, SpringBoard's part
#   install <deb>          copy the package over, dpkg -i, respring (the hand-over to GIF Stash lives in SpringBoard)
#   remove                 dpkg -r com.adarsh.vidgrab, respring
#   diag on|off            make / remove the marker that switches the test commands and the log on
#                          (an app notices "on" at its next start, "off" at once)
#   open <bundle id>       bring an app to the front (the phone must be unlocked)
#   close <program>        end an app, so that its next start loads the installed library
#   run <program> <line>…  run test command lines in that app (see the top of VGDebug.m)
#   log <bundle id> [n]    the last n lines of that app's vidgrab.log (default 40)
#   fetch <bundle id> <name> <dir>   copy the picture made by "shot <name>" into <dir>, then delete it on the phone
#   sblog                  SpringBoard's part: the hand-over log
#   prefs                  the settings as stored
#   clean <bundle id>      delete that app's vidgrab.log, pictures and work folders
#
# The SSH shell sees the jailbreak root as /; the real file system is under /rootfs.
set -u
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 iphone-root"
SHARED=/var/mobile/Library/VidGrab                    # in the jailbreak root: apps can read it
APPS=/rootfs/var/mobile/Containers/Data/Application

container() {                                         # the data folder of the app with this bundle id
  $SSH "for d in $APPS/*/; do if grep -q -a -F '$1' \"\$d.com.apple.mobile_container_manager.metadata.plist\" 2>/dev/null; then echo \"\$d\"; fi; done | head -1"
}

case "${1:-}" in
  status)
    $SSH "dpkg-query -W -f='\${Package} \${Version} [\${Status}]\n' com.adarsh.vidgrab 2>/dev/null || echo 'com.adarsh.vidgrab: not installed'; ls -la /Library/MobileSubstrate/DynamicLibraries/ | grep -i vidgrab; ls -la $SHARED 2>/dev/null; tail -n 5 /rootfs/var/mobile/Library/Logs/VidGrab.log 2>/dev/null; true" ;;
  install)
    deb="${2:?usage: phone.sh install <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/vidgrab.deb' < "$deb" || exit 1
    $SSH 'dpkg -i /tmp/vidgrab.deb; rc=$?; rm -f /tmp/vidgrab.deb; echo "dpkg exit $rc"; dpkg -s com.adarsh.vidgrab | grep -E "^(Version|Status)"; exit $rc' || exit 1
    echo "respringing…"
    $SSH 'sbreload' || true ;;
  remove)
    $SSH 'dpkg -r com.adarsh.vidgrab; sbreload' ;;
  diag)
    if [ "${2:-}" = "on" ]; then
      $SSH "mkdir -p $SHARED && touch $SHARED/diag && chown -R mobile:mobile $SHARED && chmod 755 $SHARED && ls -la $SHARED"
    else
      $SSH "rm -f $SHARED/diag $SHARED/cmd*.txt; ls -la $SHARED 2>/dev/null; true"
    fi ;;
  open)
    $SSH "uiopen --bundleid ${2:?usage: phone.sh open <bundle id>}" ;;
  close)
    $SSH "killall -9 '${2:?usage: phone.sh close <program>}' 2>/dev/null; true" ;;
  run)
    app="${2:?usage: phone.sh run <program> <line>…}"; shift 2
    [ $# -gt 0 ] || { echo "usage: phone.sh run <program> <line>…"; exit 1; }
    { echo "token-$(date +%s)-$$"; printf '%s\n' "$@"; } | $SSH "cat > $SHARED/cmd.tmp && chown mobile:mobile $SHARED/cmd.tmp && chmod 644 $SHARED/cmd.tmp && mv $SHARED/cmd.tmp $SHARED/cmd-$app.txt" ;;
  log)
    dir=$(container "${2:?usage: phone.sh log <bundle id> [n]}")
    [ -n "$dir" ] || { echo "no data folder found for $2"; exit 1; }
    $SSH "tail -n ${3:-40} \"${dir}tmp/vidgrab.log\" 2>/dev/null || echo 'no vidgrab.log in that app yet'" ;;
  fetch)
    dir=$(container "${2:?usage: phone.sh fetch <bundle id> <name> <dir>}")
    name="${3:?name}"; to="${4:?dir}"
    mkdir -p "$to"
    $SSH "cat \"${dir}tmp/vidgrab-$name.jpg\"" > "$to/vidgrab-$name.jpg" && $SSH "rm -f \"${dir}tmp/vidgrab-$name.jpg\""
    ls -la "$to/vidgrab-$name.jpg" ;;
  sblog)
    $SSH "tail -n ${2:-20} /rootfs/var/mobile/Library/Logs/VidGrab.log 2>/dev/null || echo 'no log yet'" ;;
  prefs)
    $SSH "plutil -p /var/mobile/Library/Preferences/com.adarsh.vidgrab.plist 2>/dev/null || echo 'no settings stored yet (everything at its default)'" ;;
  clean)
    dir=$(container "${2:?usage: phone.sh clean <bundle id>}")
    [ -n "$dir" ] || { echo "no data folder found for $2"; exit 1; }
    $SSH "rm -rf \"${dir}tmp/vidgrab.log\" \"${dir}tmp/vidgrab-cmd.last\" \"${dir}tmp/vidgrab-work\" \"${dir}tmp/vidgrab-outbox\"; rm -f \"${dir}tmp/\"vidgrab-*.jpg; echo cleaned" ;;
  *)
    sed -n '2,17p' "$0" ;;
esac
