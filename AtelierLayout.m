/*  AtelierLayout.m — where the tiles go. Arithmetic only; tools/layout_check.py repeats it in
    Python for the phone's screen and a few others and checks nothing overlaps or leaves the screen.

    Without "Resize apps" every app keeps the size of the whole screen and its tile is a scaled
    picture of it, so the main tile always has the screen's proportions:

      Side    main at `sideScale` (0.80) against the right edge; minis in a column on the left,
              as wide as the room that leaves, each showing the whole app
      Top     four tiles across the top showing the upper part of each app; the main below, as
              large as fits
      Split   two tiles next to each other, their widths set by `split`

    With "Resize apps" (beta) the apps are laid out at the size of the main tile instead, the
    main tile fills the room it has, and Split puts one app above the other at full width.     */

#import "Atelier.h"

static const CGFloat kMargin = 10, kGap = 8, kGrab = 26;

AtelierGeometry AtelierLayoutCompute(AtelierLayoutKind kind, CGSize screen, UIEdgeInsets safe, NSInteger apps,
                                     double split, BOOL resize, double sideScale) {
    AtelierGeometry g;
    memset(&g, 0, sizeof(g));
    CGFloat W = screen.width, H = screen.height;
    CGFloat top = safe.top + 4;
    CGFloat bottom = H - MAX(safe.bottom, 12);
    apps = MAX(0, MIN(ATELIER_MAX_SLOTS, apps));
    NSInteger minis = MAX(0, apps - 1);
    g.sceneSize = screen;

    if (kind == AtelierLayoutSplit) {
        CGFloat t = top + kGrab, availH = bottom - t;
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

    CGFloat tileW, tileH;
    if (kind == AtelierLayoutTop) {
        tileW = floor((W - 5 * kMargin) / 4.0);
        tileH = round(tileW * 1.22);
        CGFloat mainTop = top + tileH + kGrab + 2, availH = bottom - mainTop;
        if (resize) {
            g.main = CGRectMake(kMargin, mainTop, W - 2 * kMargin, availH);
            g.sceneSize = g.main.size;
        } else {
            CGFloat s = MIN(availH / H, (W - 2 * kMargin) / W);
            CGFloat w = round(W * s), h = round(H * s);
            g.main = CGRectMake(floor((W - w) / 2.0), mainTop, w, h);
        }
        tileH = MIN(tileH, round(tileW * g.sceneSize.height / g.sceneSize.width));
        for (NSInteger i = 0; i < 4; i++) {
            CGRect r = CGRectMake(kMargin + i * (tileW + kMargin), top, tileW, tileH);
            if (i < minis) g.minis[i] = r;
            else if (i == minis && apps >= 1 && apps < ATELIER_MAX_SLOTS) g.plus = r;
        }
    } else {
        CGFloat mainTop = top + kGrab, availH = bottom - mainTop;
        if (resize) {
            tileW = round(W * 0.135);
            CGFloat x = kMargin + tileW + kGap;
            g.main = CGRectMake(x, mainTop, W - x - kMargin, availH);
            g.sceneSize = g.main.size;
        } else {
            CGFloat s = MIN(MIN(sideScale, availH / H), (W - 2 * kMargin - kGap - 48) / W);
            CGFloat w = round(W * s), h = round(H * s);
            g.main = CGRectMake(W - kMargin - w, mainTop + floor((availH - h) / 2.0), w, h);
            tileW = g.main.origin.x - kGap - kMargin;
        }
        tileH = round(tileW * g.sceneSize.height / g.sceneSize.width);
        tileH = MIN(tileH, floor((g.main.size.height - 3 * kGap) / 4.0));
        CGFloat y = g.main.origin.y;
        for (NSInteger i = 0; i < 4; i++) {
            CGRect r = CGRectMake(kMargin, y, tileW, tileH);
            if (i < minis) { g.minis[i] = r; y += tileH + kGap; }
            else if (i == minis && apps >= 1 && apps < ATELIER_MAX_SLOTS) g.plus = CGRectMake(kMargin, y, tileW, tileW);
        }
    }
    g.miniCount = minis;
    g.grabber = CGRectMake(CGRectGetMidX(g.main) - 32, g.main.origin.y - 24, 64, 22);
    if (apps == 0) {                                      // an empty bench: one big "+"
        g.plus = g.main;
        g.main = CGRectZero;
        g.grabber = CGRectZero;
    }
    return g;
}
