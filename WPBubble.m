/*  WPBubble.m — the floating Wingman bubble, owned by SpringBoard.

    Uses a CLASSIC UIWindow (initWithFrame:, no UIWindowScene). In SpringBoard a
    scene-based window can fail to find a usable scene; a plain high-level window
    reliably composites over whatever app is in front, the same way the volume
    HUD does, while the app underneath never sees it. The window is only
    bubble-sized, so touches outside it still reach the app.                    */

#import "WPlus.h"

static CGFloat   const kBubbleSize = 52;
static NSString *const kPosKey     = @"com.adarsh.wingmanplus.bubblePos";
static UIWindowLevel const kBubbleLevel = 100000;   // above status bar / app

@interface WPBubble ()
@property (nonatomic, strong) UIView *dot;
@property (nonatomic) CGPoint grabOffset;
@property (nonatomic) BOOL capturing;
@property (nonatomic) BOOL built;
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
    _dot.backgroundColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1.0]; // dating pink/red
    _dot.layer.cornerRadius = kBubbleSize / 2;
    _dot.layer.shadowColor = UIColor.blackColor.CGColor;
    _dot.layer.shadowOffset = CGSizeMake(0, 2);
    _dot.layer.shadowOpacity = 0.4;
    _dot.layer.shadowRadius = 5;
    [_window.rootViewController.view addSubview:_dot];

    UILabel *heart = [[UILabel alloc] initWithFrame:_dot.bounds];
    heart.text = @"♥";
    heart.textColor = UIColor.whiteColor;
    heart.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    heart.textAlignment = NSTextAlignmentCenter;
    [_dot addSubview:heart];

    [_dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap)]];
    [_dot addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)]];
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
    // DIAG (v1.0.2): force-show everywhere, even the home screen, to prove the tweak
    // loads. Normal build gates on [WPHost wingmanEnabledForFrontmost].
    BOOL wanted = YES;
    if (!wanted) { _window.hidden = YES; return; }
    if (!_built) [self _build];
    // Attach to (or follow) the current foreground scene so the window renders.
    UIWindowScene *scene = [self _activeScene];
    if (scene && _window.windowScene != scene) _window.windowScene = scene;
    if (!_capturing) _window.hidden = NO;
}

#pragma mark - tap -> capture -> sheet

- (void)beginAppendTo:(WPSheet *)sheet {
    _pendingSheet = sheet;
    [sheet dismissForAppend];        // hide the sheet so the user can scroll the app
    [self evaluateVisibility];       // make sure the bubble is back for the next tap
}

- (void)_tap {
    if (_capturing) return;
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

- (void)_toast:(NSString *)msg {
    CGRect b = [UIScreen mainScreen].bounds;
    UILabel *t = [[UILabel alloc] init];
    t.text = msg; t.textColor = UIColor.whiteColor;
    t.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    t.font = [UIFont systemFontOfSize:14]; t.textAlignment = NSTextAlignmentCenter;
    t.numberOfLines = 0; t.layer.cornerRadius = 10; t.clipsToBounds = YES;
    t.frame = CGRectMake(40, b.size.height - 160, b.size.width - 80, 44);
    UIWindow *w = [[UIWindow alloc] initWithFrame:b];
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
