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

+ (UIImage *)captureScreenHiding:(void(^)(void))hide restore:(void(^)(void))show {
    if (hide) hide();
    // Let the hide land on screen before we snapshot, so the bubble isn't in it.
    // We're already on the main thread; spin the runloop briefly instead of an
    // async hop so the caller gets the image back synchronously.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
    UIImage *shot = [self _rawScreen];
    if (show) show();
    return shot;
}

@end
