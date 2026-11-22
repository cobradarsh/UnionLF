/*  AtelierGestures.m — fingers: a mini's tap, hold and swipe; the swipe up that closes the bench;
    and the phone's own Home gesture.

    Why not gesture recognisers. A pan recogniser spends the first ten points deciding that it is
    a pan and leaves them out of what it reports; a hold recogniser fires after 0.4 s if the
    finger has moved less than ten. Put on one view, a slow, careful swipe became a hold (the
    menu opened instead: seen in the simulator), a short one was never long enough, and a touch
    that the system took away was never heard of at all. So the views here follow the finger
    themselves, from the point where it came down:

      AtelierTrack       where a finger came down, where it is, how fast it was going when it left
      AtelierShield      the view over a mini. Under 8 points of movement it is a tap, or after
                         0.4 s a hold (its menu); from 8 points on it is a swipe and stays one:
                         no menu can open after a swipe has begun.
      AtelierCloseStrip  the lowest strip of the bench (the dock's height and everything below
                         it). A finger that goes up from it carries the bench with it.

    The Home gesture (AtelierHome). On a phone without a Home button the bottom edge belongs to
    SpringBoard: a finger that starts there is SpringBoard's, and a view of ours hears nothing
    of it or has it taken away after a few points. With the bench up over the Home Screen the
    gesture then did nothing visible, and the bench stayed. Two things now, both only watching:

      1. While the bench is up, a target of ours sits on SpringBoard's own Home recogniser
         (-[SBSwitcherController homeGestureBottomEdgeRecognizer], the deck grabber's pull
         recogniser, and any other "HomeGesture" recogniser in the window that holds the system
         gestures). SpringBoard's targets are untouched; ours is told of the same finger and
         moves the bench with it. Taken off again when the bench goes away.
      2. Small replacements that call the old code first thing and change nothing: the places
         where SpringBoard is told "home" (the grabber pull beginning, the switcher's pan
         beginning, the Home Screen's own bar swipe, a Home button press, the simulated press
         that tests use). Each is put in only if the method is there with the arguments it is
         expected to have, and each says so in the log when it fires with the bench up.

    Every name was found in the phone's iOS 16.5 cache (dyld_shared_cache_arm64e.symbols) on
    22 Nov 2026. Which of them a real finger sets off, only the phone can show: the log says.   */

#import "Atelier.h"

#pragma mark - a finger, followed

@implementation AtelierTrack {
    CGPoint _points[8];
    CFTimeInterval _times[8];
    int _count, _head;
}

- (void)_note:(CGPoint)p time:(CFTimeInterval)t {
    _points[_head] = p;
    _times[_head] = t;
    _head = (_head + 1) % 8;
    if (_count < 8) _count++;
}

- (void)beginAt:(CGPoint)p time:(CFTimeInterval)t {
    _down = _now = p;
    _downTime = _lastTime = t;
    _count = 0;
    _head = 0;
    [self _note:p time:t];
}

- (void)moveTo:(CGPoint)p time:(CFTimeInterval)t {
    _now = p;
    _lastTime = t;
    [self _note:p time:t];
}

- (CGPoint)travel {
    return CGPointMake(_now.x - _down.x, _now.y - _down.y);
}

// What the finger was doing at the very end: from the oldest of its last samples that is no more
// than 50 ms old (a flick is over in a tenth of a second; a longer look would count its start
// in). The lift is a sample of its own, so a finger that stopped and then lifted has no speed:
// with nothing in those 50 ms, the sample before them is used, however old.
- (CGPoint)velocity {
    if (_count < 2) return CGPointZero;
    int newest = (_head + 7) % 8, pick = -1;
    for (int i = 1; i < _count; i++) {
        int k = (newest - i + 8) % 8;
        BOOL old = _times[newest] - _times[k] > 0.05;
        if (old && pick >= 0) break;
        pick = k;
        if (old) break;
    }
    if (pick < 0) return CGPointZero;
    CFTimeInterval dt = _times[newest] - _times[pick];
    if (dt < 0.004) return CGPointZero;
    return CGPointMake((_points[newest].x - _points[pick].x) / dt, (_points[newest].y - _points[pick].y) / dt);
}

@end

#pragma mark - the view over a mini

@implementation AtelierShield {
    AtelierTrack *_track;
    __weak UITouch *_touch;
    BOOL _down, _swiping, _held;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.multipleTouchEnabled = NO;
    return self;
}

- (void)_reset {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hold) object:nil];
    _down = NO;
    _touch = nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_down) return;                                   // one finger at a time
    UITouch *touch = touches.anyObject;
    _touch = touch;
    _down = YES;
    _swiping = NO;
    _held = NO;
    _track = [AtelierTrack new];
    [_track beginAt:[touch locationInView:nil] time:touch.timestamp];
    [self performSelector:@selector(_hold) withObject:nil afterDelay:0.40 inModes:@[ NSRunLoopCommonModes ]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = _touch;
    if (!_down || !touch || ![touches containsObject:touch]) return;
    [_track moveTo:[touch locationInView:nil] time:touch.timestamp];
    if (_held) return;                                   // the menu is open: this finger has done its work
    CGPoint d = _track.travel;
    if (!_swiping && hypot(d.x, d.y) >= 8) {
        _swiping = YES;                                  // a swipe from here on: no hold can come any more
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hold) object:nil];
        [self.delegate shield:self swipe:AtelierTouchBegan track:_track];
    }
    if (_swiping) [self.delegate shield:self swipe:AtelierTouchMoved track:_track];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = _touch;
    if (!_down || (touch && ![touches containsObject:touch])) return;
    if (touch) [_track moveTo:[touch locationInView:nil] time:touch.timestamp];
    BOOL swiping = _swiping, held = _held;
    AtelierTrack *track = _track;
    [self _reset];
    if (swiping) [self.delegate shield:self swipe:AtelierTouchEnded track:track];
    else if (!held) [self.delegate shieldTapped:self];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_down) return;
    BOOL swiping = _swiping;
    AtelierTrack *track = _track;
    [self _reset];
    if (swiping) [self.delegate shield:self swipe:AtelierTouchCancelled track:track];
}

- (void)_hold {
    if (!_down || _swiping || _held) return;
    _held = YES;
    [self.delegate shieldHeld:self];
}

@end

#pragma mark - the strip a swipe up closes the bench from

@implementation AtelierCloseStrip {
    AtelierTrack *_track;
    __weak UITouch *_touch;
    BOOL _down, _going, _mine;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.multipleTouchEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_down) return;
    UITouch *touch = touches.anyObject;
    _touch = touch;
    _down = YES;
    _going = NO;
    _mine = NO;
    _track = [AtelierTrack new];
    [_track beginAt:[touch locationInView:nil] time:touch.timestamp];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = _touch;
    if (!_down || !touch || ![touches containsObject:touch]) return;
    [_track moveTo:[touch locationInView:nil] time:touch.timestamp];
    CGPoint d = _track.travel;
    CGFloat up = -d.y;
    AtelierBench *bench = [AtelierBench shared];
    if (!_going && up >= 6 && up > fabs(d.x)) {
        _going = YES;
        _mine = [bench beginDragOpening:NO motion:AtelierMotionLift owner:self];
    }
    if (_mine) [bench dragTo:1.0 - MIN(0.9, MAX(0, up) / 280.0) owner:self];
}

- (void)_finish:(BOOL)cancelled {
    if (!_down) return;
    UITouch *touch = _touch;
    if (touch && !cancelled) [_track moveTo:[touch locationInView:nil] time:touch.timestamp];
    CGPoint d = _track.travel;
    CGFloat up = -d.y, speed = -_track.velocity.y;
    BOOL going = _going, mine = _mine;
    _down = NO;
    _touch = nil;
    AtelierBench *bench = [AtelierBench shared];
    if (!going) {
        if (!cancelled && hypot(d.x, d.y) < 8) { [bench backdropTapped]; return; }       // a tap on the backdrop
        AtelierLog(@"bottom swipe: began at %.0f,%.0f · moved %.0f up, %.0f sideways · not closed: %@", _track.down.x, _track.down.y,
                   up, fabs(d.x), cancelled ? @"the touch was taken away before it had gone up 6 pt" : @"it did not go up");
        return;
    }
    // far enough, or flicked; or the system took the finger while it was going up, which is the
    // Home gesture as seen from here
    BOOL far = up >= 40, flick = up >= 12 && speed >= 350, taken = cancelled && up >= 10;
    BOOL close = cancelled ? taken : (far || flick);
    NSString *how = cancelled ? @"the system took the touch as it went up" : (far ? @"travel" : @"a flick");
    NSString *whyNot = cancelled ? @"the touch was taken away after too little travel" : @"under 40 pt and no flick (350 pt/s after 12 pt)";
    AtelierLog(@"bottom swipe: began at %.0f,%.0f · %.0f pt up · %.0f pt/s at the lift · %@", _track.down.x, _track.down.y, up, speed,
               !mine ? @"something else was moving the bench" : (close ? [@"closed by " stringByAppendingString:how] : [@"not closed: " stringByAppendingString:whyNot]));
    if (mine) [bench endDrag:close velocity:MAX(0, speed) / 280.0 reason:@"swipe up from the bottom" owner:self];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = _touch;
    if (touch && ![touches containsObject:touch]) return;
    [self _finish:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self _finish:YES];
}

@end

#pragma mark - the phone's own Home gesture

@implementation AtelierHome {
    NSHashTable<UIGestureRecognizer *> *_watched;        // SpringBoard's recognisers our target is on
    BOOL _going, _mine;                                  // a Home swipe is under way / and it is moving the bench
    CGFloat _reach;                                      // the furthest up it has been
    CFAbsoluteTime _beganAt;
}

static NSMutableArray<NSString *> *gHookNotes;           // one line per replacement: in place, or why not

+ (instancetype)shared {
    static AtelierHome *home;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ home = [AtelierHome new]; });
    return home;
}

#pragma mark watching SpringBoard's recogniser

- (void)_collectFrom:(UIView *)view into:(NSMutableArray *)found depth:(int)depth {
    for (UIGestureRecognizer *g in view.gestureRecognizers) {
        if ([NSStringFromClass([g class]) containsString:@"HomeGesture"] && ![found containsObject:g]) [found addObject:g];
    }
    if (depth >= 4) return;
    for (UIView *sub in view.subviews) [self _collectFrom:sub into:found depth:depth + 1];
}

- (void)benchCameUp {
    [self benchWentAway];
    NSMutableArray *found = [NSMutableArray array];
    void (^add)(id) = ^(id g) {
        if ([g isKindOfClass:UIGestureRecognizer.class] && ![found containsObject:g]) [found addObject:g];
    };
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            id switcher = AtelierMsg(scene, @"switcherController");
            id manager = AtelierMsg(switcher, @"gestureManager");
            add(AtelierMsg(switcher, @"homeGestureBottomEdgeRecognizer"));
            add(AtelierMsg(manager, @"homeGestureBottomEdgeRecognizer"));
            add(AtelierMsg(AtelierMsg(manager, @"deckGrabberTongue"), @"edgePullGestureRecognizer"));
            id window = AtelierMsg(AtelierMsg(scene, @"systemGestureManager"), @"windowForSystemGestures");
            if ([window isKindOfClass:UIView.class]) [self _collectFrom:window into:found depth:0];
        }
    } @catch (NSException *e) {
        AtelierLog(@"Home gesture: looking for SpringBoard's recogniser threw %@", e.reason);
    }
    _watched = [NSHashTable weakObjectsHashTable];
    NSCountedSet *kinds = [NSCountedSet set];
    for (UIGestureRecognizer *g in found) {
        [g addTarget:self action:@selector(_homePan:)];
        [_watched addObject:g];
        [kinds addObject:NSStringFromClass([g class])];
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *kind in kinds) [names addObject:[NSString stringWithFormat:@"%@ x%lu", kind, (unsigned long)[kinds countForObject:kind]]];
    static NSString *said;
    NSString *now = found.count ? [NSString stringWithFormat:@"watching %lu of SpringBoard's own recognisers (%@)", (unsigned long)found.count, [names componentsJoinedByString:@", "]]
                                : @"none of SpringBoard's Home recognisers was found: only the replacements can tell";
    if (![now isEqualToString:said]) { said = now; AtelierLog(@"Home gesture: %@", now); }       // said once, and again only if it changes
    _going = NO;
    _mine = NO;
}

- (void)benchWentAway {
    for (UIGestureRecognizer *g in _watched) [g removeTarget:self action:@selector(_homePan:)];
    _watched = nil;
    _going = NO;
    _mine = NO;
}

// SpringBoard's own recogniser reports: the same finger SpringBoard is following.
- (void)_homePan:(UIGestureRecognizer *)g {
    AtelierBench *bench = [AtelierBench shared];
    if (!bench.visible) return;
    UIView *view = g.view;
    CGPoint moved = CGPointZero, speed = CGPointZero, at = [g locationInView:view];
    if ([g respondsToSelector:@selector(translationInView:)]) moved = [(UIPanGestureRecognizer *)g translationInView:view];
    if ([g respondsToSelector:@selector(velocityInView:)]) speed = [(UIPanGestureRecognizer *)g velocityInView:view];
    CGFloat up = -moved.y, upSpeed = -speed.y;
    CGFloat height = view.bounds.size.height > 100 ? view.bounds.size.height : [AtelierHost screenSize].height;
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _going = NO;
            _mine = NO;
            // only a swipe that comes up from the bottom edge is the Home gesture
            if (at.y + up < height - 90) {
                AtelierLog(@"Home gesture: %@ began at y %.0f of %.0f, not at the bottom edge: left alone", NSStringFromClass([g class]), at.y, height);
                break;
            }
            _going = YES;
            _reach = up;
            _beganAt = CFAbsoluteTimeGetCurrent();
            _mine = [bench beginDragOpening:NO motion:AtelierMotionLift owner:self];
            AtelierLog(@"Home gesture: SpringBoard's %@ began at %.0f,%.0f with the bench up%@", NSStringFromClass([g class]), at.x, at.y,
                       _mine ? @": the bench follows it" : @" (the bench is not free to follow)");
            if (_mine) [bench dragTo:1.0 - MIN(0.9, MAX(0, up) / 280.0) owner:self];
            break;
        }
        case UIGestureRecognizerStateChanged:
            if (!_going) break;
            _reach = MAX(_reach, up);
            if (_mine) [bench dragTo:1.0 - MIN(0.9, MAX(0, up) / 280.0) owner:self];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!_going) break;
            _going = NO;
            BOOL ended = g.state == UIGestureRecognizerStateEnded;
            // as iOS does with an app: a real swipe up sends it away, a nudge lets it settle back
            BOOL close = ended ? (up >= 40 || (up >= 12 && upSpeed >= 350)) : _reach >= 60;
            AtelierLog(@"Home gesture: %@ · %.0f pt up (most %.0f) · %.0f pt/s · %@", ended ? @"lifted" : @"given up by SpringBoard", up, _reach, upSpeed,
                       !_mine ? @"the bench was not following" : (close ? @"bench closed" : @"bench stays: under 40 pt and no flick"));
            if (_mine) [bench endDrag:close velocity:MAX(0, upSpeed) / 280.0 reason:@"Home gesture" owner:self];
            _mine = NO;
            break;
        }
        default:
            break;
    }
}

- (BOOL)_swipeUnderWay {
    return _going;
}

#pragma mark the replacements

// A Home swipe has begun, says SpringBoard. If the recogniser above is being followed it will
// close the bench with the finger; if it is not (the recogniser was not found, or is another
// one), the bench goes now.
static void AtelierHomeBegan(NSString *what) {
    if (![AtelierBench shared].visible) return;
    AtelierLog(@"Home: %@ fired with the bench up", what);
    dispatch_async(dispatch_get_main_queue(), ^{         // after this turn: our own target on the recogniser runs later in it
        AtelierBench *bench = [AtelierBench shared];
        if (!bench.visible || [[AtelierHome shared] _swipeUnderWay]) return;
        [bench homeAction:[NSString stringWithFormat:@"Home gesture, heard through %@", what]];
    });
}

// "Go home", done: the bench goes.
static void AtelierHomeDone(NSString *what) {
    if (![AtelierBench shared].visible) return;
    AtelierLog(@"Home: %@ fired with the bench up", what);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AtelierBench shared] homeAction:[NSString stringWithFormat:@"Home, heard through %@", what]];
    });
}

static void (*orig_tongueBegan)(id, SEL, id, double, double, id);
static void hook_tongueBegan(id self, SEL _cmd, id tongue, double distance, double velocity, id gesture) {
    if (orig_tongueBegan) orig_tongueBegan(self, _cmd, tongue, distance, velocity, gesture);
    @try { AtelierHomeBegan(@"the grabber pull beginning"); } @catch (__unused id e) {}
}

static void (*orig_switcherPanBegan)(id, SEL, id);
static void hook_switcherPanBegan(id self, SEL _cmd, id gesture) {
    if (orig_switcherPanBegan) orig_switcherPanBegan(self, _cmd, gesture);
    @try { AtelierHomeBegan(@"the switcher's pan beginning"); } @catch (__unused id e) {}
}

// These three may return a BOOL or nothing; whatever comes back is handed on as it came.
static BOOL (*orig_barSwipe)(id, SEL, id);
static BOOL hook_barSwipe(id self, SEL _cmd, id view) {
    BOOL r = orig_barSwipe ? orig_barSwipe(self, _cmd, view) : NO;
    @try { AtelierHomeDone(@"the Home Screen's bar swipe"); } @catch (__unused id e) {}
    return r;
}

static BOOL (*orig_homeTap)(id, SEL);
static BOOL hook_homeTap(id self, SEL _cmd) {
    BOOL r = orig_homeTap ? orig_homeTap(self, _cmd) : NO;
    @try { AtelierHomeDone(@"the icon controller's Home tap"); } @catch (__unused id e) {}
    return r;
}

static BOOL (*orig_homePress)(id, SEL, id);
static BOOL hook_homePress(id self, SEL _cmd, id scene) {
    BOOL r = orig_homePress ? orig_homePress(self, _cmd, scene) : NO;
    @try { AtelierHomeDone(@"a Home button press"); } @catch (__unused id e) {}
    return r;
}

static BOOL (*orig_homePressFrom)(id, SEL, id, long long);
static BOOL hook_homePressFrom(id self, SEL _cmd, id scene, long long source) {
    BOOL r = orig_homePressFrom ? orig_homePressFrom(self, _cmd, scene, source) : NO;
    @try { AtelierHomeDone(@"a Home button press (with its source)"); } @catch (__unused id e) {}
    return r;
}

static void (*orig_simulatedPress)(id, SEL, id);
static void hook_simulatedPress(id self, SEL _cmd, id completion) {
    if (orig_simulatedPress) orig_simulatedPress(self, _cmd, completion);
    @try { AtelierHomeDone(@"a simulated Home press"); } @catch (__unused id e) {}
}

+ (void)install {
    static BOOL done;
    if (done) return;
    done = YES;
    gHookNotes = [NSMutableArray array];
    // class, method, what it must look like (what it returns, then its arguments: @ object, d number
    // with a fraction, q whole number, v nothing, ? anything), the new code, where the old code goes
    struct { const char *cls, *sel, *shape; IMP code; IMP *old; } hooks[] = {
        { "SBFluidSwitcherGestureManager", "grabberTongueBeganPulling:withDistance:andVelocity:andGesture:", "v@dd@", (IMP)hook_tongueBegan, (IMP *)&orig_tongueBegan },
        { "SBFluidSwitcherGestureManager", "_handleSwitcherPanGestureBegan:", "v@", (IMP)hook_switcherPanBegan, (IMP *)&orig_switcherPanBegan },
        { "SBIconController", "homeGesturePerformedForBarSwipeAffordanceView:", "?@", (IMP)hook_barSwipe, (IMP *)&orig_barSwipe },
        { "SBIconController", "handleHomeButtonTap", "?", (IMP)hook_homeTap, (IMP *)&orig_homeTap },
        { "SBUIController", "handleHomeButtonSinglePressUpForWindowScene:", "?@", (IMP)hook_homePress, (IMP *)&orig_homePress },
        { "SBUIController", "handleHomeButtonSinglePressUpForWindowScene:withSourceType:", "?@q", (IMP)hook_homePressFrom, (IMP *)&orig_homePressFrom },
        { "SpringBoard", "_simulateHomeButtonPressWithCompletion:", "v@", (IMP)hook_simulatedPress, (IMP *)&orig_simulatedPress },
    };
    NSUInteger placed = 0, count = sizeof(hooks) / sizeof(hooks[0]);
    for (NSUInteger i = 0; i < count; i++) {
        NSString *why = nil;
        BOOL ok = AtelierHookShaped(@(hooks[i].cls), @(hooks[i].sel), hooks[i].shape, hooks[i].code, hooks[i].old, &why);
        if (ok) placed++;
        [gHookNotes addObject:[NSString stringWithFormat:@"-[%s %s]: %@", hooks[i].cls, hooks[i].sel, ok ? @"in place" : (why ?: @"not placed")]];
    }
    AtelierLog(@"Home: %lu of %lu replacements in place%@", (unsigned long)placed, (unsigned long)count, placed == count ? @"" : @" (the log has the others, each with its reason)");
    for (NSString *note in gHookNotes) if (![note hasSuffix:@"in place"]) AtelierLog(@"Home: %@", note);
}

+ (void)benchCameUp { [[self shared] benchCameUp]; }
+ (void)benchWentAway { [[self shared] benchWentAway]; }

+ (NSString *)debugState {
    AtelierHome *home = [self shared];
    NSMutableArray<NSString *> *kinds = [NSMutableArray array];
    for (UIGestureRecognizer *g in home->_watched) [kinds addObject:[NSString stringWithFormat:@"%@ in %@", NSStringFromClass([g class]), NSStringFromClass([g.view class])]];
    return [NSString stringWithFormat:@"Home: watching [%@] · replacements:\n    %@", [kinds componentsJoinedByString:@", "],
            [gHookNotes componentsJoinedByString:@"\n    "] ?: @"(not put in yet)"];
}

@end
