#!/usr/bin/env python3
"""The bench's layout arithmetic (AtelierLayout.m) repeated in Python and checked.

For the phone's screen and a few others, every layout, every number of apps (0 to 6), with and
without the band, with and without "resize":

  - every tile, the "+", the free places and the band are on the screen, below the status bar /
    Dynamic Island (nothing above the safe area) and above the Home indicator;
  - no two of them overlap, and nothing lies on the "..." pill (in Side the pill is in the band's
    lower row: there the band's upper row and its flags zone must stay clear of it);
  - Side: the column of five places is exactly as tall as the main (same top, same bottom,
    equal gaps); Top: the row of five is exactly as wide as the main;
  - the main keeps the screen's proportions when apps are not resized, and in Side a mini shows
    the whole app (its width is the app's width at the mini's scale, to within a point).

Usage: python3 tools/layout_check.py        (prints a table; exit 1 if anything is wrong)
"""
import sys

MARGIN, GAP, GRAB, MAX_SLOTS = 10.0, 8.0, 26.0, 6
BAND_TALL, BAND_LINE = 62.0, 30.0
SIDE, TOP, SPLIT = 0, 1, 2


def rnd(x):                       # C's round(): halves away from zero
    return float(int(x + 0.5)) if x >= 0 else -float(int(-x + 0.5))


def floor(x):
    return float(int(x // 1))


def R(x, y, w, h):
    return (x, y, w, h)


def empty(r):
    return r is None or r[2] <= 0 or r[3] <= 0


def compute(kind, W, H, safe_top, safe_bottom, apps, split=0.5, resize=False, side_scale=0.80, band=True):
    g = {"main": None, "second": None, "minis": [], "plus": None, "grabber": None, "grabber2": None,
         "divider": None, "scene": (W, H), "band": None, "compact": False, "count": 0}
    top = safe_top + 4
    bottom = H - max(safe_bottom, 12)
    apps = max(0, min(MAX_SLOTS, apps))
    minis = max(0, apps - 1)

    if kind == SPLIT:
        if band:
            g["band"], g["compact"] = R(MARGIN, top, W - 2 * MARGIN, BAND_LINE), True
        t = top + (BAND_LINE + 2 if band else 0) + GRAB
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
        if band:
            g["band"], g["compact"] = R(MARGIN, top, W - 2 * MARGIN, BAND_LINE), True
        row_top = top + (BAND_LINE + 6 if band else 0)
        tile_w, tile_h = 58.0, 70.0
        if resize:
            tile_w = (W - 2 * MARGIN - 4 * GAP) / 5
            tile_h = rnd(tile_w * 1.22)
            main_top = row_top + tile_h + GRAB + 2
            avail = bottom - main_top
            g["main"] = R(MARGIN, main_top, W - 2 * MARGIN, avail)
            g["scene"] = (g["main"][2], g["main"][3])
            tile_h = min(tile_h, rnd(tile_w * g["scene"][1] / g["scene"][0]))
        else:
            for n in range(3):
                main_top = row_top + tile_h + GRAB + 2
                avail = bottom - main_top
                s = min(avail / H, (W - 2 * MARGIN) / W)
                w = rnd(W * s)
                tile_w = (w - 4 * GAP) / 5
                if n < 2:
                    tile_h = rnd(tile_w * 1.22)
            g["main"] = R(floor((W - w) / 2), main_top, w, min(rnd(H * s), avail))
        g["minis"] = [R(g["main"][0] + i * (tile_w + GAP), row_top, tile_w, tile_h) for i in range(5)]
    else:
        if band:
            g["band"] = R(MARGIN, top, W - 2 * MARGIN, BAND_TALL)
        pane_top = top + (BAND_TALL + 4 if band else GRAB)
        avail = bottom - pane_top
        if resize:
            tile_w = rnd(W * 0.135)
            x = MARGIN + tile_w + GAP
            g["main"] = R(x, pane_top, W - x - MARGIN, avail)
            g["scene"] = (g["main"][2], g["main"][3])
            column_x = MARGIN
        else:
            s = (W - 2 * MARGIN - GAP + 0.8 * GAP * W / H) / (1.2 * W)
            s = min(s, side_scale, avail / H)
            w, h = rnd(W * s), rnd(H * s)
            y = pane_top if band else pane_top + floor((avail - h) / 2)
            g["main"] = R(W - MARGIN - w, y, w, h)
            tile_w = min(g["main"][0] - GAP - MARGIN, rnd((h - 4 * GAP) / 5 * W / H))
            column_x = g["main"][0] - GAP - tile_w
        tile_h = (g["main"][3] - 4 * GAP) / 5
        g["minis"] = [R(column_x, g["main"][1] + i * (tile_h + GAP), tile_w, tile_h) for i in range(5)]
    g["count"] = minis
    if 1 <= apps < MAX_SLOTS:
        g["plus"] = g["minis"][minis]
    g["grabber"] = R(g["main"][0] + g["main"][2] / 2 - 32, g["main"][1] - 24, 64, 22)
    if apps == 0:
        g["plus"], g["main"], g["grabber"] = g["main"], None, None
    return g


def overlap(a, b):
    return a[0] < b[0] + b[2] - 0.01 and b[0] < a[0] + a[2] - 0.01 and a[1] < b[1] + b[3] - 0.01 and b[1] < a[1] + a[3] - 0.01


# (name, width, height, safe top, safe bottom, Dynamic Island bottom or 0)
SCREENS = [("iPhone 14 Pro Max", 430, 932, 59, 34, 48), ("iPhone 14 Pro", 393, 852, 59, 34, 48),
           ("iPhone 13 mini", 375, 812, 50, 34, 0), ("iPhone SE", 375, 667, 20, 0, 0)]
NAMES = {SIDE: "side", TOP: "top", SPLIT: "split"}


def main():
    problems = 0

    def bad(kind, where, what):
        nonlocal problems
        print("%-11s %s: %s" % (kind, where, what))
        problems += 1

    for name, W, H, st, sb, island in SCREENS:
        for kind in (SIDE, TOP, SPLIT):
            for resize in (False, True):
                for band in (True, False):
                    for apps in range(0, MAX_SLOTS + 1):
                        g = compute(kind, W, H, st, sb, apps, 0.5, resize, 0.80, band)
                        where = "%s %s%s%s apps=%d" % (name, NAMES[kind], " resize" if resize else "", "" if band else " no-band", apps)
                        places = g["minis"]
                        tiles = [("main", g["main"]), ("second", g["second"])]
                        if apps == 0 or kind == SPLIT:
                            tiles.append(("plus", g["plus"]))
                        tiles += [("place%d" % i, r) for i, r in enumerate(places)]      # apps, the "+" and the outlines
                        tiles = [(n, r) for n, r in tiles if not empty(r)]
                        if apps == 0:
                            tiles = [(n, r) for n, r in tiles if n != "plus"] + [("plus", g["plus"])]
                        everything = tiles + ([("band", g["band"])] if not empty(g["band"]) else [])
                        for n, r in everything:
                            if r[0] < -0.01 or r[1] < st - 0.01 or r[0] + r[2] > W + 0.01 or r[1] + r[3] > H - sb + 0.01:
                                bad("OFF SCREEN", where, "%s %s" % (n, r))
                            if island and r[1] < island:
                                bad("ISLAND", where, "%s %s" % (n, r))
                        for i in range(len(tiles)):
                            for j in range(i + 1, len(tiles)):
                                if overlap(tiles[i][1], tiles[j][1]):
                                    bad("OVERLAP", where, "%s %s / %s %s" % (tiles[i][0], tiles[i][1], tiles[j][0], tiles[j][1]))
                        for pill, tile in (("grabber", "main"), ("grabber2", "second")):
                            if empty(g[pill]) or empty(g[tile]):
                                continue
                            for n, r in tiles:
                                if overlap(g[pill], r):
                                    bad("PILL", where, "%s lies on %s" % (pill, n))
                            if g[pill][1] < st - 0.01:
                                bad("PILL", where, "%s is above the safe area" % pill)
                        if not empty(g["band"]):
                            for n, r in tiles:
                                if overlap(g["band"], r):
                                    bad("BAND", where, "the band lies on %s" % n)
                            for pill in ("grabber", "grabber2"):
                                if empty(g[pill]):
                                    continue
                                if g["compact"]:
                                    if overlap(g["band"], g[pill]):
                                        bad("BAND", where, "the compact band lies on %s" % pill)
                                else:
                                    upper = R(g["band"][0], g["band"][1], g["band"][2], 37)          # clock and shortcut icons
                                    flags = R(g["band"][0], g["band"][1] + 38, g[pill][0] - 8 - g["band"][0], 24)
                                    if overlap(upper, g[pill]) or overlap(flags, g[pill]):
                                        bad("BAND", where, "the band's contents lie on the pill")
                                    if flags[2] < 150:
                                        bad("BAND", where, "only %.0f pt for the flags" % flags[2])
                        if kind == SIDE and places and not empty(g["main"]):
                            m = g["main"]
                            if abs(places[0][1] - m[1]) > 0.01 or abs(places[4][1] + places[4][3] - (m[1] + m[3])) > 0.01:
                                bad("COLUMN", where, "column %.2f..%.2f, main %.2f..%.2f" % (places[0][1], places[4][1] + places[4][3], m[1], m[1] + m[3]))
                            gaps = [places[i + 1][1] - (places[i][1] + places[i][3]) for i in range(4)]
                            if max(gaps) - min(gaps) > 0.01 or abs(gaps[0] - GAP) > 0.01:
                                bad("COLUMN", where, "gaps %s" % gaps)
                            if not resize:
                                whole = places[0][3] * W / H              # the width at which the tile shows the whole app
                                if places[0][2] > whole + 1.0:
                                    bad("COLUMN", where, "a mini %.1f wide shows the app %.1f tall, the tile is %.1f" % (places[0][2], places[0][2] * H / W, places[0][3]))
                        if kind == TOP and places and not empty(g["main"]):
                            m = g["main"]
                            if abs(places[0][0] - m[0]) > 0.01 or abs(places[4][0] + places[4][2] - (m[0] + m[2])) > 0.01:
                                bad("ROW", where, "row %.2f..%.2f, main %.2f..%.2f" % (places[0][0], places[4][0] + places[4][2], m[0], m[0] + m[2]))
                        if not resize and not empty(g["main"]):
                            ratio = (g["main"][2] / g["main"][3]) / (W / H)
                            if abs(ratio - 1) > 0.012:
                                bad("PROPORTION", where, "main %s" % (g["main"],))
        g = compute(SIDE, W, H, st, sb, 6)
        t = compute(TOP, W, H, st, sb, 6)
        print("%-18s side: main %3.0fx%3.0f at %3.0f,%3.0f (x%.3f) minis %2.0fx%5.1f band %3.0f..%3.0f   top: main %3.0fx%3.0f (x%.3f) minis %4.1fx%2.0f"
              % (name, g["main"][2], g["main"][3], g["main"][0], g["main"][1], g["main"][2] / W, g["minis"][0][2], g["minis"][0][3],
                 g["band"][1], g["band"][1] + g["band"][3], t["main"][2], t["main"][3], t["main"][2] / W, t["minis"][0][2], t["minis"][0][3]))
    print("layout check: %s" % ("OK" if problems == 0 else "%d problem(s)" % problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
