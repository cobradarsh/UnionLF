/*  WPBubble.m — the floating Wingman bubble, owned by SpringBoard.

    Uses a CLASSIC UIWindow (initWithFrame:, no UIWindowScene). In SpringBoard a
    scene-based window can fail to find a usable scene; a plain high-level window
    reliably composites over whatever app is in front, the same way the volume
    HUD does, while the app underneath never sees it. The window is only
    bubble-sized, so touches outside it still reach the app.                    */

#import "WPlus.h"

// Same bubble as the Android app: a deep-night disc with a purple ring and the 🪽 glyph.
static UIColor *WPBubbleAccent(void) { return [UIColor colorWithRed:0x7C/255.0 green:0x5C/255.0 blue:0xFF/255.0 alpha:1]; }
static UIColor *WPBubbleIdle(void)   { return [UIColor colorWithRed:0x1B/255.0 green:0x1B/255.0 blue:0x26/255.0 alpha:0.93]; }

static CGFloat   const kBubbleSize = 52;
static NSString *const kPosKey     = @"com.adarsh.wingmanplus.bubblePos";
static UIWindowLevel const kBubbleLevel = 100000;   // above status bar / app
static NSTimeInterval const kScrollMaxSeconds = 90; // a forgotten scroll-capture finishes by itself

@interface WPBubble ()
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *glyph;        // the 🪽 (idle) / frame count (capturing)
@property (nonatomic) CGPoint grabOffset;
@property (nonatomic) BOOL capturing;
@property (nonatomic) BOOL built;
@property (nonatomic) BOOL scrolling;                // scroll-capture session active
@property (nonatomic) BOOL busy;                     // re-entrancy guard for the tick
@property (nonatomic, strong) NSMutableArray<UIImage *> *scrollFrames;
@property (nonatomic, strong) NSData *lastTickSig;   // previous probe (to detect "at rest")
@property (nonatomic, strong) NSData *lastSavedSig;  // last SAVED screen (to detect "new content")
@property (nonatomic, strong) NSTimer *scrollTimer;
@property (nonatomic) CFAbsoluteTime scrollStart;    // when the scroll-capture session began
@property (nonatomic, weak) WPSheet *pendingSheet;   // set while adding screens to an open sheet
@end

@implementation WPBubble

+ (instancetype)shared {
    static WPBubble *b; static dispatch_once_t t;
    dispatch_once(&t, ^{ b = [WPBubble new]; });
    return b;
}

- (void)start { [self evaluateVisibility]; }

#pragma mark - build (classic window, no scene)

- (void)_build {
    CGRect screen = [UIScreen mainScreen].bounds;

    CGFloat x = screen.size.width - kBubbleSize - 10;
    CGFloat y = screen.size.height * 0.4;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kPosKey];
    if (saved.length) {
        CGPoint p = CGPointFromString(saved);
        if (CGRectContainsPoint(CGRectInset(screen, -2, -2), p)) { x = p.x; y = p.y; }
    }

    _window = [[UIWindow alloc] initWithFrame:CGRectMake(x, y, kBubbleSize, kBubbleSize)];
    _window.windowLevel = kBubbleLevel;
    _window.backgroundColor = UIColor.clearColor;
    _window.opaque = NO;
    _window.rootViewController = [UIViewController new];
    _window.rootViewController.view.backgroundColor = UIColor.clearColor;

    _dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kBubbleSize, kBubbleSize)];
    _dot.backgroundColor = WPBubbleIdle();
    _dot.layer.borderWidth = 2;
    _dot.layer.borderColor = WPBubbleAccent().CGColor;
    _dot.layer.cornerRadius = kBubbleSize / 2;
    _dot.layer.shadowColor = UIColor.blackColor.CGColor;
    _dot.layer.shadowOffset = CGSizeMake(0, 2);
    _dot.layer.shadowOpacity = 0.4;
    _dot.layer.shadowRadius = 5;
    [_window.rootViewController.view addSubview:_dot];

    _glyph = [[UILabel alloc] initWithFrame:_dot.bounds];
    _glyph.text = @"🪽";
    _glyph.textColor = UIColor.whiteColor;
    _glyph.font = [UIFont systemFontOfSize:24];
    _glyph.textAlignment = NSTextAlignmentCenter;
    [_dot addSubview:_glyph];

    [_dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap)]];
    [_dot addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)]];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_longPress:)];
    lp.minimumPressDuration = 0.4;   // hold = start a scroll-capture session
    [_dot addGestureRecognizer:lp];
    _built = YES;
}

#pragma mark - visibility

// On iOS 13+ a UIWindow only actually displays when it belongs to a foreground
// UIWindowScene. A bare initWithFrame: window (what 1.0.x used) stays invisible in
// SpringBoard - which is why the bubble never appeared even though the dylib loaded
// (confirmed by wingmanplus_loaded.txt). Attaching the window to the current scene
// is what makes it render.
- (UIWindowScene *)_activeScene {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

- (void)evaluateVisibility {
    // Show only over the apps that should get Wingman (dating + chat auto-detected,
    // plus anything picked in Settings); hidden on the home screen and everywhere else.
    // Stay visible during a scroll-capture session (it's in a dating app anyway).
    BOOL wanted = _scrolling || [WPHost wingmanEnabledForFrontmost];
    if (!wanted) { if (_built) _window.hidden = YES; return; }
    if (!_built) [self _build];
    // Attach to (or follow) the current foreground scene so the window renders.
    UIWindowScene *scene = [self _activeScene];
    if (scene && _window.windowScene != scene) _window.windowScene = scene;
    if (!_capturing && !_busy) _window.hidden = NO;   // don't un-hide mid clean shot
}

#pragma mark - tap -> capture -> sheet

- (void)beginAppendTo:(WPSheet *)sheet {
    _pendingSheet = sheet;
    [sheet dismissForAppend];        // hide the sheet so the user can scroll the app
    [self evaluateVisibility];       // make sure the bubble is back for the next tap
}

- (void)_tap {
    if (_capturing) return;
    if (_scrolling) { [self _finishScrollCapture]; return; }   // tap ends an active session
    _capturing = YES;
    __weak typeof(self) ws = self;
    UIImage *shot = [WPCapture captureScreenHiding:^{ ws.window.hidden = YES; }
                                           restore:^{ ws.window.hidden = NO; }];
    _capturing = NO;
    if (!shot) { [self _toast:@"Couldn't read the screen. Try again."]; return; }
    if (_pendingSheet) {
        WPSheet *sheet = _pendingSheet; _pendingSheet = nil;
        [sheet appendImage:shot];
        [sheet reshowAfterAppend];
        return;
    }
    WPSheet *sheet = [[WPSheet alloc] initWithImage:shot];
    [sheet presentGlobally];
}

#pragma mark - hold to start, flick through, tap to finish (scroll-capture)

- (void)_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (_capturing || _scrolling) return;
    [self _startScrollCapture];
}

- (void)_startScrollCapture {
    _scrolling = YES;
    _scrollStart = CFAbsoluteTimeGetCurrent();
    _scrollFrames = [NSMutableArray array];
    _lastTickSig = nil; _lastSavedSig = nil;
    [self _setRecordingLook:YES];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self _toast:@"Capturing — scroll the profile, tap 🪽 to finish."];
    // grab the starting screen right away
    __weak typeof(self) ws = self;
    UIImage *first = [WPCapture captureScreenHiding:^{ ws.window.hidden = YES; }
                                            restore:^{ ws.window.hidden = NO; }];
    if (first) { [_scrollFrames addObject:first]; _lastSavedSig = [WPCapture signatureOf:first]; }
    [self _updateCount];
    _scrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 target:self
                                                  selector:@selector(_scrollTick) userInfo:nil repeats:YES];
}

// Each tick a quick probe (bubble left visible — its few pixels don't move the change
// detector) tells us when the screen has come to REST on NEW content; only then do we
// take one clean shot (bubble hidden) and keep it. So you get one frame per resting
// position as you flick down, with almost no bubble flicker.
- (void)_scrollTick {
    if (!_scrolling || _busy) return;
    if (_scrollFrames.count >= 10) { [self _finishScrollCapture]; return; }   // safety cap
    if (CFAbsoluteTimeGetCurrent() - _scrollStart > kScrollMaxSeconds) { [self _finishScrollCapture]; return; }
    _busy = YES;
    NSData *sig = [WPCapture probeSignature];   // fingerprint only; no frame is kept for a probe
    if (sig) {
        BOOL stable = _lastTickSig && [WPCapture signature:sig matches:_lastTickSig];
        BOOL isNew  = !_lastSavedSig || ![WPCapture signature:sig matches:_lastSavedSig];
        if (stable && isNew) {
            __weak typeof(self) ws = self;
            UIImage *clean = [WPCapture captureScreenHiding:^{ ws.window.hidden = YES; }
                                                    restore:^{ ws.window.hidden = NO; }];
            if (clean) {
                [_scrollFrames addObject:clean];
                _lastSavedSig = sig;
                [self _updateCount];
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            }
        }
        _lastTickSig = sig;
    }
    _busy = NO;
}

- (void)_finishScrollCapture {
    [_scrollTimer invalidate]; _scrollTimer = nil;
    _scrolling = NO; _busy = NO;
    [self _setRecordingLook:NO];
    NSArray<UIImage *> *frames = [_scrollFrames copy]; _scrollFrames = nil;
    if (frames.count == 0) { [self _toast:@"Nothing captured. Try again."]; return; }
    WPSheet *sheet = [[WPSheet alloc] initWithImage:frames.firstObject];
    for (NSUInteger k = 1; k < frames.count; k++) [sheet appendImage:frames[k]];
    [sheet presentGlobally];
}

- (void)_setRecordingLook:(BOOL)on {
    _dot.backgroundColor = on ? WPBubbleAccent() : WPBubbleIdle();        // purple = capturing, night = idle
    _dot.layer.borderColor = (on ? UIColor.whiteColor : WPBubbleAccent()).CGColor;
    [self _updateCount];
}

- (void)_updateCount {
    if (_scrolling) {
        _glyph.text = [NSString stringWithFormat:@"%lu", (unsigned long)_scrollFrames.count];
        _glyph.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    } else {
        _glyph.text = @"🪽";
        _glyph.font = [UIFont systemFontOfSize:24];
    }
}

- (void)_toast:(NSString *)msg {
    CGRect b = [UIScreen mainScreen].bounds;
    UILabel *t = [[UILabel alloc] init];
    t.text = msg; t.textColor = UIColor.whiteColor;
    t.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    t.font = [UIFont systemFontOfSize:14]; t.textAlignment = NSTextAlignmentCenter;
    t.numberOfLines = 0; t.layer.cornerRadius = 10; t.clipsToBounds = YES;
    t.frame = CGRectMake(40, b.size.height - 160, b.size.width - 80, 44);
    UIWindowScene *scene = [self _activeScene];
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:b];
    w.frame = b;
    w.windowLevel = kBubbleLevel + 1; w.backgroundColor = UIColor.clearColor;
    w.userInteractionEnabled = NO;
    w.rootViewController = [UIViewController new];
    [w.rootViewController.view addSubview:t];
    w.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ w.hidden = YES; (void)w; });
}

#pragma mark - drag

- (void)_pan:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:_window];
    p = CGPointMake(p.x + _window.frame.origin.x, p.y + _window.frame.origin.y);
    CGRect f = _window.frame;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _grabOffset = CGPointMake(p.x - f.origin.x, p.y - f.origin.y); break;
        case UIGestureRecognizerStateChanged:
            f.origin = CGPointMake(p.x - _grabOffset.x, p.y - _grabOffset.y);
            _window.frame = f; break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: [self _snap]; break;
        default: break;
    }
}

- (void)_snap {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGRect f = _window.frame;
    CGFloat x = (CGRectGetMidX(f) < screen.size.width/2) ? 8 : screen.size.width - f.size.width - 8;
    CGFloat y = MAX(60, MIN(f.origin.y, screen.size.height - f.size.height - 80));
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                        options:0 animations:^{ self.window.frame = CGRectMake(x, y, f.size.width, f.size.height); }
                     completion:^(BOOL d) {
        [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(CGPointMake(x,y)) forKey:kPosKey];
    }];
}

@end
