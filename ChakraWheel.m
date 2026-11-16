/*  ChakraWheel.m — the menu the ball opens.

    A full-screen window that exists only while the menu is up: a dimmed backdrop, a frosted
    plate (a disc around the ball for the wheel, a panel for the column) and one view per entry.
    ChakraLayout says where the icons go.

    Two ways to pick:
      • slide: the finger that went down on the ball keeps moving; the nearest icon lights up,
        ticks, and lifting the finger runs it (ChakraBall feeds the points in, since the touch
        belongs to its window);
      • tap: with the menu open, touch an icon. Touch anywhere else and it closes.
    A switch (Flashlight, Wi-Fi…) that is tapped flips and leaves the menu open, the way Control
    Centre does; everything else closes the menu first and runs once it is out of the way.

    The window stays in portrait. When the app in front is in landscape the icons and the
    caption are turned instead, so they read upright.                                        */

#import "Chakra.h"

#pragma mark - one entry

@interface ChakraItemView : UIView
@property (nonatomic, strong, readonly) ChakraItem *item;
@property (nonatomic) BOOL lit;
- (instancetype)initWithItem:(ChakraItem *)item icon:(CGFloat)icon label:(BOOL)label;
- (void)refreshIcon;
@end

@implementation ChakraItemView {
    UIImageView *_iconView;
    UILabel *_label;
    CGFloat _icon;
}

- (instancetype)initWithItem:(ChakraItem *)item icon:(CGFloat)icon label:(BOOL)label {
    // The icon sits in the middle of the view, so turning the view leaves it where it is.
    CGFloat w = icon + 26, h = icon + 40;
    if ((self = [super initWithFrame:CGRectMake(0, 0, w, h)])) {
        _item = item;
        _icon = icon;
        self.userInteractionEnabled = NO;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake((w - icon) / 2.0, (h - icon) / 2.0, icon, icon)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.shadowColor = UIColor.blackColor.CGColor;
        _iconView.layer.shadowOpacity = 0.35;
        _iconView.layer.shadowRadius = 5;
        _iconView.layer.shadowOffset = CGSizeMake(0, 2);
        [self addSubview:_iconView];

        if (label) {
            _label = [[UILabel alloc] initWithFrame:CGRectMake(0, (h + icon) / 2.0 + 3, w, 14)];
            _label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
            _label.textColor = UIColor.whiteColor;
            _label.textAlignment = NSTextAlignmentCenter;
            _label.lineBreakMode = NSLineBreakByTruncatingTail;
            _label.text = item.title;
            _label.layer.shadowColor = UIColor.blackColor.CGColor;
            _label.layer.shadowOpacity = 0.7;
            _label.layer.shadowRadius = 2;
            _label.layer.shadowOffset = CGSizeZero;
            [self addSubview:_label];
        }
        [self refreshIcon];
    }
    return self;
}

- (void)refreshIcon { _iconView.image = [_item iconWithSize:_icon]; }

- (void)setLit:(BOOL)lit {
    if (_lit == lit) return;
    _lit = lit;
    _iconView.layer.shadowColor = (lit ? [ChakraSettings shared].accentColor : UIColor.blackColor).CGColor;
    _iconView.layer.shadowOpacity = lit ? 0.95 : 0.35;
    _iconView.layer.shadowRadius = lit ? 10 : 5;
    _iconView.layer.shadowOffset = lit ? CGSizeZero : CGSizeMake(0, 2);
    [UIView animateWithDuration:0.14 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self->_iconView.transform = lit ? CGAffineTransformMakeScale(1.22, 1.22) : CGAffineTransformIdentity;
    } completion:nil];
}

@end

#pragma mark - the view of the window: taps while the menu is open

@interface ChakraWheel ()
- (void)_touchAt:(CGPoint)p phase:(NSInteger)phase;      // 0 down, 1 moved, 2 up, 3 cancelled
@end

@interface ChakraWheelRootView : UIView
@property (nonatomic, weak) ChakraWheel *wheel;
@end

@implementation ChakraWheelRootView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.wheel _touchAt:[touches.anyObject locationInView:self] phase:0];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.wheel _touchAt:[touches.anyObject locationInView:self] phase:1];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.wheel _touchAt:[touches.anyObject locationInView:self] phase:2];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.wheel _touchAt:CGPointZero phase:3];
}
@end

#pragma mark - the menu

@implementation ChakraWheel {
    UIWindow *_window;
    ChakraWheelRootView *_root;
    UIView *_backdrop;
    UIVisualEffectView *_plate;
    NSMutableArray<ChakraItemView *> *_views;
    ChakraLayout *_layout;
    ChakraItemView *_hover;
    UIVisualEffectView *_caption;
    UILabel *_captionLabel;
    CGPoint _hub;
    ChakraEdge _edge;
    CGFloat _angle;              // how far entries are turned to read upright
    BOOL _open, _closing;
    NSUInteger _idleGen;
}

+ (instancetype)shared {
    static ChakraWheel *w;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ w = [ChakraWheel new]; });
    return w;
}

- (BOOL)isOpen { return _open; }
- (NSUInteger)itemCount { return _views.count; }

- (void)_ensureWindow {
    UIWindowScene *scene = [ChakraHost mainScene];
    if (!_window) {
        _window = [ChakraHost overlayWindowAtLevel:100005];
        _root = [[ChakraWheelRootView alloc] initWithFrame:_window.bounds];
        _root.wheel = self;
        _root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _root.backgroundColor = UIColor.clearColor;
        [_window.rootViewController.view addSubview:_root];
    } else if (scene && _window.windowScene != scene) {
        _window.windowScene = scene;
    }
}

- (CGAffineTransform)_upright { return CGAffineTransformMakeRotation(_angle); }
- (CGAffineTransform)_folded  { return CGAffineTransformScale(CGAffineTransformMakeRotation(_angle), 0.3, 0.3); }

- (void)_buildWithItems:(NSArray<ChakraItem *> *)items {
    ChakraSettings *s = [ChakraSettings shared];
    for (UIView *v in [_root.subviews copy]) [v removeFromSuperview];
    _views = [NSMutableArray array];
    _hover = nil;

    _backdrop = [[UIView alloc] initWithFrame:_root.bounds];
    _backdrop.backgroundColor = s.dim ? [UIColor colorWithWhite:0 alpha:0.32] : UIColor.clearColor;
    _backdrop.userInteractionEnabled = NO;
    [_root addSubview:_backdrop];

    _plate = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _plate.userInteractionEnabled = NO;
    _plate.clipsToBounds = YES;
    _plate.layer.borderWidth = 1;
    _plate.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    if (s.style == ChakraStyleColumn) {
        _plate.frame = _layout.plateRect;
        _plate.layer.cornerRadius = MIN(28, MIN(_plate.bounds.size.width, _plate.bounds.size.height) / 2.0);
    } else {
        CGFloat R = _layout.plateRadius;
        _plate.frame = CGRectMake(_hub.x - R, _hub.y - R, 2 * R, 2 * R);
        _plate.layer.cornerRadius = R;
        // the rings and spokes of the wheel, faint
        UIBezierPath *path = [UIBezierPath bezierPath];
        for (NSNumber *ring in _layout.ringRadii) {
            CGFloat r = ring.doubleValue;
            [path moveToPoint:CGPointMake(R + r, R)];
            [path addArcWithCenter:CGPointMake(R, R) radius:r startAngle:0 endAngle:2 * M_PI clockwise:YES];
        }
        CGFloat inner = s.ballSize / 2.0 + 10;
        for (int i = 0; i < 8; i++) {
            CGFloat a = i * M_PI / 4.0 + M_PI / 8.0;
            [path moveToPoint:CGPointMake(R + cos(a) * inner, R + sin(a) * inner)];
            [path addLineToPoint:CGPointMake(R + cos(a) * (R - 1), R + sin(a) * (R - 1))];
        }
        CAShapeLayer *lines = [CAShapeLayer layer];
        lines.frame = _plate.bounds;
        lines.fillColor = UIColor.clearColor.CGColor;
        lines.strokeColor = [UIColor colorWithWhite:1 alpha:0.09].CGColor;
        lines.lineWidth = 1;
        lines.path = path.CGPath;
        [_plate.contentView.layer addSublayer:lines];
    }
    UIView *tint = [[UIView alloc] initWithFrame:_plate.bounds];
    tint.backgroundColor = [s.accentColor colorWithAlphaComponent:0.10];
    tint.userInteractionEnabled = NO;
    [_plate.contentView insertSubview:tint atIndex:0];
    [_root addSubview:_plate];

    // Labels are laid out for portrait; turned on their side they would run into each other.
    BOOL labels = s.labels && fabs(_angle) < 0.01;
    NSUInteger n = MIN(items.count, _layout.centers.count);
    for (NSUInteger i = 0; i < n; i++) {
        ChakraItemView *v = [[ChakraItemView alloc] initWithItem:items[i] icon:s.iconSize label:labels];
        v.center = _hub;
        v.alpha = 0;
        v.transform = [self _folded];
        [_root addSubview:v];
        [_views addObject:v];
    }

    _caption = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    _caption.userInteractionEnabled = NO;
    _caption.clipsToBounds = YES;
    _caption.layer.cornerRadius = 16;
    _caption.alpha = 0;
    _captionLabel = [UILabel new];
    _captionLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _captionLabel.textColor = UIColor.whiteColor;
    _captionLabel.textAlignment = NSTextAlignmentCenter;
    [_caption.contentView addSubview:_captionLabel];
    [_root addSubview:_caption];
}

- (void)openFromHub:(CGPoint)hub edge:(ChakraEdge)edge {
    if (_open) return;
    NSArray<ChakraItem *> *items = [ChakraItems visible];
    if (items.count == 0) {
        [ChakraHost toast:@"The wheel is empty. Hold the ball for a moment and let go to add apps."];
        return;
    }
    ChakraSettings *s = [ChakraSettings shared];
    [self _ensureWindow];
    _hub = hub;
    _edge = edge;
    _angle = [ChakraHost interfaceAngle];
    ChakraLayoutInput input;
    input.hub = hub;
    input.edge = edge;
    input.screen = [ChakraHost screenSize];
    input.safe = [ChakraHost safeInsets];
    input.icon = s.iconSize;
    input.ball = s.ballSize;
    input.labels = s.labels && fabs(_angle) < 0.01;
    input.style = s.style;
    _layout = [ChakraLayout layoutForCount:items.count input:input];
    if (_layout.centers.count == 0) {
        ChakraLog(@"wheel: no room for any icon (hub %.0f,%.0f)", hub.x, hub.y);
        return;
    }
    [self _buildWithItems:items];
    _open = YES;
    _closing = NO;
    _window.hidden = NO;

    _backdrop.alpha = 0;
    _plate.alpha = 0;
    CGPoint plateHome = _plate.center;
    if (s.style == ChakraStyleColumn) _plate.center = CGPointMake((plateHome.x + hub.x) / 2.0, plateHome.y);
    _plate.transform = CGAffineTransformMakeScale(0.25, 0.25);
    UIViewAnimationOptions live = UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState;
    [UIView animateWithDuration:0.2 delay:0 options:live animations:^{ self->_backdrop.alpha = 1; } completion:nil];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.6 options:live animations:^{
        self->_plate.transform = CGAffineTransformIdentity;
        self->_plate.center = plateHome;
        self->_plate.alpha = 1;
    } completion:nil];
    CGAffineTransform upright = [self _upright];
    for (NSUInteger i = 0; i < _views.count; i++) {
        ChakraItemView *v = _views[i];
        CGPoint home = _layout.centers[i].CGPointValue;
        [UIView animateWithDuration:0.42 delay:0.012 * i usingSpringWithDamping:0.74 initialSpringVelocity:0.8 options:live animations:^{
            v.center = home;
            v.alpha = 1;
            v.transform = upright;
        } completion:nil];
    }
    [self _armAutoClose];
    ChakraLog(@"wheel open: %lu of %lu entries, %lu ring(s), edge %@, hub %.0f,%.0f",
          (unsigned long)_views.count, (unsigned long)items.count, (unsigned long)_layout.ringRadii.count,
          edge == ChakraEdgeLeft ? @"left" : @"right", hub.x, hub.y);
}

- (void)closeAnimated:(BOOL)animated completion:(dispatch_block_t)completion {
    if (!_open) { if (completion) completion(); return; }
    if (_closing) { if (completion) ChakraAfter(0.25, completion); return; }
    _closing = YES;
    _idleGen++;
    [self _setHover:nil];
    dispatch_block_t finish = ^{
        self->_window.hidden = YES;
        for (UIView *v in [self->_root.subviews copy]) [v removeFromSuperview];
        self->_views = nil;
        self->_layout = nil;
        self->_open = NO;
        self->_closing = NO;
        [[ChakraBall shared] wheelDidClose];
        if (completion) completion();
    };
    if (!animated) { finish(); return; }
    CGAffineTransform folded = [self _folded];
    CGPoint hub = _hub;
    [UIView animateWithDuration:0.17 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn animations:^{
        self->_backdrop.alpha = 0;
        self->_plate.alpha = 0;
        self->_plate.transform = CGAffineTransformMakeScale(0.3, 0.3);
        self->_caption.alpha = 0;
        for (ChakraItemView *v in self->_views) {
            v.center = hub;
            v.alpha = 0;
            v.transform = folded;
        }
    } completion:^(BOOL finished) { finish(); }];
}

// The menu closes by itself when nothing has touched it for a while.
- (void)_armAutoClose {
    NSUInteger gen = ++_idleGen;
    ChakraAfter(10.0, ^{
        if (self->_open && !self->_closing && gen == self->_idleGen) [self closeAnimated:YES completion:nil];
    });
}

#pragma mark picking

- (ChakraItemView *)_viewNear:(CGPoint)p {
    CGFloat reach = MAX(40, [ChakraSettings shared].iconSize * 0.8);
    CGFloat best = reach * reach;
    ChakraItemView *hit = nil;
    NSUInteger n = MIN(_views.count, _layout.centers.count);
    for (NSUInteger i = 0; i < n; i++) {
        CGPoint c = _layout.centers[i].CGPointValue;
        CGFloat d2 = (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y);
        if (d2 < best) { best = d2; hit = _views[i]; }
    }
    return hit;
}

- (void)_setHover:(ChakraItemView *)v {
    if (v == _hover) return;
    _hover.lit = NO;
    _hover = v;
    v.lit = YES;
    if (v) {
        [_root bringSubviewToFront:v];
        [_root bringSubviewToFront:_caption];
        ChakraHapticPlay(ChakraHapticTick);
    }
    [self _showCaptionFor:v];
}

- (void)_showCaptionFor:(ChakraItemView *)v {
    if (!v) {
        [UIView animateWithDuration:0.12 animations:^{ self->_caption.alpha = 0; }];
        return;
    }
    ChakraItem *item = v.item;
    NSString *text = item.title ?: @"";
    if (item.isToggle) text = [text stringByAppendingString:(item.isOn ? @"  ·  On" : @"  ·  Off")];
    _captionLabel.text = text;

    CGSize screen = [ChakraHost screenSize];
    UIEdgeInsets safe = [ChakraHost safeInsets];
    CGSize fit = [_captionLabel sizeThatFits:CGSizeMake(screen.width - 80, 40)];
    CGFloat w = MIN(screen.width - 40, fit.width + 30), h = 32;
    CGFloat dir = (_edge == ChakraEdgeLeft) ? 1 : -1;
    CGRect plate = _plate.frame;
    BOOL wheel = [ChakraSettings shared].style != ChakraStyleColumn;
    CGPoint c;
    if (fabs(_angle) < 0.01) {
        // above the plate where there is room, otherwise below it
        CGFloat cx = wheel ? _hub.x + dir * MIN(_layout.plateRadius * 0.5, screen.width * 0.3) : CGRectGetMidX(plate);
        cx = MAX(w / 2.0 + 12, MIN(screen.width - w / 2.0 - 12, cx));
        CGFloat cy = CGRectGetMinY(plate) - 24;
        if (cy - h / 2.0 < safe.top + 6) cy = CGRectGetMaxY(plate) + 24;
        if (cy + h / 2.0 > screen.height - safe.bottom - 6) cy = safe.top + 6 + h / 2.0;
        c = CGPointMake(cx, cy);
    } else {
        // on its side: beside the plate, towards the middle of the screen
        CGFloat reach = wheel ? _layout.plateRadius + 30 : plate.size.width + 60;
        CGFloat cx = _hub.x + dir * reach;
        cx = MAX(h / 2.0 + 8, MIN(screen.width - h / 2.0 - 8, cx));
        CGFloat cy = MAX(safe.top + w / 2.0 + 8, MIN(screen.height - safe.bottom - w / 2.0 - 8, _hub.y));
        c = CGPointMake(cx, cy);
    }
    _caption.transform = CGAffineTransformIdentity;
    _caption.bounds = CGRectMake(0, 0, w, h);
    _caption.center = c;
    _captionLabel.frame = CGRectMake(0, 0, w, h);
    _caption.transform = [self _upright];
    [UIView animateWithDuration:0.12 animations:^{ self->_caption.alpha = 1; }];
}

- (void)_run:(ChakraItemView *)v stay:(BOOL)stay {
    ChakraItem *item = v.item;
    if (!item) return;
    ChakraHapticPlay(ChakraHapticCommit);
    ChakraLog(@"run %@%@", item.key, stay ? @" (menu stays open)" : @"");
    if (stay) {
        [item perform];
        [self _armAutoClose];
        __weak ChakraItemView *wv = v;
        __weak ChakraWheel *ws = self;
        // a switch reports its new state a moment later (Wi-Fi and Bluetooth take the longest)
        for (NSNumber *delay in @[ @0.3, @1.0, @2.2 ]) {
            ChakraAfter(delay.doubleValue, ^{
                ChakraWheel *me = ws;
                ChakraItemView *view = wv;
                if (!me || !view || !me->_open || me->_closing) return;
                [view refreshIcon];
                if (me->_hover == view) [me _showCaptionFor:view];
            });
        }
        return;
    }
    [self closeAnimated:YES completion:^{ [item perform]; }];
}

- (void)hoverAtScreenPoint:(CGPoint)point {
    if (!_open || _closing) return;
    [self _armAutoClose];
    [self _setHover:[self _viewNear:point]];
}

- (BOOL)commitHover {
    if (!_open || _closing || !_hover) return NO;
    [self _run:_hover stay:NO];
    return YES;
}

- (void)clearHover { [self _setHover:nil]; }

- (void)_touchAt:(CGPoint)p phase:(NSInteger)phase {
    if (!_open || _closing) return;
    [self _armAutoClose];
    switch (phase) {
        case 0:
        case 1:
            [self _setHover:[self _viewNear:p]];
            break;
        case 2: {
            ChakraItemView *v = [self _viewNear:p];
            [self _setHover:v];
            if (!v) { [self closeAnimated:YES completion:nil]; break; }
            BOOL stay = v.item.isToggle;
            [self _run:v stay:stay];
            if (stay) {
                __weak ChakraWheel *ws = self;
                ChakraAfter(0.9, ^{ ChakraWheel *me = ws; if (me && me->_hover == v) [me _setHover:nil]; });
            }
            break;
        }
        default:
            [self _setHover:nil];
            break;
    }
}

#pragma mark tests

- (void)debugHoverIndex:(NSUInteger)index {
    if (!_open || index >= _views.count) { ChakraLog(@"hover %lu: no such entry", (unsigned long)index); return; }
    [self _setHover:_views[index]];
}

- (void)debugTapIndex:(NSUInteger)index {
    if (!_open || index >= _views.count || index >= _layout.centers.count) { ChakraLog(@"tap %lu: no such entry", (unsigned long)index); return; }
    CGPoint p = _layout.centers[index].CGPointValue;
    [self _touchAt:p phase:0];
    [self _touchAt:p phase:2];
}

- (NSString *)debugState {
    if (!_open) return @"wheel closed";
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger n = MIN(_views.count, _layout.centers.count);
    for (NSUInteger i = 0; i < n; i++) {
        CGPoint c = _layout.centers[i].CGPointValue;
        ChakraItem *item = _views[i].item;
        [parts addObject:[NSString stringWithFormat:@"%lu %@ @%.0f,%.0f%@", (unsigned long)i, item.key, c.x, c.y,
                          item.isToggle ? (item.isOn ? @" on" : @" off") : @""]];
    }
    return [NSString stringWithFormat:@"wheel open%@, rings %@, plate %.0f, turn %.0f°: %@", _closing ? @" (closing)" : @"",
            [_layout.ringRadii componentsJoinedByString:@"/"], _layout.plateRadius, _angle * 180.0 / M_PI,
            [parts componentsJoinedByString:@"; "]];
}

@end
