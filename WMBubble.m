/*  WMBubble.m — draggable floating bubble

    Fixes in 1.3.0:
    - show() used to return early if the window already existed, so after the
      first tap (which hides the bubble to capture the screen) it never came
      back. show() now always re-attaches to the live scene and un-hides.
    - The bubble is re-shown every time the app returns to the foreground.
    - Dragging is measured in screen coordinates (it used to be measured inside
      the moving bubble window, which made it jumpy).
    - The first tap after a drag is no longer swallowed.               */

#import "Wingman.h"
#import "WMSheet.h"

// ── screenshot shield ─────────────────────────────────────
// iOS keeps the contents of a password field (secureTextEntry) out of
// screenshots, screen recordings and AirPlay mirroring. Anything placed inside
// that field's internal canvas view inherits the protection. The field itself
// is invisible and can never start editing, so it just acts as a container.
@interface WMSecureField : UITextField
@end
@implementation WMSecureField
- (BOOL)canBecomeFirstResponder { return NO; }
- (CGRect)caretRectForPosition:(UITextPosition *)p { return CGRectZero; }
@end

// Returns the view to put protected content in, or nil if this iOS version
// doesn't expose the canvas (then the caller falls back to a normal view).
static UIView *WMMakeShield(UIView *host) {
    WMSecureField *f = [[WMSecureField alloc] initWithFrame:host.bounds];
    f.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    f.borderStyle = UITextBorderStyleNone;
    f.backgroundColor = UIColor.clearColor;
    f.textColor = UIColor.clearColor;
    f.tintColor = UIColor.clearColor;
    f.secureTextEntry = YES;
    [host addSubview:f];
    [f layoutIfNeeded];

    UIView *canvas = nil;
    for (UIView *v in f.subviews)
        if ([NSStringFromClass(v.class) containsString:@"Canvas"]) { canvas = v; break; }
    if (!canvas) canvas = f.subviews.firstObject;
    if (!canvas) { [f removeFromSuperview]; return nil; }

    // the field must never react to touches itself
    for (UIGestureRecognizer *g in [f.gestureRecognizers copy]) [f removeGestureRecognizer:g];
    if ([f respondsToSelector:@selector(setInteractions:)]) f.interactions = @[];

    canvas.frame = f.bounds;
    canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    canvas.userInteractionEnabled = YES;
    return canvas;
}

static CGFloat const kBubbleSize = 48;
static NSString *const kWMPosKey = @"com.adarsh.wingman.bubblePos";

@interface WMBubble ()
@property (nonatomic) CGPoint grabOffset;
@property (nonatomic, readwrite) BOOL userHidden;
@property (nonatomic) BOOL capturing;
@end

@implementation WMBubble

+ (instancetype)shared {
    static WMBubble *b;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ b = [WMBubble new]; });
    return b;
}

#pragma mark - lifecycle

- (void)_buildInScene:(UIWindowScene *)scene {
    CGRect screen = scene.coordinateSpace.bounds;
    WMSettings *s = [WMSettings shared];

    _overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    _overlayWindow.windowLevel = UIWindowLevelAlert + 50;
    _overlayWindow.backgroundColor = UIColor.clearColor;
    _overlayWindow.opaque = NO;
    _overlayWindow.rootViewController = [UIViewController new];
    _overlayWindow.rootViewController.view.backgroundColor = UIColor.clearColor;

    CGFloat x = s.bubbleOnRight ? (screen.size.width - kBubbleSize - 12) : 2;
    CGFloat y = screen.size.height * 0.45;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kWMPosKey];
    if (saved.length) {
        CGPoint p = CGPointFromString(saved);
        if (CGRectContainsPoint(CGRectInset(screen, -1, -1), p)) { x = p.x; y = p.y; }
    }
    _overlayWindow.frame = CGRectMake(x, y, kBubbleSize + 10, kBubbleSize + 10);

    _bubbleView = [[UIView alloc] initWithFrame:CGRectMake(5, 5, kBubbleSize, kBubbleSize)];
    _bubbleView.backgroundColor = [UIColor colorWithRed:0.3 green:0.55 blue:1.0 alpha:1];
    _bubbleView.layer.cornerRadius = kBubbleSize / 2;
    _bubbleView.layer.shadowColor = UIColor.blackColor.CGColor;
    _bubbleView.layer.shadowOffset = CGSizeMake(0, 2);
    _bubbleView.layer.shadowOpacity = 0.4;
    _bubbleView.layer.shadowRadius = 4;
    _bubbleView.alpha = s.bubbleAlpha;
    // inside the shield so your own screenshots/recordings never show it
    UIView *root = _overlayWindow.rootViewController.view;
    root.frame = CGRectMake(0, 0, kBubbleSize + 10, kBubbleSize + 10);  // real size before the shield
    UIView *shield = WMMakeShield(root);
    [(shield ?: root) addSubview:_bubbleView];

    UILabel *lbl = [[UILabel alloc] initWithFrame:_bubbleView.bounds];
    lbl.text = @"W";
    lbl.textColor = UIColor.whiteColor;
    lbl.font = [UIFont boldSystemFontOfSize:22];
    lbl.textAlignment = NSTextAlignmentCenter;
    [_bubbleView addSubview:lbl];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tapped)];
    [_bubbleView addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_longPressed:)];
    lp.minimumPressDuration = 0.5;
    [_bubbleView addGestureRecognizer:lp];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panned:)];
    [_bubbleView addGestureRecognizer:pan];
}

- (void)show {
    if (_userHidden || _capturing) return;
    UIWindowScene *scene = WMActiveScene();
    if (!scene) return;

    if (!_overlayWindow) {
        [self _buildInScene:scene];
    } else if (_overlayWindow.windowScene != scene) {
        _overlayWindow.windowScene = scene;          // app got a new scene: move over
    }
    _bubbleView.alpha = [WMSettings shared].bubbleAlpha;
    _overlayWindow.alpha = 1;
    _overlayWindow.hidden = NO;
}

- (void)hide {
    _overlayWindow.hidden = YES;
}

- (void)hideUntilReopen {
    _userHidden = YES;
    [self hide];
}

- (void)appWillEnterForeground {
    _userHidden = NO;
}

- (void)refresh {
    [[WMSettings shared] reload];
    if ([WMApps currentKind] == WMAppKindNone) { [self hide]; return; }
    [self show];
}

#pragma mark - capture

- (void)_tapped {
    if (_capturing) return;
    _capturing = YES;
    [WMCapture dismissKeyboardInChat];   // minimise the keyboard so earlier messages come into frame
    [self hide];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray<UIImage *> *frames = [WMCapture screenshotHidingView:self.overlayWindow];
        self.capturing = NO;
        [self show];
        [self _presentSheetWithFrames:frames];
    });
}

- (void)_longPressed:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan || _capturing) return;
    _capturing = YES;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [WMCapture dismissKeyboardInChat];   // minimise the keyboard before the scrolling capture
    [self hide];
    [WMCapture scrollCaptureHidingView:self.overlayWindow completion:^(NSArray<UIImage *> *frames) {
        self.capturing = NO;
        [self show];
        [self _presentSheetWithFrames:frames];
    }];
}

- (void)_presentSheetWithFrames:(NSArray<UIImage *> *)frames {
    if (frames.count == 0) return;
    WMSheet *sheet = [[WMSheet alloc] initWithImages:frames];
    [sheet presentGlobally];
}

#pragma mark - drag

// finger position in screen (scene) coordinates
- (CGPoint)_screenPoint:(UIGestureRecognizer *)g {
    CGPoint p = [g locationInView:_overlayWindow];
    return CGPointMake(p.x + _overlayWindow.frame.origin.x, p.y + _overlayWindow.frame.origin.y);
}

- (void)_panned:(UIPanGestureRecognizer *)pan {
    CGPoint p = [self _screenPoint:pan];
    CGRect f = _overlayWindow.frame;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _grabOffset = CGPointMake(p.x - f.origin.x, p.y - f.origin.y);
            break;
        case UIGestureRecognizerStateChanged:
            f.origin = CGPointMake(p.x - _grabOffset.x, p.y - _grabOffset.y);
            _overlayWindow.frame = f;
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            [self _snapToEdge];
            break;
        default: break;
    }
}

- (void)_snapToEdge {
    UIWindowScene *sc = _overlayWindow.windowScene;
    CGRect screen = sc ? sc.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    for (UIWindow *w in sc.windows) if (w.windowLevel == UIWindowLevelNormal) { safe = w.safeAreaInsets; break; }

    CGRect f = _overlayWindow.frame;
    CGFloat targetX = (CGRectGetMidX(f) < screen.size.width / 2) ? 2 : screen.size.width - f.size.width - 2;
    CGFloat minY = MAX(50, safe.top + 8), maxY = screen.size.height - f.size.height - MAX(50, safe.bottom + 60);
    CGFloat targetY = MAX(minY, MIN(f.origin.y, maxY));

    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:0 animations:^{
        self.overlayWindow.frame = CGRectMake(targetX, targetY, f.size.width, f.size.height);
    } completion:^(BOOL done) {
        [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(CGPointMake(targetX, targetY))
                                                  forKey:kWMPosKey];
    }];
}

@end
