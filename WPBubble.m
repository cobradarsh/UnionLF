/*  WPBubble.m — the floating Wingman bubble, owned by SpringBoard.

    Because this window lives in SpringBoard (not the dating app) at a very high
    window level, it composites ABOVE whatever app is in front — the same way the
    volume HUD and notifications do — while the app underneath never sees it.
    The window is only bubble-sized, so touches outside it still reach the app.  */

#import "WPlus.h"

static CGFloat   const kBubbleSize = 52;
static NSString *const kPosKey     = @"com.adarsh.wingmanplus.bubblePos";
// Above the status bar / app, below nothing that matters to us.
static UIWindowLevel const kBubbleLevel = 100000;

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

#pragma mark - build

- (void)_buildInScene:(UIWindowScene *)scene {
    CGRect screen = scene.coordinateSpace.bounds;

    _window = [[UIWindow alloc] initWithWindowScene:scene];
    _window.windowLevel = kBubbleLevel;
    _window.backgroundColor = UIColor.clearColor;
    _window.opaque = NO;
    _window.rootViewController = [UIViewController new];
    _window.rootViewController.view.backgroundColor = UIColor.clearColor;

    CGFloat x = screen.size.width - kBubbleSize - 10;
    CGFloat y = screen.size.height * 0.4;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kPosKey];
    if (saved.length) {
        CGPoint p = CGPointFromString(saved);
        if (CGRectContainsPoint(CGRectInset(screen, -2, -2), p)) { x = p.x; y = p.y; }
    }
    _window.frame = CGRectMake(x, y, kBubbleSize, kBubbleSize);

    _dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kBubbleSize, kBubbleSize)];
    _dot.backgroundColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1.0]; // dating pink/red
    _dot.layer.cornerRadius = kBubbleSize / 2;
    _dot.layer.shadowColor = UIColor.blackColor.CGColor;
    _dot.layer.shadowOffset = CGSizeMake(0, 2);
    _dot.layer.shadowOpacity = 0.4;
    _dot.layer.shadowRadius = 5;
    [_window.rootViewController.view addSubview:_dot];

    UILabel *heart = [[UILabel alloc] initWithFrame:_dot.bounds];
    heart.text = @"♥";                 // ♥
    heart.textColor = UIColor.whiteColor;
    heart.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    heart.textAlignment = NSTextAlignmentCenter;
    [_dot addSubview:heart];

    [_dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap)]];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)];
    [_dot addGestureRecognizer:pan];
    _built = YES;
}

#pragma mark - visibility (driven by the frontmost app)

- (void)evaluateVisibility {
    // DIAG (v1.0.1): force-show everywhere, even the home screen, to prove the tweak
    // loads into SpringBoard. Normal build gates on [WPHost wingmanEnabledForFrontmost].
    BOOL wanted = YES;
    if (!wanted) { _window.hidden = YES; return; }

    UIWindowScene *scene = WMActiveScene();
    if (!scene) { _window.hidden = YES; return; }

    if (!_built) {
        [self _buildInScene:scene];
    } else if (_window.windowScene != scene) {
        _window.windowScene = scene;                 // SpringBoard handed us a new scene
    }
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
    if (!shot) {
        [self _toast:@"Couldn't read the screen. Try again."];
        return;
    }
    // Adding another screen to a profile capture already in progress?
    if (_pendingSheet) {
        WPSheet *sheet = _pendingSheet;
        _pendingSheet = nil;
        [sheet appendImage:shot];
        [sheet reshowAfterAppend];
        return;
    }
    WPSheet *sheet = [[WPSheet alloc] initWithImage:shot];
    [sheet presentGlobally];
}

- (void)_toast:(NSString *)msg {
    UIWindowScene *scene = _window.windowScene ?: WMActiveScene();
    if (!scene) return;
    UILabel *t = [[UILabel alloc] init];
    t.text = msg; t.textColor = UIColor.whiteColor;
    t.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    t.font = [UIFont systemFontOfSize:14]; t.textAlignment = NSTextAlignmentCenter;
    t.numberOfLines = 0; t.layer.cornerRadius = 10; t.clipsToBounds = YES;
    CGRect b = scene.coordinateSpace.bounds;
    t.frame = CGRectMake(40, b.size.height - 160, b.size.width - 80, 44);
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
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
    UIWindowScene *sc = _window.windowScene;
    CGRect screen = sc ? sc.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
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
