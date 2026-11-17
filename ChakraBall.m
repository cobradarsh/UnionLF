/*  ChakraBall.m — the ball on the edge of the screen.

    A small window, only as big as the ball plus a finger's margin, in SpringBoard's main scene
    (a window outside a foreground scene never renders). Touches anywhere else go straight to
    whatever is underneath.

      tap                    open the menu (tap again, or anywhere outside it, to close)
      double / triple tap    whatever Settings → Chakra says (nothing, until you choose)
      slide                  the menu opens under the finger; lift over an icon to run it
                             (or, if Settings says dragging moves the ball: it moves)
      hold, then drag        move the ball; it snaps to the nearer edge and remembers the spot
      hold, then let go      the editor, or whatever "Hold" is set to

    While a double or triple tap is set, a single tap waits a quarter of a second to see whether
    another one follows; with neither set it acts at once.

    Left alone for a few seconds the ball fades and tucks part-way into the edge.

    Touch points are worked out as "point in the window + the window's origin". Both are read
    from the model layer, so they agree even while the window is still gliding out of the edge. */

#import "Chakra.h"

static const CGFloat kChakraPad = 8;            // invisible touch margin around the ball
static const CGFloat kChakraGap = 6;            // between the ball and the edge while it is out
static const double kChakraTapWait = 0.28;      // how long a tap waits for the next one
static const double kChakraHold = 0.5;          // how long a press is before it counts as a hold

typedef NS_ENUM(NSInteger, ChakraTouchMode) {
    ChakraTouchNone = 0,
    ChakraTouchPending,         // finger down, not yet a slide or a hold
    ChakraTouchSlide,           // picking from the menu
    ChakraTouchLifted,          // held, or dragged in "dragging moves the ball" mode: the ball follows the finger
};

@interface ChakraBall ()
- (void)_touchBegan:(CGPoint)p;
- (void)_touchMoved:(CGPoint)p;
- (void)_touchEnded:(CGPoint)p;
- (void)_touchCancelled;
@end

@interface ChakraBallView : UIView
@property (nonatomic, weak) ChakraBall *ball;
@end

@implementation ChakraBallView

- (CGPoint)_screenPoint:(NSSet<UITouch *> *)touches {
    UIWindow *w = self.window;
    CGPoint p = [touches.anyObject locationInView:w];
    return CGPointMake(p.x + w.frame.origin.x, p.y + w.frame.origin.y);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event     { [self.ball _touchBegan:[self _screenPoint:touches]]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event     { [self.ball _touchMoved:[self _screenPoint:touches]]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event     { [self.ball _touchEnded:[self _screenPoint:touches]]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self.ball _touchCancelled]; }

@end

@implementation ChakraBall {
    UIWindow *_window;
    ChakraBallView *_view;          // the whole window: the touch target
    UIView *_disc;                  // the ball you see (it carries the shadow and fades while resting)
    UIView *_face;                  // the dark disc with the coloured rim behind the plain wheel mark (the golden sun has none)
    UIImageView *_mark;             // what is on the face: the golden sun wheel, or the plain wheel mark
    NSInteger _markKind;            // which of the two was asked for when _mark was last filled (-1: not yet)
    BOOL _markIsSun;
    CGFloat _size;                  // the ball's diameter as built
    ChakraEdge _edge;
    CGFloat _yFrac;
    BOOL _shown, _tucked;
    ChakraTouchMode _mode;
    CGPoint _down, _last, _grab;
    BOOL _moved, _heldStill;        // _heldStill: this lift came from holding, not from a drag
    NSUInteger _holdGen, _idleGen, _tapGen;
    NSInteger _tapCount;            // taps so far in the run being counted
    CGFloat _markTurn;              // the wheel mark turns an eighth while the menu is open
}

+ (instancetype)shared {
    static ChakraBall *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [ChakraBall new]; });
    return b;
}

#pragma mark geometry

- (CGRect)_frameTucked:(BOOL)tucked {
    CGSize screen = [ChakraHost screenSize];
    UIEdgeInsets safe = [ChakraHost safeInsets];
    CGFloat side = _size + 2 * kChakraPad;
    CGFloat minC = safe.top + 6 + _size / 2.0, maxC = screen.height - safe.bottom - 6 - _size / 2.0;
    CGFloat cy = MAX(minC, MIN(MAX(minC, maxC), _yFrac * screen.height));
    CGFloat discX;
    if (tucked && [ChakraSettings shared].tuck) {
        CGFloat hidden = _size * 0.42;
        discX = (_edge == ChakraEdgeLeft) ? -hidden : (screen.width - _size + hidden);
    } else {
        discX = (_edge == ChakraEdgeLeft) ? kChakraGap : (screen.width - kChakraGap - _size);
    }
    return CGRectMake(discX - kChakraPad, cy - side / 2.0, side, side);
}

- (CGPoint)hub {
    CGRect f = [self _frameTucked:NO];
    return CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
}

#pragma mark building

- (void)_build {
    ChakraSettings *s = [ChakraSettings shared];
    _size = s.ballSize;
    _edge = s.ballEdge;
    _yFrac = s.ballY;
    _tucked = YES;
    _shown = NO;
    _mode = ChakraTouchNone;
    _tapCount = 0;

    _window = [ChakraHost overlayWindowAtLevel:100010];
    _window.frame = [self _frameTucked:YES];

    UIView *host = _window.rootViewController.view;
    _view = [[ChakraBallView alloc] initWithFrame:host.bounds];
    _view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _view.backgroundColor = UIColor.clearColor;
    _view.ball = self;
    [host addSubview:_view];

    _disc = [[UIView alloc] initWithFrame:CGRectMake(kChakraPad, kChakraPad, _size, _size)];
    _disc.userInteractionEnabled = NO;
    _disc.layer.shadowColor = UIColor.blackColor.CGColor;
    _disc.layer.shadowOpacity = 0.35;
    _disc.layer.shadowRadius = 5;
    _disc.layer.shadowOffset = CGSizeMake(0, 2);
    [_view addSubview:_disc];

    // A plain disc, not a blur: the ball rests half-transparent, and a blur view only works at full strength.
    _face = [[UIView alloc] initWithFrame:_disc.bounds];
    _face.userInteractionEnabled = NO;
    _face.layer.cornerRadius = _size / 2.0;
    _face.layer.borderWidth = 2;
    [_disc addSubview:_face];

    _mark = [[UIImageView alloc] initWithFrame:_disc.bounds];
    _mark.contentMode = UIViewContentModeCenter;
    _mark.tintColor = UIColor.whiteColor;
    _markKind = -1;                 // _paint fills it
    [_disc addSubview:_mark];

    [self _paint];
    _disc.alpha = s.idleAlpha;
}

- (void)_paint {
    ChakraSettings *s = [ChakraSettings shared];
    UIColor *accent = s.accentColor;
    NSInteger kind = s.ballIcon;
    if (kind != _markKind) {                                // only when it changes: this runs every couple of seconds
        // the golden sun stands on its own and takes the whole ball; the plain mark sits inside a disc
        UIImage *sun = (kind == 0) ? [ChakraGlyphs sunWithSize:round(_size)] : nil;
        _mark.image = sun ?: [ChakraGlyphs chakraWithSize:round(_size * 0.62)];
        _markIsSun = (sun != nil);
        _markKind = kind;
    }
    _face.hidden = _markIsSun;                              // nothing behind the golden sun, nothing round it
    CALayer *shade = _disc.layer;
    if (_markIsSun) {
        // The shadow is now cast by the gold itself (there is nothing else in the layer). Tighter and
        // darker than the disc's, so the rays keep their edge on a pale or a yellow wallpaper.
        shade.shadowOpacity = 0.7;
        shade.shadowRadius = 2.5;
        shade.shadowOffset = CGSizeMake(0, 1.5);
    } else {
        shade.shadowOpacity = 0.35;
        shade.shadowRadius = 5;
        shade.shadowOffset = CGSizeMake(0, 2);
        CGFloat r = 0, g = 0, b = 0, a = 1;
        [accent getRed:&r green:&g blue:&b alpha:&a];
        // night blue-black with a quarter of the accent mixed in
        _face.backgroundColor = [UIColor colorWithRed:0.105 * 0.74 + r * 0.26 green:0.105 * 0.74 + g * 0.26 blue:0.150 * 0.74 + b * 0.26 alpha:0.95];
        _face.layer.borderColor = accent.CGColor;
    }
    _mark.transform = CGAffineTransformMakeRotation([ChakraHost interfaceAngle] + _markTurn);
    [ChakraHost keepOutOfScreenshots:_window];
}

#pragma mark showing and hiding

- (void)setSuppressed:(BOOL)suppressed {
    if (_suppressed == suppressed) return;
    _suppressed = suppressed;
    [self refresh];
}

- (void)refresh {
    ChakraSettings *s = [ChakraSettings shared];
    BOOL want = s.enabled && !_suppressed && ![ChakraEditor isOpen];
    if (want && !s.lockScreen && [ChakraHost isLocked]) want = NO;
    if (want && s.hideLandscape && UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)[ChakraHost interfaceOrientation])) want = NO;

    if (!want) {
        if (_shown || (_window && !_window.hidden)) {
            _shown = NO;
            _mode = ChakraTouchNone;
            _holdGen++;
            _idleGen++;
            [self _forgetTaps];
            if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:NO completion:nil];
            _window.hidden = YES;
        }
        return;
    }

    if (_window && fabs(_size - s.ballSize) > 0.5) {         // a new size: build it again
        _window.hidden = YES;
        _window = nil;
        _shown = NO;
    }
    if (!_window) [self _build];

    UIWindowScene *scene = [ChakraHost mainScene];
    if (scene && _window.windowScene != scene) _window.windowScene = scene;
    [self _paint];

    // the spot may have been changed under Settings → Chakra → Ball Position
    BOOL moved = (_edge != s.ballEdge) || fabs(_yFrac - s.ballY) > 0.0005;
    if (_mode == ChakraTouchNone && moved) {
        _edge = s.ballEdge;
        _yFrac = s.ballY;
        if (_shown) {
            if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:NO completion:nil];
            // come out where it now lives, so the change can be seen while the slider is still moving
            _tucked = NO;
            _window.frame = [self _frameTucked:NO];
            _disc.alpha = 1;
            [self _restSoon];
        }
    }
    if (!_shown) {
        _shown = YES;
        _tucked = YES;
        _window.frame = [self _frameTucked:YES];
        _window.hidden = NO;
        _disc.alpha = 0;
        [UIView animateWithDuration:0.25 animations:^{ self->_disc.alpha = s.idleAlpha; }];
    } else if (_tucked && _mode == ChakraTouchNone && ![ChakraWheel shared].isOpen) {
        _disc.alpha = s.idleAlpha;                             // the resting strength may have been changed
        _window.frame = [self _frameTucked:YES];               // … or tucking switched on or off
    }
}

// Something is happening: come out of the edge at full strength.
- (void)_wake {
    _idleGen++;
    _tucked = NO;
    CGRect home = [self _frameTucked:NO];
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_window.frame = home;
        self->_disc.alpha = 1;
    } completion:nil];
}

- (void)_restSoon {
    NSUInteger gen = ++_idleGen;
    ChakraAfter(2.5, ^{
        if (gen != self->_idleGen || self->_mode != ChakraTouchNone || !self->_shown || [ChakraWheel shared].isOpen) return;
        self->_tucked = YES;
        CGRect rest = [self _frameTucked:YES];
        CGFloat alpha = [ChakraSettings shared].idleAlpha;
        [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
            self->_window.frame = rest;
            self->_disc.alpha = alpha;
        } completion:nil];
    });
}

- (void)_scaleDisc:(CGFloat)scale {
    [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_disc.transform = (scale == 1) ? CGAffineTransformIdentity : CGAffineTransformMakeScale(scale, scale);
    } completion:nil];
}

- (void)_turnMark:(BOOL)open {
    _markTurn = open ? M_PI_4 : 0;
    CGFloat angle = [ChakraHost interfaceAngle] + _markTurn;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_mark.transform = CGAffineTransformMakeRotation(angle);
    } completion:nil];
}

#pragma mark the menu

- (void)_openWheel {
    if ([ChakraWheel shared].isOpen) return;
    ChakraHapticPlay(ChakraHapticOpen);
    [[ChakraWheel shared] openFromHub:[self hub] edge:_edge];
}

// The menu is up, however it was opened: the ball comes out and its wheel mark turns.
- (void)wheelDidOpen {
    if (!_shown) return;
    [self _wake];
    [self _turnMark:YES];
}

- (void)wheelDidClose {
    [self _turnMark:NO];
    if (_mode == ChakraTouchNone) [self _restSoon];
}

#pragma mark taps and holds

- (void)_forgetTaps {
    _tapCount = 0;
    _tapGen++;
}

// Run what a double tap, triple tap or hold is set to.
- (void)_runGesture:(ChakraItem *)item named:(NSString *)name {
    ChakraHapticPlay(ChakraHapticCommit);
    ChakraLog(@"%@ on the ball: %@", name, item.key);
    BOOL toggle = item.isToggle;
    dispatch_block_t run = ^{
        [item perform];
        if (toggle) ChakraAfter(0.45, ^{ [ChakraHost toast:[NSString stringWithFormat:@"%@  ·  %@", item.title, item.isOn ? @"On" : @"Off"]]; });
    };
    if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:YES completion:run];
    else run();
}

// The run of taps is over: act on how many there were.
- (void)_settleTaps {
    NSInteger taps = _tapCount;
    [self _forgetTaps];
    if (taps <= 0) return;
    ChakraItem *item = nil;
    NSString *name = nil;
    if (taps >= 3) { item = [ChakraItems itemForGesture:@"Triple"]; name = @"triple tap"; }
    if (!item && taps >= 2) { item = [ChakraItems itemForGesture:@"Double"]; name = @"double tap"; }
    if (item) [self _runGesture:item named:name];
    else [self _openWheel];                                // one tap, or more taps with nothing set for them
}

- (void)_tapped {
    if ([ChakraWheel shared].isOpen) {                     // a tap on the ball while the menu is up closes it, at once
        [self _forgetTaps];
        [[ChakraWheel shared] closeAnimated:YES completion:nil];
        return;
    }
    NSInteger most = 1;
    if ([ChakraItems itemForGesture:@"Triple"]) most = 3;
    else if ([ChakraItems itemForGesture:@"Double"]) most = 2;
    _tapCount++;
    if (_tapCount >= most) { [self _settleTaps]; return; }
    NSUInteger gen = ++_tapGen;
    ChakraAfter(kChakraTapWait, ^{
        // (if a finger is down again, its own lift settles the run)
        if (gen == self->_tapGen && self->_mode == ChakraTouchNone) [self _settleTaps];
    });
}

#pragma mark touches

- (void)_touchBegan:(CGPoint)p {
    _mode = ChakraTouchPending;
    _down = p;
    _last = p;
    _moved = NO;
    _heldStill = NO;
    [self _wake];
    [self _scaleDisc:0.92];
    NSUInteger gen = ++_holdGen;
    ChakraAfter(kChakraHold, ^{
        if (gen == self->_holdGen && self->_mode == ChakraTouchPending) [self _liftFromHold:YES];
    });
}

// The ball comes off the edge and follows the finger: after a hold, or straight away when
// Settings says dragging moves the ball.
- (void)_liftFromHold:(BOOL)held {
    _mode = ChakraTouchLifted;
    _heldStill = held;
    _moved = NO;
    _down = _last;
    [self _forgetTaps];
    if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:YES completion:nil];
    CGRect f = _window.frame;
    _grab = CGPointMake(_last.x - f.origin.x, _last.y - f.origin.y);
    ChakraHapticPlay(held ? ChakraHapticLift : ChakraHapticOpen);
    [self _scaleDisc:1.2];
}

- (void)_touchMoved:(CGPoint)p {
    _last = p;
    CGFloat travel = hypot(p.x - _down.x, p.y - _down.y);
    ChakraSettings *s = [ChakraSettings shared];
    switch (_mode) {
        case ChakraTouchPending:
            if (travel <= 10) break;
            _holdGen++;
            [self _forgetTaps];
            if (s.dragMoves && !s.lockPosition && ![ChakraWheel shared].isOpen) {
                _last = _down;                                 // lift from where the finger went down, so the ball does not jump
                [self _liftFromHold:NO];
                _last = p;
                [self _touchMoved:p];
            } else {
                _mode = ChakraTouchSlide;
                [self _scaleDisc:1];
                [self _openWheel];
                [[ChakraWheel shared] hoverAtScreenPoint:p];
            }
            break;
        case ChakraTouchSlide:
            [[ChakraWheel shared] hoverAtScreenPoint:p];
            break;
        case ChakraTouchLifted: {
            if (s.lockPosition) break;                         // held, but the spot is locked: it stays put
            if (travel > 8) _moved = YES;
            CGRect f = _window.frame;
            f.origin = CGPointMake(p.x - _grab.x, p.y - _grab.y);
            _window.frame = f;
            break;
        }
        default:
            break;
    }
}

- (void)_touchEnded:(CGPoint)p {
    ChakraTouchMode mode = _mode;
    _mode = ChakraTouchNone;
    _holdGen++;
    _last = p;
    [self _scaleDisc:1];
    switch (mode) {
        case ChakraTouchPending:
            [self _tapped];
            break;
        case ChakraTouchSlide:
            if (![[ChakraWheel shared] commitHover]) [[ChakraWheel shared] closeAnimated:YES completion:nil];
            break;
        case ChakraTouchLifted:
            if (_moved) {
                [self _drop];
            } else {
                [self _snapHome];
                if (_heldStill) {
                    ChakraItem *item = [ChakraItems itemForGesture:@"Hold"];
                    if (item) [self _runGesture:item named:@"hold"];
                }
            }
            break;
        default:
            break;
    }
    if (![ChakraWheel shared].isOpen) [self _restSoon];
}

- (void)_touchCancelled {
    ChakraTouchMode mode = _mode;
    _mode = ChakraTouchNone;
    _holdGen++;
    [self _forgetTaps];
    [self _scaleDisc:1];
    if (mode == ChakraTouchSlide) [[ChakraWheel shared] closeAnimated:YES completion:nil];
    if (mode == ChakraTouchLifted) { if (_moved) [self _drop]; else [self _snapHome]; }
    if (![ChakraWheel shared].isOpen) [self _restSoon];
}

// Let go after a drag: the nearer edge, the height it was dropped at.
- (void)_drop {
    CGSize screen = [ChakraHost screenSize];
    CGRect f = _window.frame;
    _edge = (CGRectGetMidX(f) < screen.width / 2.0) ? ChakraEdgeLeft : ChakraEdgeRight;
    _yFrac = MAX(0.0, MIN(1.0, CGRectGetMidY(f) / MAX(1, screen.height)));
    [[ChakraSettings shared] setBallEdge:_edge y:_yFrac];
    ChakraLog(@"ball moved: %@ edge, %.0f%% down", _edge == ChakraEdgeLeft ? @"left" : @"right", _yFrac * 100);
    [self _snapHome];
}

- (void)_snapHome {
    _tucked = NO;
    CGRect home = [self _frameTucked:NO];
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_window.frame = home;
    } completion:nil];
}

#pragma mark tests

- (void)debugMoveToEdge:(ChakraEdge)edge y:(CGFloat)y {
    [[ChakraSettings shared] setBallEdge:edge y:y];
    if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:NO completion:nil];
    [self refresh];
}

- (void)debugTouch:(NSInteger)phase at:(CGPoint)point {
    if (!_shown) { ChakraLog(@"touch: the ball is hidden"); return; }
    switch (phase) {
        case 0:  [self _touchBegan:point]; break;
        case 1:  [self _touchMoved:point]; break;
        case 2:  [self _touchEnded:point]; break;
        default: [self _touchCancelled]; break;
    }
}

- (void)debugTap {
    if (!_shown) { ChakraLog(@"tap: the ball is hidden"); return; }
    CGPoint hub = [self hub];
    [self _touchBegan:hub];
    [self _touchEnded:hub];
}

- (void)debugSlideToIndex:(NSUInteger)index {
    if (!_shown) { ChakraLog(@"slide: the ball is hidden"); return; }
    CGPoint hub = [self hub];
    CGFloat inward = (_edge == ChakraEdgeLeft) ? 24 : -24;
    [self _touchBegan:hub];
    [self _touchMoved:CGPointMake(hub.x + inward, hub.y)];           // far enough to count as a slide: the menu opens
    if (_mode != ChakraTouchSlide || ![ChakraWheel shared].isOpen || index >= [ChakraWheel shared].itemCount) {
        ChakraLog(@"slide %lu: not sliding (mode %ld, menu %@)", (unsigned long)index, (long)_mode, [ChakraWheel shared].isOpen ? @"open" : @"closed");
        [self _touchEnded:CGPointMake(hub.x + inward, hub.y)];
        return;
    }
    CGPoint target = [[ChakraWheel shared] centerOfIndex:index];
    [self _touchMoved:CGPointMake((hub.x + target.x) / 2.0, (hub.y + target.y) / 2.0)];
    [self _touchMoved:target];
    [self _touchEnded:target];
}

- (NSString *)debugState {
    if (!_window) return @"ball not built";
    return [NSString stringWithFormat:@"ball %@, %@ edge, y %.3f, size %.0f, window %@, %@, strength %.2f, mode %ld, taps %ld",
            _shown ? @"shown" : @"hidden", _edge == ChakraEdgeLeft ? @"left" : @"right", _yFrac, _size,
            NSStringFromCGRect(_window.frame), _tucked ? @"tucked" : @"out", _disc.alpha, (long)_mode, (long)_tapCount];
}

@end
