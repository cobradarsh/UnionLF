/*  WPCapture.m — grab the whole screen from inside SpringBoard.

    This is the Snapper 3 technique. UIKit has a private C function that renders
    the live display (including the foreground app) into a UIImage. We resolve it
    at RUNTIME with dlsym so a wrong prototype can never fail to link or crash
    SpringBoard — if the symbol isn't there we simply return nil and report it.

    Two spellings exist across iOS versions; we try the rotation variant first
    (what Snapper imports) and fall back to the no-argument one. Passing 0 is a
    safe "no rotation" either way under the arm64 calling convention.

    OWNERSHIP: both functions follow the Core Foundation "Create" rule and hand back
    a UIImage the caller already owns (+1). ARC can't know that for a dlsym'd C
    function, so typing them as returning UIImage * made it retain the result again,
    and every capture leaked one full-screen image (14 MB or more). Scroll-capture
    probes ~3 times a second, so SpringBoard passed its memory limit within a minute
    and iOS killed it: the "crash + respring". They're typed void * now and the +1
    is handed to ARC with __bridge_transfer, so each shot is freed once it's used.  */

#import "WPlus.h"
#import <dlfcn.h>

typedef void *(*WPScreenRotFn)(long);   // _UICreateScreenUIImageWithRotation, returns +1
typedef void *(*WPScreenFn)(void);      // _UICreateScreenUIImage, returns +1

// Frames are kept (up to 12 per capture) and OCR'd inside SpringBoard, so they're stored
// at most this tall instead of the native 2796 px. Claude only reads 1568 px anyway, and
// Vision still reads chat text easily at this size.
static const CGFloat kWPFrameMaxLongEdge = 1900;

@implementation WPCapture

+ (UIImage *)_rawScreen {
    static WPScreenRotFn rotFn; static WPScreenFn plainFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rotFn   = (WPScreenRotFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImageWithRotation");
        plainFn = (WPScreenFn)  dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    });
    void *owned = NULL;
    @try {
        if (rotFn)        owned = rotFn(0);
        else if (plainFn) owned = plainFn();
    } @catch (__unused id e) { owned = NULL; }
    return (__bridge_transfer UIImage *)owned;   // ARC takes over the +1 and releases it
}

// The private API can hand back a UIImage that isn't a plain CGImage bitmap
// (wide-gamut / IOSurface backing). Vision OCR and UIImageJPEGRepresentation both
// reject that, so replies failed with "couldn't read the chat" even though a shot
// was taken. Re-draw it into a standard opaque bitmap so OCR and JPEG always work.
+ (UIImage *)_normalize:(UIImage *)raw {
    if (!raw) return nil;
    CGSize sz = raw.size;
    if ((sz.width < 1 || sz.height < 1) && raw.CGImage)
        sz = CGSizeMake(CGImageGetWidth(raw.CGImage), CGImageGetHeight(raw.CGImage));
    if (sz.width < 1 || sz.height < 1) return raw;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    // The default format renders 16-bit wide colour on this screen: 8 bytes a pixel, ~29 MB
    // for a full 3x frame. 8-bit sRGB at the capped size is ~6.5 MB and reads the same.
    fmt.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    CGFloat scale = raw.scale > 0 ? raw.scale : [UIScreen mainScreen].scale;
    CGFloat longPx = MAX(sz.width, sz.height) * scale;
    if (longPx > kWPFrameMaxLongEdge) scale *= kWPFrameMaxLongEdge / longPx;
    fmt.scale = scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *norm = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [raw drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    }];
    return (norm && norm.CGImage) ? norm : raw;
}

+ (UIImage *)captureScreenHiding:(void(^)(void))hide restore:(void(^)(void))show {
    if (hide) hide();
    // Let the hide land on screen before we snapshot, so the bubble isn't in it.
    // We're already on the main thread; spin the runloop briefly instead of an
    // async hop so the caller gets the image back synchronously.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
    UIImage *shot = nil;
    @autoreleasepool { shot = [self _normalize:[self _rawScreen]]; }   // full-size original freed here
    if (show) show();
    return shot;
}

// Capture without toggling any overlay.
+ (UIImage *)captureNow {
    UIImage *shot = nil;
    @autoreleasepool { shot = [self _normalize:[self _rawScreen]]; }
    return shot;
}

// Scroll-capture probes the screen ~3 times a second only to see whether it moved, so the
// probe fingerprints the raw shot directly instead of building a full frame every time.
+ (NSData *)probeSignature {
    NSData *sig = nil;
    @autoreleasepool { sig = [self signatureOf:[self _rawScreen]]; }
    return sig;
}

// A tiny grayscale fingerprint so we can tell when the screen stopped changing
// (profile reached the bottom, so a swipe no longer moves it).
+ (NSData *)signatureOf:(UIImage *)img {
    if (!img) return nil;
    const int W = 24, H = 48;
    uint8_t *buf = calloc((size_t)(W * H), 1);
    if (!buf) return nil;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W, gray, (CGBitmapInfo)kCGImageAlphaNone);
    NSData *d = nil;
    if (ctx) {
        // Draw through UIKit so raw (IOSurface-backed) shots, which may have no CGImage, and
        // finished frames fingerprint the same way. Flipped to UIKit's top-left origin.
        CGContextTranslateCTM(ctx, 0, H);
        CGContextScaleCTM(ctx, 1, -1);
        UIGraphicsPushContext(ctx);
        [img drawInRect:CGRectMake(0, 0, W, H)];
        UIGraphicsPopContext();
        d = [NSData dataWithBytes:buf length:(NSUInteger)(W * H)];
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(gray);
    free(buf);
    return d;
}

+ (BOOL)signature:(NSData *)a matches:(NSData *)b {
    if (!a || !b || a.length != b.length || a.length == 0) return NO;
    const uint8_t *pa = a.bytes, *pb = b.bytes;
    NSUInteger diff = 0, n = a.length;
    for (NSUInteger i = 0; i < n; i++) if (abs((int)pa[i] - (int)pb[i]) > 12) diff++;
    return diff < n / 20;   // <5% of cells changed => effectively the same screen
}

@end

#pragma mark - scroll-capture judge

/*  Decides, probe by probe, when a hold-and-scroll capture should keep a frame.

    The old rule was "the screen held still for two probes and isn't the screen kept last". A VIDEO broke it: a clip
    that changes a little all the time keeps passing that test without the page moving at all, so one screen was kept
    over and over until the frame limit, and the limit ended the capture in the middle of the profile.

    The judge works on the rows of the 24 x 48 fingerprint instead of the whole screen at once:
      - rows that change when a lot of the screen changes are page content; rows that never do are the app's bars;
      - a detailed content row that still shows exactly what the last kept frame showed proves the page has not
        scrolled, whatever a video next to it is doing (a scroll moves every row of the page);
      - with a video playing the screen never holds still, so "at rest" also means: a few content rows have stopped.
    Where nothing can be proven (a video filling the view) it keeps a frame now and then instead of none.            */

enum { kSigW = 24, kSigH = 48, kSigTol = 12 };
// Only the middle rows count as proof. The top and bottom belong to bars (status, title, tabs, typing box), which
// look the same wherever the page is scrolled.
enum { kProofTop = 8, kProofEnd = 41 };
enum {
    kMoveRows  = 10,   // this many rows changing between two probes = "a lot of the screen changed"
    kRestRows  = 3,    // this many content rows holding still = at rest, even while a video plays
    kProofRows = 4,    // this many content rows identical to the kept frame = the same place
    kNewRows   = 4,    // (video playing) this many still rows that differ from the kept frame = a new place
};
static const NSTimeInterval kForcedWaitMin = 2.5, kForcedWaitMax = 10.0, kPinnedWait = 6.0;

// Cells of row r that differ between a and b. Masked cells (the bubble, the hint) never count.
static int WPRowDiff(const uint8_t *a, const uint8_t *b, const uint8_t *m, int r) {
    int n = 0, o = r * kSigW;
    for (int c = 0; c < kSigW; c++)
        if (!(m && m[o + c]) && abs((int)a[o + c] - (int)b[o + c]) > kSigTol) n++;
    return n;
}

// A row with detail in it (a photo, text). A blank row looks the same wherever the page is, so it proves nothing.
static BOOL WPRowRich(const uint8_t *a, const uint8_t *m, int r) {
    int n = 0, o = r * kSigW;
    for (int c = 0; c + 1 < kSigW; c++) {
        if (m && (m[o + c] || m[o + c + 1])) continue;
        if (abs((int)a[o + c] - (int)a[o + c + 1]) > kSigTol) n++;
    }
    return n >= 3;
}

// Differing cells over the whole screen; *counted gets how many cells were compared.
static int WPSigDiff(const uint8_t *a, const uint8_t *b, const uint8_t *m, int *counted) {
    int diff = 0, n = 0;
    for (int i = 0; i < kSigW * kSigH; i++) {
        if (m && m[i]) continue;
        n++;
        if (abs((int)a[i] - (int)b[i]) > kSigTol) diff++;
    }
    if (counted) *counted = n;
    return diff;
}

// Under 5% of the cells changed: effectively the same screen (the test scroll-capture always used).
static BOOL WPSigAlike(const uint8_t *a, const uint8_t *b, const uint8_t *m) {
    int n = 0, diff = WPSigDiff(a, b, m, &n);
    return diff * 20 < n;
}

@implementation WPScrollJudge {
    NSData *_prev, *_prev2;            // the last two probes
    NSData *_ref;                      // the screen kept last (or, at the frame limit, last judged)
    CFAbsoluteTime _refTime;
    NSMutableArray<NSData *> *_kept;   // fingerprints of the kept frames, in the frames' order
    uint8_t _content[kSigH];           // 2 = not seen moving yet (taken as content), 1 = moves with the page, 0 = doesn't
    BOOL _shared[kSigH];               // rows the pending probe has in common with _ref
    BOOL _moved;                       // the screen visibly changed since _ref
    NSTimeInterval _forcedWait;        // gap before the next "nothing can be proven" frame; doubles each time
    CFAbsoluteTime _unrestSince;       // when the screen last stopped being at rest (0 = it is at rest)
    NSData *_pending, *_pendingMask;   // the probe wantsFrame said yes to, until settleKept:
    BOOL _pendingForced;
}

- (instancetype)initWithFirst:(NSData *)first now:(CFAbsoluteTime)now {
    if ((self = [super init])) {
        _kept = [NSMutableArray array];
        if (first.length == kSigW * kSigH) { [_kept addObject:first]; _ref = first; }
        _refTime = now;
        memset(_content, 2, sizeof(_content));
        _forcedWait = kForcedWaitMin;
    }
    return self;
}

- (BOOL)wantsFrame:(NSData *)probe mask:(NSData *)mask now:(CFAbsoluteTime)now {
    _pending = nil; _pendingMask = nil;
    if (probe.length != kSigW * kSigH) return NO;
    NSData *prev = _prev, *prev2 = _prev2, *ref = _ref;   // held so their bytes stay valid below
    _prev2 = prev; _prev = probe;                         // the history moves on whatever the verdict
    if (!prev) return NO;
    const uint8_t *m  = (mask.length == probe.length) ? mask.bytes : NULL;
    const uint8_t *c  = probe.bytes, *p = prev.bytes;
    const uint8_t *pp = prev2 ? prev2.bytes : NULL, *s = ref ? ref.bytes : NULL;

    // Which rows changed since the last probe. When a lot did, those rows are page content, and a row that was
    // only assumed to be content and sat still through it is not.
    BOOL changed[kSigH]; int nChanged = 0;
    for (int r = 0; r < kSigH; r++) { changed[r] = WPRowDiff(c, p, m, r) > 1; if (changed[r]) nChanged++; }
    if (nChanged >= kMoveRows)
        for (int r = 0; r < kSigH; r++) {
            if (changed[r]) _content[r] = 1;
            else if (_content[r] == 2) _content[r] = 0;
        }
    BOOL stable = WPSigAlike(c, p, m);
    if (!stable) _moved = YES;

    // Evidence rows: detailed content rows that are holding still. On a still screen that is all of them; with a
    // video playing, the ones unchanged across the last two probe pairs.
    int evidence = 0, same = 0;
    memset(_shared, 0, sizeof(_shared));
    for (int r = kProofTop; r < kProofEnd; r++) {
        if (!_content[r] || !WPRowRich(c, m, r)) continue;
        if (!stable && !(pp && !changed[r] && WPRowDiff(p, pp, m, r) <= 1)) continue;
        evidence++;
        if (s && WPRowDiff(c, s, m, r) <= 1) { same++; _shared[r] = YES; }
    }

    BOOL proven  = same >= kProofRows;                    // the page is where the kept frame left it
    BOOL atRest  = stable || evidence >= kRestRows;
    BOOL differs = !s || !WPSigAlike(c, s, m);
    if (atRest) _unrestSince = 0;
    else if (_unrestSince == 0) _unrestSince = now;
    BOOL isNew   = stable ? differs : (evidence - same) >= kNewRows;
    BOOL want = NO, forced = NO;
    if (_moved || !s) {
        NSTimeInterval waited = now - _refTime;
        if (atRest && isNew && !proven) want = YES;
        // Nothing has held still for a while and nothing proves the place (a video fills the view): keep one
        // now and then. An ordinary flick is over long before this.
        else if (!atRest && !proven && differs && MIN(waited, now - _unrestSince) >= _forcedWait) want = forced = YES;
        // "Same place" says a minority of rows while the rest moved on: rows pinned to the screen. Never block for good.
        else if (atRest && isNew && proven && same * 2 < evidence && waited >= kPinnedWait) want = forced = YES;
    }
    if (want) { _pending = probe; _pendingMask = mask; _pendingForced = forced; }
    return want;
}

// Content rows two fingerprints have in common, detail for detail.
- (int)_sharedRows:(NSData *)a with:(NSData *)b mask:(const uint8_t *)m {
    if (a.length != kSigW * kSigH || b.length != a.length) return 0;
    const uint8_t *pa = a.bytes, *pb = b.bytes;
    int n = 0;
    for (int r = kProofTop; r < kProofEnd; r++)
        if (_content[r] && WPRowRich(pa, m, r) && WPRowDiff(pa, pb, m, r) <= 1) n++;
    return n;
}

- (NSInteger)frameToReplace {
    NSData *cur = _pending;
    NSUInteger n = _kept.count;
    if (!cur || n < 2) return NSNotFound;
    const uint8_t *m = (_pendingMask.length == cur.length) ? _pendingMask.bytes : NULL;
    // A repeat of the screen kept last: leave the new one out.
    if ([self _sharedRows:cur with:_kept[n - 1] mask:m] >= kProofRows) return NSNotFound;
    // Two kept frames of one place (a video was playing there): the later one makes room.
    for (NSUInteger i = 1; i < n; i++)
        if ([self _sharedRows:_kept[i] with:_kept[i - 1] mask:m] >= kProofRows) return (NSInteger)i;
    // Otherwise the two most alike neighbours, the new frame included.
    int best = WPSigDiff(cur.bytes, _kept[n - 1].bytes, m, NULL);
    NSInteger idx = NSNotFound;
    for (NSUInteger i = 1; i < n; i++) {
        int d = WPSigDiff(_kept[i].bytes, _kept[i - 1].bytes, m, NULL);
        if (d < best) { best = d; idx = (NSInteger)i; }
    }
    return idx;
}

- (void)settleKept:(BOOL)kept replacing:(NSInteger)idx now:(CFAbsoluteTime)now {
    NSData *cur = _pending;
    if (!cur) return;
    if (kept) {
        if (idx != NSNotFound && idx >= 0 && (NSUInteger)idx < _kept.count) [_kept removeObjectAtIndex:(NSUInteger)idx];
        [_kept addObject:cur];
    }
    if (_pendingForced) {
        _forcedWait = MIN(_forcedWait * 2, kForcedWaitMax);
    } else {
        // Two different places had these rows in common, so they don't move with the page.
        for (int r = 0; r < kSigH; r++) if (_shared[r]) _content[r] = 0;
        _forcedWait = kForcedWaitMin;
    }
    _ref = cur; _refTime = now; _moved = NO;
    _pending = nil; _pendingMask = nil;
}

@end
