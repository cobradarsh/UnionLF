/*  Tweak.m — Chakra's entry point. Loads into SpringBoard only.

    Nothing is hooked. The constructor only arranges for Chakra to start a few seconds after
    SpringBoard is up; everything else happens on the main thread from notifications:

      com.adarsh.chakra/prefs                    a switch was flipped under Settings → Chakra
      com.apple.springboard.lockstate            locked / unlocked: the ball leaves the lock screen
      com.apple.springboard.hasBlankedScreen     screen off: the menu closes and the tick stops
      SpringBoard's active-orientation observer  the app in front turned: icons turn with it

    plus a slow tick (every 2 s, only while the screen is on) that notes which app is in front,
    for "Last App", and catches any lock or orientation change that came without a notification.

    Start-up guard: Chakra counts SpringBoard starts in <log dir>/Chakra.boot and clears the
    count once it has been running for 25 s. Four starts in a row that never got that far mean
    something is restarting SpringBoard right after launch, so Chakra stays out of the way until
    one of its settings is changed.                                                           */

#import "Chakra.h"

static NSTimer *gTick;
static BOOL gStarted, gHeld;

#pragma mark - start-up guard

static NSString *ChakraBootPath(void) { return [ChakraLogDir() stringByAppendingPathComponent:@"Chakra.boot"]; }

static NSInteger ChakraBootCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:ChakraBootPath() encoding:NSUTF8StringEncoding error:nil];
    return MAX(0, s.integerValue);
}

static void ChakraSetBootCount(NSInteger n) {
    [[NSString stringWithFormat:@"%ld\n", (long)n] writeToFile:ChakraBootPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - events

static void ChakraTick(void) {
    @try {
        [ChakraHost noteFront];
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

static void ChakraBegin(NSInteger attempt) {
    if (gStarted) return;
    if (!UIApplication.sharedApplication || ![ChakraHost mainScene]) {
        if (attempt < 90) ChakraAfter(1.0, ^{ ChakraBegin(attempt + 1); });
        else ChakraLog(@"gave up: SpringBoard never showed a main scene");
        return;
    }
    gStarted = YES;
    [[ChakraSettings shared] reload];
    CGSize sz = [ChakraHost screenSize];
    UIEdgeInsets safe = [ChakraHost safeInsets];
    ChakraLog(@"Chakra %@ started: iOS %@, screen %.0fx%.0f (safe %.0f/%.0f), %lu entries on the wheel, enabled=%d",
          CHAKRA_VERSION, UIDevice.currentDevice.systemVersion, sz.width, sz.height, safe.top, safe.bottom,
          (unsigned long)[ChakraItems visible].count, (int)[ChakraSettings shared].enabled);
    ChakraLog(@"%@", [ChakraActions report]);

    static ChakraOrientationWatcher *watcher;
    watcher = [ChakraOrientationWatcher new];
    if (!ChakraSendObj(UIApplication.sharedApplication, @"addActiveOrientationObserver:", watcher))
        ChakraLog(@"no orientation observer on this iOS: the tick covers it");

    int token = 0;
    notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) {
        ChakraLockChanged();
        ChakraAfter(0.7, ^{ ChakraLockChanged(); });           // the lock screen is still on its way in or out
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
    [[ChakraBall shared] refresh];
    ChakraDebugStart();
}

static void ChakraBoot(void) {
    [[ChakraSettings shared] reload];
    int token = 0;
    notify_register_dispatch(CHAKRA_N_PREFS, &token, dispatch_get_main_queue(), ^(int t) {
        if (gHeld) {                                    // the way back in after the start-up guard stepped in
            gHeld = NO;
            ChakraSetBootCount(0);
            [[ChakraSettings shared] reload];
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

    NSInteger starts = ChakraBootCount();
    if (starts >= 4) {
        gHeld = YES;
        ChakraLog(@"standing by: SpringBoard has restarted %ld times in a row right after Chakra started. "
               "Change any setting under Settings → Chakra to start it again.", (long)starts);
        return;
    }
    ChakraSetBootCount(starts + 1);
    ChakraAfter(3.0, ^{ ChakraBegin(0); });
    ChakraAfter(25.0, ^{ if (gStarted) ChakraSetBootCount(0); });
}

__attribute__((constructor)) static void ChakraInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { ChakraBoot(); } @catch (NSException *e) { NSLog(@"[Chakra] start threw %@", e.reason); }
        });
    }
}
