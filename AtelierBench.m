/*  AtelierBench.m — the bench window: tiles, layouts, the swap, the "..." menu, the freeze clock.

    One SpringBoard window over the Home Screen and apps (under Control Centre, notifications
    and the lock screen). Behind everything a blur of whatever was on screen; on it one tile per
    app. A tile is a rounded clip view holding the pane's view (AtelierScenes.m), which always
    has the size of the app's scene and is scaled down to the tile's width.

      main tile     nothing of SpringBoard's lies over it, so touches go straight to the app
      mini tile     a shield on top takes the touches (AtelierShield, AtelierGestures.m): a tap
                    makes it the main, a hold opens its menu, a swipe acts on it (left closes,
                    right makes it the main, up locks or unlocks, down is the Settings choice).
                    A frozen mini also shows a still, and its app is in the background. A locked
                    app is never frozen and can't be swiped away.

    Coming and going. How far in the bench is, is one number: 0 gone, 1 fully there (-_show:).
    The backdrop's blur and dim follow it, and everything else (one container view) is moved and
    scaled as a whole; nothing is laid out again on the way. A finger can hold that number (the
    edge strip, the swipe up, SpringBoard's Home gesture: -beginDragOpening:…, -dragTo:,
    -endDrag:…), and when nobody holds it, it settles to 0 or 1 on a short spring.

    Above the tiles is the band (AtelierBand.m): index numbers, clock, market flags, shortcut
    apps. Under them the dock (AtelierToggles.m): six switches and the credit line. A swipe up
    that starts on the dock or below it puts the bench away.

    While the bench is up a half-second clock looks after it: it puts the bench away when
    SpringBoard moves on (another app in front, the App Switcher, a lock), restarts an app that
    was closed underneath, and freezes the minis when their time is up. The clock and the touch
    watcher exist only while the bench is on screen; hidden, the bench does nothing at all.     */

#import "Atelier.h"
#import <dlfcn.h>

// When each app was last the main app of the bench, or was put on it by hand. Kept by bundle id
// for as long as SpringBoard runs, so it outlives the bench being put away and brought back (the
// tiles don't: they are made anew each time, and on the phone the first version of this, kept on
// the tile, let go of whichever social app happened to come first in the row). A full bench
// lets go of the social app with the oldest entry; none at all counts as oldest.
static NSMutableDictionary<NSString *, NSNumber *> *gUsedAt;

static void AtelierNoteUsed(NSString *bid) {
    if (bid.length == 0) return;
    if (!gUsedAt) gUsedAt = [NSMutableDictionary dictionary];
    gUsedAt[bid] = @(CFAbsoluteTimeGetCurrent());
}

static CFAbsoluteTime AtelierUsedAt(NSString *bid) {
    return bid.length ? [gUsedAt[bid] doubleValue] : 0;
}

#pragma mark - a tile

@interface AtelierTile : UIView
@property (nonatomic, strong) AtelierPane *pane;
@property (nonatomic, strong) UIView *clip;
@property (nonatomic, strong) UIImageView *still;
@property (nonatomic, strong) AtelierShield *shield;
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
    _shield = [[AtelierShield alloc] initWithFrame:self.bounds];
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

@interface AtelierBench () <UIGestureRecognizerDelegate, AtelierShieldDelegate>
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
    UIBlurEffect *_blurEffect;
    UIViewPropertyAnimator *_blurScrub;      // holds the blur part-way while the bench is part-way in
    UIView *_dim;
    AtelierCloseStrip *_closeStrip;          // along the bottom: a finger that goes up from it closes the bench
    UIView *_content;                        // everything but the backdrop: what moves when the bench comes and goes
    UIView *_stage;                          // holds the tiles
    NSMutableArray<AtelierTile *> *_tiles;   // index 0 is the main
    NSMutableArray<AtelierTile *> *_leaving; // tiles on their way out; their apps are let go once they are out of sight
    // coming and going
    CGFloat _progress;                       // 0 gone … 1 fully there
    AtelierMotion _motion;                   // how it moves between the two
    __weak id _dragOwner;                    // who is moving it by hand right now
    BOOL _dragOpening;                       // … and whether that began as an opening
    CADisplayLink *_settle;                  // runs while the bench settles to 0 or 1 by itself
    CGFloat _settleTo, _settleSpeed, _settleDamping;
    CFTimeInterval _settleBegan, _settleLast;
    void (^_settleThen)(void);
    BOOL _dockDragging;                      // a finger that came down on a switch is carrying the bench up
    BOOL _bounce;                            // the next layout springs back with a bounce (a lock)
    BOOL _flies;                             // the next app to leave flies out …
    AtelierSwipe _flyWay;                    // … this way
    UIButton *_grabber, *_grabber2;
    UIControl *_plus;
    UIView *_divider;
    AtelierMenu *_menu;
    NSTimer *_watch;
    CFAbsoluteTime _lastTouch, _busyUntil;
    NSString *_frontAtOpen;
    double _split;
    BOOL _closing;
    CGPoint _bottomDown;                     // where a finger on the dock came down
    UIPanGestureRecognizer *_dockPan;
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
    UIViewAutoresizing fill = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // The backdrop: a blur of what was on the screen and a dim over it. Both follow -_show:.
    _blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _blur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _blur.frame = _root.bounds;
    _blur.autoresizingMask = fill;
    _blur.userInteractionEnabled = NO;
    [_root addSubview:_blur];
    _dim = [[UIView alloc] initWithFrame:_root.bounds];
    _dim.autoresizingMask = fill;
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];
    _dim.alpha = 0;
    [_root addSubview:_dim];
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backdropTapped)]];

    // Under everything else: the strip a swipe up closes the bench from. The dock's switches lie
    // over it and take their own touches.
    _closeStrip = [[AtelierCloseStrip alloc] initWithFrame:CGRectZero];
    [_root addSubview:_closeStrip];

    // What moves as one when the bench comes and goes.
    _content = [[AtelierPassView alloc] initWithFrame:_root.bounds];
    _content.autoresizingMask = fill;
    [_root addSubview:_content];

    _stage = [[AtelierPassView alloc] initWithFrame:_content.bounds];
    _stage.autoresizingMask = fill;
    [_content addSubview:_stage];

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
    cross.autoresizingMask = fill;
    cross.userInteractionEnabled = NO;
    [_plus addSubview:cross];
    [_plus addTarget:self action:@selector(_plusTapped) forControlEvents:UIControlEventTouchUpInside];
    _plus.hidden = YES;
    [_content addSubview:_plus];

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
        [_content insertSubview:o belowSubview:_stage];
        [_outlines addObject:o];
    }

    _band = [[AtelierBand alloc] initWithFrame:CGRectZero];
    _band.alpha = 0;
    _band.onShortcut = ^(NSString *bid) { [weak openShortcut:bid]; };
    _band.onShortcutHeld = ^(NSString *bid, CGRect frame) { [weak _showShortcutMenu:bid frame:frame]; };
    _band.onAddShortcut = ^{ [weak _addShortcut]; };
    [_content addSubview:_band];

    _dock = [[AtelierDock alloc] initWithFrame:CGRectZero];
    _dock.alpha = 0;
    // a swipe up that starts on one of the switches carries the bench away too (and does not flip the switch)
    UIPanGestureRecognizer *dockUp = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_dockSwiped:)];
    dockUp.maximumNumberOfTouches = 1;
    dockUp.delegate = self;
    [_dock addGestureRecognizer:dockUp];
    _dockPan = dockUp;
    [_content addSubview:_dock];

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
    [_content addSubview:_grabber];
    [_content addSubview:_grabber2];

    _divider = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 88)];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.tag = 7;
    bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
    bar.layer.cornerRadius = 2.5;
    bar.userInteractionEnabled = NO;
    [_divider addSubview:bar];
    [_divider addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_dividerDragged:)]];
    _divider.hidden = YES;
    [_content addSubview:_divider];
    [_content addSubview:_swipePill];
}

// (The dock's swipe is the only recogniser with this delegate.)
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return g.view != other.view;
}

// Where the finger came down is noted here: by the time a pan begins it has already travelled
// ten points or so, and its own figure for how far it has gone leaves those out.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    if (g == _dockPan) _bottomDown = [touch locationInView:nil];
    return YES;
}

#pragma mark coming and going

// The blur at `q` of its full strength. A blur view is not to be faded with its alpha; it is
// scrubbed with a paused animator from "no effect" to the effect. The animator is made anew for
// every time the bench comes up and stopped when it has gone (one that is still paused when it
// is let go of makes UIKit throw). `set blurScrub 0` is the plain way, should this misbehave.
- (void)_blurTo:(CGFloat)q {
    q = MAX(0, MIN(1, q));
    if ([[AtelierSettings shared] tune:@"blurScrub" fallback:1] < 1) {
        [self _endBlurScrub];
        if (_blur.effect != _blurEffect) _blur.effect = _blurEffect;
        _blur.alpha = q;
        return;
    }
    if (!_blurScrub) {
        UIVisualEffectView *blur = _blur;
        UIBlurEffect *effect = _blurEffect;
        blur.alpha = 1;
        blur.effect = nil;
        _blurScrub = [[UIViewPropertyAnimator alloc] initWithDuration:1.0 curve:UIViewAnimationCurveLinear animations:^{ blur.effect = effect; }];
        _blurScrub.pausesOnCompletion = YES;
        [_blurScrub pauseAnimation];
    }
    _blurScrub.fractionComplete = q;
}

- (void)_endBlurScrub {
    if (!_blurScrub) return;
    @try { [_blurScrub stopAnimation:YES]; } @catch (__unused id e) {}
    _blurScrub = nil;
}

// How far in the bench is: 0 gone, 1 fully there. Everything about that is here, and nothing is
// laid out: the backdrop fades and one container is moved and scaled.
- (void)_show:(CGFloat)p {
    p = MAX(-0.05, MIN(1.05, p));                        // the spring may go a hair past either end
    _progress = p;
    CGFloat q = MAX(0, MIN(1, p)), away = 1 - p;
    [self _blurTo:q];
    _dim.alpha = q;
    CGSize screen = [AtelierHost screenSize];
    CGFloat tx = 0, ty = 0, scale = 1, fade = q;
    switch (_motion) {
        case AtelierMotionFromRight: tx = away * screen.width * 0.36;  scale = 1 - 0.08 * away; fade = MIN(1, q * 2.2); break;
        case AtelierMotionFromLeft:  tx = -away * screen.width * 0.36; scale = 1 - 0.08 * away; fade = MIN(1, q * 2.2); break;
        case AtelierMotionLift:      ty = -away * screen.height * 0.07; scale = 1 - 0.14 * away; fade = MIN(1, q * 1.5); break;
        default:                     scale = 1 - 0.07 * away; break;
    }
    _content.alpha = fade;
    _content.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(tx, ty), scale, scale);
}

// From where it is to `target` (0 or 1) on a spring, starting at `speed` (progress per second,
// towards the target) and with `damping` (1 = no bounce). A quarter of a second, never more
// than 0.4 s. `then` runs when it is there.
- (void)_settleTo:(CGFloat)target speed:(CGFloat)speed damping:(CGFloat)damping then:(void (^)(void))then {
    [_settle invalidate];
    _settleTo = target;
    _settleSpeed = (target >= _progress ? 1 : -1) * MIN(12.0, MAX(0, speed));
    _settleDamping = damping;
    _settleThen = [then copy];
    _settleBegan = _settleLast = CACurrentMediaTime();
    _settle = [CADisplayLink displayLinkWithTarget:self selector:@selector(_settleStep:)];
    if (@available(iOS 15.0, *)) _settle.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [_settle addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)_settleStep:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = MAX(0.001, MIN(1.0 / 30.0, now - _settleLast));
    _settleLast = now;
    const CGFloat stiffness = 26.0;                      // rad/s
    CGFloat x = _progress - _settleTo;
    for (int i = 0; i < 2; i++) {                        // two half steps: a long frame cannot make it jump
        CGFloat h = dt / 2.0;
        CGFloat pull = -2.0 * _settleDamping * stiffness * _settleSpeed - stiffness * stiffness * x;
        _settleSpeed += pull * h;
        x += _settleSpeed * h;
    }
    BOOL there = (fabs(x) < 0.004 && fabs(_settleSpeed) < 0.1) || now - _settleBegan > 0.40;
    [self _show:(there ? _settleTo : _settleTo + x)];
    if (there) [self _settled];
}

- (void)_settled {
    [_settle invalidate];
    _settle = nil;
    void (^then)(void) = _settleThen;
    _settleThen = nil;
    if (then) then();
}

// Whatever was settling is there this instant (its `then` runs now).
- (void)_settleNow {
    if (!_settle) return;
    [self _show:_settleTo];
    [self _settled];
}

- (BOOL)dragging { return _dragOwner != nil; }
- (CGFloat)progress { return _progress; }

- (BOOL)beginDragOpening:(BOOL)opening motion:(AtelierMotion)motion owner:(id)owner {
    if (!owner) return NO;
    // one hand at a time; only SpringBoard's own Home gesture takes over from another
    id holder = _dragOwner;
    if (holder && holder != owner && ![owner isKindOfClass:AtelierHome.class]) return NO;
    if (opening) {
        if (_closing) [self _settleNow];                 // still on its way out from the last time: it is out now
        if (_visible) return NO;
        if (![self _presentApps:[self _appsToOpen] layout:[[AtelierSettings shared] layout] motion:motion byHand:YES]) return NO;
    } else {
        if (!_visible || _closing) return NO;
        [_settle invalidate];                            // if it was still settling in, the finger has it now
        _settle = nil;
        _settleThen = nil;
        if (_progress > 0.995) _motion = motion;         // fully in, every motion looks the same: no jump
        [self hideMenu];
    }
    _dragOpening = opening;
    _dragOwner = owner;
    return YES;
}

- (void)dragTo:(CGFloat)progress owner:(id)owner {
    if (!owner || owner != _dragOwner || !_visible || _closing) return;
    [self _show:MAX(0, MIN(1, progress))];
}

- (void)endDrag:(BOOL)complete velocity:(CGFloat)velocity reason:(NSString *)why owner:(id)owner {
    if (!owner || owner != _dragOwner) return;
    _dragOwner = nil;
    if (!_visible || _closing) return;
    BOOL stays = _dragOpening ? complete : !complete;
    if (stays) {
        if (_dragOpening) AtelierHapticPlay(AtelierHapticOpen);
        [self _settleTo:1 speed:(_dragOpening ? velocity : 0) damping:0.82 then:nil];
    } else {
        [self _closeAnimated:YES reason:why motion:_motion speed:(_dragOpening ? 0 : velocity) keeping:nil then:nil];
    }
}

// "Go home" happened somewhere in SpringBoard: the bench goes, as an app would.
- (void)homeAction:(NSString *)what {
    if (!_visible || _closing) return;
    [self _closeAnimated:YES reason:what motion:AtelierMotionLift speed:0 keeping:nil then:nil];
}

// The room between the tiles and one side of the screen: the edge strip is no wider while the bench is up.
- (CGFloat)marginOnRight:(BOOL)right {
    CGSize screen = [AtelierHost screenSize];
    CGFloat margin = 44;
    CGRect rects[8] = { _geometry.main, _geometry.second, _geometry.plus,
                        _geometry.minis[0], _geometry.minis[1], _geometry.minis[2], _geometry.minis[3], _geometry.minis[4] };
    for (int i = 0; i < 8; i++) {
        if (CGRectIsEmpty(rects[i])) continue;
        margin = MIN(margin, right ? screen.width - CGRectGetMaxX(rects[i]) : rects[i].origin.x);
    }
    return MAX(0, margin);
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

// A full bench that must take one more app lets go of a social app, and of nothing else (the
// user's rule: "close the oldest open social media app only"). Among the social apps that aren't
// locked it is the one that was the main app longest ago; the main app itself only when there is
// no other; with nothing to tell them apart, the last in the row. NO when Settings has this
// switched off or no such app is on the bench: then nothing is removed.
- (BOOL)_makeRoomIn:(NSMutableArray<NSString *> *)apps for:(NSString *)bid {
    if (apps.count < ATELIER_MAX_SLOTS) return YES;
    if (![AtelierSettings shared].makeRoom) return NO;
    NSUInteger pick = NSNotFound;
    CFAbsoluteTime oldest = 0;
    for (NSUInteger i = 0; i < apps.count; i++) {
        NSString *other = apps[i];
        if ([other isEqualToString:bid] || [self isLocked:other] || ![AtelierHost isSocialApp:other]) continue;
        CFAbsoluteTime used = AtelierUsedAt(other);
        if (i == 0 && _visible) used = CFAbsoluteTimeGetCurrent();               // the main app is in use right now
        if (pick == NSNotFound || used <= oldest) { pick = i; oldest = used; }
    }
    if (pick == NSNotFound) return NO;
    NSString *gone = apps[pick];
    AtelierLog(@"room: %@ leaves the full bench for %@ (the social app used longest ago)", gone, bid);
    [AtelierHost toast:[NSString stringWithFormat:@"Closed %@ to make room.", [AtelierHost displayNameForBundleID:gone]]];
    [apps removeObjectAtIndex:pick];
    return YES;
}

// `bid` first, the rest after it. A bench that is full makes room the one way it may (see above);
// nil when it cannot, and then there is no room.
- (NSArray<NSString *> *)_list:(NSArray<NSString *> *)list withFirst:(NSString *)bid {
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithArray:list ?: @[]];
    if (bid.length) {
        [out removeObject:bid];
        while (out.count >= ATELIER_MAX_SLOTS) if (![self _makeRoomIn:out for:bid]) return nil;
        [out insertObject:bid atIndex:0];
    }
    return out;
}

// What the bench opens with: what was on it last time, and the app in front first.
- (NSArray<NSString *> *)_appsToOpen {
    AtelierSettings *s = [AtelierSettings shared];
    [AtelierHost reloadHiddenApps];
    [self _loadLocks];
    NSArray<NSString *> *apps = [s slots];
    NSString *front = [AtelierHost frontmostBundleID];
    if (front && s.addFront) apps = [self _list:apps withFirst:front] ?: apps;
    return apps;
}

- (void)open {
    [self openWithMotion:AtelierMotionZoom];
}

- (void)openWithMotion:(AtelierMotion)motion {
    if (_closing) [self _settleNow];
    if (_visible) return;
    [self _presentApps:[self _appsToOpen] layout:[[AtelierSettings shared] layout] motion:motion byHand:NO];
}

- (void)openWithApps:(NSArray<NSString *> *)bids layout:(NSInteger)layout {
    AtelierLayoutKind kind = (layout >= 0 && layout <= 2) ? (AtelierLayoutKind)layout : (_visible ? _layout : [[AtelierSettings shared] layout]);
    if (_closing) [self _settleNow];
    if (!_visible) { [self _presentApps:bids layout:kind motion:AtelierMotionZoom byHand:NO]; return; }
    _layout = kind;
    [self _setApps:[self _usable:bids] animated:YES];
    [self touched];
}

- (void)openAdding:(NSString *)bid {
    [AtelierHost reloadHiddenApps];
    if ([AtelierHost isHiddenApp:bid]) return;
    NSArray<NSString *> *base = _visible ? [self apps] : [[AtelierSettings shared] slots];
    NSArray<NSString *> *with = [self _list:base withFirst:bid];
    if (!with) [AtelierHost toast:@"The bench is full. Close an app to make room."];
    [self openWithApps:(with ?: base) layout:-1];
}

// A shortcut app from the band: it becomes the main app. A full bench makes room for it by
// closing a social app, if one is open; otherwise it says it is full.
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
        NSMutableArray<NSString *> *room = [apps mutableCopy];
        if (![self _makeRoomIn:room for:bid]) {
            AtelierLog(@"shortcut %@: the bench is full", bid);
            AtelierHapticPlay(AtelierHapticSwap);
            [AtelierHost toast:@"The bench is full. Close an app to make room."];
            return;
        }
        apps = room;
    }
    AtelierLog(@"shortcut %@: opened as the main app", bid);
    [self _setApps:[@[ bid ] arrayByAddingObjectsFromArray:apps] animated:YES];
    [self touched];
}

- (void)toggle {
    if (_visible) [self closeAnimated:YES reason:@"toggle"];
    else [self open];
}

// byHand: the bench comes up all the way out and waits for a finger (-dragTo:); otherwise it
// settles in by itself, at once.
- (BOOL)_presentApps:(NSArray<NSString *> *)bids layout:(AtelierLayoutKind)layout motion:(AtelierMotion)motion byHand:(BOOL)byHand {
    AtelierSettings *s = [AtelierSettings shared];
    if (!s.enabled) { AtelierLog(@"open: %@ is switched off", ATELIER_NAME); return NO; }
    if ([AtelierHost isLocked]) { AtelierLog(@"open: the phone is locked"); return NO; }
    if (_closing || _visible) return NO;
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
    _dragOwner = nil;
    _motion = motion;
    _lastTouch = CFAbsoluteTimeGetCurrent();
    [self _setApps:[self _usable:bids] animated:NO];
    _window.hidden = NO;                                 // on the screen first: the blur's scrub needs its layers there
    [self _show:0];
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
    [AtelierHome benchCameUp];                           // SpringBoard's Home gesture is watched from here to the close
    [[AtelierTrigger shared] refresh];
    AtelierLog(@"bench open%@: %@ · layout %ld · front %@ · level %.0f", byHand ? @" (following a finger)" : @"",
               [[self apps] componentsJoinedByString:@" "], (long)_layout, _frontAtOpen ?: @"home", _window.windowLevel);
    if (!byHand) {
        AtelierHapticPlay(AtelierHapticOpen);
        [self _settleTo:1 speed:0 damping:0.82 then:nil];
    }
    return YES;
}

- (void)closeAnimated:(BOOL)animated reason:(NSString *)why {
    [self _closeAnimated:animated reason:why motion:AtelierMotionZoom speed:0 keeping:nil then:nil];
}

- (void)closeAnimated:(BOOL)animated reason:(NSString *)why motion:(AtelierMotion)motion {
    [self _closeAnimated:animated reason:why motion:motion speed:0 keeping:nil then:nil];
}

// The bench goes: everything that runs is stopped at once, then it leaves from wherever it is
// (a finger may have carried it part of the way) and the apps are given back.
- (void)_closeAnimated:(BOOL)animated reason:(NSString *)why motion:(AtelierMotion)motion speed:(CGFloat)speed
               keeping:(NSString *)keep then:(void (^)(void))then {
    if (!_visible || _closing) { if (then) then(); return; }
    _closing = YES;
    _dragOwner = nil;
    _dockDragging = NO;
    AtelierLog(@"bench close (%@)", why ?: @"?");
    [self _persist];
    [_watch invalidate];
    _watch = nil;
    [_band stop];
    [[AtelierQuotes shared] stop];                       // nothing is fetched once the bench is on its way out
    [AtelierToggles benchWentAway];                      // Keep Awake ends here, whatever closed the bench
    [AtelierHome benchWentAway];
    AtelierHIDStop();
    [self hideMenu];
    [self _hideSwipePill];
    _swipeTile = nil;
    [AtelierSheets dismiss];
    [_settle invalidate];
    _settle = nil;
    _settleThen = nil;
    if (_progress > 0.995) _motion = motion;             // part-way out already: it goes on the way it was going
    void (^finish)(void) = ^{
        NSString *front = [AtelierHost frontmostBundleID];
        for (AtelierTile *l in [self->_leaving copy]) [self _gone:l];
        for (AtelierTile *t in self->_tiles) {
            NSString *bid = t.pane.bundleID;
            [t.pane detachKeepingForeground:([bid isEqualToString:front] || [bid isEqualToString:keep])];
            [t removeFromSuperview];
        }
        [self->_tiles removeAllObjects];
        [self _show:0];
        self->_window.hidden = YES;
        [self _endBlurScrub];
        self->_blur.effect = nil;
        self->_visible = NO;
        self->_closing = NO;
        self->_stripFloor = 0;
        [[AtelierTrigger shared] refresh];
        if (then) then();
    };
    if (!animated) { finish(); return; }
    [self _settleTo:0 speed:speed damping:1.0 then:finish];
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
    NSUInteger had = old.count;
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    for (NSString *bid in bids) {
        AtelierTile *tile = nil;
        for (AtelierTile *t in old) if ([t.pane.bundleID isEqualToString:bid]) { tile = t; break; }
        if (tile) {
            [old removeObject:tile];
        } else {
            // back before it had quite left: the old tile is gone this instant
            for (AtelierTile *l in [_leaving copy]) if ([l.pane.bundleID isEqualToString:bid]) [self _gone:l];
            tile = [[AtelierTile alloc] initWithPane:[AtelierPane paneWithBundleID:bid]];
            tile.shield.delegate = self;
            tile.alpha = 0;
            tile.liveSince = CFAbsoluteTimeGetCurrent();
            [fresh addObject:bid];
            [_stage addSubview:tile];
        }
        [next addObject:tile];
    }
    BOOL flies = _flies;
    AtelierSwipe way = _flyWay;
    _flies = NO;
    CGSize screen = [AtelierHost screenSize];
    for (AtelierTile *gone in old) {
        if (!animated || !_visible || _closing || gone.parked || gone.alpha < 0.05) { [self _gone:gone]; continue; }
        // It leaves the way it was swiped (or shrinks away), and lets go of its app when it is
        // out of sight: the picture stays whole while it flies.
        if (!_leaving) _leaving = [NSMutableArray array];
        [_leaving addObject:gone];
        gone.shield.delegate = nil;
        gone.userInteractionEnabled = NO;
        CGRect f = gone.frame;
        CGAffineTransform to = gone.transform;
        if (!flies) to = CGAffineTransformScale(to, 0.8, 0.8);
        else if (way == AtelierSwipeLeft) to = CGAffineTransformTranslate(to, -(CGRectGetMaxX(f) + 30), 0);
        else if (way == AtelierSwipeRight) to = CGAffineTransformTranslate(to, screen.width - f.origin.x + 30, 0);
        else if (way == AtelierSwipeUp) to = CGAffineTransformTranslate(to, 0, -(CGRectGetMaxY(f) + 30));
        else to = CGAffineTransformTranslate(to, 0, screen.height - f.origin.y + 30);
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState animations:^{
            gone.transform = to;
            gone.alpha = flies ? 0.35 : 0;
        } completion:^(BOOL done) { [self _gone:gone]; }];
    }
    _tiles = next;
    // one app added to a bench that was already there was put on it by hand, just now; a whole
    // bench coming up tells nothing about when its apps were last used
    if (had > 0 && fresh.count == 1) AtelierNoteUsed(fresh[0]);
    if (_tiles.count) AtelierNoteUsed(_tiles[0].pane.bundleID);
    [self _layoutAnimated:animated];
    if (_visible) [self _persist];
}

// A tile that has left the bench: its app is given back. (Safe to call twice.)
- (void)_gone:(AtelierTile *)tile {
    if (!tile.superview && ![_leaving containsObject:tile]) return;
    [_leaving removeObject:tile];
    [tile.pane detachKeepingForeground:[tile.pane.bundleID isEqualToString:[AtelierHost frontmostBundleID]]];
    [tile removeFromSuperview];
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
        self->_closeStrip.frame = g.closeStrip;
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
    BOOL bounce = _bounce;
    _bounce = NO;
    if (animated) {
        _busyUntil = now + 0.5;
        [UIView animateWithDuration:(bounce ? 0.34 : 0.32) delay:0 usingSpringWithDamping:(bounce ? 0.58 : 0.84) initialSpringVelocity:(bounce ? 0.8 : 0.3)
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
    AtelierNoteUsed(down.pane.bundleID);                 // in use until now
    AtelierNoteUsed(up.pane.bundleID);                   // in use from now
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
    _bounce = YES;                                       // it springs back into place with a short bounce
    [self _layoutAnimated:YES];                          // shows or hides the padlock, wakes it if it was a still
    if (lock) {                                          // and the padlock pops in
        t.lockBadge.transform = CGAffineTransformMakeScale(0.2, 0.2);
        [UIView animateWithDuration:0.30 delay:0.04 usingSpringWithDamping:0.5 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ t.lockBadge.transform = CGAffineTransformIdentity; } completion:nil];
    }
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
    [self _closeAnimated:YES reason:@"full screen" motion:AtelierMotionZoom speed:0 keeping:bid then:^{
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

// A tap: at once, the mini is the main.
- (void)shieldTapped:(AtelierShield *)shield {
    NSUInteger slot = [self _slotOfTileWithShield:shield];
    if (slot == NSNotFound) return;
    if (_menu) { [self hideMenu]; return; }
    AtelierTile *t = _tiles[slot];
    if (t.pane.state == AtelierPaneFailed || t.pane.state == AtelierPaneIdle) { t.restarts = 0; [t.pane attach]; }
    [self makeMain:slot];
}

// A hold: its menu. (The shield never calls this once a swipe has begun.)
- (void)shieldHeld:(AtelierShield *)shield {
    NSUInteger slot = [self _slotOfTileWithShield:shield];
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
        case AtelierSwipeLeft:
            _flies = YES;                                // it flies out the way it was swiped; the others close up
            _flyWay = AtelierSwipeLeft;
            [self closeSlot:slot];
            _flies = NO;
            break;
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

// A swipe on a mini (the shield calls from 8 points of movement on). The mini follows the finger
// one to one along the way the swipe set out, and its label goes with it. Letting go acts when
// the swipe is armed:
//
//   far enough   55% of the way from where the finger came down to the edge of the screen it is
//                heading for, never more than 40 points and never less than 14. (A mini in the
//                column lies against the left edge: a finger that comes down 30 points from it
//                can't travel 40.) A finger that has reached the edge counts as well. Past that
//                point the mini gives only half of what the finger does, so the point is felt.
//   or a flick   350 points a second or more along the swipe at the lift, after 10 points.
//
// Every swipe leaves one line in the log, armed or not: direction, travel, the travel it needed,
// the speed at the lift, the room, and why it did nothing if it did nothing.
- (void)shield:(AtelierShield *)shield swipe:(AtelierTouchPhase)phase track:(AtelierTrack *)track {
    NSUInteger slot = [self _slotOfTileWithShield:shield];
    if (slot == NSNotFound || slot == 0) return;
    AtelierTile *t = _tiles[slot];
    CGPoint d = track.travel, down = track.down, at = track.now;
    if (phase == AtelierTouchBegan) {
        [self hideMenu];
        _swipeTile = t;
        _swipeAxis = fabs(d.x) > fabs(d.y) ? 1 : 2;      // eight points in: the way it is going is plain
        _swipeArmed = NO;
        _lastTouch = CFAbsoluteTimeGetCurrent();
        [_stage bringSubviewToFront:t];
        return;
    }
    if (t != _swipeTile) return;
    static NSArray<NSString *> *names;
    if (!names) names = @[ @"left", @"right", @"up", @"down" ];
    CGFloat v = _swipeAxis == 1 ? d.x : d.y, mag = fabs(v), sign = v < 0 ? -1 : 1;
    AtelierSwipe swipe = _swipeAxis == 1 ? (v < 0 ? AtelierSwipeLeft : AtelierSwipeRight) : (v < 0 ? AtelierSwipeUp : AtelierSwipeDownward);
    BOOL allowed = NO;
    NSString *title = [self _swipeTitle:swipe tile:t allowed:&allowed];
    CGSize screen = [AtelierHost screenSize];
    // the room the finger had that way when it came down, and what is left of it now
    CGFloat room = swipe == AtelierSwipeLeft ? down.x : (swipe == AtelierSwipeRight ? screen.width - down.x
                 : (swipe == AtelierSwipeUp ? down.y : screen.height - down.y));
    CGFloat left = swipe == AtelierSwipeLeft ? at.x : (swipe == AtelierSwipeRight ? screen.width - at.x
                 : (swipe == AtelierSwipeUp ? at.y : screen.height - at.y));
    CGFloat threshold = MIN(40.0, MAX(14.0, 0.55 * room));
    BOOL far = mag >= threshold || (mag >= 10 && left <= 3);
    if (phase == AtelierTouchMoved) {
        // one to one up to the point where letting go acts, half as much past it; a refused swipe barely gives
        CGFloat shown = allowed ? (mag <= threshold ? mag : threshold + (mag - threshold) * 0.5) : MIN(18, mag * 0.22);
        shown *= sign;
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
    // lifted, or taken away
    CGPoint velocity = track.velocity;
    CGFloat speed = (_swipeAxis == 1 ? velocity.x : velocity.y) * sign;      // along the swipe; negative = going back
    BOOL ended = phase == AtelierTouchEnded;
    BOOL flick = mag >= 10 && speed >= 350;
    BOOL fire = ended && allowed && (far || flick);
    BOOL refused = ended && !allowed && title.length && (far || flick);
    NSString *numbers = [NSString stringWithFormat:@"travel %.0f pt (it needed %.0f), %.0f pt/s at the lift, room %.0f pt",
                         mag, threshold, speed, room];
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
               !ended ? @" (the touch was taken away)" : (refused ? @" (refused)" : (!allowed ? @" (nothing is set for that way)" : @" (too short, and no flick)")));
    if (refused) [self performSwipe:swipe onSlot:slot];                     // logs it and taps the finger
    [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ t.transform = CGAffineTransformIdentity; } completion:nil];
}

- (void)_grabberTapped:(UIButton *)b {
    if (_menu) { [self hideMenu]; return; }
    [self showMenuForSlot:(NSUInteger)b.tag];
}

- (void)backdropTapped {
    if (_menu) [self hideMenu];
}

// A finger that came down on one of the dock's switches and goes up: the bench goes with it, as
// from the strip under the dock (AtelierCloseStrip). 40 points, or a flick, and it is closed.
- (void)_dockSwiped:(UIPanGestureRecognizer *)g {
    CGPoint at = [g locationInView:nil];
    CGFloat up = _bottomDown.y - at.y, side = fabs(at.x - _bottomDown.x);
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _dockDragging = up > side && [self beginDragOpening:NO motion:AtelierMotionLift owner:g];
            if (_dockDragging) [self dragTo:1.0 - MIN(0.9, MAX(0, up) / 280.0) owner:g];
            break;
        case UIGestureRecognizerStateChanged:
            if (_dockDragging) [self dragTo:1.0 - MIN(0.9, MAX(0, up) / 280.0) owner:g];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!_dockDragging) break;
            _dockDragging = NO;
            CGFloat speed = -[g velocityInView:nil].y;
            BOOL ended = g.state == UIGestureRecognizerStateEnded;
            BOOL close = ended ? (up >= 40 || (up >= 12 && speed >= 350)) : up >= 10;
            AtelierLog(@"bottom swipe: began on a switch at %.0f,%.0f · %.0f pt up · %.0f pt/s at the lift · %@", _bottomDown.x, _bottomDown.y, up, speed,
                       close ? (ended ? @"closed" : @"closed: the system took the touch as it went up") : @"not closed: under 40 pt and no flick");
            [self endDrag:close velocity:MAX(0, speed) / 280.0 reason:@"swipe up from the bottom" owner:g];
            break;
        }
        default:
            break;
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
    [_content addSubview:menu];
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
    static NSArray<NSString *> *motions;
    if (!motions) motions = @[ @"zoom", @"from the right", @"from the left", @"lift" ];
    NSString *coming = [NSString stringWithFormat:@"%.2f in (%@)%@%@%@", _progress, motions[(NSUInteger)_motion % 4], _dragOwner ? @" HELD by " : @"",
                        _dragOwner ? NSStringFromClass([_dragOwner class]) : @"", _settle ? @" settling" : @""];
    return [NSString stringWithFormat:@"bench %@ %@ layout %ld split %.2f front-at-open %@ idle %.1fs menu [%@] %@ · %@ · %@ · %@ · hidden apps %lu",
            _visible ? (_closing ? @"closing" : @"up") : @"hidden", coming, (long)_layout, _split, _frontAtOpen ?: @"home",
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
    for (NSString *line in [[AtelierTrigger shared] debugWhere]) [lines addObject:line]; // the edge strip and its handle
    NSString *text = [lines componentsJoinedByString:@"\n"];
    [[text stringByAppendingString:@"\n"] writeToFile:[AtelierLogDir() stringByAppendingPathComponent:@"atelier_where.txt"]
                                          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return text;
}

- (void)debugMenuTap:(NSUInteger)index {
    [_menu runItem:index];
}

@end
