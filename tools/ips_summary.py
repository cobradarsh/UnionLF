#!/usr/bin/env python3
"""Print the gist of .ips crash reports: why the process died and the top of the thread that crashed.

Usage: python3 tools/ips_summary.py <report.ips> [<report.ips> ...]
"""
import json
import sys


def frames(report, frame_list, limit=24):
    images = report.get("usedImages", [])
    for f in frame_list[:limit]:
        index = f.get("imageIndex", -1)
        image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
        symbol = f.get("symbol")
        where = "%s + %s" % (symbol, f.get("symbolLocation", 0)) if symbol else hex(f.get("imageOffset", 0))
        print("      %-30s %s" % (image, where))


def main():
    for path in sys.argv[1:]:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
            head, _, body = text.partition("\n")
            json.loads(head)
            report = json.loads(body)
        except Exception as e:                      # an old-style text report, or half written
            print("== %s: not a JSON report (%s)" % (path, e))
            continue
        print("== %s" % path)
        print("   process %s (pid %s) at %s" % (report.get("procName"), report.get("pid"), report.get("captureTime")))
        exc = report.get("exception", {})
        print("   exception: %s %s %s" % (exc.get("type"), exc.get("signal", ""), exc.get("subtype", "")))
        term = report.get("termination", {})
        if term:
            print("   termination: %s / %s %s" % (term.get("namespace"), term.get("indicator"), term.get("reasons", "")))
        if report.get("asi"):
            print("   info: %s" % json.dumps(report["asi"])[:900])
        last = report.get("lastExceptionBacktrace")
        if last:
            print("   last exception thrown from:")
            frames(report, last)
        for thread in report.get("threads", []):
            if thread.get("triggered"):
                print("   crashed thread %s %s:" % (thread.get("name", ""), thread.get("queue", "")))
                frames(report, thread.get("frames", []))
    return 0


if __name__ == "__main__":
    sys.exit(main())
