#!/usr/bin/env python3
"""Chooses the iOS simulator for a test run.

Reads `xcrun simctl list -j` on standard input and prints one line:
    USE|<udid>|<device name>|<iOS version>          an existing iPhone of the wanted iOS
    CREATE|<runtime id>|<device type id>|<version>  none exists yet: create one of this kind
Nothing is printed when no iOS runtime is installed.

Usage: xcrun simctl list -j | python3 tools/pick_sim.py [wanted iOS version, e.g. 16.4]
Without a wanted version, or when it is not installed, the oldest iOS there is (the nearest to the phone's 16.5).
"""
import json
import re
import sys

want = sys.argv[1] if len(sys.argv) > 1 else ""
data = json.load(sys.stdin)
runtimes = []
for rt in data.get("runtimes", []):
    ident = rt.get("identifier", "")
    if "SimRuntime.iOS-" not in ident or not rt.get("isAvailable", False):
        continue
    version = tuple(int(x) for x in re.findall(r"\d+", rt.get("version", "0"))[:2])
    runtimes.append((version, ident, rt))
if not runtimes:
    sys.exit(0)
runtimes.sort(key=lambda item: item[0])
chosen = None
if want:
    wanted = tuple(int(x) for x in re.findall(r"\d+", want)[:2])
    for item in runtimes:
        if item[0][:len(wanted)] == wanted:
            chosen = item
if chosen is None:
    chosen = runtimes[0]
version, ident, rt = chosen
label = "%d.%d" % (version[0], version[1])

best = None
for dev in data.get("devices", {}).get(ident, []):
    name = dev.get("name", "")
    if not name.startswith("iPhone") or not dev.get("isAvailable", True):
        continue
    score = (name == "iPhone 14 Pro Max", "Pro Max" in name, "Pro" in name, name)
    if best is None or score > best[0]:
        best = (score, dev["udid"], name)

types = [t.get("identifier", "") for t in rt.get("supportedDeviceTypes", [])]
if not types:
    types = [t.get("identifier", "") for t in data.get("devicetypes", [])]
phones = sorted(t for t in types if "iPhone" in t)
pick = "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro-Max"
if best and (best[0][0] or pick not in phones):
    print("USE|%s|%s|%s" % (best[1], best[2], label))
elif pick in phones:
    print("CREATE|%s|%s|%s" % (ident, pick, label))
elif best:
    print("USE|%s|%s|%s" % (best[1], best[2], label))
elif phones:
    print("CREATE|%s|%s|%s" % (ident, phones[-1], label))
