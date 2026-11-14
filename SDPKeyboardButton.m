/*  SDPKeyboardButton.m — floating "hide keyboard" button, owned by SpringBoard.

    Same build as the Wingman bubble: a classic UIWindow only as big as the button,
    attached to SpringBoard's main scene (a window outside a foreground scene never
    renders), so touches anywhere else still reach the apps underneath.

    It shows only while an app reports its keyboard is up (SDP_N_KB_SHOW). Tap it and
    SpringBoard asks that app to drop its keyboard (SDP_N_KB_DISMISS). Long-press it
    while Dynamic Stage shows two apps to swap them by hand. Drag it anywhere; it
    snaps to the nearest edge and remembers the spot.                               */

#import "SDPlus.h"
#import <errno.h>
#import <signal.h>

static NSString *const kPosKey = @"com.adarsh.sdplus.kbButtonPos";
static UIWindowLevel const kLevel = 99999;   // just under the Wingman bubble (100000)

static UIColor *SDPAccent(void) { return [UIColor colorWithRed:0x7C/255.0 green:0x5C/255.0 blue:0xFF/255.0 alpha:1]; }
static UIColor *SDPIdle(void)   { return [UIColor colorWithRed:0x1B/255.0 green:0x1B/255.0 blue:0x26/255.0 alpha:0.93]; }

@implementation SDPKeyboardButton {
    UIWindow *_window;
    UIView *_dot;
    UIImageView *_glyph;
    NSMutableDictionary<NSNumber *, NSNumber *> *_kbPids;   // pid -> when its keyboard showed
    pid_t _lastPid;
    CGPoint _grab;
    CGFloat _size;
    BOOL _built;
}

+ (instancetype)shared {
    static SDPKeyboardButton *b; static dispatch_once_t t;
    dispatch_once(&t, ^{ b = [SDPKeyboardButton new]; b->_kbPids = [NSMutableDictionary dictionary]; });
    return b;
}

#pragma mark - keyboard state from apps

- (void)keyboardShownInPid:(pid_t)pid {
    if (pid <= 0) return;
    _kbPids[@(pid)] = @(CFAbsoluteTimeGetCurrent());
    _lastPid = pid;
    [self refresh];
}

- (void)keyboardHiddenInPid:(pid_t)pid {
    [_kbPids removeObjectForKey:@(pid)];
    if (_lastPid == pid) _lastPid = (pid_t)[_kbPids.allKeys.firstObject intValue];
    [self refresh];
}

- (void)_pruneDeadPids {
    for (NSNumber *p in _kbPids.allKeys) {
        if (kill(p.intValue, 0) != 0 && errno == ESRCH) [_kbPids removeObjectForKey:p];
    }
}

#pragma mark - visibility

- (void)refresh {
    [self _pruneDeadPids];
    SDPSettings *s = [SDPSettings shared];
    BOOL stageOpen = [SDPStage isOpen];
    BOOL want = s.enabled && s.keyboardButton && _kbPids.count > 0 && ([SDPHost frontmostBundleID] != nil || stageOpen);
    if (want && s.keyboardButtonOnlyInStage) want = stageOpen;
    if (!want) { if (_built && !_window.hidden) _window.hidden = YES; return; }
    if (!_built) [self _build];
    [self _applySize:s.keyboardButtonSize];
    UIWindowScene *scene = [SDPHost mainScene];
    if (scene && _window.windowScene != scene) _window.windowScene = scene;
    if (_window.hidden) {
        _window.hidden = NO;
        _dot.transform = CGAffineTransformMakeScale(0.6, 0.6);
        _dot.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ self->_dot.transform = CGAffineTransformIdentity; self->_dot.alpha = 1; }];
    }
}

#pragma mark - build

- (void)_build {
    CGRect screen = UIScreen.mainScreen.bounds;
    _size = [SDPSettings shared].keyboardButtonSize;
    CGFloat x = screen.size.width - _size - 8, y = screen.size.height * 0.36;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kPosKey];
    if (saved.length) {
        CGPoint p = CGPointFromString(saved);
        if (CGRectContainsPoint(CGRectInset(screen, -2, -2), p)) { x = p.x; y = p.y; }
    }
    UIWindowScene *scene = [SDPHost mainScene];
    _window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:screen];
    _window.frame = CGRectMake(x, y, _size, _size);
    _window.windowLevel = kLevel;
    _window.backgroundColor = UIColor.clearColor;
    _window.opaque = NO;
    _window.rootViewController = [UIViewController new];
    _window.rootViewController.view.backgroundColor = UIColor.clearColor;

    _dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _size, _size)];
    _dot.backgroundColor = SDPIdle();
    _dot.layer.borderWidth = 2;
    _dot.layer.borderColor = SDPAccent().CGColor;
    _dot.layer.cornerRadius = _size / 2;
    _dot.layer.shadowColor = UIColor.blackColor.CGColor;
    _dot.layer.shadowOffset = CGSizeMake(0, 2);
    _dot.layer.shadowOpacity = 0.4;
    _dot.layer.shadowRadius = 5;
    [_window.rootViewController.view addSubview:_dot];

    _glyph = [[UIImageView alloc] initWithFrame:_dot.bounds];
    _glyph.contentMode = UIViewContentModeCenter;
    _glyph.tintColor = UIColor.whiteColor;
    [_dot addSubview:_glyph];
    [self _setGlyphSize];

    [_dot addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap)]];
    [_dot addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)]];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_long:)];
    lp.minimumPressDuration = 0.45;
    [_dot addGestureRecognizer:lp];
    _window.hidden = YES;
    _built = YES;
}

- (void)_setGlyphSize {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:_size * 0.40
                                                                                       weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:@"keyboard.chevron.compact.down" withConfiguration:cfg]
                ?: [UIImage systemImageNamed:@"chevron.down" withConfiguration:cfg];
    _glyph.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)_applySize:(CGFloat)size {
    if (fabs(size - _size) < 0.5) return;
    _size = size;
    CGRect f = _window.frame;
    _window.frame = CGRectMake(f.origin.x, f.origin.y, size, size);
    _dot.frame = CGRectMake(0, 0, size, size);
    _dot.layer.cornerRadius = size / 2;
    _glyph.frame = _dot.bounds;
    [self _setGlyphSize];
}

#pragma mark - actions

- (void)_tap {
    pid_t target = _kbPids.count == 1 ? (pid_t)[_kbPids.allKeys.firstObject intValue] : 0;   // 0 = every app
    SDPLog(@"keyboard button: dismiss pid %d (%lu keyboards up)", target, (unsigned long)_kbPids.count);
    SDPPost(SDP_N_KB_DISMISS, (uint64_t)target);
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [_kbPids removeAllObjects];
    [UIView animateWithDuration:0.15 animations:^{
        self->_dot.transform = CGAffineTransformMakeScale(0.6, 0.6);
        self->_dot.alpha = 0;
    } completion:^(BOOL done) {
        self->_window.hidden = YES;
        self->_dot.transform = CGAffineTransformIdentity;
        self->_dot.alpha = 1;
    }];
}

- (void)_long:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (![SDPStage isOpen]) { [SDPHost toast:@"Open two apps in Dynamic Stage to swap them."]; return; }
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [SDPStage swapWithReason:@"button" refocus:NO];
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
        case UIGestureRecognizerStateCancelled:
            [self _snap];
            break;
        default: break;
    }
}

- (void)_snap {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect f = _window.frame;
    CGFloat x = (CGRectGetMidX(f) < screen.size.width / 2) ? 8 : screen.size.width - f.size.width - 8;
    CGFloat y = MAX(50, MIN(f.origin.y, screen.size.height - f.size.height - 40));
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:0
                     animations:^{ self->_window.frame = CGRectMake(x, y, f.size.width, f.size.height); }
                     completion:^(BOOL d) {
        [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(CGPointMake(x, y)) forKey:kPosKey];
    }];
}

@end
