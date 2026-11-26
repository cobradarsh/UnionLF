// Touch and what is drawn: the recognizers on the app's windows, the menu, the progress pill,
// and the window of VidGrab's own that the last two live in.
#import "VidGrabUI.h"
#import <objc/runtime.h>

#pragma mark - the overlay window

@interface VGOverlayRoot : UIViewController
@end

@implementation VGOverlayRoot
- (void)loadView {
    UIView *view = [UIView new];
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}
// Never the reason the screen turns: only the way it is turned now.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientation now = self.view.window.windowScene.interfaceOrientation;
    return now == UIInterfaceOrientationUnknown ? UIInterfaceOrientationMaskAll : (UIInterfaceOrientationMask)(1 << now);
}
- (BOOL)shouldAutorotate { return YES; }
@end

@interface VGOverlayWindow : UIWindow
@end

@implementation VGOverlayWindow
// Only VidGrab's own things take touches; everything else goes to the app underneath.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    if (view == self || view == self.rootViewController.view) return nil;
    return view;
}
// The app keeps its status bar, and its key window unless a sheet of ours needs the keyboard.
- (BOOL)_canAffectStatusBarAppearance { return NO; }
- (BOOL)_canBecomeKeyWindow { return self.rootViewController.presentedViewController != nil; }
@end

static VGOverlayWindow *gOverlay;
static __weak UIWindow *gOverlaySource;
static UIView *gPillView;

static UIWindowScene *VGActiveScene(UIWindow *from) {
    if (from.windowScene) return from.windowScene;
    UIWindowScene *any = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        any = (UIWindowScene *)scene;
    }
    return any;
}

static VGOverlayWindow *VGOverlayFor(UIWindow *from) {
    UIWindowScene *scene = VGActiveScene(from);
    if (!scene) return nil;
    if (!gOverlay) {
        gOverlay = [[VGOverlayWindow alloc] initWithWindowScene:scene];
        gOverlay.windowLevel = UIWindowLevelAlert + 1;
        gOverlay.backgroundColor = UIColor.clearColor;
        gOverlay.rootViewController = [VGOverlayRoot new];
    } else if (gOverlay.windowScene != scene && !gOverlay.rootViewController.presentedViewController) {
        gOverlay.windowScene = scene;
    }
    gOverlay.frame = scene.coordinateSpace.bounds;
    if (from) gOverlaySource = from;
    gOverlay.hidden = NO;
    return gOverlay;
}

@implementation VGOverlay

+ (UIWindow *)window { return gOverlay; }
+ (UIViewController *)presented { return gOverlay.rootViewController.presentedViewController; }

/// iOS tells a share sheet's owner that it closed only when a person closes it. When VidGrab
/// closes one itself (another sheet comes, a test), it says so here, or the queue would wait on it.
static void VGClosedByVidGrab(UIViewController *controller) {
    if (![controller isKindOfClass:UIActivityViewController.class]) return;
    UIActivityViewControllerCompletionWithItemsHandler handler = ((UIActivityViewController *)controller).completionWithItemsHandler;
    if (handler) handler(nil, NO, nil, nil);
}

+ (void)present:(UIViewController *)controller from:(UIWindow *)window {
    VGOverlayWindow *overlay = VGOverlayFor(window);
    if (!overlay) return;
    UIViewController *root = overlay.rootViewController;
    void (^show)(void) = ^{ [root presentViewController:controller animated:YES completion:nil]; };
    UIViewController *old = root.presentedViewController;
    if (old) {
        [root dismissViewControllerAnimated:NO completion:^{
            VGClosedByVidGrab(old);
            show();
        }];
    } else {
        show();
    }
}

+ (void)dismissPresented:(void (^)(void))completion {
    UIViewController *root = gOverlay.rootViewController;
    UIViewController *old = root.presentedViewController;
    if (!old) {
        if (completion) completion();
        [self releaseIfIdle];
        return;
    }
    [root dismissViewControllerAnimated:YES completion:^{
        VGClosedByVidGrab(old);
        if (completion) completion();
        [VGOverlay releaseIfIdle];
    }];
}

/// With nothing left to show, the window goes away and the app's window is the key window again.
+ (void)releaseIfIdle {
    if (!gOverlay) return;
    if (gOverlay.rootViewController.presentedViewController || gPillView) return;
    BOOL wasKey = gOverlay.isKeyWindow;
    gOverlay.hidden = YES;
    UIWindow *source = gOverlaySource;
    if (wasKey && source && !source.isHidden) [source makeKeyWindow];
}

@end

#pragma mark - the menu

static VGMenu *gMenu;

@interface VGAlertController : UIAlertController
@property (nonatomic, copy) void (^onGone)(void);
@end

@implementation VGAlertController
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    void (^gone)(void) = self.onGone;
    self.onGone = nil;
    if (gone) gone();
}
@end

@implementation VGMenu {
    NSString *_title, *_message;
    NSMutableArray<NSString *> *_titles;
    NSMutableArray *_blocks;
    __weak VGAlertController *_alert;
}

+ (instancetype)menuWithTitle:(NSString *)title message:(NSString *)message {
    VGMenu *menu = [VGMenu new];
    menu->_title = [title copy];
    menu->_message = [message copy];
    menu->_titles = [NSMutableArray new];
    menu->_blocks = [NSMutableArray new];
    return menu;
}

+ (VGMenu *)current { return gMenu; }
- (NSArray<NSString *> *)titles { return [_titles copy]; }

- (void)add:(NSString *)title run:(void (^)(void))run {
    [_titles addObject:title];
    [_blocks addObject:[run copy]];
}

- (void)presentFrom:(UIWindow *)window anchor:(CGRect)anchor {
    VGAlertController *alert = [VGAlertController alertControllerWithTitle:_title message:_message
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < _titles.count; i++) {
        void (^run)(void) = _blocks[i];
        [alert addAction:[UIAlertAction actionWithTitle:_titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            gMenu = nil;
            run();
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { gMenu = nil; }]];
    alert.onGone = ^{
        // on the next turn: by then a choice has shown what it wants to show (a second menu, the share sheet)
        dispatch_async(dispatch_get_main_queue(), ^{ [VGOverlay releaseIfIdle]; });
    };
    UIWindow *overlay = VGOverlayFor(window);
    alert.popoverPresentationController.sourceView = overlay.rootViewController.view;
    alert.popoverPresentationController.sourceRect = CGRectIsNull(anchor) ? CGRectMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds), 1, 1) : anchor;
    _alert = alert;
    gMenu = self;
    [VGOverlay present:alert from:window];
}

- (BOOL)choose:(NSString *)titlePrefix {
    for (NSUInteger i = 0; i < _titles.count; i++) {
        if (![_titles[i] hasPrefix:titlePrefix]) continue;
        void (^run)(void) = _blocks[i];
        gMenu = nil;
        VGAlertController *alert = _alert;
        if (alert.presentingViewController) [alert.presentingViewController dismissViewControllerAnimated:NO completion:run];
        else run();
        return YES;
    }
    return NO;
}

@end

#pragma mark - the pill

@interface VGPillView : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UIView *track, *fill;
@property (nonatomic, strong) UIButton *close;
@property (nonatomic, copy) void (^onCancel)(void);
@property (nonatomic) double fraction;
@property (nonatomic) BOOL finished;
@property (nonatomic) NSInteger generation;
@end

@implementation VGPillView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 22;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        blur.frame = self.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blur.userInteractionEnabled = NO;
        [self addSubview:blur];

        _icon = [UIImageView new];
        _icon.tintColor = UIColor.whiteColor;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_icon];

        _label = [UILabel new];
        _label.textColor = UIColor.whiteColor;
        _label.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
        _label.numberOfLines = 3;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.85;
        [self addSubview:_label];

        _close = [UIButton buttonWithType:UIButtonTypeSystem];
        [_close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]]
                forState:UIControlStateNormal];
        _close.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
        _close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        _close.layer.cornerRadius = 13;
        _close.accessibilityLabel = @"Cancel download";
        [_close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_close];

        _track = [UIView new];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        _track.userInteractionEnabled = NO;
        [self addSubview:_track];
        _fill = [UIView new];
        _fill.backgroundColor = [UIColor colorWithRed:0.25 green:0.68 blue:1.0 alpha:1];
        [_track addSubview:_fill];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pillTapped)]];
        self.accessibilityIdentifier = @"VidGrabPill";
    }
    return self;
}

- (void)closeTapped {
    void (^cancel)(void) = self.onCancel;
    self.onCancel = nil;
    if (cancel) cancel();
    else [VGPill hide];
}

- (void)pillTapped {
    if (self.finished) [VGPill hide];
}

- (void)setSymbol:(NSString *)name tint:(UIColor *)tint {
    self.icon.image = [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    self.icon.tintColor = tint;
}

/// Sizes the pill for its text and places it under the status bar / Dynamic Island.
- (void)place {
    UIView *host = self.superview;
    if (!host) return;
    CGFloat width = MIN(host.bounds.size.width - 28, 330);
    BOOL closable = !self.close.isHidden;
    CGFloat textLeft = 44, textRight = closable ? 46 : 16;
    CGSize fit = [self.label sizeThatFits:CGSizeMake(width - textLeft - textRight, 200)];
    CGFloat height = MAX(44, ceil(fit.height) + 22);
    CGFloat top = MAX(host.safeAreaInsets.top, 20) + 6;
    self.frame = CGRectMake(round((host.bounds.size.width - width) / 2), top, width, height);
    self.layer.cornerRadius = MIN(22, height / 2);
    self.icon.frame = CGRectMake(15, (height - 20) / 2, 20, 20);
    self.label.frame = CGRectMake(textLeft, 0, width - textLeft - textRight, height - (self.track.isHidden ? 0 : 3));
    self.close.frame = CGRectMake(width - 36, (height - 26) / 2, 26, 26);
    self.track.frame = CGRectMake(0, height - 3, width, 3);
    self.fill.frame = CGRectMake(0, 0, width * MAX(0.0, MIN(1.0, self.fraction)), 3);
}

@end

static NSString *gPillLog = @"hidden";

@implementation VGPill

+ (VGPillView *)viewFrom:(UIWindow *)window {
    VGOverlayWindow *overlay = VGOverlayFor(window);
    if (!overlay) return nil;
    VGPillView *pill = (VGPillView *)gPillView;
    if (!pill) {
        pill = [[VGPillView alloc] initWithFrame:CGRectMake(0, 0, 300, 44)];
        pill.alpha = 0;
        gPillView = pill;
    }
    UIView *host = overlay.rootViewController.view;
    if (pill.superview != host) [host addSubview:pill];
    pill.generation++;
    return pill;
}

+ (void)appear:(VGPillView *)pill {
    [pill place];
    if (pill.alpha < 1) {
        pill.transform = CGAffineTransformMakeTranslation(0, -12);
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
            pill.alpha = 1;
            pill.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

+ (void)showProgress:(double)fraction text:(NSString *)text from:(UIWindow *)window onCancel:(void (^)(void))cancel {
    VGPillView *pill = [self viewFrom:window];
    if (!pill) return;
    pill.finished = NO;
    pill.onCancel = cancel;
    pill.close.hidden = NO;
    pill.track.hidden = NO;
    pill.fraction = fraction;
    pill.label.text = text;
    [pill setSymbol:@"arrow.down.circle.fill" tint:UIColor.whiteColor];
    gPillLog = [NSString stringWithFormat:@"progress %.2f \"%@\"", fraction, text];
    [self appear:pill];
}

+ (void)update:(double)fraction text:(NSString *)text {
    VGPillView *pill = (VGPillView *)gPillView;
    if (!pill || pill.finished) return;
    BOOL textChanged = ![pill.label.text isEqualToString:text];
    pill.fraction = MAX(pill.fraction, fraction);              // never backwards
    pill.label.text = text;
    gPillLog = [NSString stringWithFormat:@"progress %.2f \"%@\"", pill.fraction, text];
    if (textChanged) {
        [pill place];
    } else {
        [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveLinear animations:^{
            pill.fill.frame = CGRectMake(0, 0, pill.track.bounds.size.width * MAX(0.0, MIN(1.0, pill.fraction)), 3);
        } completion:nil];
    }
}

+ (void)finish:(NSString *)text symbol:(NSString *)symbol tint:(UIColor *)tint stay:(NSTimeInterval)stay from:(UIWindow *)window {
    VGPillView *pill = [self viewFrom:window];
    if (!pill) return;
    pill.finished = YES;
    pill.onCancel = nil;
    pill.close.hidden = YES;
    pill.track.hidden = YES;
    pill.label.text = text;
    [pill setSymbol:symbol tint:tint];
    [self appear:pill];
    NSInteger generation = pill.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VGPillView *still = (VGPillView *)gPillView;
        if (still && still.generation == generation) [VGPill hide];       // not if something newer is showing
    });
}

+ (void)succeed:(NSString *)text {
    gPillLog = [NSString stringWithFormat:@"success \"%@\"", text];
    [self finish:text symbol:@"checkmark.circle.fill" tint:[UIColor colorWithRed:0.30 green:0.85 blue:0.45 alpha:1] stay:2.2 from:nil];
    if ([VGPrefs haptic]) [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

+ (void)fail:(NSString *)text {
    gPillLog = [NSString stringWithFormat:@"failure \"%@\"", text];
    [self finish:text symbol:@"exclamationmark.triangle.fill" tint:[UIColor colorWithRed:1.0 green:0.62 blue:0.25 alpha:1] stay:5.0 from:nil];
    if ([VGPrefs haptic]) [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError];
}

+ (void)note:(NSString *)text from:(UIWindow *)window {
    gPillLog = [NSString stringWithFormat:@"note \"%@\"", text];
    [self finish:text symbol:@"info.circle.fill" tint:UIColor.whiteColor stay:2.6 from:window];
}

+ (void)hide {
    VGPillView *pill = (VGPillView *)gPillView;
    if (!pill) return;
    gPillView = nil;
    gPillLog = @"hidden";
    [UIView animateWithDuration:0.2 animations:^{
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeTranslation(0, -12);
    } completion:^(BOOL finished) {
        [pill removeFromSuperview];
        [VGOverlay releaseIfIdle];
    }];
}

+ (NSString *)stateForLog { return gPillLog; }

@end

#pragma mark - what a hold or a tap does

static void VGShowQualities(VGSource *source, VGDelivery delivery, UIWindow *window, CGRect anchor) {
    VGJob *probe = [[VGJob alloc] initWithSource:source];
    [VGPill note:@"Reading the qualities…" from:window];
    [probe loadVariants:^(NSArray<VGVariant *> *variants, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VGPill hide];
            if (variants.count < 2) {
                if (error) {
                    [VGPill fail:error.localizedDescription];
                } else {
                    [VGPill note:@"This video comes in one quality only." from:window];
                    VGStartDownload(source, delivery, variants.firstObject, window);
                }
                return;
            }
            VGMenu *menu = [VGMenu menuWithTitle:@"Quality" message:nil];
            NSMutableSet<NSString *> *listed = [NSMutableSet new];
            for (VGVariant *variant in variants) {
                if (!variant.decodable || [listed containsObject:variant.title]) continue;
                [listed addObject:variant.title];
                [menu add:variant.title run:^{ VGStartDownload(source, delivery, variant, window); }];
                if (menu.titles.count >= 9) break;
            }
            [menu presentFrom:window anchor:anchor];
        });
    }];
}

static BOOL VGStashInstalled(void) {
    // SpringBoard keeps a copy of GIF Stash's library where apps can see it; its note tells that the app is there
    NSString *info = [VGRoot() stringByAppendingPathComponent:@"var/mobile/Library/GifStash/mirror.info"];
    if (VGTestFolder()) return YES;
    return [NSFileManager.defaultManager fileExistsAtPath:info];
}

void VGTrigger(VGSource *source, UIWindow *window, CGRect anchor) {
    VGTriggerAction(source, window, anchor, [VGPrefs action]);
}

void VGTriggerAction(VGSource *source, UIWindow *window, CGRect anchor, NSInteger action) {
    if (!source) return;
    if ([VGPrefs haptic]) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    VGLog(@"trigger: %@ in %@ (action %ld)", source.shortName, NSStringFromClass(window.class), (long)action);
    if (action == 1) { VGStartDownload(source, VGDeliverPhotos, nil, window); return; }
    if (action == 2) { VGStartDownload(source, VGDeliverShare, nil, window); return; }
    if (action == 3 && VGStashInstalled() && !source.isPicture) { VGStartDownload(source, VGDeliverStash, nil, window); return; }

    NSString *busy = VGDownloadRunning() || VGQueueCount()
        ? [NSString stringWithFormat:@"\n%@%lu waiting: a new one joins the queue", VGDownloadRunning() ? @"1 downloading, " : @"", (unsigned long)VGQueueCount()]
        : @"";
    VGMenu *menu = [VGMenu menuWithTitle:@"VidGrab" message:[source.shortName stringByAppendingString:busy]];
    [menu add:@"Save to Photos" run:^{ VGStartDownload(source, VGDeliverPhotos, nil, window); }];
    [menu add:@"Share…" run:^{ VGStartDownload(source, VGDeliverShare, nil, window); }];
    if (source.isPicture) {
        UIImage *picture = source.picture;
        [menu add:@"Copy Picture" run:^{
            UIPasteboard.generalPasteboard.image = picture;
            [VGPill note:@"Picture copied" from:window];
        }];
    }
    if (VGStashInstalled() && !source.isPicture) [menu add:@"Save to GIF Stash" run:^{ VGStartDownload(source, VGDeliverStash, nil, window); }];
    if (source.looksLikeHLS) [menu add:@"Choose Quality…" run:^{ VGShowQualities(source, VGDeliverPhotos, window, anchor); }];
    if (source.url && !source.url.isFileURL) {
        [menu add:@"Copy Link" run:^{
            UIPasteboard.generalPasteboard.URL = source.url;
            [VGPill note:@"Link copied" from:window];
        }];
    }
    if (VGQueueCount()) {
        [menu add:[NSString stringWithFormat:@"Clear Queue (%lu)", (unsigned long)VGQueueCount()] run:^{
            NSUInteger cleared = VGClearQueue();
            [VGPill note:[NSString stringWithFormat:@"%lu waiting download%@ removed", (unsigned long)cleared, cleared == 1 ? @"" : @"s"] from:window];
        }];
    }
    [menu presentFrom:window anchor:anchor];
}

#pragma mark - recognizers

@interface VGHoldRecognizer : UILongPressGestureRecognizer
@property (nonatomic, weak) AVPlayerLayer *target;
@property (nonatomic, weak) CALayer *button;                   // held on a download button: the menu
@end

static CFTimeInterval gButtonHeldAt;                          // a hold on a button: the tap that ends it is no tap
@implementation VGHoldRecognizer
@end

/// The tap on a download button. While it follows a touch, the app's own tap and hold recognizers
/// under the finger are switched off, so the tap is VidGrab's alone; they come back when it is over.
@interface VGBadgeTapRecognizer : UITapGestureRecognizer
@property (nonatomic, weak) CALayer *target;                  // a video's layer or a picture's
@property (nonatomic, strong) NSHashTable<UIGestureRecognizer *> *silenced;
- (void)restoreOthers;
@end

@implementation VGBadgeTapRecognizer
- (void)restoreOthers {
    for (UIGestureRecognizer *other in self.silenced) other.enabled = YES;
    self.silenced = nil;
}
- (void)reset {
    [super reset];
    [self restoreOthers];
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return YES; }
@end

/// Recognizers VidGrab never touches: scrolling and zooming, and everything iOS itself puts on
/// views (scroll views' helpers, the gate for system gestures at the screen's edges). What is
/// left are plain taps and holds and the recognizers an app has written itself.
static BOOL VGIsMovement(UIGestureRecognizer *recognizer) {
    if ([recognizer isKindOfClass:UIPanGestureRecognizer.class] || [recognizer isKindOfClass:UIPinchGestureRecognizer.class]
        || [recognizer isKindOfClass:UIRotationGestureRecognizer.class] || [recognizer isKindOfClass:UISwipeGestureRecognizer.class]) return YES;
    if ([recognizer isMemberOfClass:UITapGestureRecognizer.class] || [recognizer isMemberOfClass:UILongPressGestureRecognizer.class]) return NO;
    NSString *name = NSStringFromClass(recognizer.class);
    return [name hasPrefix:@"UI"] || [name hasPrefix:@"_UI"] || [name hasPrefix:@"_"];
}

/// The app's tap and hold recognizers on the views under a point (scrolling and zooming are left alone).
static NSArray<UIGestureRecognizer *> *VGAppRecognizersAt(UIWindow *window, CGPoint point) {
    NSMutableArray<UIGestureRecognizer *> *found = [NSMutableArray new];
    for (UIView *view = [window hitTest:point withEvent:nil]; view; view = view.superview) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            if ([recognizer isKindOfClass:VGHoldRecognizer.class] || [recognizer isKindOfClass:VGBadgeTapRecognizer.class]) continue;
            if (!recognizer.isEnabled || VGIsMovement(recognizer)) continue;
            [found addObject:recognizer];
        }
    }
    return found;
}

@interface VGGestureCenter : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSHashTable<UIGestureRecognizer *> *recognizers;
@end

static char kAttachedKey;

@implementation VGGestureCenter

+ (instancetype)shared {
    static VGGestureCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        center = [VGGestureCenter new];
        center.recognizers = [NSHashTable weakObjectsHashTable];
    });
    return center;
}

- (void)configure:(UIGestureRecognizer *)recognizer {
    BOOL on = [VGPrefs enabled];
    if ([recognizer isKindOfClass:VGHoldRecognizer.class]) {
        VGHoldRecognizer *hold = (VGHoldRecognizer *)recognizer;
        NSInteger fingers = [VGPrefs holdFingers];
        hold.enabled = on && fingers > 0;
        hold.numberOfTouchesRequired = MAX(1, fingers);
        hold.minimumPressDuration = [VGPrefs holdTime];
        hold.allowableMovement = 12;
        // taking the touch away from the view keeps the lift of the finger from counting as a tap there
        hold.cancelsTouchesInView = [VGPrefs blockAppHold];
        hold.delaysTouchesBegan = NO;
        hold.delaysTouchesEnded = NO;
    } else {
        recognizer.enabled = on && ([VGPrefs badge] || [VGPrefs pictures]);
        recognizer.cancelsTouchesInView = YES;
        recognizer.delaysTouchesBegan = YES;                 // only for touches that begin on a button (see shouldReceiveTouch)
    }
}

- (void)attachTo:(UIWindow *)window {
    if (!window || objc_getAssociatedObject(window, &kAttachedKey)) return;
    NSString *name = NSStringFromClass(window.class);
    if ([window isKindOfClass:VGOverlayWindow.class] || [name containsString:@"Keyboard"] || [name containsString:@"TextEffects"]
        || [name containsString:@"StatusBar"] || [name containsString:@"PiP"]) return;
    objc_setAssociatedObject(window, &kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VGHoldRecognizer *hold = [[VGHoldRecognizer alloc] initWithTarget:self action:@selector(held:)];
    VGBadgeTapRecognizer *tap = [[VGBadgeTapRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    for (UIGestureRecognizer *recognizer in @[hold, tap]) {
        recognizer.delegate = self;
        [self configure:recognizer];
        [window addGestureRecognizer:recognizer];
        [self.recognizers addObject:recognizer];
    }
}

- (void)attachToAllWindows {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) [self attachTo:window];
    }
}

- (void)settingsChanged {
    for (UIGestureRecognizer *recognizer in self.recognizers.allObjects) [self configure:recognizer];
}

#pragma mark delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    VGRefreshBadgesSoon();                                   // a touch is a good moment to look at the players again
    VGFollowScrolling();
    if (![recognizer isKindOfClass:VGBadgeTapRecognizer.class]) return YES;
    VGBadgeTapRecognizer *tap = (VGBadgeTapRecognizer *)recognizer;
    UIWindow *window = (UIWindow *)recognizer.view;
    if (![window isKindOfClass:UIWindow.class]) return NO;
    CGPoint point = [touch locationInView:window];
    CALayer *layer = VGBadgeLayerAtPoint(window, point);
    tap.target = layer;
    if (!layer) return NO;                                   // not on a button: this touch is none of ours
    // After this touch has been handed out, quieten the app's own tap and hold recognizers under it.
    __weak VGBadgeTapRecognizer *weakTap = tap;
    dispatch_async(dispatch_get_main_queue(), ^{
        VGBadgeTapRecognizer *strong = weakTap;
        if (!strong || strong.state != UIGestureRecognizerStatePossible || strong.numberOfTouches == 0) return;
        NSHashTable *silenced = [NSHashTable weakObjectsHashTable];
        for (UIGestureRecognizer *other in VGAppRecognizersAt(window, point)) {
            other.enabled = NO;
            [silenced addObject:other];
        }
        strong.silenced = silenced;
        // whatever happens to the tap, they are back within moments
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIGestureRecognizer *other in silenced) other.enabled = YES;
        });
    });
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    UIWindow *window = (UIWindow *)recognizer.view;
    if (![window isKindOfClass:UIWindow.class]) return NO;
    if ([recognizer isKindOfClass:VGHoldRecognizer.class]) {
        VGHoldRecognizer *hold = (VGHoldRecognizer *)recognizer;
        CGPoint point = [recognizer locationInView:window];
        hold.button = VGBadgeLayerAtPoint(window, point);   // on a button (a video's or a picture's): the menu
        hold.target = hold.button ? nil : VGPlayerLayerAtPoint(window, point);
        return hold.button != nil || hold.target != nil;     // a hold anywhere else is not VidGrab's business
    }
    return ((VGBadgeTapRecognizer *)recognizer).target != nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return [recognizer isKindOfClass:VGHoldRecognizer.class];
}

#pragma mark actions

- (void)held:(VGHoldRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIWindow *window = (UIWindow *)recognizer.view;
    CALayer *button = recognizer.button;
    if (button && [window isKindOfClass:UIWindow.class]) {
        VGSource *source = VGSourceForBadgeLayer(button);
        if (!source) return;
        gButtonHeldAt = CACurrentMediaTime();
        VGTriggerAction(source, window, VGBadgeFrameInWindow(button, window), 0);
        return;
    }
    AVPlayerLayer *layer = recognizer.target;
    CGPoint point = [recognizer locationInView:window];
    if (!layer || ![window isKindOfClass:UIWindow.class]) return;
    VGSource *source = VGSourceForPlayerLayer(layer);
    if (!source) return;
    if ([VGPrefs blockAppHold]) {
        // the app's own hold (speed-up, pause, preview) started alongside: end it
        NSArray<UIGestureRecognizer *> *others = VGAppRecognizersAt(window, point);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIGestureRecognizer *other in others) {
                if (!other.isEnabled) continue;
                other.enabled = NO;
                other.enabled = YES;
            }
        });
    }
    VGTrigger(source, window, CGRectMake(point.x, point.y, 1, 1));
}

- (void)tapped:(VGBadgeTapRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    UIWindow *window = (UIWindow *)recognizer.view;
    CALayer *layer = recognizer.target;
    if (!layer || ![window isKindOfClass:UIWindow.class]) return;
    if (CACurrentMediaTime() - gButtonHeldAt < 2.0) {                 // the finger lifting after a hold on the button
        gButtonHeldAt = 0;
        return;
    }
    VGSource *source = VGSourceForBadgeLayer(layer);
    if (!source) return;
    VGTriggerAction(source, window, VGBadgeFrameInWindow(layer, window), [VGPrefs tapAction]);
}

@end

void VGGesturesInstall(void) {
    VGGestureCenter *gestures = [VGGestureCenter shared];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIWindowDidBecomeVisibleNotification, UIWindowDidBecomeKeyNotification]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:UIWindow.class]) [gestures attachTo:note.object];
        }];
    }
    for (NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification, UISceneDidActivateNotification, UIApplicationDidBecomeActiveNotification]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [gestures attachToAllWindows];
            VGRefreshBadgesSoon();
        }];
    }
    [center addObserverForName:VGPrefsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [gestures settingsChanged];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ [gestures attachToAllWindows]; });
}

#pragma mark - for the tests

BOOL VGWindowIsWatched(UIWindow *window) {
    return window && objc_getAssociatedObject(window, &kAttachedKey) != nil;
}

NSArray<UIWindow *> *VGAppWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (objc_getAssociatedObject(window, &kAttachedKey) && !window.isHidden) [windows addObject:window];
        }
    }
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.isKeyWindow != b.isKeyWindow) return a.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : (a.windowLevel < b.windowLevel ? NSOrderedDescending : NSOrderedSame);
    }];
    return windows;
}

NSString *VGDescribeTouchAt(UIWindow *window, CGPoint point) {
    NSMutableArray<NSString *> *chain = [NSMutableArray new];
    for (UIView *view = [window hitTest:point withEvent:nil]; view && chain.count < 6; view = view.superview) {
        [chain addObject:NSStringFromClass(view.class)];
    }
    NSMutableArray<NSString *> *recognizers = [NSMutableArray new];
    for (UIGestureRecognizer *recognizer in VGAppRecognizersAt(window, point)) [recognizers addObject:NSStringFromClass(recognizer.class)];
    NSInteger ours = 0;
    for (UIGestureRecognizer *recognizer in window.gestureRecognizers) {
        if ([recognizer isKindOfClass:VGHoldRecognizer.class] || [recognizer isKindOfClass:VGBadgeTapRecognizer.class]) ours += recognizer.isEnabled ? 1 : 0;
    }
    return [NSString stringWithFormat:@"lands on %@; the app's tap/hold recognizers there: %@; VidGrab recognizers on the window: %ld",
            [chain componentsJoinedByString:@" < "], recognizers.count ? [recognizers componentsJoinedByString:@", "] : @"none", (long)ours];
}

/// What the tap recognizer would decide for a touch at this point, without a touch.
BOOL VGWouldTakeTapAt(UIWindow *window, CGPoint point) {
    return VGBadgeLayerAtPoint(window, point) != nil;
}
