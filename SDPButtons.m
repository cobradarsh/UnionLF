/*  SDPButtons.m — the floating buttons, owned by SpringBoard.

    SDPBubble is the Wingman-bubble look (night disc, purple ring) in a classic UIWindow
    only as big as the button, attached to SpringBoard's main scene (a window outside a
    foreground scene never renders). Touches anywhere else go straight to the apps.
    Drag a bubble anywhere: it snaps to the nearest side and remembers the spot.

      • Hide-keyboard button: shows while an app's keyboard is up. Tap = that app drops its
        keyboard. Long-press = swap the two apps.
      • Swap button: shows while Dynamic Stage has two apps open. Tap = swap top and bottom. */

#import "SDPlus.h"
#import <errno.h>
#import <signal.h>

static UIColor *SDPAccent(void) { return [UIColor colorWithRed:0x7C/255.0 green:0x5C/255.0 blue:0xFF/255.0 alpha:1]; }
static UIColor *SDPIdle(void)   { return [UIColor colorWithRed:0x1B/255.0 green:0x1B/255.0 blue:0x26/255.0 alpha:0.93]; }

#pragma mark - generic bubble

@interface SDPBubble : NSObject
- (instancetype)initWithKey:(NSString *)posKey symbol:(NSString *)symbol fallback:(NSString *)fallback
                      level:(UIWindowLevel)level defaultOrigin:(CGPoint (^)(CGFloat size))defaultOrigin;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);
@property (nonatomic, readonly) BOOL visible;
- (void)show:(BOOL)show size:(CGFloat)size;
- (void)popAway;                                  // tap feedback, then hide
@end

@implementation SDPBubble {
    NSString *_posKey, *_symbol, *_fallback;
    UIWindowLevel _level;
    CGPoint (^_defaultOrigin)(CGFloat);
    UIWindow *_window;
    UIView *_dot;
    UIImageView *_glyph;
    CGPoint _grab;
    CGFloat _size;
}

- (instancetype)initWithKey:(NSString *)posKey symbol:(NSString *)symbol fallback:(NSString *)fallback
                      level:(UIWindowLevel)level defaultOrigin:(CGPoint (^)(CGFloat))defaultOrigin {
    if ((self = [super init])) {
        _posKey = posKey; _symbol = symbol; _fallback = fallback; _level = level; _defaultOrigin = defaultOrigin;
    }
    return self;
}

- (BOOL)visible { return _window && !_window.hidden; }

- (void)_build:(CGFloat)size {
    CGRect screen = UIScreen.mainScreen.bounds;
    _size = size;
    CGPoint o = _defaultOrigin ? _defaultOrigin(size) : CGPointMake(screen.size.width - size - 8, screen.size.height * 0.4);
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:_posKey];
    if (saved.length) {
        CGPoint p = CGPointFromString(saved);
        if (CGRectContainsPoint(CGRectInset(screen, -2, -2), p)) o = p;
    }
    UIWindowScene *scene = [SDPHost mainScene];
    _window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:screen];
    _window.frame = CGRectMake(o.x, o.y, size, size);
    _window.windowLevel = _level;
    _window.backgroundColor = UIColor.clearColor;
    _window.opaque = NO;
    _window.rootViewController = [UIViewController new];
    _window.rootViewController.view.backgroundColor = UIColor.clearColor;

    _dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    _dot.backgroundColor = SDPIdle();
    _dot.layer.borderWidth = 2;
    _dot.layer.borderColor = SDPAccent().CGColor;
    _dot.layer.cornerRadius = size / 2;
    _dot.layer.shadowColor = UIColor.blackColor.CGColor;
    _dot.layer.shadowOffset = CGSizeMake(0, 2);
    _dot.layer.shadowOpacity = 0.4;
    _dot.layer.shadowRadius = 5;
    [_window.rootViewController.view addSubview:_dot];

    _glyph = [[UIImageView alloc] initWithFrame:_dot.bounds];
    _glyph.contentMode = UIViewContentModeCenter;
    _glyph.tintColor = UIColor.whiteColor;
    [_dot addSubview:_glyph];
    [self _setGlyph];

    [_dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap)]];
    [_dot addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)]];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_long:)];
    lp.minimumPressDuration = 0.45;
    [_dot addGestureRecognizer:lp];
    _window.hidden = YES;
}

- (void)_setGlyph {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:_size * 0.40
                                                                                       weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:_symbol withConfiguration:cfg] ?: [UIImage systemImageNamed:_fallback withConfiguration:cfg];
    _glyph.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)_resize:(CGFloat)size {
    if (fabs(size - _size) < 0.5) return;
    _size = size;
    CGRect f = _window.frame;
    _window.frame = CGRectMake(f.origin.x, f.origin.y, size, size);
    _dot.frame = CGRectMake(0, 0, size, size);
    _dot.layer.cornerRadius = size / 2;
    _glyph.frame = _dot.bounds;
    [self _setGlyph];
}

- (void)show:(BOOL)show size:(CGFloat)size {
    if (!show) { if (_window && !_window.hidden) _window.hidden = YES; return; }
    if (!_window) [self _build:size];
    [self _resize:size];
    UIWindowScene *scene = [SDPHost mainScene];
    if (scene && _window.windowScene != scene) _window.windowScene = scene;
    if (_window.hidden) {
        _window.hidden = NO;
        _dot.transform = CGAffineTransformMakeScale(0.6, 0.6);
        _dot.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ self->_dot.transform = CGAffineTransformIdentity; self->_dot.alpha = 1; }];
    }
}

- (void)popAway {
    [UIView animateWithDuration:0.15 animations:^{
        self->_dot.transform = CGAffineTransformMakeScale(0.6, 0.6);
        self->_dot.alpha = 0;
    } completion:^(BOOL done) {
        self->_window.hidden = YES;
        self->_dot.transform = CGAffineTransformIdentity;
        self->_dot.alpha = 1;
    }];
}

- (void)_tap { if (self.onTap) self.onTap(); }

- (void)_long:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}

- (void)_pan:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:_window];
    p = CGPointMake(p.x + _window.frame.origin.x, p.y + _window.frame.origin.y);
    CGRect f = _window.frame;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _grab = CGPointMake(p.x - f.origin.x, p.y - f.origin.y);
            break;
        case UIGestureRecognizerStateChanged:
            f.origin = CGPointMake(p.x - _grab.x, p.y - _grab.y);
            _window.frame = f;
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGRect screen = UIScreen.mainScreen.bounds;
            CGFloat x = (CGRectGetMidX(f) < screen.size.width / 2) ? 8 : screen.size.width - f.size.width - 8;
            CGFloat y = MAX(50, MIN(f.origin.y, screen.size.height - f.size.height - 40));
            NSString *key = _posKey;
            [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:0
                             animations:^{ self->_window.frame = CGRectMake(x, y, f.size.width, f.size.height); }
                             completion:^(BOOL d) {
                [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(CGPointMake(x, y)) forKey:key];
            }];
            break;
        }
        default: break;
    }
}

@end

#pragma mark - hide-keyboard button

@implementation SDPKeyboardButton {
    SDPBubble *_bubble;
    NSMutableDictionary<NSNumber *, NSNumber *> *_kbPids;   // pid -> when its keyboard showed
}

+ (instancetype)shared {
    static SDPKeyboardButton *b; static dispatch_once_t t;
    dispatch_once(&t, ^{ b = [SDPKeyboardButton new]; [b _setup]; });
    return b;
}

- (void)_setup {
    _kbPids = [NSMutableDictionary dictionary];
    _bubble = [[SDPBubble alloc] initWithKey:@"com.adarsh.sdplus.kbButtonPos" symbol:@"keyboard.chevron.compact.down"
                                    fallback:@"chevron.down" level:99999
                               defaultOrigin:^CGPoint(CGFloat size) {
        CGRect s = UIScreen.mainScreen.bounds;
        return CGPointMake(s.size.width - size - 8, s.size.height * 0.36);
    }];
    __weak typeof(self) ws = self;
    _bubble.onTap = ^{ [ws _dismiss]; };
    _bubble.onLongPress = ^{
        if (![SDPStage isOpen]) { [SDPHost toast:@"Open two apps in Dynamic Stage to swap them."]; return; }
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        [SDPStage swapWithReason:@"keyboard button" refocus:NO];
    };
}

- (void)keyboardShownInPid:(pid_t)pid {
    if (pid <= 0) return;
    _kbPids[@(pid)] = @(CFAbsoluteTimeGetCurrent());
    [self refresh];
}

- (void)keyboardHiddenInPid:(pid_t)pid {
    [_kbPids removeObjectForKey:@(pid)];
    [self refresh];
}

- (void)refresh {
    for (NSNumber *p in _kbPids.allKeys) {
        if (kill(p.intValue, 0) != 0 && errno == ESRCH) [_kbPids removeObjectForKey:p];
    }
    SDPSettings *s = [SDPSettings shared];
    BOOL stageOpen = [SDPStage isOpen];
    BOOL want = s.enabled && s.keyboardButton && _kbPids.count > 0 && ([SDPHost frontmostBundleID] != nil || stageOpen);
    if (want && s.keyboardButtonOnlyInStage) want = stageOpen;
    [_bubble show:want size:s.keyboardButtonSize];
}

- (void)_dismiss {
    pid_t target = _kbPids.count == 1 ? (pid_t)[_kbPids.allKeys.firstObject intValue] : 0;   // 0 = every app
    SDPLog(@"keyboard button: dismiss pid %d (%lu keyboards up)", target, (unsigned long)_kbPids.count);
    SDPPost(SDP_N_KB_DISMISS, (uint64_t)target);
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [_kbPids removeAllObjects];
    [_bubble popAway];
}

@end

#pragma mark - swap button

@implementation SDPSwapButton {
    SDPBubble *_bubble;
    CFAbsoluteTime _hideUntil;   // stays hidden while a swap is running
}

+ (instancetype)shared {
    static SDPSwapButton *b; static dispatch_once_t t;
    dispatch_once(&t, ^{ b = [SDPSwapButton new]; [b _setup]; });
    return b;
}

- (void)_setup {
    // first time: left edge, on the line between the two windows
    _bubble = [[SDPBubble alloc] initWithKey:@"com.adarsh.sdplus.swapButtonPos" symbol:@"arrow.up.arrow.down"
                                    fallback:@"arrow.2.squarepath" level:99998
                               defaultOrigin:^CGPoint(CGFloat size) {
        CGRect s = UIScreen.mainScreen.bounds;
        return CGPointMake(8, s.size.height * 0.46 - size / 2);
    }];
    __weak typeof(self) ws = self;
    _bubble.onTap = ^{ [ws _swap]; };
    _bubble.onLongPress = ^{ [SDPHost toast:@"Tap to swap the top and bottom apps. Drag to move this button."]; };
}

- (void)refresh {
    SDPSettings *s = [SDPSettings shared];
    BOOL want = s.enabled && s.swapButton && [SDPStage isOpen] && CFAbsoluteTimeGetCurrent() > _hideUntil;
    [_bubble show:want size:s.keyboardButtonSize];
}

- (void)_swap {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    _hideUntil = CFAbsoluteTimeGetCurrent() + 2.5;
    [_bubble popAway];
    [SDPStage swapWithReason:@"swap button" refocus:NO];
}

@end
