#!/usr/bin/env python3
"""The bench's layout arithmetic (AtelierLayout.m) repeated in Python and checked.

For the phone's screen and a few others, every layout, every number of apps, with and
without "Resize apps": each tile is on the screen, clear of the status bar and the Home
indicator, no two tiles overlap, the main tile keeps the screen's proportions when apps
are not resized, and the "..." pill sits above its tile.

Usage: python3 tools/layout_check.py        (prints a table; exit 1 if anything is wrong)
"""
import sys

MARGIN, GAP, GRAB, MAX_SLOTS = 10.0, 8.0, 26.0, 5
SIDE, TOP, SPLIT = 0, 1, 2


def rnd(x):                       # C's round(): halves away from zero
    return float(int(x + 0.5)) if x >= 0 else -float(int(-x + 0.5))


def floor(x):
    return float(int(x // 1))


def R(x, y, w, h):
    return (x, y, w, h)


def empty(r):
    return r is None or r[2] <= 0 or r[3] <= 0


def compute(kind, W, H, safe_top, safe_bottom, apps, split=0.5, resize=False, side_scale=0.80):
    g = {"main": None, "second": None, "minis": [], "plus": None, "grabber": None, "grabber2": None,
         "divider": None, "scene": (W, H)}
    top = safe_top + 4
    bottom = H - max(safe_bottom, 12)
    apps = max(0, min(MAX_SLOTS, apps))
    minis = max(0, apps - 1)

    if kind == SPLIT:
        t = top + GRAB
        avail = bottom - t
        p = max(0.3, min(0.7, split))
        if resize:
            gap_h, w = 30.0, W - 2 * MARGIN
            h1 = rnd((avail - gap_h) * p)
            h2 = avail - gap_h - h1
            g["main"] = R(MARGIN, t, w, h1)
            g["second"] = R(MARGIN, t + h1 + gap_h, w, h2)
            g["divider"] = R(W / 2 - 44, t + h1, 88, gap_h)
            g["grabber2"] = R(W - MARGIN - 64, t + h1 + 4, 64, 22)
            g["scene"] = (w, h1)
        else:
            gap_w = 16.0
            total = W - 2 * MARGIN - gap_w
            w1 = rnd(total * p)
            w2 = total - w1
            h1, h2 = rnd(H * w1 / W), rnd(H * w2 / W)
            if h1 > avail:
                h1 = avail
                w1 = rnd(W * h1 / H)
            if h2 > avail:
                h2 = avail
                w2 = rnd(W * h2 / H)
            g["main"] = R(MARGIN, t + floor((avail - h1) / 2), w1, h1)
            g["second"] = R(W - MARGIN - w2, t + floor((avail - h2) / 2), w2, h2)
            g["divider"] = R(g["main"][0] + g["main"][2] + (gap_w - 28) / 2, t + avail / 2 - 44, 28, 88)
            g["grabber2"] = R(g["second"][0] + g["second"][2] / 2 - 32, g["second"][1] - 24, 64, 22)
        g["grabber"] = R(g["main"][0] + g["main"][2] / 2 - 32, g["main"][1] - 24, 64, 22)
        if apps < 2:
            g["plus"], g["second"], g["grabber2"], g["divider"] = g["second"], None, None, None
        if apps == 0:
            g["plus"], g["main"], g["grabber"] = g["main"], None, None
        return g

    if kind == TOP:
        tile_w = floor((W - 5 * MARGIN) / 4)
        tile_h = rnd(tile_w * 1.22)
        main_top = top + tile_h + GRAB + 2
        avail = bottom - main_top
        if resize:
            g["main"] = R(MARGIN, main_top, W - 2 * MARGIN, avail)
            g["scene"] = (g["main"][2], g["main"][3])
        else:
            s = min(avail / H, (W - 2 * MARGIN) / W)
            w, h = rnd(W * s), rnd(H * s)
            g["main"] = R(floor((W - w) / 2), main_top, w, h)
        tile_h = min(tile_h, rnd(tile_w * g["scene"][1] / g["scene"][0]))
        for i in range(4):
            r = R(MARGIN + i * (tile_w + MARGIN), top, tile_w, tile_h)
            if i < minis:
                g["minis"].append(r)
            elif i == minis and 1 <= apps < MAX_SLOTS:
                g["plus"] = r
    else:
        main_top = top + GRAB
        avail = bottom - main_top
        if resize:
            tile_w = rnd(W * 0.135)
            x = MARGIN + tile_w + GAP
            g["main"] = R(x, main_top, W - x - MARGIN, avail)
            g["scene"] = (g["main"][2], g["main"][3])
        else:
            s = min(side_scale, avail / H, (W - 2 * MARGIN - GAP - 48) / W)
            w, h = rnd(W * s), rnd(H * s)
            g["main"] = R(W - MARGIN - w, main_top + floor((avail - h) / 2), w, h)
            tile_w = g["main"][0] - GAP - MARGIN
        tile_h = rnd(tile_w * g["scene"][1] / g["scene"][0])
        tile_h = min(tile_h, floor((g["main"][3] - 3 * GAP) / 4))
        y = g["main"][1]
        for i in range(4):
            if i < minis:
                g["minis"].append(R(MARGIN, y, tile_w, tile_h))
                y += tile_h + GAP
            elif i == minis and 1 <= apps < MAX_SLOTS:
                g["plus"] = R(MARGIN, y, tile_w, tile_w)
    g["grabber"] = R(g["main"][0] + g["main"][2] / 2 - 32, g["main"][1] - 24, 64, 22)
    if apps == 0:
        g["plus"], g["main"], g["grabber"] = g["main"], None, None
    return g


def overlap(a, b):
    return a[0] < b[0] + b[2] - 0.01 and b[0] < a[0] + a[2] - 0.01 and a[1] < b[1] + b[3] - 0.01 and b[1] < a[1] + a[3] - 0.01


SCREENS = [("iPhone 14 Pro Max", 430, 932, 59, 34), ("iPhone 14 Pro", 393, 852, 59, 34),
           ("iPhone 13 mini", 375, 812, 50, 34), ("iPhone SE", 375, 667, 20, 0)]
NAMES = {SIDE: "side", TOP: "top", SPLIT: "split"}


def main():
    problems = 0
    for name, W, H, st, sb in SCREENS:
        for kind in (SIDE, TOP, SPLIT):
            for resize in (False, True):
                for apps in range(0, 6):
                    g = compute(kind, W, H, st, sb, apps, 0.5, resize)
                    tiles = [("main", g["main"]), ("second", g["second"]), ("plus", g["plus"])]
                    tiles += [("mini%d" % i, r) for i, r in enumerate(g["minis"])]
                    tiles = [(n, r) for n, r in tiles if not empty(r)]
                    where = "%s %s%s apps=%d" % (name, NAMES[kind], " resize" if resize else "", apps)
                    for n, r in tiles:
                        if r[0] < -0.01 or r[1] < st - 0.01 or r[0] + r[2] > W + 0.01 or r[1] + r[3] > H - sb + 0.01:
                            print("OFF SCREEN  %s: %s %s" % (where, n, r))
                            problems += 1
                    for i in range(len(tiles)):
                        for j in range(i + 1, len(tiles)):
                            if overlap(tiles[i][1], tiles[j][1]):
                                print("OVERLAP     %s: %s %s / %s %s" % (where, tiles[i][0], tiles[i][1], tiles[j][0], tiles[j][1]))
                                problems += 1
                    for pill, tile in (("grabber", "main"), ("grabber2", "second")):
                        if empty(g[pill]) or empty(g[tile]):
                            continue
                        for n, r in tiles:
                            if overlap(g[pill], r):
                                print("PILL        %s: %s lies on %s" % (where, pill, n))
                                problems += 1
                        if g[pill][1] < st - 0.01:
                            print("PILL        %s: %s is under the status bar" % (where, pill))
                            problems += 1
                    if not resize and not empty(g["main"]):
                        ratio = (g["main"][2] / g["main"][3]) / (W / H)
                        if abs(ratio - 1) > 0.01:
                            print("PROPORTION  %s: main %s" % (where, g["main"]))
                            problems += 1
        g = compute(SIDE, W, H, st, sb, 5)
        t = compute(TOP, W, H, st, sb, 5)
        print("%-18s side: main %3.0fx%3.0f (x%.2f) minis %2.0fx%3.0f   top: main %3.0fx%3.0f (x%.2f) minis %2.0fx%3.0f"
              % (name, g["main"][2], g["main"][3], g["main"][2] / W, g["minis"][0][2], g["minis"][0][3],
                 t["main"][2], t["main"][3], t["main"][2] / W, t["minis"][0][2], t["minis"][0][3]))
    print("layout check: %s" % ("OK" if problems == 0 else "%d problem(s)" % problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
