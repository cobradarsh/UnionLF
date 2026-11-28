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
static NSTimeInterval const kScrollIdleSeconds = 90;  // a forgotten scroll-capture finishes this long after its last new screen
static NSTimeInterval const kScrollMaxSeconds  = 300; // ...and no session runs longer than this
static NSUInteger     const kScrollMaxFrames   = 12;  // frames kept per capture; past it the most repetitive one makes room
static NSTimeInterval const kToastSeconds      = 1.8;

// Marks the fingerprint cells (24 x 48) that `r` covers, plus one cell around it, in a probe mask.
static void WPMaskRect(uint8_t *m, CGRect r, CGSize screen) {
    if (screen.width < 1 || screen.height < 1 || CGRectIsEmpty(r)) return;
    int c0 = (int)floor(CGRectGetMinX(r) / screen.width  * 24) - 1, c1 = (int)floor(CGRectGetMaxX(r) / screen.width  * 24) + 1;
    int r0 = (int)floor(CGRectGetMinY(r) / screen.height * 48) - 1, r1 = (int)floor(CGRectGetMaxY(r) / screen.height * 48) + 1;
    for (int y = MAX(r0, 0); y <= MIN(r1, 47); y++)
        for (int x = MAX(c0, 0); x <= MIN(c1, 23); x++) m[y * 24 + x] = 1;
}

@interface WPBubble ()
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *glyph;        // the 🪽 (idle) / frame count (capturing)
@property (nonatomic) CGPoint grabOffset;
@property (nonatomic) BOOL capturing;
@property (nonatomic) BOOL built;
@property (nonatomic) BOOL scrolling;                // scroll-capture session active
@property (nonatomic) BOOL busy;                     // re-entrancy guard for the tick
@property (nonatomic, strong) NSMutableArray<UIImage *> *scrollFrames;
@property (nonatomic, strong) WPScrollJudge *judge;  // decides when the screen is worth a frame
@property (nonatomic) CFAbsoluteTime lastKeep;       // when the last frame was kept
@property (nonatomic) CFAbsoluteTime toastUntil;     // a hint is on screen until then...
@property (nonatomic) CGRect toastRect;              // ...here (kept out of the change detector)
@property (nonatomic, strong) NSTimer *scrollTimer;
@property (nonatomic) CFAbsoluteTime scrollStart;    // when the scroll-capture session began
@property (nonatomic, weak) WPSheet *pendingSheet;   // set while adding screens to an open sheet
@property (nonatomic) BOOL autoScroll;               // the bubble scrolls the profile by itself (dating apps)
@property (nonatomic) BOOL swiping;                  // one of our swipes is in flight
@property (nonatomic) NSInteger swipes;              // swipes sent this session
@property (nonatomic) NSInteger autoKept;            // frames kept after one of our swipes
@property (nonatomic) NSInteger misses;              // swipes in a row that brought nothing new
@property (nonatomic) CFAbsoluteTime swipeDone;      // when the last swipe finished (0 = none yet)
@property (nonatomic) BOOL forceAuto;                // self-test: auto-scroll whatever the app
@property (nonatomic, copy) NSString *endReason;     // why the capture ended (self-test log)
@property (nonatomic, copy) void (^testDone)(NSUInteger, NSInteger, NSString *);   // self-test: report, no sheet
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
// (confirmed by wingmanplus_loaded.txt). Attaching the window to SpringBoard's main
// scene (WPHost mainScene, the same one the sheet uses) is what makes it render.
- (void)evaluateVisibility {
    // Show only over the apps that should get Wingman (dating + chat auto-detected,
    // plus anything picked in Settings); hidden on the home screen and everywhere else.
    // Stay visible during a scroll-capture session (it's in a dating app anyway).
    BOOL wanted = _scrolling || [WPHost wingmanEnabledForFrontmost];
    if (!wanted) { if (_built) _window.hidden = YES; return; }
    if (!_built) [self _build];
    // Attach to SpringBoard's main scene so the window renders.
    UIWindowScene *scene = [WPHost mainScene];
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
    [WPScroll watchForRealTouch];        // this finger tells auto-scroll which touchscreen to speak for
    [self _startScrollCapture];
}

- (void)_startScrollCapture {
    _scrolling = YES;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    _scrollStart = now; _lastKeep = now;
    _scrollFrames = [NSMutableArray array];
    [self _setRecordingLook:YES];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    // The starting screen first and the hint after it, so the hint can't end up in the screenshot.
    __weak typeof(self) ws = self;
    UIImage *first = [WPCapture captureScreenHiding:^{ ws.window.hidden = YES; }
                                            restore:^{ ws.window.hidden = NO; }];
    if (first) [_scrollFrames addObject:first];
    _judge = [[WPScrollJudge alloc] initWithFirst:(first ? [WPCapture signatureOf:first] : nil) now:now];
    // In a dating app the bubble scrolls the profile itself; if the app doesn't move, it hands over to you.
    _autoScroll = (_forceAuto || ([WMSettings shared].autoScroll && [WMApps currentKind] == WMAppKindDating))
                  && [WPScroll available];
    _forceAuto = NO; _endReason = @"tap";
    _swiping = NO; _swipes = 0; _autoKept = 0; _misses = 0; _swipeDone = 0;
    [self _toast:_autoScroll ? @"Scrolling the profile for you. Tap 🪽 to stop."
                             : @"Capturing — scroll the profile, tap 🪽 to finish."];
    [self _updateCount];
    if (_autoScroll) {
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ws _autoSwipe];
        });
    }
    _scrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 target:self
                                                  selector:@selector(_scrollTick) userInfo:nil repeats:YES];
}

// The cells of a probe that show our own overlays (the bubble with its frame count, a hint while it is up), so
// they never count as the screen changing.
- (NSData *)_probeMask {
    NSMutableData *mask = [NSMutableData dataWithLength:24 * 48];
    CGSize screen = [UIScreen mainScreen].bounds.size;
    WPMaskRect(mask.mutableBytes, _window.frame, screen);
    if (CFAbsoluteTimeGetCurrent() < _toastUntil) WPMaskRect(mask.mutableBytes, _toastRect, screen);
    return mask;
}

// Each tick a quick probe (bubble left visible) goes to the judge, which says when the screen has come to REST
// on NEW content; only then do we take one clean shot (bubble hidden) and keep it. So you get one frame per
// resting position as you flick down, with almost no bubble flicker, and a video playing on the page neither
// repeats one screen over and over nor stops the screens after it from being kept.
- (void)_scrollTick {
    if (!_scrolling || _busy) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // Only a forgotten session ends by itself. Reaching the frame limit used to end it too: a video filled the
    // limit with repeats of one screen, and the capture stopped in the middle of the profile.
    if (now - _lastKeep > kScrollIdleSeconds || now - _scrollStart > kScrollMaxSeconds) {
        _endReason = @"idle or time limit"; [self _finishScrollCapture]; return;
    }
    if (_autoScroll) {
        if (_scrollFrames.count >= kScrollMaxFrames) {                                         // full: stop here
            _endReason = @"frame limit"; [self _finishScrollCapture]; return;
        }
        if (_swiping || _swipeDone == 0 || now - _swipeDone < 0.6) return;                    // let the page land
    }
    _busy = YES;
    NSData *sig = [WPCapture probeSignature];   // fingerprint only; no frame is kept for a probe
    if (sig && [_judge wantsFrame:sig mask:[self _probeMask] now:now]) {
        NSInteger drop = NSNotFound;
        BOOL keep = YES;
        if (_scrollFrames.count >= kScrollMaxFrames) {   // full: the most repetitive frame makes room, or this one is it
            drop = [_judge frameToReplace];
            keep = (drop != NSNotFound);
        }
        UIImage *clean = nil;
        if (keep) {
            __weak typeof(self) ws = self;
            clean = [WPCapture captureScreenHiding:^{ ws.window.hidden = YES; }
                                           restore:^{ ws.window.hidden = NO; }];
        }
        if (clean && _scrollFrames) {
            if (drop != NSNotFound && drop >= 0 && (NSUInteger)drop < _scrollFrames.count)
                [_scrollFrames removeObjectAtIndex:(NSUInteger)drop];
            [_scrollFrames addObject:clean];
            _lastKeep = now;
            if (_autoScroll && _swipeDone > 0) _autoKept++;
            [self _updateCount];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }
        if (clean || !keep) [_judge settleKept:(clean != nil) replacing:drop now:now];   // a failed shot is tried again
    }
    _busy = NO;
    if (_autoScroll && _scrolling) {
        if (_lastKeep >= _swipeDone) {                        // that swipe brought a new screen: the next one
            _misses = 0;
            if (now - _lastKeep >= 0.3) [self _autoSwipe];
        } else if (now - _swipeDone > 2.4) {                  // nothing new since the swipe
            _misses++;
            if (_autoKept == 0) [self _autoHandOver];         // never moved: this app ignores our swipes
            else if (_misses >= 2) { _endReason = @"end of the page"; [self _finishScrollCapture]; }   // the end
            else [self _autoSwipe];                           // once more (a slow page, a sticky card)
        }
    }
}

// One swipe up the middle of the screen, about two thirds of its height, with no fling: the page moves a
// fixed amount, so consecutive screens overlap a little and nothing is skipped.
- (void)_autoSwipe {
    if (!_scrolling || !_autoScroll || _swiping) return;
    _swiping = YES; _swipes++;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL sent = [WPScroll swipeFrom:CGPointMake(0.5, 0.76) to:CGPointMake(0.5, 0.12) duration:0.38 hold:0.12];
        dispatch_async(dispatch_get_main_queue(), ^{
            WPBubble *ss = ws;
            if (!ss) return;
            ss.swiping = NO;
            ss.swipeDone = CFAbsoluteTimeGetCurrent();
            if (!sent) [ss _autoHandOver];
        });
    });
}

- (void)selfTestAutoCapture:(void (^)(NSUInteger, NSInteger, NSString *))done {
    if (_capturing || _scrolling || !done) return;
    _testDone = done;
    _forceAuto = YES;
    [self _startScrollCapture];
}

// The app didn't move for our swipes: carry on as a normal hold-and-scroll capture.
- (void)_autoHandOver {
    if (!_autoScroll) return;
    _autoScroll = NO;
    if (_testDone) { _endReason = @"handed over: the page never moved"; [self _finishScrollCapture]; return; }
    [self _toast:@"This app didn't scroll by itself. Scroll it yourself, tap 🪽 to finish."];
}

- (void)_finishScrollCapture {
    [_scrollTimer invalidate]; _scrollTimer = nil;
    _scrolling = NO; _busy = NO;
    _autoScroll = NO; _swiping = NO;
    _judge = nil;
    [self _setRecordingLook:NO];
    NSArray<UIImage *> *frames = [_scrollFrames copy]; _scrollFrames = nil;
    if (_testDone) {                                     // self-test: report, keep nothing, open nothing
        void (^done)(NSUInteger, NSInteger, NSString *) = _testDone; _testDone = nil;
        done(frames.count, _swipes, _endReason ?: @"?");
        return;
    }
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
    _toastRect = t.frame;                                              // the hint, in screen points
    _toastUntil = CFAbsoluteTimeGetCurrent() + kToastSeconds + 0.5;    // a little past its removal
    UIWindowScene *scene = [WPHost mainScene];
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:b];
    w.frame = t.frame;                    // only as big as the hint: touches beside it go to the app
    t.frame = (CGRect){CGPointZero, t.frame.size};
    w.windowLevel = kBubbleLevel + 1; w.backgroundColor = UIColor.clearColor;
    w.userInteractionEnabled = NO;
    w.rootViewController = [UIViewController new];
    [w.rootViewController.view addSubview:t];
    w.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kToastSeconds*NSEC_PER_SEC)),
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
