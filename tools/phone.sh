#!/bin/bash
# tools/phone.sh — Shani on the phone, over USB SSH (host "iphone-root", RootHide).
#
#   status               is the package installed, are the libraries there, the last log lines
#   install <deb>        copy the package over, dpkg -i, respring
#   remove               dpkg -r com.adarsh.shani, respring
#   log [n]              the last n lines of Shani.log (default 40)
#   run <line> [<line>…] run test command lines in order (see the top of ShaniDebug.m);
#                        they work while Settings → Shani → Debug Log is on (it is by default)
#   state                what is on the list and what is held (state.plist, no notification text)
#   settings             start Settings in the background and show the helper's self-test:
#                        are the Apps & Log screens there, can they read Shani's files
#   fetch <name> <dir>   copy the screenshot made by "shot <name>" into <dir>, then delete it on the phone
#   clearlog             empty Shani.log
#
# The SSH shell sees the jailbreak root as /; the real file system, where SpringBoard writes, is
# under /rootfs. Its login shell is zsh, so nothing here relies on a wildcard that may match nothing.
set -u
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 iphone-root"
LOGS=/rootfs/var/mobile/Library/Logs
DATA=/rootfs/var/mobile/Library/Shani

send_lines() {                                        # the lines become the command file, in one move
  printf '%s\n' "$@" | $SSH "cat > $LOGS/shani_cmd.tmp && chown mobile:mobile $LOGS/shani_cmd.tmp && mv $LOGS/shani_cmd.tmp $LOGS/shani_cmd.txt"
}

case "${1:-}" in
  status)
    $SSH "dpkg-query -W -f='\${Package} \${Version} [\${Status}]\n' com.adarsh.shani 2>/dev/null || echo 'com.adarsh.shani: not installed'; ls -la /Library/MobileSubstrate/DynamicLibraries/ | grep -i shani; cat $LOGS/Shani.boot 2>/dev/null | sed 's/^/boot count: /'; tail -n 8 $LOGS/Shani.log 2>/dev/null; true" ;;
  install)
    deb="${2:?usage: phone.sh install <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/shani.deb' < "$deb" || exit 1
    $SSH 'dpkg -i /tmp/shani.deb; rc=$?; rm -f /tmp/shani.deb; echo "dpkg exit $rc"; dpkg -s com.adarsh.shani | grep -E "^(Version|Status)"; exit $rc' || exit 1
    echo "respringing…"
    $SSH 'sbreload' || true
    ;;
  settings)
    $SSH "rm -f $LOGS/ShaniSettings.log; touch $LOGS/shani_prefs_test; chown mobile:mobile $LOGS/shani_prefs_test; killall -9 Preferences 2>/dev/null; true"
    $SSH "uiopen --bundleid com.apple.Preferences > /dev/null 2>&1 || uiopen prefs: > /dev/null 2>&1; true"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      $SSH "grep -q '^done' $LOGS/ShaniSettings.log 2>/dev/null" && break
      sleep 2
    done
    $SSH "cat $LOGS/ShaniSettings.log 2>/dev/null || echo 'no report: Settings did not start, or the helper is not in it'; rm -f $LOGS/shani_prefs_test" ;;
  remove)
    $SSH 'dpkg -r com.adarsh.shani; sbreload' ;;
  log)
    $SSH "tail -n ${2:-40} $LOGS/Shani.log" ;;
  clearlog)
    $SSH ": > $LOGS/Shani.log; chown mobile:mobile $LOGS/Shani.log" ;;
  state)
    $SSH "plutil -p $DATA/state.plist 2>/dev/null || cat $DATA/state.plist 2>/dev/null || echo 'no state file yet'; ls -la $DATA/log 2>/dev/null" ;;
  run)
    shift
    [ $# -gt 0 ] || { echo "usage: phone.sh run <line> [<line>…]"; exit 1; }
    send_lines "$@" ;;
  fetch)
    name="${2:?usage: phone.sh fetch <name> <dir>}"; dir="${3:?usage: phone.sh fetch <name> <dir>}"
    mkdir -p "$dir"
    $SSH "cat $LOGS/shani_$name.jpg" > "$dir/shani_$name.jpg" && $SSH "rm -f $LOGS/shani_$name.jpg"
    ls -la "$dir/shani_$name.jpg" ;;
  *)
    sed -n '2,17p' "$0" ;;
esac
