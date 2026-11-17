/*  Tweak.m — Chakra's entry point. Loads into SpringBoard only.

    Nothing is hooked. The constructor only sets up listeners; Chakra starts a few seconds after
    SpringBoard reports that it has finished starting (com.apple.springboard.finishedstartup), and
    everything after that happens on the main thread from notifications:

      com.adarsh.chakra/prefs                    a switch was flipped under Settings → Chakra
      com.apple.springboard.lockstate            locked / unlocked: the ball leaves the lock screen
      com.apple.springboard.hasBlankedScreen     screen off: the menu closes and the tick stops
      SpringBoard's active-orientation observer  the app in front turned: icons turn with it

    plus a slow tick (every 2 s, only while the screen is on) that notes which app is in front,
    for "Last App", and catches any lock or orientation change that came without a notification.

    Start-up guard: each time Chakra starts it adds one to <log dir>/Chakra.boot, and clears the
    file once it has been running for 25 s. Three starts in a row that never got that far mean
    SpringBoard keeps restarting right after Chakra comes up, so on the fourth Chakra stays out
    of the way until one of its settings is changed. The start writes its steps to the log as
    it goes, so the log shows which step was the last.                                       */

#import "Chakra.h"
#import <unistd.h>

static NSTimer *gTick;
static BOOL gStarted, gHeld;
static NSString *gStartReason;

#pragma mark - start-up guard

static NSString *ChakraBootPath(void) { return [ChakraLogDir() stringByAppendingPathComponent:@"Chakra.boot"]; }

static NSInteger ChakraBootCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:ChakraBootPath() encoding:NSUTF8StringEncoding error:nil];
    return MAX(0, s.integerValue);
}

static void ChakraSetBootCount(NSInteger n) {
    [[NSString stringWithFormat:@"%ld\n", (long)n] writeToFile:ChakraBootPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL ChakraGuardOn(void) {
#if TARGET_OS_SIMULATOR
    if (getenv("CHAKRA_NO_GUARD")) return NO;           // the simulator test wants to see every start
#endif
    return YES;
}

#pragma mark - events

static void ChakraTick(void) {
    @try {
        [ChakraHost noteFront];
        [[ChakraWheel shared] closeIfFrontChanged];
        [[ChakraBall shared] refresh];
    } @catch (NSException *e) {
        ChakraLog(@"tick threw %@", e.reason);
    }
}

static void ChakraStartTick(void) {
    if (gTick) return;
    gTick = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { ChakraTick(); }];
    gTick.tolerance = 1.0;
}

static void ChakraStopTick(void) {
    [gTick invalidate];
    gTick = nil;
}

void ChakraSettingsChanged(void) {
    [[ChakraSettings shared] reload];
    [ChakraItems flushIcons];
    [ChakraItems syncPickedApps];
    if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:NO completion:nil];
    [[ChakraBall shared] refresh];
    ChakraDebugStart();
}

static void ChakraLockChanged(void) {
    BOOL locked = [ChakraHost isLocked];
    if (locked && [ChakraEditor isOpen]) [ChakraEditor dismiss];
    if (locked && ![ChakraSettings shared].lockScreen && [ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:NO completion:nil];
    [[ChakraBall shared] refresh];
}

// SpringBoard tells its orientation observers when the app in front turns.
@interface ChakraOrientationWatcher : NSObject
@end

@implementation ChakraOrientationWatcher

- (void)activeInterfaceOrientationWillChangeToOrientation:(long long)orientation {}

- (void)activeInterfaceOrientationDidChangeToOrientation:(long long)orientation
                                 willAnimateWithDuration:(double)duration
                                         fromOrientation:(long long)from {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:YES completion:nil];   // its icons were laid out for the old way up
        [[ChakraBall shared] refresh];
    });
}

@end

#pragma mark - start

// Each step of the start is in the log file before the next one begins, so if SpringBoard dies
// during the start the log says how far it got.
static void ChakraStep(NSString *what) {
    ChakraLog(@"start: %@", what);
    ChakraLogFlush();
}

static void ChakraBegin(NSInteger attempt) {
    if (gStarted || gHeld) return;
    if (!UIApplication.sharedApplication || ![ChakraHost mainScene]) {
        if (attempt < 90) ChakraAfter(1.0, ^{ ChakraBegin(attempt + 1); });
        else ChakraLog(@"gave up: SpringBoard never showed a main scene");
        return;
    }

    // The guard counts starts that got this far and then did not last 25 seconds.
    NSInteger failed = ChakraBootCount();
    if (failed >= 3 && ChakraGuardOn()) {
        gHeld = YES;
        ChakraLog(@"standing by: the last %ld times Chakra started, SpringBoard restarted within 25 seconds. "
               "Change any setting under Settings → Chakra to start it again.", (long)failed);
        ChakraLogFlush();
        return;
    }
    gStarted = YES;
    ChakraSetBootCount(failed + 1);
    ChakraAfter(25.0, ^{ ChakraSetBootCount(0); });

    [[ChakraSettings shared] reload];
    CGSize sz = [ChakraHost screenSize];
    UIEdgeInsets safe = [ChakraHost safeInsets];
    ChakraStep([NSString stringWithFormat:@"Chakra %@ in SpringBoard (pid %d), iOS %@, screen %.0fx%.0f (safe %.0f/%.0f), enabled=%d, start %ld (%@)",
                CHAKRA_VERSION, (int)getpid(), UIDevice.currentDevice.systemVersion, sz.width, sz.height, safe.top, safe.bottom,
                (int)[ChakraSettings shared].enabled, (long)(failed + 1), gStartReason ?: @"?"]);

    @try {
        static ChakraOrientationWatcher *watcher;
        watcher = [ChakraOrientationWatcher new];
        if (!ChakraSendObj(UIApplication.sharedApplication, @"addActiveOrientationObserver:", watcher))
            ChakraLog(@"no orientation observer on this iOS: the tick covers it");

        int token = 0;
        notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) {
            ChakraLockChanged();
            ChakraAfter(0.7, ^{ ChakraLockChanged(); });       // the lock screen is still on its way in or out
        });
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t blank = 0;
            notify_get_state(t, &blank);
            if (blank) {
                ChakraStopTick();
                if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:NO completion:nil];
            } else {
                ChakraStartTick();
            }
            ChakraLockChanged();
        });
        ChakraStartTick();
    } @catch (NSException *e) {
        ChakraLog(@"start: the observers threw %@", e.reason);
    }
    ChakraStep(@"observers in place, building the ball");

    @try {
        [[ChakraBall shared] refresh];
    } @catch (NSException *e) {
        ChakraLog(@"start: the ball threw %@", e.reason);
    }
    ChakraStep([[ChakraBall shared] debugState]);

    ChakraDebugStart();
    NSUInteger entries = 0;
    @try {
        [ChakraItems syncPickedApps];
        entries = [ChakraItems visible].count;
        ChakraAfter(1.5, ^{ [ChakraItems warmIcons]; });
    } @catch (NSException *e) {
        ChakraLog(@"start: the wheel's entries threw %@", e.reason);
    }
    ChakraLog(@"started: %lu entries on the wheel", (unsigned long)entries);
    ChakraLogFlush();

    // (a little later: asking which actions work touches SpringBoard's own singletons, and those
    //  should be the ones SpringBoard made for itself, not ones made early on Chakra's account)
    ChakraAfter(6.0, ^{ ChakraLog(@"%@", [ChakraActions report]); });
}

static void ChakraBoot(void) {
    [[ChakraSettings shared] reload];
    int token = 0;
    notify_register_dispatch(CHAKRA_N_PREFS, &token, dispatch_get_main_queue(), ^(int t) {
        if (gHeld) {                                    // the way back in after the start-up guard stepped in
            gHeld = NO;
            ChakraSetBootCount(0);
            ChakraLog(@"a setting changed: starting again");
            ChakraBegin(0);
            return;
        }
        if (!gStarted) return;
        ChakraSettingsChanged();
        ChakraSettings *s = [ChakraSettings shared];
        ChakraLog(@"settings: enabled=%d size=%.0f idle=%.2f tuck=%d accent=%ld style=%ld icons=%.0f labels=%d dim=%d haptics=%ld lock=%d landscape=%d",
              (int)s.enabled, s.ballSize, s.idleAlpha, (int)s.tuck, (long)s.accent, (long)s.style, s.iconSize, (int)s.labels, (int)s.dim,
              (long)s.haptics, (int)s.lockScreen, (int)s.hideLandscape);
    });

    // Chakra starts only once SpringBoard says it has finished starting, and a few seconds after
    // that. Started earlier (3 s after the library loaded, as first written) it asked SpringBoard
    // for controllers SpringBoard had not made yet, in the middle of its launch; in the simulator
    // that restarted SpringBoard five times in a row. Two fallbacks, in case the first signal
    // never comes: UIKit's own "finished launching" notice, and half a minute after loading.
    __block BOOL scheduled = NO;
    void (^go)(NSString *) = ^(NSString *why) {
        if (scheduled) return;
        scheduled = YES;
        gStartReason = why;
        ChakraAfter(4.0, ^{ ChakraBegin(0); });
    };
    notify_register_dispatch("com.apple.springboard.finishedstartup", &token, dispatch_get_main_queue(), ^(int t) {
        go(@"SpringBoard finished starting");
    });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                       queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        ChakraAfter(8.0, ^{ go(@"8 s after UIKit's launch notice"); });
    }];
    ChakraAfter(30.0, ^{ go(@"30 s after loading"); });
}

__attribute__((constructor)) static void ChakraInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        // Only listeners are set up here, before SpringBoard has started; they run on the main queue later.
        @try { ChakraBoot(); } @catch (NSException *e) { NSLog(@"[Chakra] start threw %@", e.reason); }
    }
}
