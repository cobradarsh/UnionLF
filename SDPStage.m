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
#import <dlfcn.h>
#import <mach-o/getsect.h>
#import <malloc/malloc.h>

static NSString *const kCardClass  = @"DS_IIllIIIIIIIlllIIIIllllllIllIll";
static NSString *const kCardShared = @"DS_IlIIIlIllllllIIIlIIIIlIIlIIIII";
static NSString *const kCardOpen   = @"DS_IIlIIlIIlllIlIIIlIIIIlIlIIlIII";
static NSString *const kCardPane   = @"DS_lllIlIlIIlIlIlIIllllllllllIllI";
static NSString *const kPaneClass  = @"DS_lIllllIllIIlIIlIIllllIIIIIlllI";  // pane: .application .open .containerView
static NSString *const kPaneCurrent = @"DS_IIlIllIlIIIllllllIIlIlllIlIlII"; // +pane: the current pane
static NSString *const kPaneExpand  = @"DS_llIIIlIIlIIllIllIIIllllIIlIlll"; // -pane: bring its app to the front
static NSString *const kHelperClass = @"DS_llIIlIIIIIIlIllIllIlllIlIIllII"; // +sharedInstance (UIView)
static NSString *const kHelperPrep  = @"DS_IlllIIIIIllIllIIlIlIlIIlIIlIll"; // called right before the expand

SDPTune gSDPTune = { .settle = 0.6, .openOldTop = YES, .guardKills = NO, .guardPairs = NO };

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
    if (!open || !v.window || v.window.hidden || !v.superview) return NO;
    CGRect r = [v convertRect:v.bounds toView:nil];          // minimised = a small pill, not a window
    return r.size.width > 120 && r.size.height > 120;
}

+ (CGRect)stageFrame {
    UIView *pane = [self _pane];
    return [pane isKindOfClass:UIView.class] ? [pane convertRect:pane.bounds toView:nil] : CGRectZero;
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

// Dynamic Stage's open method doesn't use its argument. It reads a global dictionary
// @{ @"view": iconView, @"app": SBApplication } that the app strip fills right before
// calling it with nil (strip handler at 0x91f70, open reads it at 0x82934 in the 1.2 arm64e
// slice; 0xe5230 in the arm64 slice). So we fill the same global, then call open with nil.
// The slot address is checked to lie inside Dynamic Stage's own __DATA,__common.
static void **SDPSelectedAppSlot(void) {
    static void **slot;
    static BOOL looked;
    if (looked) return slot;
    looked = YES;
    Class card = NSClassFromString(kCardClass);
    Dl_info info;
    if (!card || !dladdr((__bridge const void *)card, &info) || !info.dli_fbase) return NULL;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
    unsigned long size = 0;
    uint8_t *common = getsectiondata(mh, "__DATA", "__common", &size);
#if __arm64e__
    uintptr_t off = 0xe5c10;
#else
    uintptr_t off = 0xe5230;
#endif
    uint8_t *p = (uint8_t *)mh + off;
    if (!common || p < common || p + sizeof(void *) > common + size) {
        SDPLog(@"selected-app slot 0x%lx is outside Dynamic Stage's __common (%p+0x%lx)", (unsigned long)off, common, size);
        return NULL;
    }
    slot = (void **)p;
    return slot;
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
    void **slot = SDPSelectedAppSlot();
    if (!slot) { SDPLog(@"openInStage(%@): no selected-app slot", bid); return NO; }
    void *old = *slot;
    if (old) {   // only ever replace what Dynamic Stage itself put there: a heap NSDictionary
        if (malloc_size(old) == 0 || ![(__bridge id)old isKindOfClass:NSDictionary.class]) {
            SDPLog(@"openInStage(%@): selected-app slot holds something unexpected, not touching it", bid);
            return NO;
        }
    }
    UIView *origin = [self _originViewAt:originRect];
    NSDictionary *sel = @{ @"view": origin, @"app": app };
    *slot = (__bridge_retained void *)sel;              // the global owns it, like Dynamic Stage's own store
    if (old) CFRelease(old);
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(card, NSSelectorFromString(kCardOpen), nil);
    } @catch (NSException *e) {
        SDPLog(@"openInStage(%@) threw %@: %@", bid, e.name, e.reason);
        return NO;
    }
    SDPLog(@"openInStage(%@) called", bid);
    return YES;
}

+ (BOOL)openInStage:(NSString *)bid { return [self _openInStage:bid from:CGRectZero]; }

// Poll `cond` every 0.1 s until it's true or time runs out, then call back on the main queue.
+ (void)_waitUntil:(BOOL (^)(void))cond timeout:(double)timeout then:(void (^)(BOOL ok))done {
    CFAbsoluteTime start = SDPNow();
    __block void (^tick)(void);
    __block __weak void (^weakTick)(void);
    tick = ^{
        if (cond()) { done(YES); return; }
        if (SDPNow() - start > timeout) { done(NO); return; }
        void (^again)(void) = weakTick;
        if (again) SDPAfter(0.1, again);
    };
    weakTick = tick;
    SDPAfter(0.1, tick);
    SDPAfter(timeout + 0.5, ^{ (void)tick; });   // keep `tick` alive until the timeout passes
}

+ (void)_waitForFront:(NSString *)bid timeout:(double)timeout then:(void (^)(BOOL ok))done {
    [self _waitUntil:^BOOL { return [[SDPHost frontmostBundleID] isEqualToString:bid]; } timeout:timeout then:done];
}

#pragma mark - swap

// Exactly what the end of Dynamic Stage's own drag-up gesture does (block sub_947a0 in 1.2):
//     [[DS_llIIlIII… sharedInstance] DS_IlllIIII…];
//     [[PaneClass DS_IIlIllIl…] DS_llIIIlIIlIIllIllIIIllllIIlIlll];   // bring the stage app to the front
// Dynamic Stage's own hooks then resize the apps (in iPhone launch mode by killing and
// relaunching them), so nothing may get in its way: no kill guard here by default.
+ (BOOL)nativeExpand {
    id pane = SDPMsg(NSClassFromString(kPaneClass), kPaneCurrent) ?: [self _pane];
    SEL expand = NSSelectorFromString(kPaneExpand);
    if (!pane || ![pane respondsToSelector:expand]) {
        SDPLog(@"nativeExpand: no pane / selector %@", [self diagnostics]);
        return NO;
    }
    id helper = SDPMsg(NSClassFromString(kHelperClass), @"sharedInstance");
    SEL prep = NSSelectorFromString(kHelperPrep);
    @try {
        if ([helper respondsToSelector:prep]) ((void (*)(id, SEL))objc_msgSend)(helper, prep);
        ((void (*)(id, SEL))objc_msgSend)(pane, expand);
    } @catch (NSException *e) {
        SDPLog(@"nativeExpand threw %@", e.reason);
        return NO;
    }
    return YES;
}

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
    if (gSDPTune.guardKills) { [self _guard:top]; [self _guard:bottom]; }

    UIView *pane = [self _pane];
    CGRect paneRect = [pane isKindOfClass:UIView.class] ? [pane convertRect:pane.bounds toView:nil] : CGRectZero;
    SDPLog(@"swap(%@): top %@ <-> stage %@ %@", why, top, bottom, [self diagnostics]);

    BOOL native = [self nativeExpand];
    if (!native) [SDPHost launchApp:bottom];
    SDPLog(@"swap: %@", native ? @"native expand called" : @"fallback: launched the stage app");

    // 1) the stage app reaches the front, 2) Dynamic Stage finishes reacting (closes or
    // re-fills its stage window), 3) if the old top app isn't in the stage yet, open it there.
    [self _waitForFront:bottom timeout:3.0 then:^(BOOL front) {
        SDPLog(@"swap: front=%d %@", front, [self diagnostics]);
        [self _waitUntil:^BOOL { return ![self isOpen] || ![[self stageBundleID] isEqualToString:bottom]; }
                 timeout:2.5 then:^(BOOL settled) {
            SDPAfter(gSDPTune.settle, ^{
                SDPLog(@"swap: settled=%d %@", settled, [self diagnostics]);
                if ([self isOpen] && [[self stageBundleID] isEqualToString:top]) {
                    SDPLog(@"swap: Dynamic Stage already moved %@ into the stage", top);
                } else if (gSDPTune.openOldTop) {
                    if (![self _openInStage:top from:paneRect]) [SDPHost toast:@"Dynamic Stage+ couldn't swap the windows."];
                }
                if (refocus) {
                    SDPAfter(1.2, ^{
                        pid_t p = [SDPHost pidForBundleID:bottom];
                        if (p > 0) SDPPost(SDP_N_REFOCUS, (uint64_t)p);
                    });
                }
                SDPAfter(2.0, ^{ SDPLog(@"swap done %@", [self diagnostics]); });
                [self _releaseBusyAfter:1.5];
                gLastSwap = SDPNow();
            });
        }];
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
    if (gSDPTune.guardPairs) { [self _guard:top]; [self _guard:bottom]; }
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
