#!/bin/bash
# tools/phone.sh — Chakra on the phone, over USB SSH (host "iphone-root", RootHide).
#
#   install <deb>        copy the package over, dpkg -i, respring
#   remove               dpkg -r com.adarsh.chakra, respring
#   log [n]              the last n lines of Chakra.log (default 40)
#   test on|off          switch the test commands on or off (the chakra_test marker file)
#   run <line> [<line>…] run test command lines in order (see the top of ChakraDebug.m)
#   fetch <name> <dir>   copy the screenshot made by "shot <name>" into <dir>, then delete it on the phone
#
# The SSH shell sees the jailbreak root as /; the real file system, where SpringBoard writes, is
# under /rootfs. Its login shell is zsh, so nothing here relies on a wildcard that may match nothing.
set -u
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 iphone-root"
LOGS=/rootfs/var/mobile/Library/Logs

case "${1:-}" in
  install)
    deb="${2:?usage: phone.sh install <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/chakra.deb' < "$deb" || exit 1
    $SSH 'dpkg -i /tmp/chakra.deb; rc=$?; rm -f /tmp/chakra.deb; echo "dpkg exit $rc"; dpkg -s com.adarsh.chakra | grep -E "^(Version|Status)"; exit $rc' || exit 1
    echo "respringing…"
    $SSH 'sbreload' || true
    ;;
  remove)
    $SSH 'dpkg -r com.adarsh.chakra; sbreload' ;;
  log)
    $SSH "tail -n ${2:-40} $LOGS/Chakra.log" ;;
  test)
    if [ "${2:-}" = "on" ]; then $SSH "touch $LOGS/chakra_test && chown mobile:mobile $LOGS/chakra_test && echo 'test commands: on'"
    else $SSH "rm -f $LOGS/chakra_test $LOGS/chakra_cmd.txt && echo 'test commands: off'"; fi ;;
  run)
    shift
    [ $# -gt 0 ] || { echo "usage: phone.sh run <line> [<line>…]"; exit 1; }
    printf '%s\n' "$@" | $SSH "cat > $LOGS/chakra_cmd.tmp && chown mobile:mobile $LOGS/chakra_cmd.tmp && mv $LOGS/chakra_cmd.tmp $LOGS/chakra_cmd.txt" ;;
  fetch)
    name="${2:?usage: phone.sh fetch <name> <dir>}"; dir="${3:?usage: phone.sh fetch <name> <dir>}"
    mkdir -p "$dir"
    $SSH "cat $LOGS/chakra_$name.jpg" > "$dir/chakra_$name.jpg" && $SSH "rm -f $LOGS/chakra_$name.jpg"
    ls -la "$dir/chakra_$name.jpg" ;;
  *)
    sed -n '2,11p' "$0" ;;
esac
