/*  ChakraLayout.m — where the icons go.

    Wheel
      Icons sit on rings around the ball. Angles are measured from the line that points straight
      into the screen: -90° is up along the edge, +90° is down. A ring may only use the part of
      its arc that stays on screen, so near a corner the half wheel becomes a quarter wheel on
      its own. The smallest number of rings that holds everything is used, and each ring is as
      tight as its icons allow; with only a few icons they fan out around the middle instead of
      being spread over the whole arc.

    Column
      One or two straight columns beside the ball, centred on it where there is room.

    Checked for 1 to 16 icons at five ball heights and three icon sizes with
    tools/layout_check.py (same arithmetic): icons never overlap or leave the screen.        */

#import "Chakra.h"

typedef struct { CGFloat lo, hi; BOOL ok; } ChakraSpan;

static CGFloat ChakraClamp(CGFloat v, CGFloat lo, CGFloat hi) { return MAX(lo, MIN(hi, v)); }

@implementation ChakraLayout {
    // what the input boils down to
    CGFloat _s, _hubY, _hubInset, _pitch, _yMin, _yMax;
}

// The part of a ring of radius r that an icon centre may use.
- (ChakraSpan)_spanAt:(CGFloat)r {
    ChakraSpan span = { 0, 0, NO };
    if (r <= 1) return span;
    CGFloat c = (_s / 2.0 + 6.0 - _hubInset) / r;          // keeps the icon clear of the edge the ball sits on
    if (c >= 1) return span;
    CGFloat side = (c <= 0) ? M_PI_2 : acos(c);
    CGFloat hi = MIN(asin(ChakraClamp((_yMax - _hubY) / r, -1, 1)), side);
    CGFloat lo = MAX(asin(ChakraClamp((_yMin - _hubY) / r, -1, 1)), -side);
    if (hi < lo) return span;
    span.lo = lo; span.hi = hi; span.ok = YES;
    return span;
}

- (NSInteger)_roomAt:(CGFloat)r {
    ChakraSpan span = [self _spanAt:r];
    if (!span.ok) return 0;
    return (NSInteger)floor((span.hi - span.lo) * r / _pitch + 1e-6) + 1;
}

+ (instancetype)layoutForCount:(NSUInteger)count input:(ChakraLayoutInput)input {
    ChakraLayout *l = [ChakraLayout new];
    l->_centers = @[];
    l->_ringRadii = @[];
    l->_plateRect = CGRectZero;
    if (count == 0 || input.icon < 1) return l;
    if (input.style == ChakraStyleColumn) [l _columnFor:count input:input];
    else [l _wheelFor:count input:input];
    return l;
}

- (void)_wheelFor:(NSUInteger)count input:(ChakraLayoutInput)input {
    CGFloat W = input.screen.width, H = input.screen.height;
    CGFloat s = input.icon;
    BOOL labels = input.labels;
    NSInteger n = (NSInteger)count;

    _s = s;
    _hubY = input.hub.y;
    _hubInset = (input.edge == ChakraEdgeLeft) ? input.hub.x : (W - input.hub.x);
    _pitch = s + (labels ? 22 : 12);                       // along a ring
    CGFloat gap = s + (labels ? 24 : 12);                  // between rings
    CGFloat cellH = s + (labels ? 18 : 0);
    _yMin = input.safe.top + 8 + s / 2.0;
    _yMax = H - input.safe.bottom - 8 - cellH + s / 2.0;
    CGFloat rMin = input.ball / 2.0 + 14 + s / 2.0;
    CGFloat rFar = W - _hubInset - s / 2.0 - 14;
    CGFloat limits[4] = { MIN(rFar, 0.46 * W), MIN(rFar, 0.62 * W), MIN(rFar, 0.80 * W), rFar };

    // the fewest rings, and for that number the tightest first ring, that hold everything
    NSInteger rings = 0, room[4] = { 0, 0, 0, 0 };
    CGFloat r1 = rMin;
    for (NSInteger tryRings = 1; tryRings <= 4 && rings == 0; tryRings++) {
        CGFloat last = limits[tryRings - 1] - (tryRings - 1) * gap;
        for (CGFloat r = rMin; r <= last + 0.01; r += 4) {
            NSInteger total = 0, each[4] = { 0, 0, 0, 0 };
            for (NSInteger j = 0; j < tryRings; j++) { each[j] = [self _roomAt:r + j * gap]; total += each[j]; }
            if (total >= n) {
                rings = tryRings; r1 = r;
                for (NSInteger j = 0; j < 4; j++) room[j] = each[j];
                break;
            }
        }
    }
    if (rings == 0) {                                      // more than fits (biggest icons, a corner): show what does
        rings = 4; r1 = rMin;
        NSInteger total = 0;
        for (NSInteger j = 0; j < 4; j++) { room[j] = [self _roomAt:r1 + j * gap]; total += room[j]; }
        n = MIN(n, total);
        if (n <= 0) return;
    }
    if (rings == 1) {                                      // a single ring reads better a little further out
        CGFloat nicer = ChakraClamp(MAX(r1, s * 2.0), r1, MAX(r1, limits[0]));
        if ([self _roomAt:nicer] >= n) { r1 = nicer; room[0] = [self _roomAt:nicer]; }
    }

    // share the icons out in proportion to each ring's room
    NSInteger total = 0, placed = 0, counts[4] = { 0, 0, 0, 0 };
    for (NSInteger j = 0; j < rings; j++) total += room[j];
    if (total <= 0) return;
    for (NSInteger j = 0; j < rings; j++) {
        counts[j] = MIN(room[j], (NSInteger)lround((double)n * room[j] / total));
        placed += counts[j];
    }
    while (placed < n) {
        NSInteger best = -1;
        for (NSInteger j = 0; j < rings; j++)
            if (room[j] - counts[j] > 0 && (best < 0 || room[j] - counts[j] > room[best] - counts[best])) best = j;
        if (best < 0) break;
        counts[best]++; placed++;
    }
    while (placed > n) {
        NSInteger worst = -1;
        double over = -1e9;
        for (NSInteger j = 0; j < rings; j++) {
            double o = counts[j] - (double)n * room[j] / total;
            if (counts[j] > 0 && o > over) { over = o; worst = j; }
        }
        if (worst < 0) break;
        counts[worst]--; placed--;
    }

    NSMutableArray<NSValue *> *centers = [NSMutableArray array];
    NSMutableArray<NSNumber *> *radii = [NSMutableArray array];
    CGFloat outer = r1;
    for (NSInteger j = 0; j < rings; j++) {
        NSInteger k = counts[j];
        if (k <= 0) continue;
        CGFloat r = r1 + j * gap;
        ChakraSpan span = [self _spanAt:r];
        if (!span.ok) continue;
        CGFloat step = (k > 1) ? MIN((span.hi - span.lo) / (k - 1), 1.3 * _pitch / r) : 0;
        CGFloat half = step * (k - 1) / 2.0;
        CGFloat middle = ChakraClamp(0, span.lo + half, MAX(span.lo + half, span.hi - half));
        for (NSInteger i = 0; i < k; i++) {
            CGFloat a = middle + (i - (k - 1) / 2.0) * step;
            CGFloat dx = _hubInset + r * cos(a);
            CGFloat x = (input.edge == ChakraEdgeLeft) ? dx : (W - dx);
            [centers addObject:[NSValue valueWithCGPoint:CGPointMake(x, _hubY + r * sin(a))]];
        }
        [radii addObject:@(r)];
        outer = r;
    }
    _centers = centers;
    _ringRadii = radii;
    _plateRadius = outer + s / 2.0 + (labels ? 28 : 14);
}

- (void)_columnFor:(NSUInteger)count input:(ChakraLayoutInput)input {
    CGFloat W = input.screen.width, H = input.screen.height;
    CGFloat s = input.icon;
    BOOL labels = input.labels;
    NSInteger n = (NSInteger)count;

    CGFloat hubInset = (input.edge == ChakraEdgeLeft) ? input.hub.x : (W - input.hub.x);
    CGFloat cellH = s + (labels ? 18 : 0);
    CGFloat rowPitch = cellH + 12;
    CGFloat colPitch = s + (labels ? 26 : 14);
    CGFloat yMin = input.safe.top + 8 + s / 2.0;
    CGFloat yMax = H - input.safe.bottom - 8 - cellH + s / 2.0;
    NSInteger maxRows = MAX(1, (NSInteger)floor((yMax - yMin) / rowPitch + 1e-6) + 1);
    NSInteger cols = (n + maxRows - 1) / maxRows;
    NSInteger maxCols = MAX(1, (NSInteger)floor((W - hubInset - input.ball / 2.0 - 16 - s - 14) / colPitch + 1e-6) + 1);
    if (cols > maxCols) { cols = maxCols; n = MIN(n, cols * maxRows); }
    NSInteger rows = (n + cols - 1) / cols;

    CGFloat blockH = (rows - 1) * rowPitch;
    CGFloat firstY = ChakraClamp(input.hub.y - blockH / 2.0, yMin, MAX(yMin, yMax - blockH));
    CGFloat firstDx = hubInset + input.ball / 2.0 + 16 + s / 2.0;

    NSMutableArray<NSValue *> *centers = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        NSInteger col = i / rows, row = i % rows;
        CGFloat dx = firstDx + col * colPitch;
        CGFloat x = (input.edge == ChakraEdgeLeft) ? dx : (W - dx);
        [centers addObject:[NSValue valueWithCGPoint:CGPointMake(x, firstY + row * rowPitch)]];
    }
    _centers = centers;
    _ringRadii = @[];
    _plateRadius = 0;

    CGFloat pad = 12;
    CGFloat nearDx = firstDx - s / 2.0 - pad - (labels ? 6 : 0);
    CGFloat farDx = firstDx + (cols - 1) * colPitch + s / 2.0 + pad + (labels ? 6 : 0);
    CGFloat top = firstY - s / 2.0 - pad;
    CGFloat bottom = firstY + blockH - s / 2.0 + cellH + pad;
    CGFloat x0 = (input.edge == ChakraEdgeLeft) ? nearDx : (W - farDx);
    _plateRect = CGRectMake(x0, top, farDx - nearDx, bottom - top);
}

@end
