#!/bin/bash
# tools/phone.sh — Atelier on the phone, over USB SSH (host "iphone-root", RootHide).
#
#   status               is the package installed, is the library there, the last log lines
#   install <deb>        copy the package over, dpkg -i, respring
#   remove               dpkg -r com.adarsh.atelier, respring
#   log [n]              the last n lines of Atelier.log (default 40)
#   run <line> [<line>…] run test command lines in order (see the top of AtelierDebug.m);
#                        they work while Settings → Atelier → Debug Log is on (it is by default)
#   fetch <name> <dir>   copy the screenshot made by "shot <name>" into <dir>, then delete it on the phone
#   clearlog             empty Atelier.log
#   settings             start Settings in the background and show whether AltList got into it
#                        (the Shortcut Apps list needs it; see PrefsHelper.m)
#
# The SSH shell sees the jailbreak root as /; the real file system, where SpringBoard writes, is
# under /rootfs. Its login shell is zsh, so nothing here relies on a wildcard that may match nothing.
set -u
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 iphone-root"
LOGS=/rootfs/var/mobile/Library/Logs

case "${1:-}" in
  status)
    $SSH "dpkg-query -W -f='\${Package} \${Version} [\${Status}]\n' com.adarsh.atelier 2>/dev/null || echo 'com.adarsh.atelier: not installed'; ls -la /Library/MobileSubstrate/DynamicLibraries/ | grep -i atelier; cat $LOGS/Atelier.boot 2>/dev/null | sed 's/^/boot count: /'; tail -n 5 $LOGS/Atelier.log 2>/dev/null; true" ;;
  install)
    deb="${2:?usage: phone.sh install <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/atelier.deb' < "$deb" || exit 1
    $SSH 'dpkg -i /tmp/atelier.deb; rc=$?; rm -f /tmp/atelier.deb; echo "dpkg exit $rc"; dpkg -s com.adarsh.atelier | grep -E "^(Version|Status)"; exit $rc' || exit 1
    # Settings is closed so that its next start loads the new AtelierPrefs library
    $SSH 'killall -9 Preferences 2>/dev/null; true'
    echo "respringing…"
    $SSH 'sbreload' || true
    ;;
  settings)
    $SSH "rm -f $LOGS/AtelierSettings.log; touch $LOGS/atelier_prefs_test; chown mobile:mobile $LOGS/atelier_prefs_test; killall -9 Preferences 2>/dev/null; true"
    printf 'spawn com.apple.Preferences\n' | $SSH "cat > $LOGS/atelier_cmd.tmp && chown mobile:mobile $LOGS/atelier_cmd.tmp && mv $LOGS/atelier_cmd.tmp $LOGS/atelier_cmd.txt"
    for i in 1 2 3 4 5 6 7 8; do
      $SSH "test -f $LOGS/AtelierSettings.log" && break
      sleep 2
    done
    $SSH "cat $LOGS/AtelierSettings.log 2>/dev/null || echo 'no report: Settings did not start, or the helper is not in it'; rm -f $LOGS/atelier_prefs_test" ;;
  remove)
    $SSH 'dpkg -r com.adarsh.atelier; sbreload' ;;
  log)
    $SSH "tail -n ${2:-40} $LOGS/Atelier.log" ;;
  clearlog)
    $SSH ": > $LOGS/Atelier.log; chown mobile:mobile $LOGS/Atelier.log" ;;
  run)
    shift
    [ $# -gt 0 ] || { echo "usage: phone.sh run <line> [<line>…]"; exit 1; }
    printf '%s\n' "$@" | $SSH "cat > $LOGS/atelier_cmd.tmp && chown mobile:mobile $LOGS/atelier_cmd.tmp && mv $LOGS/atelier_cmd.tmp $LOGS/atelier_cmd.txt" ;;
  fetch)
    name="${2:?usage: phone.sh fetch <name> <dir>}"; dir="${3:?usage: phone.sh fetch <name> <dir>}"
    mkdir -p "$dir"
    $SSH "cat $LOGS/atelier_$name.jpg" > "$dir/atelier_$name.jpg" && $SSH "rm -f $LOGS/atelier_$name.jpg"
    ls -la "$dir/atelier_$name.jpg" ;;
  *)
    sed -n '2,16p' "$0" ;;
esac
