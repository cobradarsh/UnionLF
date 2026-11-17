#!/usr/bin/env python3
"""Puts the simulator runs of tools/sim_bench.sh side by side.

usage: bench_report.py <output folder of sim_bench.sh>

Reads result-r<round>-<variant>.txt (variant: none, orig, opt) and the small .bmp copies of the
screenshots, prints the numbers, what each variant left on screen in the menu, how much the
pictures differ, and a list of checks. The exit code is 1 when a check fails on iOS 16, the
system the tweak is for; on any other iOS the checks are printed for information only.
"""
import glob
import os
import re
import struct
import sys

VARIANTS = ("none", "orig", "opt")
TIMING = re.compile(r"\.(ns|ms|us_per_cell|cpu_ms)$")
STRUCTURE = re.compile(r"\.(view x\d+|layout|supplementary|header) ")


def read_result(path):
    values, structure = {}, []
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return None, []
    for line in lines:
        if STRUCTURE.search(line):
            structure.append(line)
            continue
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip()] = value.strip()
    return values, structure


def number(text):
    try:
        return float(text.split()[0])
    except (AttributeError, ValueError, IndexError):
        return None


def read_bmp(path):
    data = open(path, "rb").read()
    if data[:2] != b"BM":
        raise ValueError("not a BMP")
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]
    if bpp not in (24, 32) or compression not in (0, 3):
        raise ValueError("unsupported BMP: %d bpp, compression %d" % (bpp, compression))
    top_down = height < 0
    height = abs(height)
    stride = ((bpp * width + 31) // 32) * 4
    step = bpp // 8
    rows = []
    for y in range(height):
        start = offset + (y if top_down else height - 1 - y) * stride
        rows.append(data[start:start + width * step])
    return width, height, step, rows


def picture_difference(path_a, path_b):
    """(mean difference per channel 0..255, percent of pixels that differ clearly), status bar and home bar left out."""
    wa, ha, sa, rows_a = read_bmp(path_a)
    wb, hb, sb, rows_b = read_bmp(path_b)
    if (wa, ha) != (wb, hb):
        return None
    top, bottom = int(ha * 0.07), int(ha * 0.96)
    total = clear = count = 0
    for y in range(top, bottom):
        ra, rb = rows_a[y], rows_b[y]
        for x in range(wa):
            ia, ib = x * sa, x * sb
            d0 = abs(ra[ia] - rb[ib])
            d1 = abs(ra[ia + 1] - rb[ib + 1])
            d2 = abs(ra[ia + 2] - rb[ib + 2])
            total += d0 + d1 + d2
            if d0 > 16 or d1 > 16 or d2 > 16:
                clear += 1
            count += 1
    return total / (3.0 * count), 100.0 * clear / count


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "sim-out"
    results, structures = {}, {}
    rounds = sorted({int(re.search(r"result-r(\d+)-", p).group(1)) for p in glob.glob(os.path.join(out, "result-r*-*.txt"))})
    for r in rounds:
        for v in VARIANTS:
            values, structure = read_result(os.path.join(out, "result-r%d-%s.txt" % (r, v)))
            if values is not None:
                results[(r, v)] = values
                structures[(r, v)] = structure
    if not results:
        print("no results in %s" % out)
        return 1
    try:
        print(open(os.path.join(out, "simulator.txt"), encoding="utf-8").read().strip())
    except OSError:
        pass
    ios = next((vals["ios"].split()[0] for vals in results.values() if vals.get("ios")), "")
    print("iOS in the simulator: %s    rounds: %s" % (ios or "?", ", ".join(str(r) for r in rounds)))

    def value(variant, key):
        """Timings: the best of the rounds. Everything else: the first round's value ('!' when rounds disagree)."""
        seen = [results[(r, variant)][key] for r in rounds if (r, variant) in results and key in results[(r, variant)]]
        if not seen:
            return None
        if TIMING.search(key):
            numbers = [n for n in (number(s) for s in seen) if n is not None]
            return "%.1f" % min(numbers) if numbers else seen[0]
        return seen[0] + ("" if all(s == seen[0] for s in seen) else " !")

    keys = []
    for vals in results.values():
        for key in vals:
            if key not in keys and key not in ("variant", "ios", "done"):
                keys.append(key)
    print()
    print("%-58s %-22s %-22s %-22s" % ("", "none", "orig (0.9.4)", "opt (rebuild)"))
    for key in keys:
        cells = [(value(v, key) or "-")[:22] for v in VARIANTS]
        print("%-58s %-22s %-22s %-22s" % (key[:58], cells[0], cells[1], cells[2]))

    def num(variant, key):
        return number(value(variant, key))

    print()
    print("what a hook adds to one -didMoveToWindow of a collection view cell (direct calls):")
    base = num("none", "moves.direct.UICollectionViewCell.ns")
    for v in ("orig", "opt"):
        n = num(v, "moves.direct.UICollectionViewCell.ns")
        if base is not None and n is not None:
            print("   %-5s %8.1f ns   (%.1f ns with the hook, %.1f ns without)" % (v, n - base, n, base))
    base = num("none", "moves.pair.UICollectionViewCell.ns")
    print("and to one addSubview + removeFromSuperview of a cell (two window changes):")
    for v in ("orig", "opt"):
        n = num(v, "moves.pair.UICollectionViewCell.ns")
        if base is not None and n is not None:
            print("   %-5s %8.1f ns   (%.1f ns with the hook, %.1f ns without)" % (v, n - base, n, base))

    first = rounds[0]
    for v in VARIANTS:
        print()
        print("what is in the menu, %s:" % v)
        for line in structures.get((first, v), []) or ["   (nothing reported)"]:
            print("   " + line)

    print()
    print("pictures of the open menu (mean difference per colour channel out of 255; share of pixels that clearly differ):")
    diffs = {}
    pairs = [("orig", first, "opt", first), ("none", first, "orig", first), ("none", first, "opt", first)]
    if len(rounds) > 1:
        pairs += [(v, rounds[0], v, rounds[1]) for v in VARIANTS]
    for va, ra, vb, rb in pairs:
        pa = os.path.join(out, "shot-r%d-%s-menu.bmp" % (ra, va))
        pb = os.path.join(out, "shot-r%d-%s-menu.bmp" % (rb, vb))
        label = "%s (round %d) against %s (round %d)" % (va, ra, vb, rb)
        if not (os.path.exists(pa) and os.path.exists(pb)):
            print("   %-44s no picture" % label)
            continue
        try:
            diff = picture_difference(pa, pb)
        except (ValueError, IndexError, struct.error) as exc:
            print("   %-44s unreadable (%s)" % (label, exc))
            continue
        if diff is None:
            print("   %-44s different sizes" % label)
            continue
        diffs[(va, ra, vb, rb)] = diff
        print("   %-44s mean %6.2f   differing %6.2f%%" % (label, diff[0], diff[1]))

    print()
    print("checks:")
    failures = 0

    def check(ok, text):
        nonlocal failures
        if ok is None:
            print("   n/a   " + text)
            return
        print("   %s  %s" % ("ok  " if ok else "FAIL", text))
        if not ok:
            failures += 1

    def flag(variant, key):
        return value(variant, key)

    for v in ("orig", "opt"):
        check((flag(v, "load.ok") or "").startswith("1"), "%s: the library loads" % v)
    for v in VARIANTS:
        check(flag(v, "done") is not None or any((r, v) in results and "done" in results[(r, v)] for r in rounds), "%s: the run reached its end" % v)
        check(flag(v, "menu.presented") == "1", "%s: the menu opened" % v)
        check(flag(v, "menu.lists_left_after_dismiss") == "0", "%s: the menu went away again" % v)
    check(flag("orig", "hook.UICollectionReusableView_has_own_didMoveToWindow") == "1",
          "orig: adds -didMoveToWindow to UICollectionReusableView, that is to every cell (this is the system-wide hook)")
    check(flag("opt", "hook.UICollectionReusableView_has_own_didMoveToWindow") == "0",
          "opt: leaves UICollectionReusableView alone")

    def alpha(variant):
        m = re.search(r"alpha=([0-9.]+)", flag(variant, "menu.list0.background") or "")
        return float(m.group(1)) if m else None

    check(alpha("none") is not None and abs(alpha("none") - 1.0) < 0.01, "none: the menu's blur is at full strength (%s)" % alpha("none"))
    check(alpha("orig") is not None and alpha("opt") is not None and abs(alpha("orig") - alpha("opt")) < 0.01 and abs(alpha("opt") - 0.5) < 0.01,
          "opt: the menu's blur is at half strength like orig's (orig %s, opt %s)" % (alpha("orig"), alpha("opt")))
    stock = num("none", "menu.list0.separators_drawing")
    check(stock is not None and stock > 0, "none: the stock menu does draw separators (%s), so the next lines mean something" % value("none", "menu.list0.separators_drawing"))
    for v in ("orig", "opt"):
        check(flag(v, "menu.list0.separators_drawing") == "0" and flag(v, "menu.after.list0.separators_drawing") == "0",
              "%s: no separator draws anything, when the menu opens and three seconds later (%s, %s)"
              % (v, flag(v, "menu.list0.separators_drawing"), flag(v, "menu.after.list0.separators_drawing")))

    def header(variant):
        for line in structures.get((first, variant), []):
            m = re.search(r"\.header bgView_hidden=(-?\d+) separator_height=(-?[0-9.]+)", line)
            if m:
                return m.group(1), float(m.group(2))
        return None

    if header("none") is None:
        check(None, "the menu's title view was not found on this iOS")
    else:
        check(header("opt") is not None and header("orig") is not None and header("opt")[0] == header("orig")[0] == "1",
              "opt: the title's own background is hidden, as with orig (orig %s, opt %s)" % (header("orig"), header("opt")))
        check(header("opt") is not None and header("orig") is not None and header("opt")[1] == header("orig")[1],
              "opt: the line under the title is as tall as with orig (orig %s, opt %s)" % (header("orig"), header("opt")))
    idle_none, idle_opt = num("none", "menu.idle3s.collection_layouts"), num("opt", "menu.idle3s.collection_layouts")
    check(None if idle_none is None or idle_opt is None else idle_opt <= idle_none + 2,
          "opt: the open menu is not laid out again and again while nothing happens (layout passes in 3 s: none %s, orig %s, opt %s)"
          % (value("none", "menu.idle3s.collection_layouts"), value("orig", "menu.idle3s.collection_layouts"), value("opt", "menu.idle3s.collection_layouts")))
    check(flag("opt", "routing.getter_same_object") == "1" and flag("orig", "routing.getter_same_object") == "0",
          "AirPlay row: opt hands out one kept view, orig a new one on every call")
    for v in ("orig", "opt"):
        check(flag(v, "routing.real_separator_draws") == "0" and flag(v, "routing.handed_out_view_draws") == "0",
              "%s: AirPlay row: neither the real separator nor the stand-in draws" % v)
        check(flag(v, "nowplaying.separator_in_view") == "0", "%s: music module: the line is taken out" % v)
        check(flag(v, "ccmenu.separator_height") == "0.0", "%s: Control Centre menu rows: separator height 0" % v)
    check(flag("none", "routing.real_separator_draws") == "1" and flag("none", "nowplaying.separator_in_view") == "1"
          and flag("none", "ccmenu.separator_height") == "1.0", "none: the stand-ins do show their separators without hooks")

    same = diffs.get(("orig", first, "opt", first))
    stock_vs_orig = diffs.get(("none", first, "orig", first))
    noise = max([d[1] for k, d in diffs.items() if k[0] == k[2]] or [0.0])
    if same is None or stock_vs_orig is None:
        check(None, "pictures: orig and opt could not be compared")
    else:
        check(stock_vs_orig[1] > 1.0, "pictures: the original visibly changes the stock menu (%.2f%% of the picture)" % stock_vs_orig[1])
        check(same[1] <= noise + 0.5, "pictures: opt looks like orig (%.2f%% differs; two runs of one variant differ by up to %.2f%%)" % (same[1], noise))

    print()
    target = ios.startswith("16.")
    if failures == 0:
        print("all checks passed on iOS %s" % ios)
    elif target:
        print("%d check(s) FAILED on iOS %s" % (failures, ios))
    else:
        print("%d check(s) failed, but this is iOS %s, not the iOS 16 the tweak is written for: for information only" % (failures, ios))
    return 1 if failures and target else 0


if __name__ == "__main__":
    sys.exit(main())
