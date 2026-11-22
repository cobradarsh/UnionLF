/*  AtelierLayout.m — where the tiles go. Arithmetic only; tools/layout_check.py repeats it in
    Python for the phone's screen and a few others and checks nothing overlaps or leaves the screen.

    Every app keeps the size of the whole screen and its tile is a scaled picture of it, so the
    main tile always has the screen's proportions:

      Side    The main against the right edge; five mini places in a column on the left. The
              column is exactly as tall as the main (first mini's top = the main's top, last
              mini's bottom = the main's bottom). The main is as large as the room between the
              two bands allows, but never so wide that a mini could not show its whole app
              (0.785 on the phone); the minis take the width that is left, showing the top of
              their app when that is wider than the whole app would be.
      Top     Five mini places across the top, the row exactly as wide as the main, each showing
              the upper part of its app; the main below, as large as fits.
      Split   Two tiles next to each other, their widths set by `split`.

    Two bands frame the tiles. The top band (index numbers, clock, market flags, shortcut apps)
    starts under the safe area, so nothing sits under the Dynamic Island: four rows in Side
    (two index lines, the clock with the shortcuts, the flags with the "..." pill above the
    main), two compact lines in Top and Split. The dock (toggles and the credit line) ends where
    the Home indicator's area begins; how tall it is depends on what it shows, so the bench
    passes its height in. A swipe up that starts in the dock or below it closes the bench
    (`closeStrip`).

    All five mini places are always worked out; the bench draws apps in the first `miniCount`,
    a "+" in the next and faint outlines in the rest, so the column keeps its length.

    `resize` (apps laid out at the size of their tile) has no Settings switch; see the README.  */

#import "Atelier.h"

static const CGFloat kMargin = 10, kGap = 8, kGrab = 26;

CGFloat AtelierBandHeight(BOOL compact, BOOL indices) {
    // Side: index lines 2 x 14, clock 28, flags 22.  Compact: index line 16, clock line 30.
    return compact ? (indices ? 16 : 0) + 30 : (indices ? 28 : 0) + 28 + 22;
}

AtelierGeometry AtelierLayoutCompute(AtelierLayoutKind kind, CGSize screen, UIEdgeInsets safe, NSInteger apps,
                                     double split, BOOL resize, double sideScale, BOOL indices, CGFloat dockHeight) {
    AtelierGeometry g;
    memset(&g, 0, sizeof(g));
    CGFloat W = screen.width, H = screen.height;
    CGFloat top = safe.top + 4;
    CGFloat bottom = H - MAX(safe.bottom, 12);
    apps = MAX(0, MIN(ATELIER_MAX_SLOTS, apps));
    NSInteger minis = MAX(0, apps - 1);
    g.sceneSize = screen;

    g.bandCompact = (kind != AtelierLayoutSide);
    CGFloat bandH = AtelierBandHeight(g.bandCompact, indices);
    g.band = CGRectMake(kMargin, top, W - 2 * kMargin, bandH);
    dockHeight = MAX(0, dockHeight);
    g.dock = CGRectMake(kMargin, bottom - dockHeight, W - 2 * kMargin, dockHeight);
    g.closeStrip = CGRectMake(0, g.dock.origin.y, W, H - g.dock.origin.y);
    CGFloat floorY = g.dock.origin.y - (dockHeight > 0 ? 4 : 0);        // the tiles end here

    if (kind == AtelierLayoutSplit) {
        CGFloat t = top + bandH + 2 + kGrab, availH = floorY - t;
        double p = MAX(0.3, MIN(0.7, split));
        if (resize) {
            CGFloat gapH = 30, w = W - 2 * kMargin;
            CGFloat h1 = round((availH - gapH) * p), h2 = availH - gapH - h1;
            g.main = CGRectMake(kMargin, t, w, h1);
            g.second = CGRectMake(kMargin, t + h1 + gapH, w, h2);
            g.divider = CGRectMake(W / 2.0 - 44, t + h1, 88, gapH);
            g.grabber2 = CGRectMake(W - kMargin - 64, t + h1 + 4, 64, 22);
            g.sceneSize = g.main.size;
        } else {
            CGFloat gapW = 16, total = W - 2 * kMargin - gapW;
            CGFloat w1 = round(total * p), w2 = total - w1;
            CGFloat h1 = round(H * w1 / W), h2 = round(H * w2 / W);
            if (h1 > availH) { h1 = availH; w1 = round(W * h1 / H); }
            if (h2 > availH) { h2 = availH; w2 = round(W * h2 / H); }
            g.main = CGRectMake(kMargin, t + floor((availH - h1) / 2.0), w1, h1);
            g.second = CGRectMake(W - kMargin - w2, t + floor((availH - h2) / 2.0), w2, h2);
            g.divider = CGRectMake(CGRectGetMaxX(g.main) + (gapW - 28) / 2.0, t + availH / 2.0 - 44, 28, 88);
            g.grabber2 = CGRectMake(CGRectGetMidX(g.second) - 32, g.second.origin.y - 24, 64, 22);
        }
        g.grabber = CGRectMake(CGRectGetMidX(g.main) - 32, g.main.origin.y - 24, 64, 22);
        if (apps < 2) {                                   // room for one more: the second place is the "+"
            g.plus = g.second;
            g.second = CGRectZero;
            g.grabber2 = CGRectZero;
            g.divider = CGRectZero;
        }
        if (apps == 0) { g.plus = g.main; g.main = CGRectZero; g.grabber = CGRectZero; }
        g.miniCount = 0;
        return g;
    }

    if (kind == AtelierLayoutTop) {
        CGFloat rowTop = top + bandH + 6;
        CGFloat tileW = 58, tileH = 70, mainTop = 0, availH = 0;
        if (resize) {
            tileW = (W - 2 * kMargin - 4 * kGap) / 5.0;
            tileH = round(tileW * 1.22);
            mainTop = rowTop + tileH + kGrab + 2;
            availH = floorY - mainTop;
            g.main = CGRectMake(kMargin, mainTop, W - 2 * kMargin, availH);
            g.sceneSize = g.main.size;
            tileH = MIN(tileH, round(tileW * g.sceneSize.height / g.sceneSize.width));
        } else {
            // the row is as wide as the main, and the main is as tall as the row leaves room for:
            // a few passes settle it
            CGFloat s = 0.7, w = 0;
            for (int pass = 0; pass < 3; pass++) {
                mainTop = rowTop + tileH + kGrab + 2;
                availH = floorY - mainTop;
                s = MIN(availH / H, (W - 2 * kMargin) / W);
                w = round(W * s);
                tileW = (w - 4 * kGap) / 5.0;
                if (pass < 2) tileH = round(tileW * 1.22);
            }
            g.main = CGRectMake(floor((W - w) / 2.0), mainTop, w, MIN(round(H * s), availH));
        }
        for (NSInteger i = 0; i < 5; i++) g.minis[i] = CGRectMake(g.main.origin.x + i * (tileW + kGap), rowTop, tileW, tileH);
    } else {
        CGFloat paneTop = top + bandH + 3, availH = floorY - paneTop;
        CGFloat tileW, tileH, columnX;
        if (resize) {
            tileW = round(W * 0.135);
            CGFloat x = kMargin + tileW + kGap;
            g.main = CGRectMake(x, paneTop, W - x - kMargin, availH);
            g.sceneSize = g.main.size;
            columnX = kMargin;
        } else {
            // the widest the main may be: the scale at which five minis as wide as the room
            // beside it, each showing the whole app, are together exactly as tall as the main
            CGFloat s = (W - 2 * kMargin - kGap + 0.8 * kGap * W / H) / (1.2 * W);
            s = MIN(MIN(s, sideScale), availH / H);
            CGFloat w = round(W * s), h = MIN(round(H * s), availH);
            g.main = CGRectMake(W - kMargin - w, paneTop, w, h);
            // the minis take the room beside it, up to a third wider than the whole app needs
            CGFloat whole = (h - 4 * kGap) / 5.0 * W / H;
            tileW = MIN(g.main.origin.x - kGap - kMargin, round(whole * 1.34));
            columnX = g.main.origin.x - kGap - tileW;
        }
        tileH = (g.main.size.height - 4 * kGap) / 5.0;
        for (NSInteger i = 0; i < 5; i++) g.minis[i] = CGRectMake(columnX, g.main.origin.y + i * (tileH + kGap), tileW, tileH);
    }
    g.miniCount = minis;
    if (apps >= 1 && apps < ATELIER_MAX_SLOTS) g.plus = g.minis[minis];
    g.grabber = CGRectMake(CGRectGetMidX(g.main) - 32, g.main.origin.y - 24, 64, 22);
    if (apps == 0) {                                      // an empty bench: one big "+"
        g.plus = g.main;
        g.main = CGRectZero;
        g.grabber = CGRectZero;
    }
    return g;
}
