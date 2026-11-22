/*  Tweak.m — the entry point of Shani. Loads into SpringBoard only.

    Shani (Saturn, the slow one) keeps an app's notifications waiting. Every notification gets
    a "Shani" button, behind a swipe to the left and among the actions when it is held down, on
    the Lock Screen too. Tap it and the app goes on Shani's list; from then on its notifications
    are kept back for the time set in Settings → Shani and come up when the time is over.

    The constructor reads the settings, puts the hooks in (ShaniHooks.m) and starts the engine:
    SpringBoard hands out every stored notification while it starts, and the ones that are being
    held must be caught again then. Nothing of SpringBoard's is touched at that point; the hooks
    are method replacements on classes, and they only act when a notification passes.

    Afterwards everything is driven by events:

      a notification is posted, changed, taken back         ShaniHooks.m → ShaniEngine
      com.adarsh.shani/prefs       a setting changed in Settings → Shani (also the list of apps)
      com.adarsh.shani/release     "Show Held Notifications Now" in Settings
      a timer at the end of the nearest hold                (one timer; none when nothing is held)
      com.apple.springboard.hasBlankedScreen                the screen came on: anything overdue comes up

    Start-up guard: each start adds one to <log dir>/Shani.boot, and the file is cleared once
    SpringBoard has been up for 25 s. Three starts in a row that never got that far mean
    SpringBoard keeps restarting right after Shani comes up, so on the fourth Shani puts no
    hook in and holds nothing until one of its settings is changed.                            */

#import "Shani.h"
#import <notify.h>
#import <unistd.h>

static BOOL gHooked, gStoodDown;

#pragma mark - start-up guard

static NSString *ShaniBootPath(void) { return [ShaniLogDir() stringByAppendingPathComponent:@"Shani.boot"]; }

static NSInteger ShaniBootCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:ShaniBootPath() encoding:NSUTF8StringEncoding error:nil];
    return MAX(0, s.integerValue);
}

static void ShaniSetBootCount(NSInteger n) {
    [[NSString stringWithFormat:@"%ld\n", (long)n] writeToFile:ShaniBootPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL ShaniGuardOn(void) {
#if TARGET_OS_SIMULATOR
    if (getenv("SHANI_NO_GUARD")) return NO;             // the simulator test wants to see every start
#endif
    return YES;
}

#pragma mark - events

static void ShaniPrefsChanged(void) {
    [[ShaniSettings shared] reload];
    if (gStoodDown) {
        // any change in Settings → Shani means "try again": the hooks go in at the next respring
        ShaniSetBootCount(0);
        ShaniLog(@"a setting changed: Shani will start again at the next respring");
        return;
    }
    if (!gHooked) return;
    [[ShaniEngine shared] settingsChanged];
    ShaniDebugStart();
}

static void ShaniReleaseAsked(void) {
    if (!gHooked) return;
    CFStringRef dom = (__bridge CFStringRef)SHANI_DOMAIN;
    CFPreferencesAppSynchronize(dom);
    NSString *which = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("releaseApp"), dom));
    if ([which isKindOfClass:NSString.class] && which.length) [[ShaniEngine shared] releaseApp:which reason:@"asked in Settings"];
    else [[ShaniEngine shared] releaseEverything:@"asked in Settings"];
}

static void ShaniListen(const char *name, dispatch_block_t block) {
    int token = 0;
    notify_register_dispatch(name, &token, dispatch_get_main_queue(), ^(__unused int t) {
        @try { block(); } @catch (NSException *e) { ShaniLog(@"%s handler threw %@", name, e.reason); }
    });
}

#pragma mark - start

__attribute__((constructor)) static void ShaniInit(void) {
    @autoreleasepool {
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundle isEqualToString:@"com.apple.springboard"]) return;

        ShaniSettings *settings = [ShaniSettings shared];
        [settings reload];
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        NSInteger boots = ShaniGuardOn() ? ShaniBootCount() : 0;
        ShaniLog(@"Shani %@ in SpringBoard (pid %d), iOS %ld.%ld.%ld, start %ld since the last good one", SHANI_VERSION, (int)getpid(),
                 (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion, (long)boots + 1);

        ShaniListen(SHANI_NOTE_PREFS, ^{ ShaniPrefsChanged(); });

        if (ShaniGuardOn() && boots >= 3) {
            gStoodDown = YES;
            ShaniLog(@"SpringBoard restarted right after the last three starts: Shani stays out of the way. Change any setting under Settings → Shani to start it again.");
            ShaniLogFlush();
            return;
        }
        if (ShaniGuardOn()) ShaniSetBootCount(boots + 1);
        ShaniLogFlush();

        if (v.majorVersion < 15) {
            ShaniLog(@"this iOS is older than Shani knows: nothing is hooked");
            return;
        }
        @try {
            gHooked = ShaniInstallUIHooks();
            if (gHooked) [[ShaniEngine shared] start];
        } @catch (NSException *e) {
            ShaniLog(@"start threw %@", e.reason);
        }
        ShaniLog(@"started: %@", gHooked ? @"watching notifications" : @"NOT hooked");
        ShaniLogFlush();

        ShaniListen(SHANI_NOTE_RELEASE, ^{ ShaniReleaseAsked(); });
        ShaniListen("com.apple.springboard.hasBlankedScreen", ^{ if (gHooked) [[ShaniEngine shared] releaseDue]; });
        ShaniListen("com.apple.springboard.finishedstartup", ^{
            ShaniLog(@"SpringBoard finished starting");
            ShaniAfter(25.0, ^{
                if (ShaniGuardOn()) ShaniSetBootCount(0);
                ShaniLog(@"up for 25 s: start-up guard cleared · %@", [[ShaniEngine shared] debugState]);
            });
        });
        // the test command file is looked at once SpringBoard has a run loop going
        dispatch_async(dispatch_get_main_queue(), ^{ ShaniDebugStart(); });
#if TARGET_OS_SIMULATOR
        // the simulator's SpringBoard may have finished starting before the library came in
        ShaniAfter(20.0, ^{ if (ShaniGuardOn()) ShaniSetBootCount(0); });
#endif
    }
}
