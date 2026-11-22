/*  AtelierTrigger.m — the way in: a swipe from the edge of the screen, near the bottom corner.

    Vivo opens its workbench with a swipe from the very corner. On an iPhone the bottom edge
    belongs to the Home gesture, so the strip sits on the side edge just above it: a see-through
    strip (22 pt wide, 110 pt tall by default) with a faint pill on the very edge to show where
    it is (Settings → Show Edge Handle).

    The strip follows the finger itself, from where it came down (no gesture recogniser: those
    leave out the first ten points). As soon as the finger has gone 5 points the bench starts to
    come in with it, from that edge; letting go finishes the job or lets it spring back:

      armed         14 pt in from the edge, or 20 pt up along it; a light tick says so
      or a flick    350 pt/s inward after 8 pt, or upward after 10

    With the bench up the same strip sends it away again, by a swipe inward only (a finger
    going up along the edge there is somebody scrolling the app), and the strip is only as wide
    as the margin beside the tiles, so it never lies over an app. A tap on the strip does
    nothing, but the strip does take it: whatever lies under it can't be tapped there. That is
    the price of the simple, dependable way (a window); Settings can make the strip shorter,
    move it to the other side or switch it off.

    Every touch on the strip leaves one line in the log: where it began, how far it went, how
    fast, and whether it fired or why not.

    triggerMode 1 (no Settings row, `set triggerMode 1` from the test file) tries the other way:
    a recogniser added to the system's own gesture manager, which watches every touch and takes
    none unless it is the swipe. It is not verified on the phone.                              */

#import "Atelier.h"

@interface AtelierTrigger () <UIGestureRecognizerDelegate>
- (void)_strip:(AtelierTouchPhase)phase track:(AtelierTrack *)track;
- (CGPoint)_onScreen:(CGPoint)pointInStripWindow;
@end

// The strip's own view: it follows one finger and tells the trigger.
@interface AtelierStripView : UIView
@end

@implementation AtelierStripView {
    AtelierTrack *_track;
    __weak UITouch *_touch;
    BOOL _down;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_down) return;
    UITouch *touch = touches.anyObject;
    _touch = touch;
    _down = YES;
    _track = [AtelierTrack new];
    [_track beginAt:[[AtelierTrigger shared] _onScreen:[touch locationInView:nil]] time:touch.timestamp];
    [[AtelierTrigger shared] _strip:AtelierTouchBegan track:_track];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = _touch;
    if (!_down || !touch || ![touches containsObject:touch]) return;
    [_track moveTo:[[AtelierTrigger shared] _onScreen:[touch locationInView:nil]] time:touch.timestamp];
    [[AtelierTrigger shared] _strip:AtelierTouchMoved track:_track];
}

- (void)_finish:(AtelierTouchPhase)phase {
    if (!_down) return;
    UITouch *touch = _touch;
    if (touch && phase == AtelierTouchEnded) [_track moveTo:[[AtelierTrigger shared] _onScreen:[touch locationInView:nil]] time:touch.timestamp];
    _down = NO;
    _touch = nil;
    [[AtelierTrigger shared] _strip:phase track:_track];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = _touch;
    if (touch && ![touches containsObject:touch]) return;
    [self _finish:AtelierTouchEnded];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self _finish:AtelierTouchCancelled];
}

@end

@implementation AtelierTrigger {
    AtelierWindow *_window;
    AtelierStripView *_strip;
    UIView *_handle;                         // the faint pill on the very edge
    UIPanGestureRecognizer *_systemPan;
    BOOL _systemInstalled;
    BOOL _fired;
    BOOL _touching, _refreshLater;           // a finger is on the strip: the strip stays where it is until it lifts
    BOOL _going, _mine, _opening, _armed;
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
    AtelierBench *bench = [AtelierBench shared];
    CGSize screen = [AtelierHost screenSize];
    BOOL right = s.triggerSide != 0;
    CGFloat w = MAX(16, MIN(44, [s tune:@"triggerWidth" fallback:22]));
    CGFloat h = s.triggerSize;
    CGFloat bottom = screen.height - MAX([AtelierHost safeInsets].bottom, 12) - 6;
    // While the bench is up: the strip ends above the dock (the switches), and is no wider than
    // the margin beside the tiles, so it never takes a touch meant for an app or a switch.
    CGFloat dock = [bench dockTop];
    if (dock > 0) {
        bottom = MIN(bottom, dock - 4);
        w = MAX(8, MIN(w, [bench marginOnRight:right]));
    }
    return CGRectMake(right ? screen.width - w : 0, bottom - h, w, h);
}

- (CGPoint)_onScreen:(CGPoint)p {
    return CGPointMake(p.x + _window.frame.origin.x, p.y + _window.frame.origin.y);
}

- (void)refresh {
    if (_touching) { _refreshLater = YES; return; }      // not under a finger
    AtelierSettings *s = [AtelierSettings shared];
    BOOL want = s.enabled && s.trigger && ![AtelierHost isLocked];
    BOOL strip = want && s.triggerMode == 0;
    if (strip) {
        if (!_window) {
            _window = [AtelierHost windowAtLevel:1003];
            UIView *v = _window.rootViewController.view;
            v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.01];
            AtelierSendBool(v.layer, @"setHitTestsAsOpaque:", YES);
            _strip = [[AtelierStripView alloc] initWithFrame:v.bounds];
            _strip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            _strip.multipleTouchEnabled = NO;
            [v addSubview:_strip];
            _handle = [[UIView alloc] initWithFrame:CGRectZero];
            _handle.userInteractionEnabled = NO;
            _handle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.34];
            _handle.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.28].CGColor;
            _handle.layer.borderWidth = 0.5;
            _handle.layer.cornerRadius = 2;
            [v addSubview:_handle];
        }
        _window.windowLevel = MAX(1003, (UIWindowLevel)[s tune:@"windowLevel" fallback:999] + 4);
        CGRect zone = [self _zone];
        _window.frame = zone;
        _window.rootViewController.view.frame = _window.bounds;
        // (a debug tint, so the strip can be seen in a screenshot)
        _window.rootViewController.view.backgroundColor = [s tune:@"triggerTint" fallback:0] > 0
            ? [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:0.45] : [UIColor colorWithWhite:0 alpha:0.01];
        // the handle: a thin pill against the screen's edge, a little shorter than the strip
        BOOL right = s.triggerSide != 0;
        CGFloat inset = MIN(18, zone.size.height * 0.16);
        _handle.frame = CGRectMake(right ? zone.size.width - 4 - 2.5 : 2.5, inset, 4, MAX(8, zone.size.height - 2 * inset));
        _handle.hidden = !s.showHandle;
        _window.hidden = NO;
    } else {
        _window.hidden = YES;
    }
    BOOL system = want && s.triggerMode == 1;
    if (system != _systemInstalled) [self _setSystemGesture:system];
}

#pragma mark the strip

// One finger on the strip, from where it came down (screen points).
- (void)_strip:(AtelierTouchPhase)phase track:(AtelierTrack *)track {
    AtelierBench *bench = [AtelierBench shared];
    BOOL right = [AtelierSettings shared].triggerSide != 0;
    CGPoint d = track.travel;
    CGFloat inward = right ? -d.x : d.x, up = -d.y;
    if (phase == AtelierTouchBegan) {
        _touching = YES;
        _going = NO;
        _mine = NO;
        _armed = NO;
        _opening = !bench.visible;
        return;
    }
    // with the bench up only a swipe inward counts: up along the edge there is a finger scrolling the app
    BOOL upCounts = _opening;
    CGFloat travel = MAX(inward, upCounts ? up * 0.7 : 0);
    BOOL armed = inward >= 14 || (upCounts && up >= 20 && inward > -10);
    if (phase == AtelierTouchMoved) {
        if (!_going && travel >= 5) {
            _going = YES;
            _opening = !bench.visible;
            _mine = [bench beginDragOpening:_opening motion:(right ? AtelierMotionFromRight : AtelierMotionFromLeft) owner:self];
        }
        if (_mine) {
            CGFloat p = MAX(0, MIN(1, travel / 150.0));
            [bench dragTo:(_opening ? p : 1 - p) owner:self];
        }
        if (armed != _armed) {
            _armed = armed;
            if (armed) AtelierHapticPlay(AtelierHapticTick);
        }
        return;
    }
    // lifted, or taken away
    CGPoint v = track.velocity;
    CGFloat speedIn = right ? -v.x : v.x, speedUp = -v.y;
    BOOL flick = (inward >= 8 && speedIn >= 350) || (upCounts && up >= 10 && speedUp >= 350 && inward > -10);
    BOOL fire = phase == AtelierTouchEnded && (armed || flick);
    NSString *result;
    if (fire && _mine) result = [NSString stringWithFormat:@"fired (%@): the bench %@", armed ? @"far enough" : @"a flick", _opening ? @"opens" : @"closes"];
    else if (fire) result = @"fired, but the bench would not move (switched off, locked, or something else was moving it)";
    else if (phase == AtelierTouchCancelled) result = @"not fired: the touch was taken away";
    else if (!_going) result = @"not fired: a tap, or under 5 pt of travel";
    else result = [NSString stringWithFormat:@"not fired: it needs 14 pt in%@, or a flick of 350 pt/s", upCounts ? @" or 20 pt up" : @""];
    AtelierLog(@"strip touch: began at %.0f,%.0f · %.0f pt in, %.0f pt up · %.0f pt/s in, %.0f up · %@", track.down.x, track.down.y,
               inward, up, speedIn, speedUp, result);
    if (_mine) {
        CGFloat carry = MAX(0, MAX(speedIn, upCounts ? speedUp * 0.7 : 0)) / 150.0;
        [bench endDrag:fire velocity:carry reason:(_opening ? @"edge swipe let go early" : @"edge swipe") owner:self];
    }
    _touching = NO;
    _going = NO;
    _mine = NO;
    if (_refreshLater) { _refreshLater = NO; [self refresh]; }
}

#pragma mark the system gesture (triggerMode 1)

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
    if (inward >= 14 || (t.y <= -20 && inward > -10)) {
        _fired = YES;
        [self _fire:@"swipe (system gesture)"];
    }
}

// Without a finger to follow: the same coming and going, at full speed.
- (void)_fire:(NSString *)why {
    AtelierLog(@"trigger: %@", why);
    AtelierBench *bench = [AtelierBench shared];
    AtelierMotion motion = [AtelierSettings shared].triggerSide != 0 ? AtelierMotionFromRight : AtelierMotionFromLeft;
    if (bench.visible) [bench closeAnimated:YES reason:@"edge swipe" motion:motion];
    else [bench openWithMotion:motion];
}

- (void)debugSwipe { [self _fire:@"test swipe"]; }

- (NSString *)debugState {
    CGRect z = [self _zone];
    return [NSString stringWithFormat:@"trigger strip %@ at %.0f,%.0f %.0fx%.0f level %.0f handle %@ · %@",
            (_window && !_window.hidden) ? @"on" : @"off", z.origin.x, z.origin.y, z.size.width, z.size.height,
            _window ? _window.windowLevel : 0.0, (_handle && !_handle.hidden) ? @"shown" : @"hidden", _note ?: @"no system gesture"];
}

// tests: the strip and its handle, on the screen
- (NSArray<NSString *> *)debugWhere {
    if (!_window || _window.hidden) return @[];
    CGRect z = _window.frame;
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"edge %.1f %.1f %.1f %.1f 0", z.origin.x, z.origin.y, z.size.width, z.size.height]];
    if (!_handle.hidden) [lines addObject:[NSString stringWithFormat:@"handle %.1f %.1f %.1f %.1f 0", z.origin.x + _handle.frame.origin.x,
                                           z.origin.y + _handle.frame.origin.y, _handle.frame.size.width, _handle.frame.size.height]];
    return lines;
}

@end
