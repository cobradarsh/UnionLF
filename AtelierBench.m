/*  AtelierBench.m — the bench window: tiles, layouts, the swap, the "..." menu, the freeze clock.

    One SpringBoard window over the Home Screen and apps (under Control Centre, notifications
    and the lock screen). Behind everything a blur of whatever was on screen; on it one tile per
    app. A tile is a rounded clip view holding the pane's view (AtelierScenes.m), which always
    has the size of the app's scene and is scaled down to the tile's width.

      main tile     nothing of SpringBoard's lies over it, so touches go straight to the app
      mini tile     a shield on top takes the touches: a tap makes it the main, a hold opens
                    its menu, a swipe acts on it (left closes, right makes it the main, up locks
                    or unlocks, down is the Settings choice). A frozen mini also shows a still,
                    and its app is in the background. A locked app is never frozen and can't be
                    swiped away.

    Above the tiles is the band (AtelierBand.m): index numbers, clock, market flags, shortcut
    apps. Under them the dock (AtelierToggles.m): six switches and the credit line. A swipe up
    that starts on the dock or below it puts the bench away.

    While the bench is up a half-second clock looks after it: it puts the bench away when
    SpringBoard moves on (another app in front, the App Switcher, a lock), restarts an app that
    was closed underneath, and freezes the minis when their time is up. The clock and the touch
    watcher exist only while the bench is on screen; hidden, the bench does nothing at all.     */

#import "Atelier.h"
#import <dlfcn.h>

#pragma mark - a tile

@interface AtelierTile : UIView
@property (nonatomic, strong) AtelierPane *pane;
@property (nonatomic, strong) UIView *clip;
@property (nonatomic, strong) UIImageView *still;
@property (nonatomic, strong) UIControl *shield;
@property (nonatomic, strong) UIImageView *badge;
@property (nonatomic, strong) UIImageView *lockBadge;
@property (nonatomic) BOOL locked;                  // stays on the bench, never frozen, can't be swiped away
@property (nonatomic) BOOL frozen;                  // showing a still, its app in the background
@property (nonatomic) BOOL parked;                  // not shown in this layout
@property (nonatomic) BOOL mini;
@property (nonatomic) CFAbsoluteTime liveSince;     // when it last became a live mini
@property (nonatomic) NSInteger restarts;           // times its app was started again under the bench
- (instancetype)initWithPane:(AtelierPane *)pane;
- (void)applyRect:(CGRect)rect mini:(BOOL)mini;
- (CGFloat)tileScale;
@end

@implementation AtelierTile

- (instancetype)initWithPane:(AtelierPane *)pane {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 100, 200)])) return nil;
    _pane = pane;
    _clip = [[UIView alloc] initWithFrame:self.bounds];
    _clip.clipsToBounds = YES;
    _clip.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    _clip.layer.cornerCurve = kCACornerCurveContinuous;
    _clip.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    _clip.layer.borderWidth = 1.0 / MAX(1, UIScreen.mainScreen.scale);
    [self addSubview:_clip];

    UIView *v = pane.view;
    v.layer.anchorPoint = CGPointZero;
    v.layer.position = CGPointZero;
    [_clip addSubview:v];

    _still = [[UIImageView alloc] initWithFrame:_clip.bounds];
    _still.contentMode = UIViewContentModeScaleToFill;
    _still.hidden = YES;
    [_clip addSubview:_still];

    // The shield takes every touch on a mini. Its layer is marked so that the window server
    // gives the touch to SpringBoard and not to the app whose picture lies underneath.
    _shield = [[UIControl alloc] initWithFrame:self.bounds];
    _shield.backgroundColor = [UIColor colorWithWhite:0 alpha:0.02];
    AtelierSendBool(_shield.layer, @"setHitTestsAsOpaque:", YES);
    _shield.hidden = YES;
    [self addSubview:_shield];

    _badge = [[UIImageView alloc] initWithImage:[AtelierHost iconForBundleID:pane.bundleID]];
    _badge.layer.cornerRadius = 6;
    _badge.layer.cornerCurve = kCACornerCurveContinuous;
    _badge.clipsToBounds = YES;
    _badge.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
    _badge.layer.borderWidth = 0.5;
    _badge.hidden = YES;
    _badge.userInteractionEnabled = NO;
    [self addSubview:_badge];

    UIImage *lock = [UIImage systemImageNamed:@"lock.fill"
                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8.5 weight:UIImageSymbolWeightBold]];
    _lockBadge = [[UIImageView alloc] initWithImage:[lock imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _lockBadge.tintColor = UIColor.whiteColor;
    _lockBadge.contentMode = UIViewContentModeCenter;
    _lockBadge.backgroundColor = [UIColor colorWithRed:0.42 green:0.40 blue:0.95 alpha:1];
    _lockBadge.layer.cornerRadius = 9;
    _lockBadge.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
    _lockBadge.layer.borderWidth = 0.5;
    _lockBadge.hidden = YES;
    _lockBadge.userInteractionEnabled = NO;
    AtelierSendBool(_lockBadge.layer, @"setAllowsHitTesting:", NO);      // over the main tile it must not take the app's touches
    [self addSubview:_lockBadge];
    return self;
}

- (CGFloat)tileScale {
    CGFloat w = MAX(1, _pane.sceneSize.width);
    return self.bounds.size.width / w;
}

// Everything here animates when called inside an animation block.
- (void)applyRect:(CGRect)rect mini:(BOOL)mini {
    _mini = mini;
    self.frame = rect;
    CGRect b = CGRectMake(0, 0, rect.size.width, rect.size.height);
    _clip.frame = b;
    _clip.layer.cornerRadius = mini ? MAX(8, MIN(rect.size.width, rect.size.height) * 0.14) : MIN(rect.size.width, rect.size.height) * 0.105;
    CGFloat s = rect.size.width / MAX(1, _pane.sceneSize.width);
    _pane.view.transform = CGAffineTransformMakeScale(s, s);
    _still.frame = b;
    _shield.frame = b;
    _shield.hidden = !mini;
    CGFloat side = MAX(18, MIN(26, rect.size.width * 0.34));
    _badge.frame = CGRectMake(-4, -4, side, side);
    _badge.hidden = !mini;
    // the padlock hangs on the top right corner (a mini's icon badge is on the top left), far
    // enough in that it stays clear of the next tile's icon badge in a row
    _lockBadge.frame = CGRectMake(rect.size.width - 17, -5, 18, 18);
    _lockBadge.hidden = !_locked;
}

@end

// Holds the tiles and nothing else: a touch between them falls through to the backdrop.
@interface AtelierPassView : UIView
@end

@implementation AtelierPassView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

#pragma mark - the "..." menu

@interface AtelierMenu : UIView
@property (nonatomic, readonly) NSArray<NSDictionary *> *items;
- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items;      // @{ @"title", @"symbol", @"red": @YES, @"run": block }
- (void)runItem:(NSUInteger)index;
@end

@implementation AtelierMenu

- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items {
    CGFloat rowH = 46, w = 236;
    if (!(self = [super initWithFrame:CGRectMake(0, 0, w, rowH * items.count)])) return nil;
    _items = [items copy];
    self.layer.cornerRadius = 15;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    glass.frame = self.bounds;
    glass.userInteractionEnabled = NO;
    [self addSubview:glass];
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = items[i];
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = CGRectMake(0, rowH * i, w, rowH);
        row.tag = (NSInteger)i;
        UIColor *tint = [item[@"red"] boolValue] ? [UIColor colorWithRed:1 green:0.42 blue:0.39 alpha:1] : UIColor.whiteColor;
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 62, rowH)];
        title.text = item[@"title"];
        title.textColor = tint;
        title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        title.adjustsFontSizeToFitWidth = YES;          // "Remove from Shortcuts" is a hair too long at full size
        title.minimumScaleFactor = 0.8;
        title.userInteractionEnabled = NO;
        [row addSubview:title];
        UIImage *glyph = [UIImage systemImageNamed:item[@"symbol"] ?: @""
                                 withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium]];
        if (glyph) {
            UIImageView *icon = [[UIImageView alloc] initWithImage:[glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            icon.tintColor = tint;
            icon.contentMode = UIViewContentModeCenter;
            icon.frame = CGRectMake(w - 46, 0, 32, rowH);
            icon.userInteractionEnabled = NO;
            [row addSubview:icon];
        }
        if (i + 1 < items.count) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, rowH - 0.5, w, 0.5)];
            line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
            line.userInteractionEnabled = NO;
            [row addSubview:line];
        }
        [row addTarget:self action:@selector(_down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [row addTarget:self action:@selector(_up:) forControlEvents:UIControlEventTouchDragExit | UIControlEventTouchCancel | UIControlEventTouchUpOutside];
        [row addTarget:self action:@selector(_tap:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:row];
    }
    return self;
}

- (void)_down:(UIButton *)row { row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; }
- (void)_up:(UIButton *)row { row.backgroundColor = UIColor.clearColor; }
- (void)_tap:(UIButton *)row { row.backgroundColor = UIColor.clearColor; [self runItem:(NSUInteger)row.tag]; }

- (void)runItem:(NSUInteger)index {
    if (index >= _items.count) return;
    void (^run)(void) = _items[index][@"run"];
    [[AtelierBench shared] hideMenu];
    AtelierHapticPlay(AtelierHapticTick);
    if (run) run();
}

@end

#pragma mark - touches that go to the apps

// A finger on the main app never reaches SpringBoard's views, so the bench cannot see that it
// is being used. While the bench is up it listens to the touch screen itself (the same listener
// SpringBoard tweaks have long used for buttons) and only notes the time. Released when the
// bench goes away.
static void *gHIDClient;
static void AtelierHIDEvent(void *target, void *refcon, void *queue, void *event);

static void AtelierHIDStart(void) {
#if !TARGET_OS_SIMULATOR
    if (gHIDClient || [[AtelierSettings shared] tune:@"touchWatch" fallback:1] < 1) return;
    void *(*create)(CFAllocatorRef) = (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    void (*schedule)(void *, CFRunLoopRef, CFStringRef) = (void (*)(void *, CFRunLoopRef, CFStringRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
    void (*reg)(void *, void *, void *, void *) = (void (*)(void *, void *, void *, void *))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventCallback");
    if (!create || !schedule || !reg || !dlsym(RTLD_DEFAULT, "IOHIDEventGetType")) { AtelierLog(@"touch watch: not on this iOS"); return; }
    gHIDClient = create(kCFAllocatorDefault);
    if (!gHIDClient) { AtelierLog(@"touch watch: no client"); return; }
    schedule(gHIDClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    reg(gHIDClient, (void *)AtelierHIDEvent, NULL, NULL);
#endif
}

static void AtelierHIDStop(void) {
#if !TARGET_OS_SIMULATOR
    if (!gHIDClient) return;
    void (*unreg)(void *, void *, void *, void *) = (void (*)(void *, void *, void *, void *))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientUnregisterEventCallback");
    void (*unschedule)(void *, CFRunLoopRef, CFStringRef) = (void (*)(void *, CFRunLoopRef, CFStringRef))dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientUnscheduleWithRunLoop");
    if (unreg) unreg(gHIDClient, (void *)AtelierHIDEvent, NULL, NULL);
    if (unschedule) unschedule(gHIDClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    CFRelease((CFTypeRef)gHIDClient);
    gHIDClient = NULL;
#endif
}

#pragma mark - the bench

@interface AtelierBench () <UIGestureRecognizerDelegate>
- (void)_touchFromScreen;
@end

static void AtelierHIDEvent(void *target, void *refcon, void *queue, void *event) {
    static int (*getType)(void *);
    static CFAbsoluteTime last;
    if (!getType) getType = (int (*)(void *))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    if (!getType || !event || getType(event) != 11) return;            // 11 = the touch screen
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.5) return;
    last = now;
    [[AtelierBench shared] _touchFromScreen];
}

@implementation AtelierBench {
    AtelierWindow *_window;
    UIView *_root;
    UIVisualEffectView *_blur;
    UIView *_dim;
    UIView *_stage;                          // holds the tiles
    NSMutableArray<AtelierTile *> *_tiles;   // index 0 is the main
    UIButton *_grabber, *_grabber2;
    UIControl *_plus;
    UIView *_divider;
    AtelierMenu *_menu;
    NSTimer *_watch;
    CFAbsoluteTime _lastTouch, _busyUntil;
    NSString *_frontAtOpen;
    double _split;
    BOOL _closing;
    BOOL _swipeFromBottom;
    CGPoint _bottomDown;                     // where the finger of a swipe up from the bottom came down
    UIPanGestureRecognizer *_bottomPan, *_dockPan;
    AtelierGeometry _geometry;
    AtelierBand *_band;                      // index numbers, clock, flags, shortcut apps
    AtelierDock *_dock;                      // toggles and the credit line
    NSInteger _ticks;                        // of the half-second clock, since the bench came up
    CGFloat _stripFloor;                     // the dock's top as the edge strip last heard it
    NSMutableArray<UIView *> *_outlines;     // the free mini places
    UILabel *_swipePill;                     // names what letting go of a swiped mini will do
    AtelierTile *_swipeTile;
    NSInteger _swipeAxis;                    // 1 sideways, 2 up and down
    BOOL _swipeArmed;
    CGPoint _swipeDown;                      // where the finger on a mini came down
    NSMutableSet<NSString *> *_locked;       // bundle ids
}

+ (instancetype)shared {
    static AtelierBench *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [AtelierBench new]; b->_tiles = [NSMutableArray array]; b->_split = 0.5; });
    return b;
}

- (NSArray<NSString *> *)apps {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (AtelierTile *t in _tiles) [out addObject:t.pane.bundleID];
    return out;
}

#pragma mark window

- (UIButton *)_makeGrabber:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(14, 6, 36, 12)];
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    pill.layer.cornerRadius = 6;
    pill.userInteractionEnabled = NO;
    [b addSubview:pill];
    for (int i = 0; i < 3; i++) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(9 + i * 7, 4, 4, 4)];
        dot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92];
        dot.layer.cornerRadius = 2;
        [pill addSubview:dot];
    }
    [b addTarget:self action:@selector(_grabberTapped:) forControlEvents:UIControlEventTouchUpInside];
    b.hidden = YES;
    return b;
}

- (void)_ensureWindow {
    if (_window) return;
    UIWindowLevel level = (UIWindowLevel)[[AtelierSettings shared] tune:@"windowLevel" fallback:999];
    _window = [AtelierHost windowAtLevel:level];
    __weak typeof(self) weak = self;
    _window.onTouch = ^{ [weak touched]; };
    _root = _window.rootViewController.view;

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _blur.frame = _root.bounds;
    _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_root addSubview:_blur];
    _dim = [[UIView alloc] initWithFrame:_root.bounds];
    _dim.autoresizingMask = _blur.autoresizingMask;
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];
    [_root addSubview:_dim];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_backdropTapped)];
    [_dim addGestureRecognizer:tap];
    // A swipe up from the bottom edge is the Home gesture: SpringBoard acts on it underneath,
    // and the bench gets out of the way at once.
    UIScreenEdgePanGestureRecognizer *home = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(_homeSwipe:)];
    home.edges = UIRectEdgeBottom;
    home.delegate = self;
    [_root addGestureRecognizer:home];
    // The same wish without the edge: a finger that starts on the backdrop in the lowest strip of
    // the screen and slides up. (In the simulator a mouse drag from the bottom never reached the
    // edge recogniser; this one does not depend on where iOS thinks the edge is.)
    UIPanGestureRecognizer *up = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_bottomSwipe:)];
    up.maximumNumberOfTouches = 1;
    up.delegate = self;
    [_dim addGestureRecognizer:up];
    _bottomPan = up;

    _stage = [[AtelierPassView alloc] initWithFrame:_root.bounds];
    _stage.autoresizingMask = _blur.autoresizingMask;
    [_root addSubview:_stage];

    _plus = [[UIControl alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    _plus.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _plus.layer.cornerRadius = 12;
    _plus.layer.cornerCurve = kCACornerCurveContinuous;
    _plus.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    _plus.layer.borderWidth = 1;
    UIImageView *cross = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"plus"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    cross.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    cross.contentMode = UIViewContentModeCenter;
    cross.frame = _plus.bounds;
    cross.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cross.userInteractionEnabled = NO;
    [_plus addSubview:cross];
    [_plus addTarget:self action:@selector(_plusTapped) forControlEvents:UIControlEventTouchUpInside];
    _plus.hidden = YES;
    [_root addSubview:_plus];

    _outlines = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        UIView *o = [[UIView alloc] initWithFrame:CGRectZero];
        o.userInteractionEnabled = NO;
        o.backgroundColor = [UIColor colorWithWhite:1 alpha:0.035];
        o.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.13].CGColor;
        o.layer.borderWidth = 1;
        o.layer.cornerRadius = 9;
        o.layer.cornerCurve = kCACornerCurveContinuous;
        o.alpha = 0;
        [_root insertSubview:o belowSubview:_stage];
        [_outlines addObject:o];
    }

    _band = [[AtelierBand alloc] initWithFrame:CGRectZero];
    _band.alpha = 0;
    _band.onShortcut = ^(NSString *bid) { [weak openShortcut:bid]; };
    _band.onShortcutHeld = ^(NSString *bid, CGRect frame) { [weak _showShortcutMenu:bid frame:frame]; };
    _band.onAddShortcut = ^{ [weak _addShortcut]; };
    [_root addSubview:_band];

    _dock = [[AtelierDock alloc] initWithFrame:CGRectZero];
    _dock.alpha = 0;
    // a swipe up that starts on one of the switches closes the bench too (and does not flip the switch)
    UIPanGestureRecognizer *dockUp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_bottomSwipe:)];
    dockUp.maximumNumberOfTouches = 1;
    dockUp.delegate = self;
    [_dock addGestureRecognizer:dockUp];
    _dockPan = dockUp;
    [_root addSubview:_dock];

    _swipePill = [UILabel new];
    _swipePill.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _swipePill.textColor = UIColor.whiteColor;
    _swipePill.textAlignment = NSTextAlignmentCenter;
    _swipePill.layer.cornerRadius = 13;
    _swipePill.clipsToBounds = YES;
    _swipePill.userInteractionEnabled = NO;
    _swipePill.alpha = 0;
    AtelierSendBool(_swipePill.layer, @"setAllowsHitTesting:", NO);

    _grabber = [self _makeGrabber:0];
    _grabber2 = [self _makeGrabber:1];
    [_root addSubview:_grabber];
    [_root addSubview:_grabber2];

    _divider = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 88)];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.tag = 7;
    bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
    bar.layer.cornerRadius = 2.5;
    bar.userInteractionEnabled = NO;
    [_divider addSubview:bar];
    [_divider addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_dividerDragged:)]];
    _divider.hidden = YES;
    [_root addSubview:_divider];
    [_root addSubview:_swipePill];
}

// Recognisers on different views never end one another: nothing on the backdrop, the dock or the
// screen's edge can cut a mini's swipe short. On one and the same view they stay rivals, so a
// mini's hold (its menu) and its swipe are still one or the other, whichever comes first.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return g.view != other.view;
}

// Where the finger came down is noted here: by the time a pan begins it has already travelled
// ten points or so, and its own figure for how far it has gone leaves those out.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:_root];
    if (g == _bottomPan || g == _dockPan) {
        _bottomDown = p;
        _swipeFromBottom = CGRectContainsPoint(_geometry.closeStrip, p);
    } else if ([g isKindOfClass:UIPanGestureRecognizer.class] && [self _slotOfTileWithShield:g.view] != NSNotFound) {
        _swipeDown = p;
    }
    return YES;
}

#pragma mark open and close

- (NSArray<NSString *> *)_usable:(NSArray<NSString *> *)bids {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *bid in bids) {
        if (![bid isKindOfClass:NSString.class] || bid.length == 0 || [out containsObject:bid]) continue;
        if (![AtelierHost applicationForBundleID:bid]) continue;
        if ([AtelierHost isHiddenApp:bid]) continue;                    // hidden by SporeX: never on the bench
        if (out.count >= ATELIER_MAX_SLOTS) break;
        [out addObject:bid];
    }
    return out;
}

- (void)_loadLocks {
    _locked = [NSMutableSet setWithArray:[[AtelierSettings shared] lockedApps]];
}

- (BOOL)isLocked:(NSString *)bid {
    if (!_locked) [self _loadLocks];
    return bid.length && [_locked containsObject:bid];
}

// `bid` first, the rest after it. A bench that is full loses its last app that isn't locked;
// nil when every other app is locked and there is no room.
- (NSArray<NSString *> *)_list:(NSArray<NSString *> *)list withFirst:(NSString *)bid {
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithArray:list ?: @[]];
    if (bid.length) {
        [out removeObject:bid];
        [out insertObject:bid atIndex:0];
        while (out.count > ATELIER_MAX_SLOTS) {
            NSUInteger drop = NSNotFound;
            for (NSUInteger i = out.count - 1; i >= 1; i--) if (![self isLocked:out[i]]) { drop = i; break; }
            if (drop == NSNotFound) return nil;
            [out removeObjectAtIndex:drop];
        }
    }
    return out;
}

- (void)open {
    if (_visible) return;
    AtelierSettings *s = [AtelierSettings shared];
    [AtelierHost reloadHiddenApps];
    [self _loadLocks];
    NSArray<NSString *> *apps = [s slots];
    NSString *front = [AtelierHost frontmostBundleID];
    if (front && s.addFront) apps = [self _list:apps withFirst:front] ?: apps;
    [self _presentApps:apps layout:[s layout]];
}

- (void)openWithApps:(NSArray<NSString *> *)bids layout:(NSInteger)layout {
    AtelierLayoutKind kind = (layout >= 0 && layout <= 2) ? (AtelierLayoutKind)layout : (_visible ? _layout : [[AtelierSettings shared] layout]);
    if (!_visible) { [self _presentApps:bids layout:kind]; return; }
    _layout = kind;
    [self _setApps:[self _usable:bids] animated:YES];
    [self touched];
}

- (void)openAdding:(NSString *)bid {
    [AtelierHost reloadHiddenApps];
    if ([AtelierHost isHiddenApp:bid]) return;
    NSArray<NSString *> *base = _visible ? [self apps] : [[AtelierSettings shared] slots];
    NSArray<NSString *> *with = [self _list:base withFirst:bid];
    if (!with) [AtelierHost toast:@"The bench is full of locked apps. Unlock one to make room."];
    [self openWithApps:(with ?: base) layout:-1];
}

// A shortcut app from the band: it becomes the main app. Nothing is pushed off a full bench.
- (void)openShortcut:(NSString *)bid {
    if (!_visible || bid.length == 0 || [AtelierHost isHiddenApp:bid]) return;
    [self hideMenu];
    NSArray<NSString *> *apps = [self apps];
    NSUInteger at = [apps indexOfObject:bid];
    if (at != NSNotFound) {
        AtelierLog(@"shortcut %@: already on the bench (place %lu)", bid, (unsigned long)at);
        if (at > 0) [self makeMain:at];
        return;
    }
    if (apps.count >= ATELIER_MAX_SLOTS) {
        AtelierLog(@"shortcut %@: the bench is full", bid);
        AtelierHapticPlay(AtelierHapticSwap);
        [AtelierHost toast:@"The bench is full. Close an app to make room."];
        return;
    }
    AtelierLog(@"shortcut %@: opened as the main app", bid);
    [self _setApps:[@[ bid ] arrayByAddingObjectsFromArray:apps] animated:YES];
    [self touched];
}

- (void)toggle {
    if (_visible) [self closeAnimated:YES reason:@"toggle"];
    else [self open];
}

- (void)_presentApps:(NSArray<NSString *> *)bids layout:(AtelierLayoutKind)layout {
    AtelierSettings *s = [AtelierSettings shared];
    if (!s.enabled) { AtelierLog(@"open: %@ is switched off", ATELIER_NAME); return; }
    if ([AtelierHost isLocked]) { AtelierLog(@"open: the phone is locked"); return; }
    if (_closing) return;
    [AtelierHost reloadHiddenApps];                      // SporeX's list, as it is now
    [self _ensureWindow];
    [self _loadLocks];
    _window.windowLevel = (UIWindowLevel)[s tune:@"windowLevel" fallback:999];
    _layout = layout;
    _ticks = 0;
    [_band reload];
    [_dock reload];
    _split = MAX(0.3, MIN(0.7, [s tune:@"split" fallback:0.5]));
    _frontAtOpen = [AtelierHost frontmostBundleID];
    _visible = YES;
    _lastTouch = CFAbsoluteTimeGetCurrent();
    [self _setApps:[self _usable:bids] animated:NO];
    _window.hidden = NO;
    _root.alpha = 0;
    _stage.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_root.alpha = 1;
        self->_stage.transform = CGAffineTransformIdentity;
    } completion:nil];
    AtelierHapticPlay(AtelierHapticOpen);
    __weak typeof(self) weak = self;
    _watch = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        @try { [weak _tick]; } @catch (NSException *e) { AtelierLog(@"bench clock threw %@", e.reason); }
    }];
    _watch.tolerance = 0.15;
    [_band start];
    [_dock refresh];                                     // what the switches are at, now
    AtelierQuotes *quotes = [AtelierQuotes shared];      // index numbers: fetched only from here to the close
    quotes.onChange = ^{ [weak _quotesChanged]; };
    [quotes start];
    AtelierHIDStart();
    [[AtelierTrigger shared] refresh];
    AtelierLog(@"bench open: %@ · layout %ld · front %@ · level %.0f", [[self apps] componentsJoinedByString:@" "],
               (long)_layout, _frontAtOpen ?: @"home", _window.windowLevel);
}

- (void)closeAnimated:(BOOL)animated reason:(NSString *)why {
    [self _closeAnimated:animated reason:why keeping:nil then:nil];
}

- (void)_closeAnimated:(BOOL)animated reason:(NSString *)why keeping:(NSString *)keep then:(void (^)(void))then {
    if (!_visible || _closing) { if (then) then(); return; }
    _closing = YES;
    AtelierLog(@"bench close (%@)", why ?: @"?");
    [self _persist];
    [_watch invalidate];
    _watch = nil;
    [_band stop];
    [[AtelierQuotes shared] stop];                       // nothing is fetched once the bench is on its way out
    [AtelierToggles benchWentAway];                      // Keep Awake ends here, whatever closed the bench
    AtelierHIDStop();
    [self hideMenu];
    [self _hideSwipePill];
    _swipeTile = nil;
    [AtelierSheets dismiss];
    void (^finish)(void) = ^{
        NSString *front = [AtelierHost frontmostBundleID];
        for (AtelierTile *t in self->_tiles) {
            NSString *bid = t.pane.bundleID;
            [t.pane detachKeepingForeground:([bid isEqualToString:front] || [bid isEqualToString:keep])];
            [t removeFromSuperview];
        }
        [self->_tiles removeAllObjects];
        self->_window.hidden = YES;
        self->_visible = NO;
        self->_closing = NO;
        self->_stripFloor = 0;
        [[AtelierTrigger shared] refresh];
        if (then) then();
    };
    if (!animated) { finish(); return; }
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_root.alpha = 0;
        self->_stage.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL done) { finish(); }];
}

- (void)_persist {
    AtelierSettings *s = [AtelierSettings shared];
    [s setSlots:[self apps]];
    [s setLayout:_layout];
}

- (void)lockChanged {
    if (_visible && [AtelierHost isLocked]) [self closeAnimated:NO reason:@"locked"];
}

- (void)settingsChanged {
    if (!_visible) return;
    AtelierSettings *s = [AtelierSettings shared];
    if (!s.enabled) { [self closeAnimated:YES reason:@"switched off"]; return; }
    _layout = [s layout];                               // the Layout row in Settings writes the same key
    [self _loadLocks];
    [_band reload];
    [_dock reload];
    [_dock refresh];
    [[AtelierQuotes shared] settingsChanged];
    [self _thawAll];
    [self _layoutAnimated:YES];
}

// SporeX's list changed (its own notification): an app it hides now leaves the bench, the
// shortcut row and any list that is open.
- (void)hiddenAppsChanged {
    [AtelierHost reloadHiddenApps];
    if (!_visible) return;
    NSArray<NSString *> *apps = [self apps], *kept = [self _usable:apps];
    if ([AtelierSheets isOpen]) [AtelierSheets dismiss];
    [self hideMenu];
    [_band reload];
    if (kept.count != apps.count) {
        AtelierLog(@"hidden apps changed: %lu app(s) leave the bench", (unsigned long)(apps.count - kept.count));
        [self _setApps:kept animated:YES];
    } else {
        [self _layoutAnimated:YES];
    }
}

- (void)_quotesChanged {
    if (_visible) [_band quotesChanged];
}

// The dock's top while the bench is up (0 when it is not): the edge strip ends above it, so the
// strip never lies over a switch.
- (CGFloat)dockTop {
    return (_visible && !CGRectIsEmpty(_geometry.dock)) ? _geometry.dock.origin.y : 0;
}

#pragma mark tiles

- (void)_setApps:(NSArray<NSString *> *)bids animated:(BOOL)animated {
    NSMutableArray<AtelierTile *> *next = [NSMutableArray array];
    NSMutableArray<AtelierTile *> *old = [_tiles mutableCopy];
    for (NSString *bid in bids) {
        AtelierTile *tile = nil;
        for (AtelierTile *t in old) if ([t.pane.bundleID isEqualToString:bid]) { tile = t; break; }
        if (tile) {
            [old removeObject:tile];
        } else {
            tile = [[AtelierTile alloc] initWithPane:[AtelierPane paneWithBundleID:bid]];
            [tile.shield addTarget:self action:@selector(_miniTapped:) forControlEvents:UIControlEventTouchUpInside];
            UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_miniHeld:)];
            hold.minimumPressDuration = 0.4;
            [tile.shield addGestureRecognizer:hold];
            UIPanGestureRecognizer *swipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_miniPanned:)];
            swipe.maximumNumberOfTouches = 1;
            swipe.delegate = self;                       // notes where the finger came down
            [tile.shield addGestureRecognizer:swipe];
            tile.alpha = 0;
            tile.liveSince = CFAbsoluteTimeGetCurrent();
            [_stage addSubview:tile];
        }
        [next addObject:tile];
    }
    NSString *front = [AtelierHost frontmostBundleID];
    for (AtelierTile *gone in old) {
        [gone.pane detachKeepingForeground:[gone.pane.bundleID isEqualToString:front]];
        [gone removeFromSuperview];
    }
    _tiles = next;
    [self _layoutAnimated:animated];
    if (_visible) [self _persist];
}

- (CGRect)_rectForSlot:(NSUInteger)slot geometry:(AtelierGeometry)g {
    if (slot == 0) return g.main;
    if (_layout == AtelierLayoutSplit) return slot == 1 ? g.second : CGRectZero;
    return ((NSInteger)slot - 1 < g.miniCount && slot - 1 < 5) ? g.minis[slot - 1] : CGRectZero;
}

- (void)_layoutAnimated:(BOOL)animated {
    if (_closing) return;
    AtelierSettings *s = [AtelierSettings shared];
    CGSize screen = [AtelierHost screenSize];
    BOOL resize = s.resizeApps;
    CGFloat dockHeight = [AtelierDock heightForWidth:screen.width - 20 compact:(_layout != AtelierLayoutSide)];
    AtelierGeometry g = AtelierLayoutCompute(_layout, screen, [AtelierHost safeInsets], (NSInteger)_tiles.count, _split, resize,
                                             [s tune:@"sideScale" fallback:0.80], s.showIndices, dockHeight);
    _geometry = g;
    if (g.dock.origin.y != _stripFloor) {                // the edge strip ends above the dock
        _stripFloor = g.dock.origin.y;
        [[AtelierTrigger shared] refresh];
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // who is on show, at which size, and who runs
    for (NSUInteger i = 0; i < _tiles.count; i++) {
        AtelierTile *t = _tiles[i];
        CGRect r = [self _rectForSlot:i geometry:g];
        BOOL parked = CGRectIsEmpty(r);
        if (parked != t.parked || (parked && t.pane.state != AtelierPaneIdle)) {
            t.parked = parked;
            if (parked) [t.pane detachKeepingForeground:[t.pane.bundleID isEqualToString:[AtelierHost frontmostBundleID]]];
        }
        if (parked) continue;
        CGSize size = screen;
        if (resize) size = (_layout == AtelierLayoutSplit) ? r.size : g.sceneSize;
        [t.pane setSceneSize:size];
        BOOL mini = (i > 0 && _layout != AtelierLayoutSplit);
        t.locked = [self isLocked:t.pane.bundleID];
        if ((!mini || t.locked) && t.frozen) [self _thaw:t];
        if (mini && !t.mini) t.liveSince = now;
        if (t.pane.state == AtelierPaneIdle || (t.pane.state == AtelierPaneFailed && !t.restarts)) [t.pane attach];
        [t.pane setLive:!t.frozen];
    }

    void (^apply)(void) = ^{
        for (NSUInteger i = 0; i < self->_tiles.count; i++) {
            AtelierTile *t = self->_tiles[i];
            CGRect r = [self _rectForSlot:i geometry:g];
            if (CGRectIsEmpty(r)) { t.alpha = 0; continue; }
            BOOL mini = (i > 0 && self->_layout != AtelierLayoutSplit);
            [t applyRect:r mini:mini];
            t.alpha = 1;
        }
        self->_plus.frame = CGRectIsEmpty(g.plus) ? self->_plus.frame : g.plus;
        self->_plus.alpha = CGRectIsEmpty(g.plus) ? 0 : 1;
        // the free places after the "+": faint outlines, so the column (or row) keeps its length
        BOOL places = self->_layout != AtelierLayoutSplit;
        for (NSInteger i = 0; i < 5; i++) {
            UIView *o = self->_outlines[(NSUInteger)i];
            BOOL show = places && (self->_tiles.count == 0 || i > g.miniCount);
            if (show) o.frame = g.minis[i];
            o.alpha = show ? 1 : 0;
        }
        BOOL band = !CGRectIsEmpty(g.band);
        if (band) {
            self->_band.frame = g.band;
            CGFloat room = CGRectIsEmpty(g.grabber) ? g.band.size.width : g.grabber.origin.x - 8 - g.band.origin.x;
            [self->_band setCompact:g.bandCompact flagsWidth:room];
            [self->_band layoutIfNeeded];
        }
        self->_band.alpha = band ? 1 : 0;
        self->_dock.frame = g.dock;
        [self->_dock setCompact:g.bandCompact];
        [self->_dock layoutIfNeeded];
        self->_dock.alpha = CGRectIsEmpty(g.dock) ? 0 : 1;
        self->_grabber.frame = g.grabber;
        self->_grabber.alpha = CGRectIsEmpty(g.grabber) ? 0 : 1;
        self->_grabber2.frame = g.grabber2;
        self->_grabber2.alpha = CGRectIsEmpty(g.grabber2) ? 0 : 1;
        if (!CGRectIsEmpty(g.divider)) {
            self->_divider.frame = g.divider;
            UIView *bar = [self->_divider viewWithTag:7];
            BOOL upright = g.divider.size.height > g.divider.size.width;
            bar.frame = upright ? CGRectMake((g.divider.size.width - 5) / 2.0, 14, 5, g.divider.size.height - 28)
                                : CGRectMake(14, (g.divider.size.height - 5) / 2.0, g.divider.size.width - 28, 5);
        }
        self->_divider.alpha = CGRectIsEmpty(g.divider) ? 0 : 1;
    };
    _plus.hidden = NO;
    _grabber.hidden = NO;
    _grabber2.hidden = NO;
    _divider.hidden = NO;
    // a tile that is new (or was parked) takes its place first and then fades in
    for (NSUInteger i = 0; i < _tiles.count; i++) {
        AtelierTile *t = _tiles[i];
        CGRect r = [self _rectForSlot:i geometry:g];
        if (t.alpha > 0 || CGRectIsEmpty(r)) continue;
        BOOL mini = (i > 0 && _layout != AtelierLayoutSplit);
        [UIView performWithoutAnimation:^{ [t applyRect:r mini:mini]; }];
    }
    if (_plus.alpha == 0 && !CGRectIsEmpty(g.plus)) [UIView performWithoutAnimation:^{ self->_plus.frame = g.plus; }];
    if (_tiles.count) [_stage bringSubviewToFront:_tiles[0]];
    if (animated) {
        _busyUntil = now + 0.5;
        [UIView animateWithDuration:0.36 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.2
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:apply completion:nil];
    } else {
        [UIView performWithoutAnimation:apply];
    }
}

- (void)makeMain:(NSUInteger)slot {
    if (slot == 0 || slot >= _tiles.count) return;
    [self hideMenu];
    AtelierTile *up = _tiles[slot], *down = _tiles[0];
    [_tiles exchangeObjectAtIndex:0 withObjectAtIndex:slot];
    down.liveSince = CFAbsoluteTimeGetCurrent();
    if (up.frozen) [self _thaw:up];
    AtelierHapticPlay(AtelierHapticSwap);
    [self _layoutAnimated:YES];
    [self touched];
    [self _persist];
    AtelierLog(@"swap: %@ is the main, %@ a mini", up.pane.bundleID, down.pane.bundleID);
}

- (void)setLayout:(AtelierLayoutKind)layout animated:(BOOL)animated {
    if (layout < 0 || layout > 2) return;
    [self hideMenu];
    _layout = layout;
    if (!_visible) { [[AtelierSettings shared] setLayout:layout]; return; }
    _lastTouch = CFAbsoluteTimeGetCurrent();
    [self _thawAll];
    [self _layoutAnimated:animated];
    [self _persist];
    AtelierLog(@"layout %ld", (long)layout);
}

- (void)cycleLayout {
    [self setLayout:(AtelierLayoutKind)((_layout + 1) % 3) animated:YES];
}

- (void)setSplit:(double)share {
    _split = MAX(0.3, MIN(0.7, share));
    if (_visible && _layout == AtelierLayoutSplit) [self _layoutAnimated:NO];
}

- (void)closeSlot:(NSUInteger)slot {
    if (slot >= _tiles.count) return;
    NSMutableArray<NSString *> *apps = [[self apps] mutableCopy];
    if ([self isLocked:apps[slot]]) {
        AtelierLog(@"close app %@: refused, it is locked", apps[slot]);
        [AtelierHost toast:@"Locked. Unlock it to close it."];
        return;
    }
    AtelierLog(@"close app %@", apps[slot]);
    [apps removeObjectAtIndex:slot];
    [self _setApps:apps animated:YES];
}

- (void)toggleLockSlot:(NSUInteger)slot {
    if (slot >= _tiles.count) return;
    AtelierTile *t = _tiles[slot];
    NSString *bid = t.pane.bundleID;
    if (!_locked) [self _loadLocks];
    BOOL lock = ![_locked containsObject:bid];
    if (lock) [_locked addObject:bid]; else [_locked removeObject:bid];
    [[AtelierSettings shared] setLockedApps:[_locked.allObjects sortedArrayUsingSelector:@selector(compare:)]];
    AtelierHapticPlay(AtelierHapticSwap);
    AtelierLog(@"%@ %@", lock ? @"lock" : @"unlock", bid);
    _lastTouch = CFAbsoluteTimeGetCurrent();
    [self _layoutAnimated:YES];                          // shows or hides the padlock, wakes it if it was a still
}

- (void)pairSlot:(NSUInteger)slot {
    if (slot == 0 || slot >= _tiles.count) return;
    AtelierTile *t = _tiles[slot];
    [_tiles removeObjectAtIndex:slot];
    [_tiles insertObject:t atIndex:1];
    AtelierLog(@"pair: %@ beside %@", t.pane.bundleID, _tiles[0].pane.bundleID);
    [self setLayout:AtelierLayoutSplit animated:YES];
}

- (void)replaceSlot:(NSUInteger)slot with:(NSString *)bid {
    if (bid.length == 0 || ![AtelierHost applicationForBundleID:bid] || [AtelierHost isHiddenApp:bid]) return;
    NSMutableArray<NSString *> *apps = [[self apps] mutableCopy];
    NSUInteger has = [apps indexOfObject:bid];
    if (slot >= apps.count) {
        if (has != NSNotFound || apps.count >= ATELIER_MAX_SLOTS) return;
        [apps addObject:bid];
    } else if (has != NSNotFound) {
        [apps exchangeObjectAtIndex:slot withObjectAtIndex:has];      // already on the bench: the two change places
    } else if ([self isLocked:apps[slot]]) {
        [AtelierHost toast:@"Locked. Unlock it to replace it."];
        return;
    } else {
        apps[slot] = bid;
    }
    [self _setApps:apps animated:YES];
    [self touched];
}

- (void)fullScreenSlot:(NSUInteger)slot {
    if (slot >= _tiles.count) return;
    NSString *bid = _tiles[slot].pane.bundleID;
    if (slot != 0) [_tiles exchangeObjectAtIndex:0 withObjectAtIndex:slot];
    // The very scene that was on the bench is opened full screen (see +activateScene:); only if
    // this iOS has no way to do that is the app opened by its bundle id.
    id scene = [_tiles[0].pane scene];
    [self _closeAnimated:YES reason:@"full screen" keeping:bid then:^{
        BOOL same = [AtelierScenes activateScene:scene];
        BOOL ok = same || [AtelierHost launchApp:bid suspended:NO];
        AtelierLog(@"full screen %@ -> %d (%@)", bid, (int)ok, same ? @"its own scene" : @"by bundle id");
    }];
}

- (void)saveAsSet {
    NSArray<NSString *> *apps = [self apps];
    if (apps.count < 2) { [AtelierHost toast:@"Add a second app first. A set is two to six apps."]; return; }
    AtelierSettings *s = [AtelierSettings shared];
    NSMutableArray<NSDictionary *> *sets = [[s sets] mutableCopy];
    NSSet *mine = [NSSet setWithArray:apps];
    for (NSDictionary *d in [sets copy]) if ([[NSSet setWithArray:d[@"apps"]] isEqualToSet:mine]) [sets removeObject:d];
    NSDictionary *set = @{ @"name": @"", @"apps": apps, @"layout": @((NSInteger)_layout) };
    [sets insertObject:set atIndex:0];
    [s setSets:sets];
    AtelierLog(@"set saved: %@ (%lu sets)", [apps componentsJoinedByString:@" "], (unsigned long)sets.count);
    [AtelierHost toast:[NSString stringWithFormat:@"Saved “%@”. Hold any of its apps' icons to open it.", [AtelierSheets setTitle:set]]];
}

// Locked apps keep their places; the set's apps take the others, in order.
- (void)openSet:(NSDictionary *)set {
    NSArray *apps = set[@"apps"];
    if (![apps isKindOfClass:NSArray.class] || apps.count == 0) return;
    [AtelierHost reloadHiddenApps];
    [self _loadLocks];
    NSArray<NSString *> *current = _visible ? [self apps] : [self _usable:[[AtelierSettings shared] slots]];
    NSMutableArray<NSString *> *incoming = [[self _usable:apps] mutableCopy];
    NSMutableDictionary<NSNumber *, NSString *> *pinned = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < current.count; i++) {
        if (![self isLocked:current[i]]) continue;
        pinned[@(i)] = current[i];
        [incoming removeObject:current[i]];
    }
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSUInteger total = MIN((NSUInteger)ATELIER_MAX_SLOTS, pinned.count + incoming.count), next = 0;
    for (NSUInteger i = 0; result.count < total && i < 2 * ATELIER_MAX_SLOTS; i++) {
        NSString *pin = pinned[@(i)];
        if (pin) { [result addObject:pin]; [pinned removeObjectForKey:@(i)]; }
        else if (next < incoming.count && result.count + pinned.count < total) [result addObject:incoming[next++]];
        else if (pinned.count == 0) break;
    }
    if (next < incoming.count)
        [AtelierHost toast:[NSString stringWithFormat:@"%lu of the set's apps had no room beside the locked ones.", (unsigned long)(incoming.count - next)]];
    AtelierLog(@"set: %@ (%lu locked kept)", [result componentsJoinedByString:@" "], (unsigned long)(total - next));
    [self openWithApps:result layout:[set[@"layout"] integerValue]];
}

#pragma mark live and still

- (void)_thaw:(AtelierTile *)t {
    if (!t.frozen) return;
    t.frozen = NO;
    t.liveSince = CFAbsoluteTimeGetCurrent();
    [t.pane setLive:YES];
    __weak AtelierTile *weak = t;
    AtelierAfter(0.45, ^{                                  // the app has drawn again by now
        AtelierTile *tile = weak;
        if (!tile || tile.frozen) return;
        [UIView animateWithDuration:0.15 animations:^{ tile.still.alpha = 0; } completion:^(BOOL done) {
            if (!tile.frozen) { tile.still.hidden = YES; tile.still.image = nil; }
            tile.still.alpha = 1;
        }];
    });
}

- (void)_thawAll {
    for (AtelierTile *t in _tiles) [self _thaw:t];
}

- (void)_freeze:(NSArray<AtelierTile *> *)tiles {
    if (tiles.count == 0) return;
    UIImage *screen = [AtelierHost screenImage];
    CGImageRef whole = screen.CGImage;
    CGSize size = [AtelierHost screenSize];
    CGFloat kx = whole ? CGImageGetWidth(whole) / MAX(1, size.width) : 0;
    CGFloat ky = whole ? CGImageGetHeight(whole) / MAX(1, size.height) : 0;
    BOOL upright = whole && CGImageGetWidth(whole) < CGImageGetHeight(whole);
    NSUInteger stills = 0;
    for (AtelierTile *t in tiles) {
        if (t.frozen || t.parked || t.pane.state != AtelierPaneHosted) continue;
        if (whole && upright) {
            CGRect r = [t.clip convertRect:t.clip.bounds toView:nil];
            CGImageRef part = CGImageCreateWithImageInRect(whole, CGRectMake(r.origin.x * kx, r.origin.y * ky, r.size.width * kx, r.size.height * ky));
            if (part) {
                t.still.image = [UIImage imageWithCGImage:part scale:kx orientation:UIImageOrientationUp];
                t.still.alpha = 1;
                t.still.hidden = NO;
                CGImageRelease(part);
                stills++;
            }
        }
        t.frozen = YES;
        [t.pane setLive:NO];
    }
    AtelierLog(@"froze %lu mini(s), %lu with a still", (unsigned long)tiles.count, (unsigned long)stills);
}

- (NSArray<AtelierTile *> *)_liveMinis {
    NSMutableArray<AtelierTile *> *out = [NSMutableArray array];
    if (_layout == AtelierLayoutSplit) return out;
    for (NSUInteger i = 1; i < _tiles.count; i++) {
        AtelierTile *t = _tiles[i];
        if (!t.frozen && !t.parked && !t.locked && t.pane.state == AtelierPaneHosted) [out addObject:t];
    }
    return out;
}

- (void)freezeNow {
    [self _freeze:[self _liveMinis]];
}

- (void)touched {
    _lastTouch = CFAbsoluteTimeGetCurrent();
    if (!_visible) return;
    if ([AtelierSettings shared].miniMode != AtelierMiniStills) [self _thawAll];
}

- (void)_touchFromScreen {
    if (_visible) [self touched];
}

- (void)_tick {
    if (!_visible || _closing) return;
    if ([AtelierHost isLocked]) { [self closeAnimated:NO reason:@"locked"]; return; }
    NSString *front = [AtelierHost frontmostBundleID];
    if (front != _frontAtOpen && ![front isEqualToString:_frontAtOpen ?: @""]) {
        [self closeAnimated:YES reason:[NSString stringWithFormat:@"%@ came to the front", front ?: @"the Home Screen"]];
        return;
    }
    if ([AtelierHost switcherVisible]) { [self closeAnimated:YES reason:@"the App Switcher opened"]; return; }

    _ticks++;
    [AtelierToggles benchTick];                          // Keep Awake, if it is on: only ever from this clock
    if (_ticks % 6 == 0) [_dock refresh];                // the switches, in case something else flipped one

    // an app that was closed underneath is started again (twice at most, then it waits for a tap)
    for (AtelierTile *t in _tiles) {
        if (t.parked) continue;
        if (![t.pane check] && t.pane.state == AtelierPaneIdle && t.restarts < 2) {
            t.restarts++;
            t.frozen = NO;
            t.still.hidden = YES;
            [t.pane attach];
            [t.pane setLive:YES];
        }
    }

    AtelierSettings *s = [AtelierSettings shared];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (s.miniMode == AtelierMiniLive || _menu || [AtelierSheets isOpen] || now < _busyUntil) return;
    NSMutableArray<AtelierTile *> *due = [NSMutableArray array];
    for (AtelierTile *t in [self _liveMinis]) {
        if (s.miniMode == AtelierMiniStills) {
            if (now - t.liveSince > [s tune:@"stillAfter" fallback:1.6]) [due addObject:t];
        } else if (now - _lastTouch > s.freezeAfter && now - t.liveSince > 1.6) {
            [due addObject:t];
        }
    }
    [self _freeze:due];
}

#pragma mark touches on the bench

- (NSUInteger)_slotOfTileWithShield:(id)shield {
    for (NSUInteger i = 0; i < _tiles.count; i++) if (_tiles[i].shield == shield) return i;
    return NSNotFound;
}

- (void)_miniTapped:(UIControl *)shield {
    NSUInteger slot = [self _slotOfTileWithShield:shield];
    if (slot == NSNotFound) return;
    if (_menu) { [self hideMenu]; return; }
    AtelierTile *t = _tiles[slot];
    if (t.pane.state == AtelierPaneFailed || t.pane.state == AtelierPaneIdle) { t.restarts = 0; [t.pane attach]; }
    [self makeMain:slot];
}

- (void)_miniHeld:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSUInteger slot = [self _slotOfTileWithShield:g.view];
    if (slot != NSNotFound) { AtelierHapticPlay(AtelierHapticSwap); [self showMenuForSlot:slot]; }
}

#pragma mark swipes on a mini

// What letting go would do, and whether it may. nil = nothing is set for this direction.
- (NSString *)_swipeTitle:(AtelierSwipe)swipe tile:(AtelierTile *)t allowed:(BOOL *)allowed {
    BOOL locked = [self isLocked:t.pane.bundleID];
    *allowed = YES;
    switch (swipe) {
        case AtelierSwipeLeft:
            if (locked) { *allowed = NO; return @"Locked"; }
            return @"Close";
        case AtelierSwipeRight:
            return @"Make Main";
        case AtelierSwipeUp:
            return locked ? @"Unlock" : @"Lock";
        case AtelierSwipeDownward:
            switch ([AtelierSettings shared].swipeDown) {
                case AtelierSwipeDownSplit:   return @"Split with Main";
                case AtelierSwipeDownFull:    return @"Full Screen";
                case AtelierSwipeDownReplace:
                    if (locked) { *allowed = NO; return @"Locked"; }
                    return @"Replace";
                default: break;
            }
            *allowed = NO;
            return nil;
    }
    *allowed = NO;
    return nil;
}

- (void)performSwipe:(AtelierSwipe)swipe onSlot:(NSUInteger)slot {
    if (slot == 0 || slot >= _tiles.count) return;
    static NSArray<NSString *> *names;
    if (!names) names = @[ @"left", @"right", @"up", @"down" ];
    AtelierTile *t = _tiles[slot];
    NSString *bid = t.pane.bundleID;
    BOOL allowed = NO;
    NSString *title = [self _swipeTitle:swipe tile:t allowed:&allowed];
    if (!allowed) {
        AtelierLog(@"swipe %@ on %@: refused (%@)", names[(NSUInteger)swipe], bid, title ?: @"nothing set");
        if (title) AtelierHapticPlay(AtelierHapticSwap);
        return;
    }
    AtelierLog(@"swipe %@ on %@: %@", names[(NSUInteger)swipe], bid, title);
    switch (swipe) {
        case AtelierSwipeLeft:  [self closeSlot:slot]; break;
        case AtelierSwipeRight: [self makeMain:slot]; break;
        case AtelierSwipeUp:    [self toggleLockSlot:slot]; break;
        case AtelierSwipeDownward: {
            AtelierSwipeDown what = [AtelierSettings shared].swipeDown;
            if (what == AtelierSwipeDownSplit) [self pairSlot:slot];
            else if (what == AtelierSwipeDownFull) [self fullScreenSlot:slot];
            else if (what == AtelierSwipeDownReplace) {
                __weak typeof(self) weak = self;
                [AtelierSheets pickAppWithTitle:@"Replace with" excluding:@[ bid ] then:^(NSString *picked) {
                    NSUInteger at = [[weak apps] indexOfObject:bid];
                    if (at != NSNotFound) [weak replaceSlot:at with:picked];
                }];
            }
            break;
        }
    }
}

- (void)_hideSwipePill {
    if (_swipePill.alpha == 0) return;
    [UIView animateWithDuration:0.12 animations:^{ self->_swipePill.alpha = 0; }];
}

- (void)_showSwipePill:(NSString *)title armed:(BOOL)armed refused:(BOOL)refused beside:(CGRect)tile {
    if (title.length == 0) { [self _hideSwipePill]; return; }
    _swipePill.text = title;
    _swipePill.backgroundColor = armed ? [UIColor colorWithRed:0.42 green:0.40 blue:0.95 alpha:1]
                                       : (refused ? [UIColor colorWithRed:0.45 green:0.16 blue:0.16 alpha:0.92] : [UIColor colorWithWhite:0.05 alpha:0.85]);
    _swipePill.textColor = (armed || refused) ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.78];
    CGSize screen = [AtelierHost screenSize];
    CGFloat w = ceil([_swipePill sizeThatFits:CGSizeMake(200, 26)].width) + 22, h = 26;
    // beside the tile in the column, under it in the row
    CGFloat x = _layout == AtelierLayoutTop ? CGRectGetMidX(tile) - w / 2.0 : CGRectGetMaxX(tile) + 10;
    CGFloat y = _layout == AtelierLayoutTop ? CGRectGetMaxY(tile) + 8 : CGRectGetMidY(tile) - h / 2.0;
    x = MAX(8, MIN(screen.width - w - 8, x));
    _swipePill.frame = CGRectMake(x, y, w, h);
    _swipePill.alpha = 1;
}

// The mini follows the finger along the way the swipe set out, past the screen's edge if the
// finger goes there, and its label goes with it. Letting go acts when the swipe is armed:
//
//   far enough   55% of the way from where the finger came down to the edge of the screen it is
//                heading for, never more than 40 points and never less than 14. (A mini in the
//                column lies against the left edge: a finger that comes down 30 points from it
//                can't travel 40.) A finger that has reached the edge counts as well.
//   or a flick   350 points a second or more along the swipe at the lift, after 10 points.
//
// The travel is measured from where the finger came down (the recogniser's own figure leaves
// out the first ten points or so, which it spends making up its mind). A swipe that ends
// without acting says why in the log: direction, travel, speed and room.
- (void)_miniPanned:(UIPanGestureRecognizer *)g {
    NSUInteger slot = [self _slotOfTileWithShield:g.view];
    if (slot == NSNotFound || slot == 0) return;
    AtelierTile *t = _tiles[slot];
    CGPoint at = [g locationInView:_root];
    CGPoint d = CGPointMake(at.x - _swipeDown.x, at.y - _swipeDown.y);
    if (g.state == UIGestureRecognizerStateBegan) {
        [self hideMenu];
        _swipeTile = t;
        _swipeAxis = 0;
        _swipeArmed = NO;
        _lastTouch = CFAbsoluteTimeGetCurrent();
        [_stage bringSubviewToFront:t];
    }
    if (t != _swipeTile) return;
    BOOL moving = g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged;
    // Which way it is going is settled once the finger has moved six points.
    if (_swipeAxis == 0 && MAX(fabs(d.x), fabs(d.y)) >= 6) _swipeAxis = fabs(d.x) > fabs(d.y) ? 1 : 2;
    if (_swipeAxis == 0) {
        if (!moving) {
            AtelierLog(@"swipe on %@ did not arm: the finger moved %.0f pt, too little to tell a direction", t.pane.bundleID, MAX(fabs(d.x), fabs(d.y)));
            _swipeTile = nil;
            [self _hideSwipePill];
        }
        return;
    }
    static NSArray<NSString *> *names;
    if (!names) names = @[ @"left", @"right", @"up", @"down" ];
    CGFloat v = _swipeAxis == 1 ? d.x : d.y;
    AtelierSwipe swipe = _swipeAxis == 1 ? (v < 0 ? AtelierSwipeLeft : AtelierSwipeRight) : (v < 0 ? AtelierSwipeUp : AtelierSwipeDownward);
    BOOL allowed = NO;
    NSString *title = [self _swipeTitle:swipe tile:t allowed:&allowed];
    CGSize screen = [AtelierHost screenSize];
    // the room the finger had that way when it came down, and what is left of it now
    CGFloat room = swipe == AtelierSwipeLeft ? _swipeDown.x : (swipe == AtelierSwipeRight ? screen.width - _swipeDown.x
                 : (swipe == AtelierSwipeUp ? _swipeDown.y : screen.height - _swipeDown.y));
    CGFloat left = swipe == AtelierSwipeLeft ? at.x : (swipe == AtelierSwipeRight ? screen.width - at.x
                 : (swipe == AtelierSwipeUp ? at.y : screen.height - at.y));
    CGFloat threshold = MIN(40.0, MAX(14.0, 0.55 * room));
    BOOL far = fabs(v) >= threshold || (fabs(v) >= 10 && left <= 3);
    if (moving) {
        CGFloat shown = allowed ? MAX(-180, MIN(180, v)) : MAX(-20, MIN(20, v * 0.22));     // a refused swipe barely gives
        t.transform = _swipeAxis == 1 ? CGAffineTransformMakeTranslation(shown, 0) : CGAffineTransformMakeTranslation(0, shown);
        BOOL armed = allowed && far;
        if (armed != _swipeArmed) {
            _swipeArmed = armed;
            if (armed) AtelierHapticPlay(AtelierHapticTick);
        }
        CGRect rect = [self _rectForSlot:slot geometry:_geometry];
        rect = _swipeAxis == 1 ? CGRectOffset(rect, shown, 0) : CGRectOffset(rect, 0, shown);      // the label goes with the tile
        [self _showSwipePill:title armed:armed refused:(!allowed && title.length) beside:rect];
        return;
    }
    CGPoint velocity = [g velocityInView:_root];
    CGFloat speed = (_swipeAxis == 1 ? velocity.x : velocity.y) * (v < 0 ? -1 : 1);      // along the swipe; negative = going back
    BOOL ended = g.state == UIGestureRecognizerStateEnded;
    BOOL flick = fabs(v) >= 10 && speed >= 350;
    BOOL fire = ended && allowed && (far || flick);
    BOOL refused = ended && !allowed && title.length && (far || flick);
    NSString *numbers = [NSString stringWithFormat:@"travel %.0f pt (it needed %.0f), %.0f pt/s at the lift, room %.0f pt",
                         fabs(v), threshold, speed, room];
    _swipeTile = nil;
    _swipeArmed = NO;
    [self _hideSwipePill];
    if (fire) {
        AtelierLog(@"swipe %@ on %@ armed by %@: %@", names[(NSUInteger)swipe], t.pane.bundleID, far ? @"travel" : @"a flick", numbers);
        // it stays where the finger left it; what follows animates it from there
        CGRect where = t.frame;
        t.transform = CGAffineTransformIdentity;
        t.frame = where;
        [self performSwipe:swipe onSlot:slot];
        [self _layoutAnimated:YES];
        return;
    }
    AtelierLog(@"swipe %@ on %@ did not arm: %@%@", names[(NSUInteger)swipe], t.pane.bundleID, numbers,
               !ended ? @" (the touch was cancelled)" : (refused ? @" (refused)" : (!allowed ? @" (nothing is set for that way)" : @"")));
    if (refused) [self performSwipe:swipe onSlot:slot];                     // logs it and taps the finger
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{ t.transform = CGAffineTransformIdentity; } completion:nil];
}

- (void)_grabberTapped:(UIButton *)b {
    if (_menu) { [self hideMenu]; return; }
    [self showMenuForSlot:(NSUInteger)b.tag];
}

- (void)_backdropTapped {
    if (_menu) [self hideMenu];
}

- (void)_homeSwipe:(UIScreenEdgePanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self closeAnimated:YES reason:@"Home gesture"];
}

// A finger that came down on the dock or below it and goes up: 48 points of travel (from where it
// came down), or a quick flick up after 20.
- (void)_bottomSwipe:(UIPanGestureRecognizer *)g {
    if (!_swipeFromBottom || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) return;
    CGPoint at = [g locationInView:_root];
    CGPoint moved = CGPointMake(at.x - _bottomDown.x, at.y - _bottomDown.y);
    BOOL up = moved.y < 0 && fabs(moved.x) < fabs(moved.y);
    BOOL far = up && moved.y <= -48;
    BOOL flick = g.state == UIGestureRecognizerStateEnded && up && moved.y <= -20 && [g velocityInView:_root].y <= -350;
    if (far || flick) {
        _swipeFromBottom = NO;
        [self closeAnimated:YES reason:(far ? @"swipe up from the bottom" : @"flick up from the bottom")];
    }
}

- (void)_plusTapped {
    if (_menu) { [self hideMenu]; return; }
    NSUInteger slot = _tiles.count;
    __weak typeof(self) weak = self;
    [AtelierSheets pickAppWithTitle:@"Add an app" excluding:[self apps] then:^(NSString *bid) { [weak replaceSlot:slot with:bid]; }];
}

- (void)_dividerDragged:(UIPanGestureRecognizer *)g {
    if (_layout != AtelierLayoutSplit) return;
    CGPoint p = [g locationInView:_root];
    CGSize screen = [AtelierHost screenSize];
    UIEdgeInsets safe = [AtelierHost safeInsets];
    BOOL stacked = _geometry.divider.size.width > _geometry.divider.size.height;
    double share;
    if (stacked) {
        CGFloat top = safe.top + 30, bottom = screen.height - MAX(safe.bottom, 12);
        share = (p.y - top) / MAX(1, bottom - top);
    } else {
        share = (p.x - 10) / MAX(1, screen.width - 20);
    }
    [self setSplit:share];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [[AtelierSettings shared] setObject:@(_split) forKey:@"split"];
        [self _layoutAnimated:YES];
    }
}

#pragma mark menu

static NSDictionary *AtelierMenuItem(NSString *title, NSString *symbol, BOOL red, void (^run)(void)) {
    return @{ @"title": title, @"symbol": symbol, @"red": @(red), @"run": [run copy] };
}

- (void)hideMenu {
    AtelierMenu *m = _menu;
    if (!m) return;
    _menu = nil;
    [UIView animateWithDuration:0.14 animations:^{ m.alpha = 0; m.transform = CGAffineTransformMakeScale(0.94, 0.94); }
                     completion:^(BOOL done) { [m removeFromSuperview]; }];
}

- (void)showMenuForSlot:(NSUInteger)slot {
    [self hideMenu];
    if (!_visible) return;
    __weak typeof(self) weak = self;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    BOOL has = slot < _tiles.count;
    NSString *bid = has ? _tiles[slot].pane.bundleID : nil;
    BOOL mini = has && slot > 0 && _layout != AtelierLayoutSplit;
    // Each action finds the app again by its bundle id: the tiles may have moved by the time a row is tapped.
    NSUInteger (^where)(void) = ^NSUInteger { return bid ? [[weak apps] indexOfObject:bid] : NSNotFound; };
    if (mini) [items addObject:AtelierMenuItem(@"Make Main", @"arrow.up.left.and.arrow.down.right", NO, ^{
        NSUInteger i = where();
        if (i != NSNotFound) [weak makeMain:i];
    })];
    if (has) [items addObject:AtelierMenuItem(@"Full Screen", @"arrow.up.forward.app", NO, ^{
        NSUInteger i = where();
        if (i != NSNotFound) [weak fullScreenSlot:i];
    })];
    if (!mini) [items addObject:AtelierMenuItem(@"Switch Layout", @"rectangle.3.group", NO, ^{ [weak cycleLayout]; })];
    BOOL locked = has && [self isLocked:bid];
    if (has && !locked) {
        [items addObject:AtelierMenuItem(@"Replace App", @"arrow.triangle.2.circlepath", NO, ^{
            if (where() == NSNotFound) return;
            [AtelierSheets pickAppWithTitle:@"Replace with" excluding:(bid ? @[ bid ] : @[]) then:^(NSString *picked) {
                NSUInteger at = where();
                if (at != NSNotFound) [weak replaceSlot:at with:picked];
            }];
        })];
        [items addObject:AtelierMenuItem(@"Close App", @"xmark", NO, ^{
            NSUInteger i = where();
            if (i != NSNotFound) [weak closeSlot:i];
        })];
    }
    if (has) [items addObject:AtelierMenuItem(locked ? @"Unlock" : @"Lock", locked ? @"lock.open" : @"lock", NO, ^{
        NSUInteger i = where();
        if (i != NSNotFound) [weak toggleLockSlot:i];
    })];
    if (!mini) {
        [items addObject:AtelierMenuItem(@"Save as Set", @"square.stack.3d.up", NO, ^{ [weak saveAsSet]; })];
        [items addObject:AtelierMenuItem(@"Sets…", @"list.bullet.rectangle", NO, ^{ [AtelierSheets showSets]; })];
        [items addObject:AtelierMenuItem([@"Close " stringByAppendingString:ATELIER_NAME], @"xmark.circle", YES, ^{ [weak closeAnimated:YES reason:@"menu"]; })];
    }
    CGSize screen = [AtelierHost screenSize];
    CGRect anchor = mini ? _tiles[slot].frame : (slot == 1 && !CGRectIsEmpty(_geometry.grabber2) ? _geometry.grabber2 : _geometry.grabber);
    if (CGRectIsEmpty(anchor)) anchor = CGRectMake(screen.width / 2.0 - 32, [AtelierHost safeInsets].top + 8, 64, 22);
    [self _showMenu:items anchor:anchor beside:(mini && _layout != AtelierLayoutTop) leftAligned:(mini && _layout == AtelierLayoutTop)];
}

// A hold on a shortcut icon.
- (void)_showShortcutMenu:(NSString *)bid frame:(CGRect)frame {
    [self hideMenu];
    if (!_visible || bid.length == 0) return;
    __weak typeof(self) weak = self;
    NSArray<NSDictionary *> *items = @[
        AtelierMenuItem(@"Open", @"arrow.up.left.and.arrow.down.right", NO, ^{ [weak openShortcut:bid]; }),
        AtelierMenuItem(@"Remove from Shortcuts", @"minus.circle", YES, ^{ [weak removeShortcut:bid]; }),
    ];
    AtelierLog(@"shortcut %@: menu", bid);
    [self _showMenu:items anchor:[_band convertRect:frame toView:_root] beside:NO leftAligned:NO];
}

// The "+" at the end of the shortcut row.
- (void)_addShortcut {
    if (_menu) { [self hideMenu]; return; }
    __weak typeof(self) weak = self;
    [AtelierSheets pickAppWithTitle:@"Add a Shortcut" excluding:[AtelierBand shownShortcuts] then:^(NSString *bid) { [weak addShortcut:bid]; }];
}

- (void)addShortcut:(NSString *)bid {
    if (bid.length == 0 || ![AtelierHost applicationForBundleID:bid] || [AtelierHost isHiddenApp:bid]) return;
    AtelierSettings *s = [AtelierSettings shared];
    NSArray<NSString *> *shown = [AtelierBand shownShortcuts];
    if ([shown containsObject:bid]) return;
    if (shown.count >= ATELIER_SHORTCUTS) { [AtelierHost toast:@"Six shortcuts is the most. Remove one first."]; return; }
    // the ones the row shows, then the new one, then any the row does not show (apps that are not installed, or are hidden)
    NSMutableArray<NSString *> *list = [shown mutableCopy];
    [list addObject:bid];
    for (NSString *other in [s shortcutApps]) if (![list containsObject:other]) [list addObject:other];
    [s setShortcutApps:list];
    AtelierLog(@"shortcut added: %@ (%lu in the row)", bid, (unsigned long)(shown.count + 1));
    [_band reload];
    [self _layoutAnimated:NO];
}

- (void)removeShortcut:(NSString *)bid {
    AtelierSettings *s = [AtelierSettings shared];
    NSMutableArray<NSString *> *list = [[s shortcutApps] mutableCopy];
    if (![list containsObject:bid]) return;
    [list removeObject:bid];
    [s setShortcutApps:list];
    AtelierLog(@"shortcut removed: %@ (%lu in the row)", bid, (unsigned long)[AtelierBand shownShortcuts].count);
    [_band reload];
    [self _layoutAnimated:NO];
}

// Puts a menu on the screen: under its anchor and centred on it, or beside it (a mini in the
// column), or under it with the left edges in line (a mini in the row).
- (void)_showMenu:(NSArray<NSDictionary *> *)items anchor:(CGRect)anchor beside:(BOOL)beside leftAligned:(BOOL)leftAligned {
    AtelierMenu *menu = [[AtelierMenu alloc] initWithItems:items];
    CGSize screen = [AtelierHost screenSize];
    CGFloat x = beside ? CGRectGetMaxX(anchor) + 8 : CGRectGetMidX(anchor) - menu.bounds.size.width / 2.0;
    CGFloat y = beside ? anchor.origin.y : CGRectGetMaxY(anchor) + 6;
    if (leftAligned) { x = anchor.origin.x; y = CGRectGetMaxY(anchor) + 8; }
    x = MAX(8, MIN(screen.width - menu.bounds.size.width - 8, x));
    y = MAX([AtelierHost safeInsets].top + 4, MIN(screen.height - menu.bounds.size.height - 40, y));
    menu.frame = CGRectMake(x, y, menu.bounds.size.width, menu.bounds.size.height);
    menu.alpha = 0;
    menu.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [_root addSubview:menu];
    _menu = menu;
    [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.3 options:0 animations:^{
        menu.alpha = 1;
        menu.transform = CGAffineTransformIdentity;
    } completion:nil];
}

#pragma mark tests

- (NSString *)debugState {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < _tiles.count; i++) {
        AtelierTile *t = _tiles[i];
        [parts addObject:[NSString stringWithFormat:@"[%lu %@%@%@%@ %.0f,%.0f %.0fx%.0f x%.3f]", (unsigned long)i, [t.pane debugState],
                          t.frozen ? @" frozen" : @"", t.parked ? @" parked" : @"", [self isLocked:t.pane.bundleID] ? @" LOCKED" : @"",
                          t.frame.origin.x, t.frame.origin.y,
                          t.frame.size.width, t.frame.size.height, [t tileScale]]];
    }
    NSMutableArray<NSString *> *menu = [NSMutableArray array];
    for (NSDictionary *item in _menu.items) [menu addObject:item[@"title"]];
    return [NSString stringWithFormat:@"bench %@ layout %ld split %.2f front-at-open %@ idle %.1fs menu [%@] %@ · %@ · %@ · %@ · hidden apps %lu",
            _visible ? @"up" : @"hidden", (long)_layout, _split, _frontAtOpen ?: @"home",
            _visible ? CFAbsoluteTimeGetCurrent() - _lastTouch : 0.0, [menu componentsJoinedByString:@" | "],
            [parts componentsJoinedByString:@" "], _band ? [_band debugState] : @"no band", _dock ? [_dock debugState] : @"no dock",
            [[AtelierQuotes shared] debugState], (unsigned long)[AtelierHost hiddenAppCount]];
}

- (AtelierBand *)debugBand { return _band; }
- (AtelierDock *)debugDock { return _dock; }

// Every tile, pill, place and shortcut with its frame on the screen, one per line:
//   name x y width height scale        (scale: the app's picture, 0 for things that aren't apps)
// Also written to <log dir>/atelier_where.txt, for a test that has to aim a finger.
- (NSString *)debugWhere {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    void (^add)(NSString *, CGRect, CGFloat) = ^(NSString *name, CGRect r, CGFloat scale) {
        if (CGRectIsEmpty(r)) return;
        [lines addObject:[NSString stringWithFormat:@"%@ %.1f %.1f %.1f %.1f %.4f", name, r.origin.x, r.origin.y, r.size.width, r.size.height, scale]];
    };
    if (_visible) {
        for (NSUInteger i = 0; i < _tiles.count; i++) {
            AtelierTile *t = _tiles[i];
            if (t.parked) continue;
            NSString *name = i == 0 ? @"main" : (_layout == AtelierLayoutSplit ? @"second" : [NSString stringWithFormat:@"mini%lu", (unsigned long)(i - 1)]);
            add(name, [self _rectForSlot:i geometry:_geometry], [t tileScale]);
        }
        if (_layout != AtelierLayoutSplit) for (NSInteger i = 0; i < 5; i++) add([NSString stringWithFormat:@"place%ld", (long)i], _geometry.minis[i], 0);
        add(@"plus", _geometry.plus, 0);
        add(@"pill", _geometry.grabber, 0);
        add(@"pill2", _geometry.grabber2, 0);
        add(@"divider", _geometry.divider, 0);
        add(@"band", _geometry.band, 0);
        if (!CGRectIsEmpty(_geometry.band)) {
            for (NSDictionary *item in [_band debugFrames]) add(item[@"name"], [_band convertRect:[item[@"frame"] CGRectValue] toView:_root], 0);
        }
        add(@"dock", _geometry.dock, 0);
        if (!CGRectIsEmpty(_geometry.dock)) {
            for (NSDictionary *item in [_dock debugFrames]) add(item[@"name"], [_dock convertRect:[item[@"frame"] CGRectValue] toView:_root], 0);
        }
        add(@"strip", _geometry.closeStrip, 0);
        if (_menu) add(@"menu", _menu.frame, 0);
    }
    for (NSString *line in [AtelierSheets debugWhere]) [lines addObject:line];           // the picker's field and keyboard, when it is up
    NSString *text = [lines componentsJoinedByString:@"\n"];
    [[text stringByAppendingString:@"\n"] writeToFile:[AtelierLogDir() stringByAppendingPathComponent:@"atelier_where.txt"]
                                          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return text;
}

- (void)debugMenuTap:(NSUInteger)index {
    [_menu runItem:index];
}

@end
