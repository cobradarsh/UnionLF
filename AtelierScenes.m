/*  AtelierScenes.m — one hosted app (AtelierPane) and the FrontBoard calls behind it.

    How an app gets onto the bench, step by step. Every name was looked for in the iOS 16.5
    (20F66) shared cache of the phone and exercised in the iOS 16.4 simulator's SpringBoard; the
    README lists them.

      1. The app's scene.   SpringBoard keeps one FBScene per running app, named
                            "sceneID:<bundle id>-default". +[FBSceneManager sharedInstance]
                            -sceneWithIdentifier: finds it; if the name is different on some
                            build, every scene is looked at and matched by its client's bundle id.
      2. No scene.          The app isn't running: -[SpringBoard launchApplicationWithIdentifier:
                            suspended:YES] starts it in the background, the way a notification
                            would, and SpringBoard makes the scene. The pane looks for it a few
                            times a second for up to eight seconds.
      3. The picture.       -[FBScene uiPresentationManager] -createPresenterWithIdentifier:…
                            gives a presenter; activated, its -presentationView is a view that
                            shows the app's layers. This is the mechanism SpringBoard itself uses
                            for the app in front, so touches inside the view go straight to the app.
      4. Live or not.       -[FBScene updateSettingsWithBlock:] with setForeground:YES makes the
                            app run as a foreground app; NO lets iOS suspend it again. The
                            picture stays where it is either way.

    A pane's view always has the size of the app's scene (the whole screen, unless the beta
    resize is on); the bench scales and places it.                                            */

#import "Atelier.h"

static NSInteger gPresenterSerial;

#pragma mark - scenes

static id AtelierSceneManager(void) {
    return AtelierMsg(NSClassFromString(@"FBSceneManager"), @"sharedInstance");
}

static NSArray *AtelierAllScenes(void) {
    id mgr = AtelierSceneManager();
    id all = AtelierMsg(mgr, @"allScenes");
    if ([all isKindOfClass:NSSet.class]) return [(NSSet *)all allObjects];
    if ([all isKindOfClass:NSArray.class]) return all;
    NSMutableArray *out = [NSMutableArray array];
    SEL en = NSSelectorFromString(@"enumerateScenesWithBlock:");
    if (AtelierShape(mgr, en, "v", 1)) {
        void (^block)(id, BOOL *) = ^(id scene, BOOL *stop) { if (scene) [out addObject:scene]; };
        @try { ((void (*)(id, SEL, id))objc_msgSend)(mgr, en, block); } @catch (__unused id e) {}
    }
    return out;
}

static NSString *AtelierSceneIdentifier(id scene) {
    NSString *ident = AtelierMsg(scene, @"identifier");
    return [ident isKindOfClass:NSString.class] ? ident : @"";
}

static NSString *AtelierSceneBundle(id scene) {
    NSString *bid = AtelierMsg(AtelierMsg(scene, @"clientProcess"), @"bundleIdentifier");
    if ([bid isKindOfClass:NSString.class] && bid.length) return bid;
    id identity = AtelierMsg(AtelierMsg(AtelierMsg(scene, @"definition"), @"clientIdentity"), @"processIdentity");
    bid = AtelierMsg(identity, @"embeddedApplicationIdentifier");
    return ([bid isKindOfClass:NSString.class] && bid.length) ? bid : nil;
}

static BOOL AtelierSceneIsApp(id scene) {
    Class appSettings = NSClassFromString(@"UIApplicationSceneSettings");
    id settings = AtelierMsg(scene, @"settings");
    return appSettings && [settings isKindOfClass:appSettings];
}

static BOOL AtelierSceneForeground(id scene) {
    return AtelierBoolMsg(AtelierMsg(scene, @"settings"), @"isForeground", NO);
}

static CGRect AtelierSceneFrame(id scene) {
    id settings = AtelierMsg(scene, @"settings");
    SEL s = NSSelectorFromString(@"frame");
    if (!settings || ![settings respondsToSelector:s]) return CGRectZero;
    @try {
        NSMethodSignature *sig = [settings methodSignatureForSelector:s];
        if (!sig || strncmp(sig.methodReturnType, "{CGRect", 7) != 0) return CGRectZero;
        return ((CGRect (*)(id, SEL))objc_msgSend)(settings, s);
    } @catch (__unused id e) {}
    return CGRectZero;
}

// Changes the scene's settings through FrontBoard's own update call.
static BOOL AtelierSceneUpdate(id scene, void (^change)(id settings)) {
    if (!scene || !change) return NO;
    SEL withBlock = NSSelectorFromString(@"updateSettingsWithBlock:");
    @try {
        if (AtelierShape(scene, withBlock, "v", 1)) {
            void (^block)(id) = ^(id settings) {
                @try { change(settings); } @catch (NSException *e) { AtelierLog(@"scene settings threw %@", e.reason); }
            };
            ((void (*)(id, SEL, id))objc_msgSend)(scene, withBlock, block);
            return YES;
        }
        SEL plain = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        id settings = [AtelierMsg(scene, @"settings") mutableCopy];
        if (settings && AtelierShape(scene, plain, "v", 2)) {
            change(settings);
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, plain, settings, nil);
            return YES;
        }
    } @catch (NSException *e) {
        AtelierLog(@"scene update threw %@", e.reason);
    }
    return NO;
}

static BOOL AtelierSceneSetForeground(id scene, BOOL foreground) {
    return AtelierSceneUpdate(scene, ^(id settings) {
        AtelierSendBool(settings, @"setForeground:", foreground);
        if (foreground) {
            AtelierSendInt(settings, @"setDeactivationReasons:", 0);     // nothing is covering it
            AtelierSendBool(settings, @"setUnderLock:", NO);
        }
    });
}

static BOOL AtelierSceneSetSize(id scene, CGSize size) {
    return AtelierSceneUpdate(scene, ^(id settings) {
        SEL s = NSSelectorFromString(@"setFrame:");
        if (![settings respondsToSelector:s]) return;
        NSMethodSignature *sig = [settings methodSignatureForSelector:s];
        if (!sig || sig.numberOfArguments != 3 || strncmp([sig getArgumentTypeAtIndex:2], "{CGRect", 7) != 0) return;
        ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, s, CGRectMake(0, 0, size.width, size.height));
    });
}

@implementation AtelierScenes

+ (id)sceneForBundleID:(NSString *)bid {
    if (bid.length == 0) return nil;
    id mgr = AtelierSceneManager();
    NSString *usual = [NSString stringWithFormat:@"sceneID:%@-default", bid];
    id scene = AtelierMsgObj(mgr, @"sceneWithIdentifier:", usual);
    if (scene) return scene;
    // not under the usual name: the app's own scene among everything FrontBoard has
    NSString *prefix = [NSString stringWithFormat:@"sceneID:%@-", bid];
    id best = nil;
    for (id s in AtelierAllScenes()) {
        if (!AtelierSceneIsApp(s)) continue;
        NSString *ident = AtelierSceneIdentifier(s);
        BOOL named = [ident hasPrefix:prefix];
        if (!named && ![AtelierSceneBundle(s) isEqualToString:bid]) continue;
        if (named && !best) best = s;
        else if (!best) best = s;
    }
    return best;
}

+ (NSString *)describeScene:(id)scene {
    if (!scene) return @"(no scene)";
    CGRect f = AtelierSceneFrame(scene);
    return [NSString stringWithFormat:@"%@ [%@] fg=%d valid=%d active=%d content=%lld frame=%.0fx%.0f pid=%lld settings=%@",
            AtelierSceneIdentifier(scene), AtelierSceneBundle(scene) ?: @"?", (int)AtelierSceneForeground(scene),
            (int)AtelierBoolMsg(scene, @"isValid", YES), (int)AtelierBoolMsg(scene, @"isActive", NO),
            AtelierIntMsg(scene, @"contentState", -1), f.size.width, f.size.height,
            AtelierIntMsg(AtelierMsg(scene, @"clientProcess"), @"pid", 0),
            NSStringFromClass([AtelierMsg(scene, @"settings") class])];
}

+ (NSString *)describeAll {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (id s in AtelierAllScenes()) [lines addObject:[self describeScene:s]];
    [lines sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"%lu scenes\n    %@", (unsigned long)lines.count, [lines componentsJoinedByString:@"\n    "]];
}

// On the phone's iOS 16.5 an app that is in the foreground shows its own keyboard without help;
// what SpringBoard decides is where a hardware keyboard's keys go. This asks SpringBoard's
// keyboard focus controller to point them at the bench's main app, where this iOS has a way in.
+ (BOOL)requestKeyboardFocusForScene:(id)scene pid:(int)pid {
    if (!scene || pid <= 0) return NO;
    @try {
        id controller = AtelierSingleton(@"SBWorkspaceKeyboardFocusController");
        SEL user = NSSelectorFromString(@"userFocusRequestedForScene:");
        if (AtelierShape(controller, user, "v", 1)) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, user, scene);
            return YES;
        }
    } @catch (NSException *e) {
        AtelierLog(@"keyboard focus threw %@", e.reason);
    }
    return NO;
}

@end

#pragma mark - the pane

@interface AtelierPaneView : UIView
@end

@implementation AtelierPaneView
@end

@implementation AtelierPane {
    id _scene;                   // FBScene
    id _presenter;               // the scene presenter this pane made
    UIView *_hostView;           // its presentationView
    UIView *_placeholder;        // icon and a line of text while there is no picture
    UILabel *_status;
    NSInteger _generation;       // bumped whenever the pane starts over, so old timers stop
    BOOL _wantLive;
    BOOL _resized;
    BOOL _strayLogged;
}

@synthesize view = _view;

+ (instancetype)paneWithBundleID:(NSString *)bid {
    AtelierPane *p = [AtelierPane new];
    p->_bundleID = [bid copy];
    p->_sceneSize = [AtelierHost screenSize];
    return p;
}

- (UIView *)view {
    if (_view) return _view;
    CGSize sz = _sceneSize;
    AtelierPaneView *v = [[AtelierPaneView alloc] initWithFrame:CGRectMake(0, 0, sz.width, sz.height)];
    v.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    v.clipsToBounds = YES;
    _view = v;

    _placeholder = [[UIView alloc] initWithFrame:v.bounds];
    _placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _placeholder.userInteractionEnabled = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[AtelierHost iconForBundleID:_bundleID]];
    icon.frame = CGRectMake((sz.width - 120) / 2.0, sz.height * 0.34, 120, 120);
    icon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    icon.layer.cornerRadius = 27;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.clipsToBounds = YES;
    [_placeholder addSubview:icon];
    _status = [[UILabel alloc] initWithFrame:CGRectMake(30, CGRectGetMaxY(icon.frame) + 22, sz.width - 60, 70)];
    _status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _status.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    _status.font = [UIFont systemFontOfSize:24 weight:UIFontWeightMedium];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 2;
    _status.text = [AtelierHost displayNameForBundleID:_bundleID];
    [_placeholder addSubview:_status];
    [v addSubview:_placeholder];
    return v;
}

- (void)_setState:(AtelierPaneState)state note:(NSString *)note {
    _state = state;
    (void)self.view;
    _placeholder.hidden = (state == AtelierPaneHosted);
    NSString *name = [AtelierHost displayNameForBundleID:_bundleID];
    if (state == AtelierPaneStarting) _status.text = [NSString stringWithFormat:@"Opening %@…", name];
    else if (state == AtelierPaneFailed) _status.text = note.length ? note : [NSString stringWithFormat:@"%@ didn't open", name];
    else _status.text = name;
    _failure = (state == AtelierPaneFailed) ? (note ?: @"failed") : nil;
    if (self.onChange) self.onChange(self);
}

- (int)pid {
    return [AtelierHost pidOfApplication:[AtelierHost applicationForBundleID:_bundleID]];
}

#pragma mark attach

- (void)attach {
    if (_state == AtelierPaneHosted || _state == AtelierPaneStarting) return;
    _generation++;
    if (![AtelierHost applicationForBundleID:_bundleID]) {
        [self _setState:AtelierPaneFailed note:@"Not installed"];
        AtelierLog(@"pane %@: SpringBoard has no such app", _bundleID);
        return;
    }
    id scene = [AtelierScenes sceneForBundleID:_bundleID];
    if (scene) {
        [self _hostScene:scene];
        return;
    }
    BOOL asked = [AtelierHost launchApp:_bundleID suspended:YES];
    AtelierLog(@"pane %@: no scene, started in the background (%d)", _bundleID, (int)asked);
    [self _setState:AtelierPaneStarting note:nil];
    [self _waitForScene:_generation tries:0];
}

- (void)_waitForScene:(NSInteger)generation tries:(NSInteger)tries {
    if (generation != _generation || _state != AtelierPaneStarting) return;
    id scene = [AtelierScenes sceneForBundleID:_bundleID];
    if (scene) {
        AtelierLog(@"pane %@: scene after %.1f s", _bundleID, tries * 0.2);
        [self _hostScene:scene];
        return;
    }
    if (tries == 12) {                                   // 2.4 s and nothing: ask once more
        BOOL asked = [AtelierHost launchApp:_bundleID suspended:YES];
        AtelierLog(@"pane %@: still no scene, asked again (%d), pid %d", _bundleID, (int)asked, [self pid]);
    }
    if (tries >= 40) {
        AtelierLog(@"pane %@: no scene after 8 s (pid %d)", _bundleID, [self pid]);
        [self _setState:AtelierPaneFailed note:nil];
        return;
    }
    __weak typeof(self) weak = self;
    AtelierAfter(0.2, ^{ [weak _waitForScene:generation tries:tries + 1]; });
}

- (void)_hostScene:(id)scene {
    @try {
        id manager = AtelierMsg(scene, @"uiPresentationManager");
        NSString *name = [NSString stringWithFormat:@"com.adarsh.atelier.%ld", (long)++gPresenterSerial];
        id presenter = nil;
        SEL withPriority = NSSelectorFromString(@"createPresenterWithIdentifier:priority:");
        // Above SpringBoard's own presenter of the same scene (the app in front, behind the bench).
        long long priority = (long long)[[AtelierSettings shared] tune:@"presenterPriority" fallback:100];
        if (AtelierShape(manager, withPriority, "@", 2) && AtelierArgIs(manager, withPriority, 3, "qQiIlL"))
            presenter = ((id (*)(id, SEL, id, long long))objc_msgSend)(manager, withPriority, name, priority);
        if (!presenter) presenter = AtelierMsgObj(manager, @"createPresenterWithIdentifier:", name);
        if (!presenter) {
            AtelierLog(@"pane %@: no presenter (manager %@)", _bundleID, NSStringFromClass([manager class]));
            [self _setState:AtelierPaneFailed note:nil];
            return;
        }
        SEL modify = NSSelectorFromString(@"modifyPresentationContext:");
        long long style = (long long)[[AtelierSettings shared] tune:@"presenterStyle" fallback:2];
        long long layers = (long long)[[AtelierSettings shared] tune:@"presenterLayers" fallback:-1];
        if (AtelierShape(presenter, modify, "v", 1)) {
            void (^block)(id) = ^(id context) {
                @try {
                    AtelierSendInt(context, @"setAppearanceStyle:", style);
                    if (layers >= 0) AtelierSendInt(context, @"setPresentedLayerTypes:", layers);
                } @catch (NSException *e) { AtelierLog(@"presentation context threw %@", e.reason); }
            };
            ((void (*)(id, SEL, id))objc_msgSend)(presenter, modify, block);
        }
        AtelierSend(presenter, @"activate");
        UIView *host = AtelierMsg(presenter, @"presentationView");
        if (![host isKindOfClass:UIView.class]) {
            AtelierLog(@"pane %@: presenter %@ has no view", _bundleID, NSStringFromClass([presenter class]));
            AtelierSend(presenter, @"invalidate");
            [self _setState:AtelierPaneFailed note:nil];
            return;
        }
        _scene = scene;
        _presenter = presenter;
        _hostView = host;
        _strayLogged = NO;
        UIView *v = self.view;
        host.frame = v.bounds;
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v insertSubview:host atIndex:0];
        if (_resized) AtelierSceneSetSize(scene, _sceneSize);
        if (_wantLive) AtelierSceneSetForeground(scene, YES);
        AtelierLog(@"pane %@: hosted %@ · presenter %@ view %@ context %@", _bundleID, [AtelierScenes describeScene:scene],
                   NSStringFromClass([presenter class]), NSStringFromClass([host class]),
                   AtelierMsg(presenter, @"presentationContext") ?: @"?");
        [self _setState:AtelierPaneHosted note:nil];
    } @catch (NSException *e) {
        AtelierLog(@"pane %@: hosting threw %@", _bundleID, e.reason);
        [self _setState:AtelierPaneFailed note:nil];
    }
}

#pragma mark live

- (BOOL)live {
    return _wantLive && _state == AtelierPaneHosted && AtelierSceneForeground(_scene);
}

- (void)setLive:(BOOL)live {
    _wantLive = live;
    if (_state != AtelierPaneHosted || !_scene) return;
    if (AtelierSceneForeground(_scene) == live) return;
    AtelierSceneSetForeground(_scene, live);
}

- (void)setSceneSize:(CGSize)size {
    if (size.width < 100 || size.height < 100) return;
    CGSize full = [AtelierHost screenSize];
    BOOL isFull = fabs(size.width - full.width) < 0.5 && fabs(size.height - full.height) < 0.5;
    if (fabs(size.width - _sceneSize.width) < 0.5 && fabs(size.height - _sceneSize.height) < 0.5) return;
    _sceneSize = size;
    _resized = !isFull;
    UIView *v = self.view;
    CGAffineTransform t = v.transform;
    v.transform = CGAffineTransformIdentity;
    v.bounds = CGRectMake(0, 0, size.width, size.height);
    v.transform = t;
    if (_state == AtelierPaneHosted && _scene) AtelierSceneSetSize(_scene, size);
}

- (BOOL)check {
    if (_state != AtelierPaneHosted) return _state != AtelierPaneFailed;
    BOOL gone = !AtelierBoolMsg(_scene, @"isValid", YES);
    if (!gone) {
        id now = AtelierMsgObj(AtelierSceneManager(), @"sceneWithIdentifier:", AtelierSceneIdentifier(_scene));
        if (now != _scene) gone = YES;
    }
    if (gone) {
        AtelierLog(@"pane %@: its scene has gone (the app was closed)", _bundleID);
        [self _dropPresenter];
        [self _setState:AtelierPaneIdle note:nil];
        return NO;
    }
    if (_wantLive && !AtelierSceneForeground(_scene)) {
        // SpringBoard sent it to the background (it does when it thinks the app left the screen)
        if (!_strayLogged) { _strayLogged = YES; AtelierLog(@"pane %@: was sent to the background, bringing it back", _bundleID); }
        AtelierSceneSetForeground(_scene, YES);
    }
    return YES;
}

- (void)_dropPresenter {
    @try { AtelierSend(_presenter, @"invalidate"); } @catch (__unused id e) {}
    [_hostView removeFromSuperview];
    _presenter = nil;
    _hostView = nil;
    _scene = nil;
}

- (void)detachKeepingForeground:(BOOL)keep {
    _generation++;
    id scene = _scene;
    BOOL resized = _resized;
    [self _dropPresenter];
    _wantLive = NO;
    if (scene && AtelierBoolMsg(scene, @"isValid", YES)) {
        if (resized) AtelierSceneSetSize(scene, [AtelierHost screenSize]);
        if (!keep && AtelierSceneForeground(scene)) AtelierSceneSetForeground(scene, NO);
    }
    _resized = NO;
    _sceneSize = [AtelierHost screenSize];
    _state = AtelierPaneIdle;
    _placeholder.hidden = NO;
}

- (NSString *)debugState {
    static NSArray<NSString *> *names;
    if (!names) names = @[ @"idle", @"starting", @"hosted", @"failed" ];
    return [NSString stringWithFormat:@"%@:%@%@%@ pid %d %.0fx%.0f", _bundleID, names[(NSUInteger)_state],
            _wantLive ? @" want-live" : @"", (_scene && AtelierSceneForeground(_scene)) ? @" fg" : @" bg",
            [self pid], _sceneSize.width, _sceneSize.height];
}

@end
