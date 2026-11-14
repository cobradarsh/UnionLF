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

SDPTune gSDPTune = { .settle = 0.6, .openOldTop = YES, .guardKills = NO, .guardPairs = NO,
                     .revealTo = 0.68, .revealFrames = 18, .swapStyle = 2,
                     .revealHold = 0, .revealEndGap = 1, .revealReset = 0.05, .revealShouldBegin = YES,
                     .fitFrac = 0.5365, .fitDelay = 0.7, .revealViewMode = 1, .revealCleanup = YES };

// Dynamic Stage's "relaunch with frame" singleton (DS_IIlIIIlIl…: settings, bundle id, frame).
// At the end of its own swipe, block sub_95e44 stores the top-window frame for the front app here
// and relaunches it; Dynamic Stage's scene hooks then give the relaunched app that frame.
static NSString *const kRelaunchClass = @"DS_IIlIIIlIlllIlIllIIIIIIlIlllIlI";
static NSString *const kRelaunchPrime = @"DS_llIllIlllllIlllIlllIIllIIIIIIl:withFrame:";
static NSString *const kRelaunchBid   = @"DS_IlIlllIllIlllIIllIIIlIlllIIIIl";
static NSString *const kRelaunchFrame = @"DS_IIlIIIllIIIIIllIlIIIlIllIIlIIl";

static NSString *const kGestureView  = @"DS_lIlIIlIIlllIllllIllllllIlIIIIl";  // the bottom-edge gesture view
static NSString *const kGestureEntry = @"DS_lIllIlllIllIIIllllIIlllIllIIII:"; // its gesture action (any recognizer)

// A recognizer that reports a scripted swipe. Dynamic Stage's handler only reads
// state, locationInView: and view from the recognizer it is given.
@interface SDPFakeSwipe : UIPanGestureRecognizer
@property (nonatomic) UIGestureRecognizerState fakeState;
@property (nonatomic) CGPoint fakePoint;                 // screen coordinates
@property (nonatomic, weak) UIView *fakeView;
@end

@implementation SDPFakeSwipe
- (UIGestureRecognizerState)state { return _fakeState; }
- (UIView *)view { return _fakeView; }
- (NSUInteger)numberOfTouches { return 1; }
- (CGPoint)locationInView:(UIView *)v {
    if (!v || !v.window) return _fakePoint;
    CGPoint inWindow = [v.window convertPoint:_fakePoint fromWindow:nil];
    return [v convertPoint:inWindow fromView:nil];
}
- (CGPoint)translationInView:(UIView *)v { return CGPointZero; }
- (CGPoint)velocityInView:(UIView *)v { return CGPointMake(0, -1200); }
@end

static SDPFakeSwipe *gLastSwipe;   // kept alive: Dynamic Stage holds on to the recognizer it is given

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

#pragma mark - reveal (synthetic swipe-up)

static UIView *SDPFindView(UIView *v, Class c, int depth) {
    if ([v isKindOfClass:c]) return v;
    if (depth > 14) return nil;
    for (UIView *s in v.subviews) { UIView *r = SDPFindView(s, c, depth + 1); if (r) return r; }
    return nil;
}

+ (UIView *)_gestureView {
    static __weak UIView *cached;
    if (cached.window) return cached;
    Class gc = NSClassFromString(kGestureView);
    if (!gc) return nil;
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) [wins addObjectsFromArray:((UIWindowScene *)s).windows];
    for (UIWindow *w in [UIApplication.sharedApplication windows]) if (![wins containsObject:w]) [wins addObject:w];
    for (UIWindow *w in wins) {
        UIView *v = SDPFindView(w, gc, 0);
        if (v) { cached = v; return v; }
    }
    return nil;
}

// Replays a short swipe up from the bottom edge into Dynamic Stage's own gesture handler:
// with an app waiting in the (hidden) stage card, that's exactly how you bring it back.
+ (BOOL)revealStage {
    UIView *gv = [self _gestureView];
    SEL entry = NSSelectorFromString(kGestureEntry);
    if (!gv || ![gv respondsToSelector:entry]) { SDPLog(@"reveal: gesture view not found"); return NO; }
    CGRect s = UIScreen.mainScreen.bounds;
    SDPFakeSwipe *g = [[SDPFakeSwipe alloc] initWithTarget:nil action:NULL];
    // SpringBoard's own pull recognizer lives on a full-screen view, and Dynamic Stage's "finger
    // lifted" maths compares the finger with half that view's height, so report a full-screen view.
    UIView *reported = gv;
    if (gSDPTune.revealViewMode == 1 && gv.window) reported = gv.window;
    else if (gSDPTune.revealViewMode == 2 && gv.superview) reported = gv.superview;
    g.fakeView = reported;
    SDPLog(@"reveal: gesture view %@ reports %@ %@", NSStringFromCGRect([gv convertRect:gv.bounds toView:nil]),
           NSStringFromClass([reported class]), NSStringFromCGRect(reported.bounds));
    CGFloat x = s.size.width / 2, y0 = s.size.height - 6, y1 = s.size.height * MAX(0.2, MIN(0.95, gSDPTune.revealTo));
    int frames = MAX(3, MIN(90, gSDPTune.revealFrames));
    // Dynamic Stage's stage window records where the finger is (touchLocation, set from its hit
    // testing on real touches); its "finger lifted" logic reads it. A synthetic swipe has no
    // touches, so keep it in step with the scripted finger.
    UIWindow *stageWindow = gv.window;
    SEL setTouch = NSSelectorFromString(@"setTouchLocation:");
    BOOL feedTouch = [stageWindow respondsToSelector:setTouch];
    void (^send)(UIGestureRecognizerState, CGFloat) = ^(UIGestureRecognizerState st, CGFloat y) {
        g.fakeState = st;
        g.fakePoint = CGPointMake(x, y);
        if (feedTouch) {
            CGPoint p = [stageWindow convertPoint:CGPointMake(x, y) fromWindow:nil];
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(stageWindow, setTouch, p);
        }
        @try { ((void (*)(id, SEL, id))objc_msgSend)(gv, entry, g); }
        @catch (NSException *e) { SDPLog(@"reveal threw %@", e.reason); }
    };
    int hold = MAX(0, MIN(60, gSDPTune.revealHold)), gap = MAX(1, MIN(30, gSDPTune.revealEndGap));
    double reset = gSDPTune.revealReset;
    gLastSwipe = g;
    SDPLog(@"reveal: swipe %.0f -> %.0f, %d frames + hold %d + gap %d, reset %.2f %@",
           y0, y1, frames, hold, gap, reset, [self diagnostics]);
    // Dynamic Stage's hook on SpringBoard's pull gesture asks this first; it records the start
    // point and resets the flags the "finger lifted" branch relies on.
    g.fakeState = UIGestureRecognizerStatePossible;
    g.fakePoint = CGPointMake(x, y0);
    if (gSDPTune.revealShouldBegin && [gv respondsToSelector:@selector(gestureRecognizerShouldBegin:)]) {
        BOOL ok = NO;
        @try { ok = [(id<UIGestureRecognizerDelegate>)gv gestureRecognizerShouldBegin:g]; }
        @catch (NSException *e) { SDPLog(@"reveal: shouldBegin threw %@", e.reason); }
        SDPLog(@"reveal: gestureRecognizerShouldBegin -> %d", ok);
    }
    send(UIGestureRecognizerStateBegan, y0);
    __block int i = 0;
    // one event per display frame, like a real finger: move, hold still, lift on its own frame
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
        i++;
        if (i <= frames) {
            double p = (double)i / frames, e = 1 - (1 - p) * (1 - p);      // ease out
            send(UIGestureRecognizerStateChanged, y0 + (y1 - y0) * MIN(1.0, e));
            return;
        }
        if (i <= frames + hold) { send(UIGestureRecognizerStateChanged, y1); return; }
        if (i < frames + hold + gap) return;                                // finger still down, no event
        send(UIGestureRecognizerStateEnded, y1);
        [t invalidate];
        if (reset >= 0) SDPAfter(reset, ^{ g.fakeState = UIGestureRecognizerStatePossible; });
        SDPAfter(1.5, ^{ SDPLog(@"reveal done %@", [self diagnostics]); });
    }];
    return YES;
}

+ (id)lastSwipe { return gLastSwipe; }

+ (NSString *)relaunchInfo {
    id ri = SDPMsg(NSClassFromString(kRelaunchClass), @"sharedInstance");
    SEL fs = NSSelectorFromString(kRelaunchFrame);
    CGRect f = [ri respondsToSelector:fs] ? ((CGRect (*)(id, SEL))objc_msgSend)(ri, fs) : CGRectZero;
    return [NSString stringWithFormat:@"relaunch{bid=%@ frame=%@}", SDPMsg(ri, kRelaunchBid) ?: @"-", NSStringFromCGRect(f)];
}

// What Dynamic Stage does when its own swipe finishes: remember the top-window frame for the
// front app, then relaunch it so the frame is applied (no kill: a running app just refreshes).
+ (void)fitTopApp:(NSString *)bid {
    if (bid.length == 0) return;
    id ri = SDPMsg(NSClassFromString(kRelaunchClass), @"sharedInstance");
    SEL prime = NSSelectorFromString(kRelaunchPrime);
    if (![ri respondsToSelector:prime]) { SDPLog(@"fit: relaunch singleton not found"); return; }
    CGRect s = UIScreen.mainScreen.bounds;
    CGRect f = CGRectMake(0, 0, s.size.width, round(s.size.height * MAX(0.2, MIN(0.9, gSDPTune.fitFrac))));
    @try { ((void (*)(id, SEL, id, CGRect))objc_msgSend)(ri, prime, bid, f); }
    @catch (NSException *e) { SDPLog(@"fit threw %@", e.reason); return; }
    BOOL launched = [SDPHost launchApp:bid];
    SDPLog(@"fit %@ to %@ launch=%d %@", bid, NSStringFromCGRect(f), launched, [self relaunchInfo]);
}

+ (id)debugTarget:(NSString *)name {
    if ([name isEqualToString:@"gv"])     return [self _gestureView];
    if ([name isEqualToString:@"card"])   return [self _card];
    if ([name isEqualToString:@"pane"])   return [self _pane];
    if ([name isEqualToString:@"mgr"])    return SDPMsg(NSClassFromString(@"DS_IIIlIIllllIlllIlllllIlIIIIlIIl"), @"sharedInstance");
    if ([name isEqualToString:@"helper"]) return SDPMsg(NSClassFromString(kHelperClass), @"sharedInstance");
    Class c = NSClassFromString(name);
    return c;                                                   // a class name: call a class method
}

static void SDPCollectViews(UIView *v, Class c, NSMutableArray *out, int depth) {
    if ([v isKindOfClass:c]) [out addObject:v];
    if (depth > 16) return;
    for (UIView *s in v.subviews) SDPCollectViews(s, c, out, depth + 1);
}

+ (NSArray<UIView *> *)_allViewsOfClass:(NSString *)name {
    Class c = NSClassFromString(name);
    NSMutableArray *out = [NSMutableArray array];
    if (!c) return out;
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) [wins addObjectsFromArray:((UIWindowScene *)s).windows];
    for (UIWindow *w in [UIApplication.sharedApplication windows]) if (![wins containsObject:w]) [wins addObject:w];
    for (UIWindow *w in wins) SDPCollectViews(w, c, out, 0);
    return out;
}

// What Dynamic Stage's finish would do to the card: drop the background blur, clear the drag
// tint, spring the card back from its slight "held" scale, and stop the gesture's frame loop.
+ (void)finishCard {
    UIView *card = [self _card];
    if (![card isKindOfClass:UIView.class] || ![self isOpen]) return;
    NSMutableArray *did = [NSMutableArray array];
    for (UIView *host in [self _allViewsOfClass:@"_TtC12DynamicStage15SwiftUIViewHost"]) {
        if ([host respondsToSelector:NSSelectorFromString(@"unBlurView")]) {
            ((void (*)(id, SEL))objc_msgSend)(host, NSSelectorFromString(@"unBlurView"));
            [did addObject:@"unblur"];
        }
    }
    UIView *tint = SDPMsg(card, @"tintView");
    if ([tint isKindOfClass:UIView.class]) { tint.backgroundColor = UIColor.clearColor; [did addObject:@"tint"]; }
    NSMutableArray<UIView *> *scaled = [NSMutableArray array];
    for (UIView *v = card; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        CGAffineTransform t = v.transform;
        if (!CGAffineTransformIsIdentity(t) && fabs(t.b) < 0.001 && fabs(t.c) < 0.001 && t.a > 0.8 && t.a < 0.999)
            [scaled addObject:v];
    }
    if (scaled.count) [did addObject:[NSString stringWithFormat:@"unscale x%lu", (unsigned long)scaled.count]];
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.3 options:0 animations:^{
        for (UIView *v in scaled) v.transform = CGAffineTransformIdentity;
        if (card.alpha < 1) card.alpha = 1;
    } completion:nil];
    UIView *gv = [self _gestureView];
    if ([gv respondsToSelector:NSSelectorFromString(@"pauseDisplayLink")]) {
        ((void (*)(id, SEL))objc_msgSend)(gv, NSSelectorFromString(@"pauseDisplayLink"));
        [did addObject:@"pause"];
    }
    SDPLog(@"finishCard: %@ %@", [did componentsJoinedByString:@","], [self diagnostics]);
}

+ (void)stopGesture {
    UIView *gv = [self _gestureView];
    SEL stop = NSSelectorFromString(@"stop");
    if ([gv respondsToSelector:stop]) ((void (*)(id, SEL))objc_msgSend)(gv, stop);
    SDPLog(@"gesture stop -> %@", gv ? @"called" : @"no gesture view");
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
    if (gSDPTune.swapStyle == 0) { [self _swapKeepingStageTop:top bottom:bottom why:why refocus:refocus]; return; }
    if (gSDPTune.swapStyle == 2) { [self _swapByExpandTop:top bottom:bottom why:why refocus:refocus]; return; }
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

// Swap the way you would by hand: Dynamic Stage's own expand brings the stage app to the front
// (its stage window closes, the old top app goes to the background but stays alive), then the
// old top app is opened in the stage while it's in the background (the case its app strip
// handles, so its window connects), then the stage is revealed and the new top app fitted.
+ (void)_swapByExpandTop:(NSString *)top bottom:(NSString *)bottom why:(NSString *)why refocus:(BOOL)refocus {
    SDPLog(@"swap(%@, expand): top %@ <-> stage %@ %@", why, top, bottom, [self diagnostics]);
    CGRect paneRect = [self stageFrame];
    if (![self nativeExpand]) [SDPHost launchApp:bottom];
    [self _waitForFront:bottom timeout:3.0 then:^(BOOL front) {
        [self _waitUntil:^BOOL { return ![self isOpen]; } timeout:2.0 then:^(BOOL closed) {
            SDPAfter(gSDPTune.settle, ^{
                SDPLog(@"swap: %@ in front=%d stage closed=%d %@", bottom, front, closed, [self diagnostics]);
                if (![self _openInStage:top from:paneRect]) {
                    [SDPHost toast:@"Dynamic Stage+ couldn't swap the windows."];
                    [self _releaseBusyAfter:0.2];
                    return;
                }
                SDPAfter(0.5, ^{
                    if (![self isOpen]) [self revealStage];
                    SDPAfter(0.35 + gSDPTune.fitDelay, ^{
                        [self fitTopApp:bottom];
                        SDPAfter(0.5, ^{ if (gSDPTune.revealCleanup) [self finishCard]; });
                    });
                    if (refocus) {
                        SDPAfter(1.8, ^{
                            pid_t p = [SDPHost pidForBundleID:bottom];
                            if (p > 0) SDPPost(SDP_N_REFOCUS, (uint64_t)p);
                        });
                    }
                    SDPAfter(2.5, ^{ SDPLog(@"swap done %@", [self diagnostics]); });
                    [self _releaseBusyAfter:2.2];
                    gLastSwap = SDPNow();
                });
            });
        }];
    }];
}

// The swap that works with Dynamic Stage 1.2 (tested on the phone):
//   1. open the top app in the (visible) stage window: Dynamic Stage swaps the pane over
//      (and would kill the old stage app, so that kill is skipped: it's about to go on top),
//   2. bring the old stage app to the front: Dynamic Stage hides its stage window, as it
//      does on any app switch, but keeps the new pane in it,
//   3. replay a swipe-up so Dynamic Stage shows the stage window again and lays both out.
+ (void)_swapKeepingStageTop:(NSString *)top bottom:(NSString *)bottom why:(NSString *)why refocus:(BOOL)refocus {
    [self _guard:bottom];
    SDPLog(@"swap(%@): top %@ <-> stage %@ %@", why, top, bottom, [self diagnostics]);
    if (![self _openInStage:top from:[self stageFrame]]) {
        [SDPHost toast:@"Dynamic Stage+ couldn't swap the windows."];
        [self _releaseBusyAfter:0.2];
        return;
    }
    SDPAfter(0.45, ^{
        [SDPHost launchApp:bottom];
        [self _waitForFront:bottom timeout:3.0 then:^(BOOL front) {
            SDPLog(@"swap: %@ in front=%d %@", bottom, front, [self diagnostics]);
            SDPAfter(gSDPTune.settle, ^{
                if (![self isOpen]) [self revealStage];
                SDPAfter(0.35 + gSDPTune.fitDelay, ^{
                    [self fitTopApp:bottom];
                    SDPAfter(0.5, ^{ if (gSDPTune.revealCleanup) [self finishCard]; });
                });
                if (refocus) {
                    SDPAfter(1.4, ^{
                        pid_t p = [SDPHost pidForBundleID:bottom];
                        if (p > 0) SDPPost(SDP_N_REFOCUS, (uint64_t)p);
                    });
                }
                SDPAfter(2.0, ^{ SDPLog(@"swap done %@", [self diagnostics]); });
                [self _releaseBusyAfter:1.8];
                gLastSwap = SDPNow();
            });
        }];
    });
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
        } else {
            SDPAfter(0.5, ^{
                if (![self isOpen]) [self revealStage];
                SDPAfter(0.35 + gSDPTune.fitDelay, ^{
                    [self fitTopApp:top];
                    SDPAfter(0.5, ^{ if (gSDPTune.revealCleanup) [self finishCard]; });
                });
            });
        }
        SDPAfter(2.5, ^{ SDPLog(@"pair done %@", [self diagnostics]); });
        [self _releaseBusyAfter:1.8];
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
