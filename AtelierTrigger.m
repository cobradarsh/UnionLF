/*  AtelierTrigger.m — the way in: a swipe from the edge of the screen, near the bottom corner.

    Vivo opens its workbench with a swipe from the very corner. On an iPhone the bottom edge
    belongs to the Home gesture, so Atelier's strip sits on the side edge just above it: a thin,
    see-through strip (16 pt wide, 110 pt tall by default) that reacts to a finger sliding in
    from the edge, or up along it. A tap on the strip does nothing, but the strip does take it:
    whatever lies under those 16 points can't be tapped there. That is the price of the simple,
    dependable way (a window); Settings can make the strip shorter, move it to the other side or
    switch it off, and the same swipe closes the bench again.

    triggerMode 1 (no Settings row yet, `set triggerMode 1` from the test file) tries the other
    way: a recogniser added to the system's own gesture manager, which watches every touch and
    takes none unless it is the swipe. It is not verified on the phone.                        */

#import "Atelier.h"

@interface AtelierTrigger () <UIGestureRecognizerDelegate>
@end

@implementation AtelierTrigger {
    AtelierWindow *_window;
    UIPanGestureRecognizer *_stripPan;
    UIPanGestureRecognizer *_systemPan;
    BOOL _systemInstalled;
    BOOL _fired;
    NSString *_note;
}

+ (instancetype)shared {
    static AtelierTrigger *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [AtelierTrigger new]; });
    return t;
}

- (CGRect)_zone {
    AtelierSettings *s = [AtelierSettings shared];
    CGSize screen = [AtelierHost screenSize];
    CGFloat w = MAX(10, MIN(40, [s tune:@"triggerWidth" fallback:16]));
    CGFloat h = s.triggerSize;
    CGFloat bottom = screen.height - MAX([AtelierHost safeInsets].bottom, 12) - 6;
    // while the bench is up its dock (the switches) lies along the bottom: the strip ends above it
    CGFloat dock = [[AtelierBench shared] dockTop];
    if (dock > 0) bottom = MIN(bottom, dock - 4);
    return CGRectMake(s.triggerSide == 0 ? 0 : screen.width - w, bottom - h, w, h);
}

- (void)refresh {
    AtelierSettings *s = [AtelierSettings shared];
    BOOL want = s.enabled && s.trigger && ![AtelierHost isLocked];
    BOOL strip = want && s.triggerMode == 0;
    if (strip) {
        if (!_window) {
            _window = [AtelierHost windowAtLevel:1003];
            UIView *v = _window.rootViewController.view;
            v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.01];
            AtelierSendBool(v.layer, @"setHitTestsAsOpaque:", YES);
            _stripPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panned:)];
            _stripPan.maximumNumberOfTouches = 1;
            [v addGestureRecognizer:_stripPan];
        }
        _window.windowLevel = MAX(1003, (UIWindowLevel)[s tune:@"windowLevel" fallback:999] + 4);
        _window.frame = [self _zone];
        _window.rootViewController.view.frame = _window.bounds;
        // (a debug tint, so the strip can be seen in a screenshot)
        _window.rootViewController.view.backgroundColor = [s tune:@"triggerTint" fallback:0] > 0
            ? [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:0.45] : [UIColor colorWithWhite:0 alpha:0.01];
        _window.hidden = NO;
    } else {
        _window.hidden = YES;
    }
    BOOL system = want && s.triggerMode == 1;
    if (system != _systemInstalled) [self _setSystemGesture:system];
}

// A recogniser on the system gesture manager sees every touch on the display and blocks none.
- (void)_setSystemGesture:(BOOL)on {
    @try {
        id manager = AtelierSingleton(@"_UISystemGestureManager");
        if (!manager) manager = AtelierSingleton(@"FBSystemGestureManager");
        id display = AtelierMsg(UIScreen.mainScreen, @"displayIdentity");
        SEL add = NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:");
        SEL remove = NSSelectorFromString(@"removeGestureRecognizer:fromDisplayWithIdentity:");
        if (!manager || !display || !AtelierShape(manager, add, "v", 2) || !AtelierShape(manager, remove, "v", 2)) {
            _note = @"no system gesture manager on this iOS";
            AtelierLog(@"trigger: %@", _note);
            return;
        }
        if (on) {
            if (!_systemPan) {
                _systemPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_panned:)];
                _systemPan.maximumNumberOfTouches = 1;
                _systemPan.cancelsTouchesInView = NO;
                _systemPan.delegate = self;
            }
            ((void (*)(id, SEL, id, id))objc_msgSend)(manager, add, _systemPan, display);
        } else if (_systemPan) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(manager, remove, _systemPan, display);
        }
        _systemInstalled = on;
        _note = [NSString stringWithFormat:@"system gesture %@ (%@)", on ? @"on" : @"off", NSStringFromClass([manager class])];
        AtelierLog(@"trigger: %@", _note);
    } @catch (NSException *e) {
        _note = [NSString stringWithFormat:@"system gesture threw %@", e.reason];
        AtelierLog(@"trigger: %@", _note);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    if (g != _systemPan) return YES;
    CGPoint p = [touch locationInView:nil];
    CGRect zone = CGRectInset([self _zone], -6, 0);
    return CGRectContainsPoint(zone, p);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return YES; }

- (void)_panned:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) _fired = NO;
    if (g.state != UIGestureRecognizerStateBegan && g.state != UIGestureRecognizerStateChanged) return;
    if (_fired) return;
    CGPoint t = [g translationInView:nil];
    CGFloat inward = ([AtelierSettings shared].triggerSide == 0) ? t.x : -t.x;
    if (inward >= 26 || (t.y <= -44 && inward > -10)) {
        _fired = YES;
        [self _fire:@"swipe"];
    }
}

- (void)_fire:(NSString *)why {
    AtelierLog(@"trigger: %@", why);
    [[AtelierBench shared] toggle];
}

- (void)debugSwipe { [self _fire:@"test swipe"]; }

- (NSString *)debugState {
    CGRect z = [self _zone];
    return [NSString stringWithFormat:@"trigger strip %@ at %.0f,%.0f %.0fx%.0f level %.0f · %@",
            (_window && !_window.hidden) ? @"on" : @"off", z.origin.x, z.origin.y, z.size.width, z.size.height,
            _window ? _window.windowLevel : 0.0, _note ?: @"no system gesture"];
}

@end
