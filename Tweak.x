/*  Tweak.x — Wingman Plus entry point (SpringBoard only).

    No logos code-injection directive here on purpose: one drags in CydiaSubstrate
    headers the RootHide Linux toolchain doesn't ship. We don't need it — a plain
    constructor plus the app-launch notification is enough to start the bubble
    once SpringBoard's UI is up. The dylib is only ever loaded into SpringBoard
    (WingmanPlus.plist), never into a dating app.                              */

#import "WPlus.h"

static NSTimer *gVisTimer;

static void WPStart(void) {
    if (gVisTimer) return;                                   // already running
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if (![bid isEqualToString:@"com.apple.springboard"]) return;
    @try {
        [[WPBubble shared] start];
        gVisTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { [[WPBubble shared] evaluateVisibility]; } @catch (__unused id e) {}
        }];
    } @catch (__unused id e) {}
}

// DIAG: drop a marker the instant the dylib is injected, so we can tell
// "loaded but no UI" from "never loaded" without relying on any window.
static void WPWriteLoadMarker(void) {
    @try {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
        NSString *line = [NSString stringWithFormat:@"WingmanPlus loaded into %@ at %@\n",
                          bid, [NSDate date]];
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"wingmanplus_loaded.txt"];
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused id e) {}
}

__attribute__((constructor))
static void WPInit(void) {
    @autoreleasepool {
        WPWriteLoadMarker();
        // Start once SpringBoard finishes launching…
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WPStart(); });
        }];
        // …or, if it had already launched before we loaded, start a bit later anyway.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WPStart(); });
    }
}
