#!/usr/bin/env python3
"""Checks the arithmetic of Chakra's wheel layout (ChakraLayout.m, -_wheelFor:input:) without a phone.

Same steps as the Objective-C: for 1 to 17 icons (16 entries and Edit), five ball heights and three icon sizes, with
and without names, it places the icons on a 430 x 932 pt screen (iPhone 14 Pro Max) and reports
any that overlap, leave the usable screen, or could not be placed. The one known case that does
not fit everything (16 of the biggest icons with names, ball in the bottom corner) shows 14.

Usage: python3 tools/layout_check.py        (last line: "problems: N")
"""
import math
import sys

W, H = 430.0, 932.0
TOP, BOTTOM = 59.0, 34.0


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def wheel(n, hub_y, hub_inset, s, labels, ball):
    """Returns (rings, points): rings = [(radius, count)], points = [(dx_from_edge, y)]."""
    pitch = s + (22 if labels else 12)          # along the arc
    gap = s + (24 if labels else 12)            # between rings
    cell_h = s + (18 if labels else 0)
    y_min = TOP + 8 + s / 2
    y_max = H - BOTTOM - 8 - cell_h + s / 2
    r_min = ball / 2 + 14 + s / 2
    r_far = W - hub_inset - s / 2 - 14

    def span(r):
        c = (s / 2 + 6 - hub_inset) / r
        if c >= 1:
            return None
        side = math.pi / 2 if c <= 0 else math.acos(c)
        hi = min(math.asin(clamp((y_max - hub_y) / r, -1, 1)), side)
        lo = max(math.asin(clamp((y_min - hub_y) / r, -1, 1)), -side)
        return (lo, hi) if hi >= lo else None

    def cap(r):
        sp = span(r)
        if sp is None:
            return 0
        return int(math.floor((sp[1] - sp[0]) * r / pitch + 1e-6)) + 1

    limits = [min(r_far, 0.46 * W), min(r_far, 0.62 * W), min(r_far, 0.80 * W), r_far]
    chosen = None
    for rings in range(1, 5):
        r1 = r_min
        last_ok = limits[rings - 1] - (rings - 1) * gap
        while r1 <= last_ok + 0.01:
            caps = [cap(r1 + j * gap) for j in range(rings)]
            if sum(caps) >= n:
                chosen = (r1, caps)
                break
            r1 += 4
        if chosen:
            break
    if not chosen:                                # more than fits: show what does
        rings = 4
        r1 = r_min
        caps = [cap(r1 + j * gap) for j in range(rings)]
        chosen = (r1, caps)
        n = min(n, sum(caps))
    r1, caps = chosen
    if len(caps) == 1:                            # a single ring reads better a little further out
        nicer = clamp(max(r1, s * 2.0), r1, max(r1, limits[0]))
        if cap(nicer) >= n:
            r1 = nicer
            caps = [cap(nicer)]
    # share the items out in proportion to each ring's room, inner rings first
    total = sum(caps)
    counts = [min(caps[j], int(round(n * caps[j] / total))) for j in range(len(caps))]
    while sum(counts) < n:
        j = max(range(len(caps)), key=lambda k: caps[k] - counts[k])
        counts[j] += 1
    while sum(counts) > n:
        j = max(range(len(caps)), key=lambda k: counts[k] - caps[k] * n / total)
        counts[j] -= 1
    pts = []
    rings_out = []
    for j, k in enumerate(counts):
        r = r1 + j * gap
        rings_out.append((r, k))
        if k == 0:
            continue
        lo, hi = span(r)
        step = min((hi - lo) / (k - 1), 1.3 * pitch / r) if k > 1 else 0.0
        half = step * (k - 1) / 2
        c0 = clamp(0.0, lo + half, hi - half)
        for i in range(k):
            th = c0 + (i - (k - 1) / 2) * step
            pts.append((hub_inset + r * math.cos(th), hub_y + r * math.sin(th)))
    return rings_out, pts, (y_min, y_max)


def check(n, hub_y, s, labels, ball=46.0):
    hub_inset = 6 + ball / 2
    rings, pts, (y_min, y_max) = wheel(n, hub_y, hub_inset, s, labels, ball)
    worst = 1e9
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            worst = min(worst, math.hypot(pts[i][0] - pts[j][0], pts[i][1] - pts[j][1]) - s)
    off = [p for p in pts if p[0] < s / 2 + 5.9 or p[0] > W - s / 2 - 13.9 or p[1] < y_min - 0.01 or p[1] > y_max + 0.01]
    return rings, len(pts), worst, off


def main():
    bad = 0
    for labels in (True, False):
        for s in (44.0, 54.0, 66.0):
            for hub_y in (90.0, 200.0, 466.0, 760.0, 880.0):
                line = []
                for n in range(1, 18):
                    rings, placed, worst, off = check(n, hub_y, s, labels)
                    flag = ""
                    if placed < n:
                        flag += "!short(%d)" % placed
                    if n > 1 and worst < 4:
                        flag += "!gap(%.0f)" % worst
                    if off:
                        flag += "!off"
                    if flag:
                        bad += 1
                    line.append("%d:%s%s" % (n, "+".join("%d@%d" % (k, r) for r, k in rings), flag))
                print("labels=%d s=%d hubY=%d  %s" % (labels, s, hub_y, "  ".join(line)))
    print("problems:", bad)
    return 0


if __name__ == "__main__":
    sys.exit(main())
