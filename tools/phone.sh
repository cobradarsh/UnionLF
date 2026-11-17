#!/bin/bash
# tools/phone.sh — IWantTranslucent on the phone, over USB SSH (host "iphone-root", RootHide).
#
#   status               which IWantTranslucent package is installed, and its files
#   diag <iwtdiag> [s]   copy the diagnostic tool over, run it for s seconds (default 20), delete it:
#                        CPU by process, where the tweak and RootHide's patch are loaded, battery
#                        temperature and power (see diag/iwtdiag.c)
#   reports [days]       crash and resource reports of the last days (default 3): how many per
#                        process, and which of them mention the tweak
#   install <deb>        remove Luki's package if it is there, install the lean one, respring
#   original <deb>       the way back: remove the lean one, install the original .deb, respring
#   remove               remove the lean one, respring
#
# The SSH shell sees the jailbreak root as /; the real file system is under /rootfs. Its login
# shell is zsh, so nothing here relies on a wildcard that may match nothing.
set -u
SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 iphone-root"
LEAN=com.adarsh.iwanttranslucent
ORIG=me.luki.iwanttranslucent
REPORTS=/rootfs/var/mobile/Library/Logs/CrashReporter

case "${1:-}" in
  status)
    $SSH "for p in $ORIG $LEAN rootless-compat com.roothide.patchloader ellekit; do dpkg-query -W -f='\${Package} \${Version} [\${Status}]\n' \$p 2>/dev/null || echo \"\$p: not installed\"; done; echo; ls -la /Library/MobileSubstrate/DynamicLibraries/ | grep -i -E 'translucent|total' ; true" ;;
  diag)
    tool="${2:?usage: phone.sh diag <iwtdiag> [seconds]}"
    [ -f "$tool" ] || { echo "no such file: $tool"; exit 1; }
    $SSH 'cat > /tmp/iwtdiag && chmod 755 /tmp/iwtdiag' < "$tool" || exit 1
    $SSH "/tmp/iwtdiag ${3:-20}; rc=\$?; rm -f /tmp/iwtdiag; exit \$rc" ;;
  reports)
    days="${2:-3}"
    $SSH "find $REPORTS -maxdepth 2 -type f -mtime -$days \( -name '*.ips' -o -name '*.synced' \) 2>/dev/null | sed -e 's#.*/##' | sort > /tmp/iwt_reports.txt; echo \"reports in the last $days day(s): \$(grep -c . /tmp/iwt_reports.txt)\"; sed -E 's/-20[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{6}.*//' /tmp/iwt_reports.txt | sort | uniq -c | sort -rn | head -40; echo; echo 'reports that mention the tweak or the patch:'; find $REPORTS -maxdepth 2 -type f -mtime -$days -name '*.ips' 2>/dev/null | while read -r f; do if grep -q -E 'IWantTranslucent|AutoPatches' \"\$f\" 2>/dev/null; then echo \"  \$f\"; fi; done | head -40; rm -f /tmp/iwt_reports.txt" ;;
  install)
    deb="${2:?usage: phone.sh install <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/iwt.deb' < "$deb" || exit 1
    $SSH "if dpkg -s $ORIG >/dev/null 2>&1; then echo 'removing the original package'; dpkg -r $ORIG || exit 1; fi; dpkg -i /tmp/iwt.deb; rc=\$?; rm -f /tmp/iwt.deb; echo \"dpkg exit \$rc\"; dpkg -s $LEAN | grep -E '^(Version|Status)'; exit \$rc" || exit 1
    echo "respringing…"
    $SSH 'sbreload' || true ;;
  original)
    deb="${2:?usage: phone.sh original <deb>}"
    [ -f "$deb" ] || { echo "no such file: $deb"; exit 1; }
    $SSH 'cat > /tmp/iwt.deb' < "$deb" || exit 1
    $SSH "if dpkg -s $LEAN >/dev/null 2>&1; then dpkg -r $LEAN || exit 1; fi; dpkg -i /tmp/iwt.deb; rc=\$?; rm -f /tmp/iwt.deb; echo \"dpkg exit \$rc\"; dpkg -s $ORIG | grep -E '^(Version|Status)'; exit \$rc" || exit 1
    echo "respringing…"
    $SSH 'sbreload' || true ;;
  remove)
    $SSH "dpkg -r $LEAN; sbreload" ;;
  *)
    sed -n '2,15p' "$0" ;;
esac
