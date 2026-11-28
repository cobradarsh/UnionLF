// The round button that floats over Photos.
//
//   nothing chosen   tap: the photo picker (up to 10 photos or videos)
//   items chosen     tap: Face ID, then Guest Mode. The button is blue and shows how many.
//   Guest Mode       tap: Face ID, then Photos is back to normal. The button is amber with a lock.
//
// A hold opens a small menu (choose again, clear, start, end). The button can be dragged; it
// settles on the nearer side of the screen and stays there.
//
// It lives in a window of its own, above everything Photos shows, that lets every touch outside
// the button fall through to Photos.
#import "GuestMode.h"
#import <PhotosUI/PhotosUI.h>

@interface GMPassWindow : UIWindow
@end

@implementation GMPassWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;     // not ours: through to Photos
    return hit;
}

- (BOOL)gm_busy {
    return self.rootViewController.presentedViewController != nil;
}

// UIKit asks these of every window (they are not public API): without them the window on top
// would take the status bar's look and the keyboard focus away from Photos.
- (BOOL)_canAffectStatusBarAppearance { return [self gm_busy]; }
- (BOOL)_canBecomeKeyWindow { return [self gm_busy]; }

@end

static UIWindow *GMPhotosWindow(UIWindow *notThis) {
    UIWindowScene *scene = notThis.windowScene ?: GMActiveScene();
    UIWindow *found = nil;
    for (UIWindow *window in scene.windows) {
        if (window == notThis || window.hidden || [window isKindOfClass:GMPassWindow.class]) continue;
        if (window.windowLevel > UIWindowLevelNormal + 1) continue;
        if (!found || window.isKeyWindow) found = window;
    }
    return found;
}

@interface GMButtonRootController : UIViewController
@property (nonatomic, copy) void (^onLayout)(void);
@end

@implementation GMButtonRootController

- (void)loadView {
    UIView *view = [UIView new];
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.onLayout) self.onLayout();
}

// Turn with Photos, never on our own account.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (GMGallery.shared.isUp) return UIInterfaceOrientationMaskAllButUpsideDown;
    UIViewController *root = GMPhotosWindow(self.viewIfLoaded.window).rootViewController;
    return root ? root.supportedInterfaceOrientations : UIInterfaceOrientationMaskAllButUpsideDown;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleDefault; }

@end

@interface GMButtonController () <PHPickerViewControllerDelegate>
@end

@implementation GMButtonController {
    GMPassWindow *_window;
    GMButtonRootController *_root;
    UIButton *_button;
    UIVisualEffectView *_blur;
    UIView *_tint;
    UIImageView *_icon;
    UILabel *_badge;
    UIVisualEffectView *_hint;
    UILabel *_hintLabel;
    __weak UIWindow *_keyBefore;
    BOOL _onRight;
    CGFloat _fraction;                                      // 0 = as high as it may go, 1 = as low
    BOOL _placed;                                           // a position was read from disk or set by a drag
    BOOL _dragging;
    BOOL _tucked;
    NSString *_iconName;
}

+ (instancetype)shared {
    static GMButtonController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [GMButtonController new]; });
    return shared;
}

#pragma mark - where the button sits

static NSString *GMButtonPath(void) {
    NSString *test = GMTestFolder();
    if (test) return [test stringByAppendingPathComponent:@"button.plist"];
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [[library stringByAppendingPathComponent:@"GuestMode"] stringByAppendingPathComponent:@"button.plist"];
}

- (void)loadPlace {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:GMButtonPath()];
    _onRight = YES;
    if ([saved[@"fraction"] respondsToSelector:@selector(doubleValue)]) {
        _fraction = MAX(0, MIN(1, [saved[@"fraction"] doubleValue]));
        _onRight = ![saved[@"left"] respondsToSelector:@selector(boolValue)] || ![saved[@"left"] boolValue];
        _placed = YES;
    }
}

- (void)savePlace {
    NSString *path = GMButtonPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"fraction": @(_fraction), @"left": @(!_onRight)} writeToFile:path atomically:YES];
}

// The stretch of the screen the button's top edge may be in.
- (void)range:(CGFloat *)low high:(CGFloat *)high {
    UIView *view = _root.view;
    UIEdgeInsets safe = view.safeAreaInsets;
    CGFloat size = GMButtonSize();
    *low = safe.top + 8;
    *high = MAX(*low, view.bounds.size.height - safe.bottom - size - 8);
}

- (void)place {
    if (!_button || _dragging) return;
    UIView *view = _root.view;
    UIEdgeInsets safe = view.safeAreaInsets;
    CGFloat size = GMButtonSize(), low, high;
    [self range:&low high:&high];
    CGFloat y;
    if (_placed) {
        y = low + (high - low) * _fraction;
    } else {
        y = MAX(low, view.bounds.size.height - safe.bottom - 49 - 18 - size);       // just above Photos' tab bar
    }
    CGFloat x = _onRight ? view.bounds.size.width - safe.right - 12 - size : safe.left + 12;
    _button.frame = CGRectMake(x, y, size, size);
    [self layoutButton];
}

- (void)layoutButton {
    CGFloat size = _button.bounds.size.width;
    _blur.frame = _button.bounds;
    _blur.layer.cornerRadius = size / 2;
    _tint.frame = _blur.bounds;
    _icon.frame = CGRectInset(_button.bounds, size * 0.2, size * 0.2);
    CGFloat b = MAX(18, size * 0.4);
    _badge.frame = CGRectMake(size - b * 0.78, -b * 0.22, b, b);
    _badge.layer.cornerRadius = b / 2;
    _badge.font = [UIFont systemFontOfSize:b * 0.6 weight:UIFontWeightBold];
    _button.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_button.bounds].CGPath;
    if (_hint && !_hint.hidden) [self layoutHint];
}

#pragma mark - making it

- (void)attach {
    if (!_window) {
        UIWindowScene *scene = GMActiveScene();
        if (!scene) return;
        [self loadPlace];
        _window = [[GMPassWindow alloc] initWithWindowScene:scene];
        _window.frame = scene.coordinateSpace.bounds;
        _window.windowLevel = UIWindowLevelStatusBar + 60;  // above the gallery (UIWindowLevelStatusBar + 50)
        _window.backgroundColor = UIColor.clearColor;
        _root = [GMButtonRootController new];
        __weak typeof(self) weak = self;
        _root.onLayout = ^{ [weak place]; };
        _window.rootViewController = _root;
        [self buildButton];
        _window.hidden = NO;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(refresh) name:GMStateChangedNotification object:nil];
        [center addObserver:self selector:@selector(settingsChanged) name:GMSettingsChangedNotification object:nil];
        GMLog(@"button: window up in scene %@, level %.0f", scene.session.persistentIdentifier, _window.windowLevel);
    }
    [self refresh];
}

- (void)buildButton {
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.accessibilityLabel = @"Guest Mode";
    _button.layer.shadowColor = UIColor.blackColor.CGColor;
    _button.layer.shadowOpacity = 0.35;
    _button.layer.shadowRadius = 6;
    _button.layer.shadowOffset = CGSizeMake(0, 2);

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    _blur.userInteractionEnabled = NO;
    _blur.clipsToBounds = YES;
    _blur.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    [_button addSubview:_blur];

    _tint = [UIView new];
    _tint.userInteractionEnabled = NO;
    [_blur.contentView addSubview:_tint];

    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _icon.tintColor = UIColor.whiteColor;
    _icon.userInteractionEnabled = NO;
    [_button addSubview:_icon];

    _badge = [UILabel new];
    _badge.textAlignment = NSTextAlignmentCenter;
    _badge.textColor = UIColor.whiteColor;
    _badge.backgroundColor = UIColor.systemRedColor;
    _badge.clipsToBounds = YES;
    _badge.userInteractionEnabled = NO;
    _badge.hidden = YES;
    [_button addSubview:_badge];

    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    [_button addGestureRecognizer:pan];
    __weak typeof(self) weak = self;
    _button.menu = [UIMenu menuWithTitle:@"" children:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion([weak menuActions]);
    }]]];
    _button.showsMenuAsPrimaryAction = NO;                  // a hold opens the menu, a tap is ours
    [_root.view addSubview:_button];
    [self place];
}

#pragma mark - look

- (void)settingsChanged {
    [self place];
    [self refresh];
}

- (void)refresh {
    if (!_window) return;
    GMState *state = GMState.shared;
    GMPhase phase = state.phase;
    // Switched off in Settings, the button is gone; Guest Mode that is on stays on until Face ID ends it.
    BOOL show = GMEnabled() || phase == GMPhaseGuest;
    _window.hidden = !show;
    if (!show) return;

    NSArray<NSString *> *names;
    UIColor *tint;
    CGFloat alpha = 1;
    NSString *badge = nil, *label;
    switch (phase) {
        case GMPhaseChosen:
            names = @[@"person.badge.shield.checkmark.fill", @"person.crop.circle.badge.checkmark", @"person.crop.circle.fill"];
            tint = [UIColor.systemBlueColor colorWithAlphaComponent:0.92];
            badge = [NSString stringWithFormat:@"%d", (int)state.identifiers.count];
            label = [NSString stringWithFormat:@"Guest Mode, %d chosen. Double tap to start.", (int)state.identifiers.count];
            break;
        case GMPhaseGuest:
            names = @[@"lock.fill"];
            tint = [UIColor.systemOrangeColor colorWithAlphaComponent:0.92];
            label = @"Guest Mode is on. Double tap to end it.";
            break;
        default:
            names = @[@"person.badge.shield.checkmark.fill", @"person.crop.circle.badge.checkmark", @"person.crop.circle.fill"];
            tint = UIColor.clearColor;
            alpha = GMButtonDim();
            label = @"Guest Mode. Double tap to choose photos.";
            break;
    }
    UIImage *image = GMSymbol(names, 22, UIImageSymbolWeightSemibold);
    _iconName = nil;
    for (NSString *name in names) {
        if ([UIImage systemImageNamed:name]) { _iconName = name; break; }
    }
    _icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _badge.text = badge;
    _badge.hidden = badge == nil;
    _button.accessibilityLabel = label;
    [UIView animateWithDuration:0.2 animations:^{
        self->_tint.backgroundColor = tint;
        self->_button.alpha = self->_tucked ? 0 : alpha;
    }];
    _button.userInteractionEnabled = !_tucked;
    if (phase == GMPhaseGuest) [self hideHint];
}

- (void)setTuckedAway:(BOOL)tucked {
    if (_tucked == tucked) return;
    _tucked = tucked;
    [self refresh];
}

#pragma mark - hint next to the button

- (void)layoutHint {
    CGSize text = [_hintLabel sizeThatFits:CGSizeMake(260, 100)];
    CGFloat w = text.width + 24, h = MAX(34, text.height + 14);
    CGRect b = _button.frame;
    CGFloat x = _onRight ? CGRectGetMinX(b) - 8 - w : CGRectGetMaxX(b) + 8;
    _hint.frame = CGRectMake(x, CGRectGetMidY(b) - h / 2, w, h);
    _hint.layer.cornerRadius = h / 2;
    _hintLabel.frame = CGRectMake(12, 0, w - 24, h);
}

- (void)showHint:(NSString *)text {
    if (!_hint) {
        _hint = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        _hint.clipsToBounds = YES;
        _hint.userInteractionEnabled = NO;
        _hintLabel = [UILabel new];
        _hintLabel.textColor = UIColor.whiteColor;
        _hintLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _hintLabel.numberOfLines = 2;
        [_hint.contentView addSubview:_hintLabel];
        [_root.view insertSubview:_hint belowSubview:_button];
    }
    _hintLabel.text = text;
    _hint.hidden = NO;
    [self layoutHint];
    _hint.alpha = 0;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideHint) object:nil];
    [UIView animateWithDuration:0.25 animations:^{ self->_hint.alpha = 1; }];
    [self performSelector:@selector(hideHint) withObject:nil afterDelay:4.0];
}

- (void)hideHint {
    if (!_hint || _hint.hidden) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideHint) object:nil];
    [UIView animateWithDuration:0.25 animations:^{ self->_hint.alpha = 0; } completion:^(BOOL finished) {
        if (self->_hint.alpha == 0) self->_hint.hidden = YES;
    }];
}

#pragma mark - touches

- (void)dragged:(UIPanGestureRecognizer *)pan {
    UIView *view = _root.view;
    if (pan.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
        [self hideHint];
    }
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint move = [pan translationInView:view];
        [pan setTranslation:CGPointZero inView:view];
        CGPoint center = _button.center;
        center.x += move.x;
        center.y += move.y;
        _button.center = center;
        return;
    }
    if (!_dragging) return;
    _dragging = NO;
    CGFloat low, high;
    [self range:&low high:&high];
    _onRight = _button.center.x > view.bounds.size.width / 2;
    CGFloat y = MAX(low, MIN(high, _button.frame.origin.y));
    _fraction = high > low ? (y - low) / (high - low) : 0;
    _placed = YES;
    [self savePlace];
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        [self place];
    } completion:nil];
}

- (void)tapped {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self buttonTapped];
}

- (void)buttonTapped {
    GMState *state = GMState.shared;
    switch (state.phase) {
        case GMPhaseIdle:
            [self presentPicker];
            break;
        case GMPhaseChosen:
            [self startGuest];
            break;
        case GMPhaseGuest:
            [self endGuest];
            break;
    }
}

- (void)startGuest {
    GMState *state = GMState.shared;
    if (state.phase != GMPhaseChosen) return;
    [self hideHint];
    NSInteger count = state.identifiers.count;
    NSString *reason = [NSString stringWithFormat:@"Start Guest Mode: only the %d chosen item%@ can be viewed in Photos.", (int)count, count == 1 ? @"" : @"s"];
    GMLog(@"button: start asked, checking the owner");
    GMAuthenticate(reason, ^(BOOL ok, NSString *detail) {
        GMLog(@"button: start → %@", detail);
        if (!ok || GMState.shared.phase != GMPhaseChosen) {
            GMLog(@"button: Guest Mode NOT started");
            return;
        }
        [GMState.shared enterGuest];
        [GMGallery.shared showAnimated:YES];
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    });
}

- (void)endGuest {
    if (GMState.shared.phase != GMPhaseGuest) return;
    GMLog(@"button: end asked, checking the owner");
    GMAuthenticate(@"End Guest Mode and show all of Photos again.", ^(BOOL ok, NSString *detail) {
        GMLog(@"button: end → %@", detail);
        if (!ok || GMState.shared.phase != GMPhaseGuest) {
            GMLog(@"button: Guest Mode stays ON");
            return;
        }
        [GMState.shared leaveGuest];
        [GMGallery.shared hideAnimated:YES];
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    });
}

#pragma mark - menu (a hold on the button)

- (NSArray<UIMenuElement *> *)menuActions {
    __weak typeof(self) weak = self;
    GMState *state = GMState.shared;
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray new];
    UIAction * (^item)(NSString *, NSArray<NSString *> *, void (^)(void)) = ^UIAction *(NSString *title, NSArray<NSString *> *symbols, void (^run)(void)) {
        return [UIAction actionWithTitle:title image:GMSymbol(symbols, 17, UIImageSymbolWeightRegular) identifier:nil handler:^(UIAction *action) { run(); }];
    };
    switch (state.phase) {
        case GMPhaseIdle:
            [items addObject:item(@"Choose Photos and Videos", @[@"photo.on.rectangle.angled"], ^{ [weak presentPicker]; })];
            break;
        case GMPhaseChosen: {
            [items addObject:item(@"Start Guest Mode", @[@"faceid", @"lock.fill"], ^{ [weak startGuest]; })];
            [items addObject:item(@"Change Selection", @[@"photo.on.rectangle.angled"], ^{ [weak presentPicker]; })];
            UIAction *clear = item(@"Clear Selection", @[@"xmark.circle"], ^{ [GMState.shared choose:@[]]; });
            clear.attributes = UIMenuElementAttributesDestructive;
            [items addObject:clear];
            break;
        }
        case GMPhaseGuest:
            [items addObject:item(@"End Guest Mode", @[@"lock.open.fill"], ^{ [weak endGuest]; })];
            break;
    }
    return items;
}

- (void)presentMenu {                                       // tests: what the menu holds right now
    NSMutableArray<NSString *> *titles = [NSMutableArray new];
    for (UIMenuElement *element in [self menuActions]) [titles addObject:element.title];
    GMLog(@"menu: %@", [titles componentsJoinedByString:@" | "]);
}

#pragma mark - picker

- (void)presentPicker {
    if (!_window || GMState.shared.phase == GMPhaseGuest || _root.presentedViewController) return;
    [self hideHint];
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];
    config.selectionLimit = GM_MAX_ITEMS;
    config.selection = PHPickerConfigurationSelectionOrdered;
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    if (GMState.shared.identifiers.count) config.preselectedAssetIdentifiers = GMState.shared.identifiers;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    _keyBefore = GMPhotosWindow(_window);
    [_root presentViewController:picker animated:YES completion:nil];
    [_window makeKeyWindow];                                // the picker's search field needs the keyboard
    GMLog(@"picker: shown (limit %d, %d already chosen)", GM_MAX_ITEMS, (int)GMState.shared.identifiers.count);
}

- (void)giveKeyBack {
    UIWindow *before = _keyBefore ?: GMPhotosWindow(_window);
    if (_window.isKeyWindow && before && !GMGallery.shared.isUp) [before makeKeyWindow];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSMutableArray<NSString *> *chosen = [NSMutableArray new];
    for (PHPickerResult *result in results) {
        if (result.assetIdentifier.length) [chosen addObject:result.assetIdentifier];
    }
    GMLog(@"picker: finished with %d result(s), %d with an identifier", (int)results.count, (int)chosen.count);
    [picker dismissViewControllerAnimated:YES completion:^{ [self giveKeyBack]; }];
    if (!chosen.count) return;                              // Cancel: what was chosen before stays
    [GMState.shared choose:chosen];
    NSInteger count = GMState.shared.identifiers.count;
    [self showHint:[NSString stringWithFormat:@"%d chosen · tap to start Guest Mode", (int)count]];
}

- (void)dismissPresented {
    if (_root.presentedViewController) {
        [_root dismissViewControllerAnimated:NO completion:^{ [self giveKeyBack]; }];
    }
    [_button.contextMenuInteraction dismissMenu];
}

#pragma mark - tests

- (NSString *)describe {
    if (!_window) return @"button: no window yet";
    return [NSString stringWithFormat:@"button: window %@ level %.0f key %d, frame %@, alpha %.2f, icon %@, badge %@, tucked %d, hint %@, presented %@",
            _window.hidden ? @"HIDDEN" : @"shown", _window.windowLevel, _window.isKeyWindow, NSStringFromCGRect(_button.frame), _button.alpha,
            _iconName ?: @"(none)", _badge.hidden ? @"-" : _badge.text, _tucked,
            (_hint && !_hint.hidden) ? _hintLabel.text : @"-",
            _root.presentedViewController ? NSStringFromClass(_root.presentedViewController.class) : @"-"];
}

@end
