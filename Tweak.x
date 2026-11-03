/*  Tweak.x — Wingman Plus entry point (SpringBoard only).

    No logos code-injection directive here on purpose: one drags in CydiaSubstrate
    headers the RootHide Linux toolchain doesn't ship. We don't need it — a plain
    constructor plus the app-launch notification is enough to start the bubble
    once SpringBoard's UI is up. The dylib is only ever loaded into SpringBoard
    (WingmanPlus.plist), never into a dating app.                              */

#import "WPlus.h"
#import <AudioToolbox/AudioToolbox.h>

static NSTimer *gVisTimer;

// DIAG: an unmistakable "the dylib loaded" signal that depends on NEITHER files
// NOR windowing — the phone vibrates and beeps. If you feel/hear this on respring,
// the tweak is loading into SpringBoard; the problem is then only the UI.
static void WPLoadSignal(void) {
    @try {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        AudioServicesPlaySystemSound(1007); // a short notification tone
    } @catch (__unused id e) {}
}

static void WPStart(void) {
    if (gVisTimer) return;                                   // already running
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"(nil)";
    // DIAG: prove WPStart actually ran, and in which process. If this file says
    // com.apple.springboard, the bubble code below executed and any remaining
    // "nothing shows" is purely windowing (handled by the scene attach in WPBubble).
    @try {
        [[NSString stringWithFormat:@"WPStart ran in %@ at %@\n", bid, [NSDate date]]
            writeToFile:@"/var/mobile/wingmanplus_started.txt" atomically:YES
               encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused id e) {}
    if (![bid isEqualToString:@"com.apple.springboard"]) return;
    WPLoadSignal(); // buzz + beep (best-effort; AudioServices is often silent in SpringBoard)
    @try {
        [[WPBubble shared] start];
        gVisTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { [[WPBubble shared] evaluateVisibility]; } @catch (__unused id e) {}
        }];
    } @catch (__unused id e) {}
}

// DIAG: write the marker to SEVERAL paths, because on RootHide NSHomeDirectory() and
// /var/mobile may be redirected and the file can land where you don't look.
static void WPWriteLoadMarker(void) {
    NSString *line = [NSString stringWithFormat:@"WingmanPlus loaded at %@\n", [NSDate date]];
    for (NSString *dir in @[NSHomeDirectory(), @"/var/mobile", NSTemporaryDirectory(), @"/var/tmp"]) {
        @try {
            [line writeToFile:[dir stringByAppendingPathComponent:@"wingmanplus_loaded.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (__unused id e) {}
    }
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
