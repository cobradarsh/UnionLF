/*  SDPStage.m — the bridge into Dynamic Stage 1.2.

    Dynamic Stage is obfuscated (class and method names like DS_lIlIIl…), so these
    names were recovered from the 1.2 binary and only match 1.2. Every call checks
    respondsToSelector: first and fails soft (a log line plus a toast), so a
    different version never crashes SpringBoard; the features just stop.

    What we know from the binary:
      • The stage card (DS_IIllIIIIIIIlllIIIIllllllIllIll) is a single view; its class
        method DS_IlIIIlIl… returns the cached instance (nil until Dynamic Stage has
        built its UI after a respring).
      • Tapping an app in Dynamic Stage's own app strip calls
            [card DS_IIlIIlIIlllIlIIIlIIIIlIlIIlIII:@{ @"app": SBApplication, @"view": iconView }]
        (the two keys are XOR-encrypted strings in the binary). That is the
        "open this app in the stage window" entry point we reuse.
      • The card's DS_lllIlIlI… property is the pane (DS_lIllllIllIIlIIlIIllllIIIIIlllI)
        hosting the app's scene; its `application` and `open` properties are plain.
      • The other window is simply the front app, so a swap is: bring the stage app
        to the front, then open the old front app in the stage.                    */

#import "SDPlus.h"

static NSString *const kCardClass  = @"DS_IIllIIIIIIIlllIIIIllllllIllIll";
static NSString *const kCardShared = @"DS_IlIIIlIllllllIIIlIIIIlIIlIIIII";
static NSString *const kCardOpen   = @"DS_IIlIIlIIlllIlIIIlIIIIlIlIIlIII";
static NSString *const kCardPane   = @"DS_lllIlIlIIlIlIlIIllllllllllIllI";
static NSString *const kPaneClass  = @"DS_lIllllIllIIlIIlIIllllIIIIIlllI";

static NSMutableDictionary<NSString *, NSNumber *> *gKillGuard;   // bundle id -> guarded until
static BOOL gBusy;                                                // a swap / pair launch is running
static CFAbsoluteTime gBusySince;
static CFAbsoluteTime gLastSwap;
static UIWindow *gOriginWindow;                                   // tiny anchor for the open animation

static inline CFAbsoluteTime SDPNow(void) { return CFAbsoluteTimeGetCurrent(); }

static void SDPAfter(double sec, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

@implementation SDPStage

#pragma mark - lookups

+ (BOOL)available {
    Class c = NSClassFromString(kCardClass);
    return c && [c respondsToSelector:NSSelectorFromString(kCardShared)]
             && [c instancesRespondToSelector:NSSelectorFromString(kCardOpen)];
}

+ (id)_card {
    if (![self available]) return nil;
    return SDPMsg(NSClassFromString(kCardClass), kCardShared);
}

+ (id)_pane {
    id pane = SDPMsg([self _card], kCardPane);
    Class pc = NSClassFromString(kPaneClass);
    if (!pane || (pc && ![pane isKindOfClass:pc])) return nil;
    return pane;
}

+ (BOOL)isOpen {
    id pane = [self _pane];
    if (![pane isKindOfClass:UIView.class]) return NO;
    SEL o = NSSelectorFromString(@"open");
    BOOL open = [pane respondsToSelector:o] ? ((BOOL (*)(id, SEL))objc_msgSend)(pane, o) : YES;
    UIView *v = pane;
    return open && v.window != nil && !v.window.hidden && v.superview != nil;
}

+ (NSString *)stageBundleID {
    id app = SDPMsg([self _pane], @"application");
    NSString *bid = SDPMsg(app, @"bundleIdentifier");
    return [bid isKindOfClass:NSString.class] && bid.length ? bid : nil;
}

+ (NSString *)diagnostics {
    id card = [self _card];
    id pane = [self _pane];
    NSString *cardFrame = [card isKindOfClass:UIView.class]
        ? NSStringFromCGRect([(UIView *)card convertRect:[(UIView *)card bounds] toView:nil]) : @"-";
    NSString *paneFrame = [pane isKindOfClass:UIView.class]
        ? NSStringFromCGRect([(UIView *)pane convertRect:[(UIView *)pane bounds] toView:nil]) : @"-";
    return [NSString stringWithFormat:@"[DS avail=%d card=%@ %@ pane=%@ %@ open=%d stageApp=%@ front=%@]",
            [self available], card ? @"yes" : @"nil", cardFrame, pane ? @"yes" : @"nil", paneFrame,
            [self isOpen], [self stageBundleID] ?: @"-", [SDPHost frontmostBundleID] ?: @"home"];
}

#pragma mark - kill guard

// Dynamic Stage can kill an app when its stage window closes (Auto Kill). During our own
// swap / pair launch the app is only moving between windows, so FBProcess kills of the
// two apps involved are skipped for a few seconds (Tweak.m hooks FBProcess).
+ (void)_guard:(NSString *)bid {
    if (bid.length == 0) return;
    if (!gKillGuard) gKillGuard = [NSMutableDictionary dictionary];
    gKillGuard[bid] = @(SDPNow() + 6.0);
}

+ (BOOL)isKillGuarded:(NSString *)bid {
    NSNumber *until = bid ? gKillGuard[bid] : nil;
    return until && until.doubleValue > SDPNow();
}

#pragma mark - busy flag

+ (BOOL)_claimBusy {
    if (gBusy && SDPNow() - gBusySince < 8.0) return NO;   // a stuck flag clears itself
    gBusy = YES; gBusySince = SDPNow();
    return YES;
}

+ (void)_releaseBusyAfter:(double)sec { SDPAfter(sec, ^{ gBusy = NO; }); }

#pragma mark - open in stage

// The strip passes its icon view so the stage can grow out of it. We pass a small clear
// view at the bottom centre (or over the old stage window when swapping).
+ (UIView *)_originViewAt:(CGRect)rect {
    CGRect screen = UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(rect)) rect = CGRectMake(screen.size.width / 2 - 30, screen.size.height - 120, 60, 60);
    if (!gOriginWindow) {
        UIWindowScene *scene = [SDPHost mainScene];
        gOriginWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:screen];
        gOriginWindow.frame = screen;
        gOriginWindow.windowLevel = 1;                       // underneath everything that matters
        gOriginWindow.backgroundColor = UIColor.clearColor;
        gOriginWindow.userInteractionEnabled = NO;
        gOriginWindow.rootViewController = [UIViewController new];
        gOriginWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
    }
    for (UIView *v in gOriginWindow.rootViewController.view.subviews) [v removeFromSuperview];
    UIView *anchor = [[UIView alloc] initWithFrame:rect];
    anchor.backgroundColor = UIColor.clearColor;
    [gOriginWindow.rootViewController.view addSubview:anchor];
    gOriginWindow.hidden = NO;
    SDPAfter(3.0, ^{ gOriginWindow.hidden = YES; });
    return anchor;
}

+ (BOOL)_openInStage:(NSString *)bid from:(CGRect)originRect {
    if (![self available]) {
        SDPLog(@"openInStage(%@): Dynamic Stage 1.2 classes not found", bid);
        return NO;
    }
    id card = [self _card];
    if (!card) {
        SDPLog(@"openInStage(%@): Dynamic Stage hasn't built its stage yet %@", bid, [self diagnostics]);
        return NO;
    }
    id app = [SDPHost applicationForBundleID:bid];
    if (!app) { SDPLog(@"openInStage(%@): no SBApplication", bid); return NO; }
    UIView *origin = [self _originViewAt:originRect];
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(card, NSSelectorFromString(kCardOpen), @{ @"app": app, @"view": origin });
    } @catch (NSException *e) {
        SDPLog(@"openInStage(%@) threw %@: %@", bid, e.name, e.reason);
        return NO;
    }
    SDPLog(@"openInStage(%@) called", bid);
    return YES;
}

+ (BOOL)openInStage:(NSString *)bid { return [self _openInStage:bid from:CGRectZero]; }

// Poll until `bid` is the front app (or time runs out), then call back on the main queue.
+ (void)_waitForFront:(NSString *)bid timeout:(double)timeout then:(void (^)(BOOL ok))done {
    CFAbsoluteTime start = SDPNow();
    __block void (^tick)(void);
    __block __weak void (^weakTick)(void);
    tick = ^{
        if ([[SDPHost frontmostBundleID] isEqualToString:bid]) { done(YES); return; }
        if (SDPNow() - start > timeout) { done(NO); return; }
        void (^again)(void) = weakTick;
        if (again) SDPAfter(0.1, again);
    };
    weakTick = tick;
    SDPAfter(0.1, tick);
    // keep `tick` alive until the timeout passes
    SDPAfter(timeout + 0.5, ^{ (void)tick; });
}

#pragma mark - swap

+ (void)swapWithReason:(NSString *)why refocus:(BOOL)refocus {
    if (SDPNow() - gLastSwap < 1.5) return;                  // never ping-pong
    NSString *bottom = [self stageBundleID];
    NSString *top = [SDPHost frontmostBundleID];
    if (![self isOpen] || !bottom || !top || [top isEqualToString:bottom]) {
        SDPLog(@"swap(%@) skipped %@", why, [self diagnostics]);
        return;
    }
    if (![self _claimBusy]) return;
    gLastSwap = SDPNow();
    [self _guard:top];
    [self _guard:bottom];

    UIView *pane = [self _pane];
    CGRect paneRect = [pane isKindOfClass:UIView.class] ? [pane convertRect:pane.bounds toView:nil] : CGRectZero;
    SDPLog(@"swap(%@): top %@ <-> stage %@ %@", why, top, bottom, [self diagnostics]);

    BOOL launched = [SDPHost launchApp:bottom];
    [self _waitForFront:bottom timeout:2.5 then:^(BOOL ok) {
        SDPLog(@"swap: launch(%@)=%d front=%d %@", bottom, launched, ok, [self diagnostics]);
        SDPAfter(ok ? 0.35 : 0.05, ^{
            BOOL opened = [self _openInStage:top from:paneRect];
            if (!opened) [SDPHost toast:@"Dynamic Stage+ couldn't swap the windows."];
            if (refocus) {
                SDPAfter(0.9, ^{
                    pid_t p = [SDPHost pidForBundleID:bottom];
                    if (p > 0) SDPPost(SDP_N_REFOCUS, (uint64_t)p);
                });
            }
            SDPAfter(1.5, ^{ SDPLog(@"swap done %@", [self diagnostics]); });
            [self _releaseBusyAfter:1.2];
            gLastSwap = SDPNow();
        });
    }];
}

+ (void)engagementFromPid:(pid_t)pid typing:(BOOL)typing {
    SDPSettings *s = [SDPSettings shared];
    if (!s.enabled || s.swapMode == SDPSwapOff) return;
    if (s.swapMode == SDPSwapTyping && !typing) return;
    if (gBusy || SDPNow() - gLastSwap < 2.0) return;
    NSString *stage = [self stageBundleID];
    if (!stage || ![self isOpen]) return;
    pid_t stagePid = [SDPHost pidForBundleID:stage];
    NSString *who = [SDPHost bundleIDForPid:pid];
    BOOL fromStage = (stagePid > 0 && stagePid == pid) || [who isEqualToString:stage];
    if (!fromStage) return;
    [self swapWithReason:(typing ? @"typing" : @"touch") refocus:(typing && s.refocusAfterSwap)];
}

#pragma mark - app pairs

+ (void)launchPairTop:(NSString *)top bottom:(NSString *)bottom {
    if (top.length == 0 || bottom.length == 0) return;
    if (![self available]) {
        [SDPHost toast:@"App Pairs need Dynamic Stage 1.2."];
        SDPLog(@"pair: Dynamic Stage 1.2 not found");
        return;
    }
    if (![self _claimBusy]) return;
    [self _guard:top];
    [self _guard:bottom];
    SDPLog(@"pair: top %@ + stage %@ %@", top, bottom, [self diagnostics]);

    void (^openBottom)(void) = ^{
        if ([self isOpen] && [[self stageBundleID] isEqualToString:bottom]) {
            SDPLog(@"pair: %@ already in the stage", bottom);
        } else if (![self openInStage:bottom]) {
            [SDPHost toast:@"Couldn't open the second app. Open Dynamic Stage once after a respring, then try again."];
        }
        SDPAfter(1.5, ^{ SDPLog(@"pair done %@", [self diagnostics]); });
        [self _releaseBusyAfter:1.0];
    };

    if ([[SDPHost frontmostBundleID] isEqualToString:top]) { openBottom(); return; }
    BOOL launched = [SDPHost launchApp:top];
    [self _waitForFront:top timeout:4.0 then:^(BOOL ok) {
        SDPLog(@"pair: launch(%@)=%d front=%d", top, launched, ok);
        if (!ok) {
            [SDPHost toast:[NSString stringWithFormat:@"%@ didn't open.", [SDPHost displayNameForBundleID:top]]];
            [self _releaseBusyAfter:0.1];
            return;
        }
        SDPAfter(0.6, openBottom);   // let the app settle before the stage opens over it
    }];
}

@end
