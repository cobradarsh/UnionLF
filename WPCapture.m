/*  WPCapture.m — grab the whole screen from inside SpringBoard.

    This is the Snapper 3 technique. UIKit has a private C function that renders
    the live display (including the foreground app) into a UIImage. We resolve it
    at RUNTIME with dlsym so a wrong prototype can never fail to link or crash
    SpringBoard — if the symbol isn't there we simply return nil and report it.

    Two spellings exist across iOS versions; we try the rotation variant first
    (what Snapper imports) and fall back to the no-argument one. Passing 0 is a
    safe "no rotation" either way under the arm64 calling convention.            */

#import "WPlus.h"
#import <dlfcn.h>

typedef UIImage *(*WPScreenRotFn)(long);   // _UICreateScreenUIImageWithRotation
typedef UIImage *(*WPScreenFn)(void);      // _UICreateScreenUIImage

@implementation WPCapture

+ (UIImage *)_rawScreen {
    static WPScreenRotFn rotFn; static WPScreenFn plainFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rotFn   = (WPScreenRotFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImageWithRotation");
        plainFn = (WPScreenFn)  dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    });
    UIImage *img = nil;
    @try {
        if (rotFn)        img = rotFn(0);
        else if (plainFn) img = plainFn();
    } @catch (__unused id e) { img = nil; }
    return img;
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
    fmt.scale  = raw.scale > 0 ? raw.scale : [UIScreen mainScreen].scale;
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
    UIImage *shot = [self _normalize:[self _rawScreen]];
    if (show) show();
    // DIAG: save the last capture so we can see exactly what was grabbed
    // (open /var/mobile/wingman_capture.jpg in Filza).
    @try {
        NSData *j = UIImageJPEGRepresentation(shot, 0.8);
        if (j) [j writeToFile:@"/var/mobile/wingman_capture.jpg" atomically:YES];
    } @catch (__unused id e) {}
    return shot;
}

// Capture without toggling any overlay (used by auto-scroll, where the bubble is
// already hidden for the whole run so it never appears in any frame).
+ (UIImage *)captureNow {
    UIImage *shot = [self _normalize:[self _rawScreen]];
    @try {
        NSData *j = UIImageJPEGRepresentation(shot, 0.8);
        if (j) [j writeToFile:@"/var/mobile/wingman_capture.jpg" atomically:YES];
    } @catch (__unused id e) {}
    return shot;
}

// A tiny grayscale fingerprint so we can tell when the screen stopped changing
// (profile reached the bottom, so a swipe no longer moves it).
+ (NSData *)signatureOf:(UIImage *)img {
    if (!img.CGImage) return nil;
    const int W = 24, H = 48;
    uint8_t *buf = calloc((size_t)(W * H), 1);
    if (!buf) return nil;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W, gray, (CGBitmapInfo)kCGImageAlphaNone);
    NSData *d = nil;
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img.CGImage);
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
