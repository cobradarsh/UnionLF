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

// Frames are kept (up to 10 per capture) and OCR'd inside SpringBoard, so they're stored
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
