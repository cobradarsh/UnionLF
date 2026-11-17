/*  ChakraCore.m — log, careful messaging, haptics, settings, SpringBoard helpers.  */

#import "Chakra.h"
#import <dlfcn.h>
#import <stdatomic.h>

static _Atomic(bool) gChakraDebugLog = true;

#pragma mark - log

NSString *ChakraLogDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#if TARGET_OS_SIMULATOR
        const char *env = getenv("CHAKRA_DIR");
        dir = (env && env[0]) ? @(env) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
#else
        dir = @"/var/mobile/Library/Logs";
#endif
    });
    return dir;
}

static dispatch_queue_t ChakraLogQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.adarsh.chakra.log", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// Returns once every line logged so far is in the file.
void ChakraLogFlush(void) {
    dispatch_sync(ChakraLogQueue(), ^{});
}

void ChakraLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[Chakra] %@", msg);
    if (!atomic_load(&gChakraDebugLog)) return;

    static NSDateFormatter *df;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        path = [ChakraLogDir() stringByAppendingPathComponent:@"Chakra.log"];
    });
    NSDate *now = [NSDate date];
    dispatch_async(ChakraLogQueue(), ^{
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:now], msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 256 * 1024) {      // keep it small: drop the older half
            NSData *all = [NSData dataWithContentsOfFile:path];
            [[all subdataWithRange:NSMakeRange(all.length / 2, all.length - all.length / 2)] writeToFile:path atomically:YES];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    });
}

void ChakraAfter(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

#pragma mark - careful messaging

static const char *ChakraBareType(const char *t) {           // skip const / in / out / oneway…
    while (t && *t && strchr("rnNoORV", *t)) t++;
    return t;
}

// The method exists, takes `args` arguments and returns one of the types in `returns`
// (Objective-C type codes: v void, @ object, B BOOL, q long long…).
BOOL ChakraShape(id target, SEL sel, const char *returns, NSUInteger args) {
    if (!target || !sel) return NO;
    @try {
        if (![target respondsToSelector:sel]) return NO;
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != args + 2) return NO;
        const char *r = ChakraBareType(sig.methodReturnType);
        return r && *r && strchr(returns, *r) != NULL;
    } @catch (__unused id e) {}
    return NO;
}

static BOOL ChakraArgIs(id target, SEL sel, NSUInteger index, const char *types) {
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments <= index) return NO;
        const char *t = ChakraBareType([sig getArgumentTypeAtIndex:index]);
        return t && *t && strchr(types, *t) != NULL;
    } @catch (__unused id e) {}
    return NO;
}

// Return types that come back in a register, so the result can simply be ignored.
static const char *const kChakraPlainReturns = "v@#BcCqQiIlLsSfd";

id ChakraMsg(id target, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!ChakraShape(target, s, "@#", 0)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, s); } @catch (__unused id e) {}
    return nil;
}

BOOL ChakraBoolMsg(id target, NSString *selName, BOOL fallback) {
    SEL s = NSSelectorFromString(selName);
    if (!ChakraShape(target, s, "Bc", 0)) return fallback;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(target, s); } @catch (__unused id e) {}
    return fallback;
}

long long ChakraIntMsg(id target, NSString *selName, long long fallback) {
    SEL s = NSSelectorFromString(selName);
    if (!ChakraShape(target, s, "qQiIlLsSBc", 0)) return fallback;
    @try {
        const char *r = ChakraBareType([target methodSignatureForSelector:s].methodReturnType);
        switch (*r) {
            case 'q': case 'Q': return ((long long (*)(id, SEL))objc_msgSend)(target, s);
            case 'i': case 'I': case 'l': case 'L': return ((int (*)(id, SEL))objc_msgSend)(target, s);
            case 's': case 'S': return ((short (*)(id, SEL))objc_msgSend)(target, s);
            default: return ((BOOL (*)(id, SEL))objc_msgSend)(target, s) ? 1 : 0;
        }
    } @catch (__unused id e) {}
    return fallback;
}

BOOL ChakraSend(id target, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!ChakraShape(target, s, kChakraPlainReturns, 0)) return NO;
    @try { ((void (*)(id, SEL))objc_msgSend)(target, s); return YES; } @catch (NSException *e) { ChakraLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL ChakraSendBool(id target, NSString *selName, BOOL arg) {
    SEL s = NSSelectorFromString(selName);
    if (!ChakraShape(target, s, kChakraPlainReturns, 1) || !ChakraArgIs(target, s, 2, "Bc")) return NO;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(target, s, arg); return YES; } @catch (NSException *e) { ChakraLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL ChakraSendInt(id target, NSString *selName, long long arg) {
    SEL s = NSSelectorFromString(selName);
    if (!ChakraShape(target, s, kChakraPlainReturns, 1) || !ChakraArgIs(target, s, 2, "qQiIlL")) return NO;
    @try { ((void (*)(id, SEL, long long))objc_msgSend)(target, s, arg); return YES; } @catch (NSException *e) { ChakraLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL ChakraSendObj(id target, NSString *selName, id arg) {
    SEL s = NSSelectorFromString(selName);
    if (!ChakraShape(target, s, kChakraPlainReturns, 1) || !ChakraArgIs(target, s, 2, "@#")) return NO;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, s, arg); return YES; } @catch (NSException *e) { ChakraLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

// SpringBoard's shared controller of a class. Where the class can say whether its controller
// exists yet, it is asked that way, so Chakra never creates one of SpringBoard's own controllers
// before SpringBoard has.
id ChakraSingleton(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    if ([cls respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")]) return ChakraMsg(cls, @"sharedInstanceIfExists");
    return ChakraMsg(cls, @"sharedInstance");
}

#pragma mark - haptics

void ChakraHapticPlay(ChakraHaptic event) {
    NSInteger level = [ChakraSettings shared].haptics;
    if (level <= 0) return;
    @try {
        if (event == ChakraHapticTick) {
            static UISelectionFeedbackGenerator *tick;
            if (!tick) tick = [UISelectionFeedbackGenerator new];
            [tick selectionChanged];
            [tick prepare];
            return;
        }
        UIImpactFeedbackStyle style = UIImpactFeedbackStyleLight;
        if (level == 2) style = UIImpactFeedbackStyleMedium;
        if (level >= 3) style = UIImpactFeedbackStyleHeavy;
        if (event == ChakraHapticCommit && level == 1) style = UIImpactFeedbackStyleMedium;
        if (event == ChakraHapticLift) style = UIImpactFeedbackStyleHeavy;
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:style] impactOccurred];
    } @catch (__unused id e) {}
}

#pragma mark - settings

@implementation ChakraSettings {
    NSDictionary *_p;
}

+ (instancetype)shared {
    static ChakraSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ChakraSettings new]; s->_p = @{}; });
    return s;
}

- (BOOL)_b:(NSString *)k def:(BOOL)d { id v = _p[k]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : d; }
- (double)_d:(NSString *)k def:(double)d { id v = _p[k]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d; }
- (NSString *)_s:(NSString *)k {
    id v = _p[k];
    if (![v isKindOfClass:NSString.class]) return @"";
    return [(NSString *)v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)reload {
    CFStringRef dom = (__bridge CFStringRef)CHAKRA_DOMAIN;
    CFPreferencesAppSynchronize(dom);
    NSDictionary *d = nil;
    CFArrayRef keys = CFPreferencesCopyKeyList(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        d = CFBridgingRelease(CFPreferencesCopyMultiple(keys, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        CFRelease(keys);
    }
    _p = [d isKindOfClass:NSDictionary.class] ? d : @{};
    atomic_store(&gChakraDebugLog, (bool)self.debugLog);
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (key.length == 0) return;
    CFStringRef dom = (__bridge CFStringRef)CHAKRA_DOMAIN;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, dom);
    CFPreferencesAppSynchronize(dom);
    NSMutableDictionary *m = [_p mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) m[key] = value; else [m removeObjectForKey:key];
    _p = m;
    atomic_store(&gChakraDebugLog, (bool)self.debugLog);
}

- (BOOL)enabled          { return [self _b:@"enabled" def:YES]; }
- (CGFloat)ballSize      { return MAX(36, MIN(64, [self _d:@"ballSize" def:46])); }
- (CGFloat)idleAlpha     { return MAX(0.15, MIN(1.0, [self _d:@"idleAlpha" def:0.6])); }
- (BOOL)tuck             { return [self _b:@"tuck" def:YES]; }
- (NSInteger)accent      { NSInteger a = (NSInteger)[self _d:@"accent" def:0]; return (a >= 0 && a <= 8) ? a : 0; }
- (NSInteger)ballIcon    { return ((NSInteger)[self _d:@"ballIcon" def:0] == 1) ? 1 : 0; }
- (ChakraStyle)style         { return ((NSInteger)[self _d:@"style" def:0] == 1) ? ChakraStyleColumn : ChakraStyleWheel; }
- (CGFloat)iconSize      { return MAX(44, MIN(66, [self _d:@"iconSize" def:54])); }
- (BOOL)labels           { return [self _b:@"labels" def:YES]; }
- (BOOL)dim              { return [self _b:@"dim" def:YES]; }
- (NSInteger)haptics     { NSInteger h = (NSInteger)[self _d:@"haptics" def:1]; return MAX(0, MIN(3, h)); }
- (BOOL)lockScreen       { return [self _b:@"lockScreen" def:NO]; }
- (BOOL)hideLandscape    { return [self _b:@"hideLandscape" def:NO]; }
- (BOOL)debugLog         { return [self _b:@"debugLog" def:YES]; }
- (BOOL)glass            { return (NSInteger)[self _d:@"plateStyle" def:0] != 1; }     // 0 glass, 1 frosted
- (BOOL)hideInShots      { return [self _b:@"hideInShots" def:YES]; }
- (BOOL)editEntry        { return [self _b:@"editEntry" def:YES]; }
- (BOOL)dragMoves        { return (NSInteger)[self _d:@"dragMode" def:0] == 1; }       // 0 picks from the wheel, 1 moves the ball
- (BOOL)lockPosition     { return [self _b:@"lockPosition" def:NO]; }

// which = Double | Triple | Hold. A hold opens the editor until something else is chosen.
- (NSString *)gesture:(NSString *)which {
    NSString *v = [self _s:[@"gesture" stringByAppendingString:which]];
    if (v.length) return v;
    return [which isEqualToString:@"Hold"] ? @"action:edit" : @"none";
}

- (NSString *)gestureApp:(NSString *)which { return [self _s:[NSString stringWithFormat:@"gesture%@App", which]]; }

- (NSArray<NSString *> *)pickedApps {
    id raw = _p[@"apps"];
    if (![raw isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id bid in (NSArray *)raw) if ([bid isKindOfClass:NSString.class] && [bid length] && ![out containsObject:bid]) [out addObject:bid];
    return out;
}
- (ChakraEdge)ballEdge       { return ((NSInteger)[self _d:@"ballEdge" def:1] == 0) ? ChakraEdgeLeft : ChakraEdgeRight; }
- (CGFloat)ballY         { return MAX(0.0, MIN(1.0, [self _d:@"ballY" def:0.44])); }

- (UIColor *)accentColor {
    static NSArray<UIColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIColor *(^rgb)(int) = ^UIColor *(int hex) {
            return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
        };
        colors = @[ rgb(0x5E5CE6),      // 0 indigo
                    rgb(0x0A84FF),      // 1 blue
                    rgb(0x30B0C7),      // 2 teal
                    rgb(0x30D158),      // 3 green
                    rgb(0xFF9F0A),      // 4 saffron
                    rgb(0xFF375F),      // 5 pink
                    rgb(0xFF453A),      // 6 red
                    rgb(0x8E8E93),      // 7 graphite
                    rgb(0xE2A72E) ];    // 8 gold, to go with the golden sun
    });
    return colors[(NSUInteger)self.accent];
}

- (void)setBallEdge:(ChakraEdge)edge y:(CGFloat)y {
    [self setObject:@((NSInteger)edge) forKey:@"ballEdge"];
    [self setObject:@(MAX(0.0, MIN(1.0, y))) forKey:@"ballY"];
}

- (NSArray<NSDictionary *> *)savedItems {
    id raw = _p[@"items"];
    if (![raw isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id d in (NSArray *)raw) if ([d isKindOfClass:NSDictionary.class]) [out addObject:d];
    return out;
}

- (void)setSavedItems:(NSArray<NSDictionary *> *)items { [self setObject:(items ?: @[]) forKey:@"items"]; }

- (NSString *)slotName:(NSInteger)slot   { return [self _s:[NSString stringWithFormat:@"sc%ldName", (long)slot]]; }
- (NSString *)slotTarget:(NSInteger)slot { return [self _s:[NSString stringWithFormat:@"sc%ldURL", (long)slot]]; }
- (NSString *)slotGlyph:(NSInteger)slot  { return [self _s:[NSString stringWithFormat:@"sc%ldGlyph", (long)slot]]; }

@end

#pragma mark - SpringBoard helpers

@implementation ChakraPortraitController
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }
@end

@implementation ChakraHost

static NSMutableArray<NSString *> *gRecent;       // apps seen in front, newest first (main thread)

+ (UIWindow *)overlayWindowAtLevel:(UIWindowLevel)level {
    CGSize sz = [self screenSize];
    CGRect screen = CGRectMake(0, 0, sz.width, sz.height);
    UIWindowScene *scene = [self mainScene];
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:screen];
    w.frame = screen;
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    w.opaque = NO;
    w.rootViewController = [ChakraPortraitController new];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    w.hidden = YES;
    [self keepOutOfScreenshots:w];
    return w;
}

// The mark iOS itself puts on the layer of a password field, which keeps that layer out of
// screenshots, screen recordings and mirroring while it still draws on the screen. It is read from
// a real password field rather than assumed (it has been 0x12 from iOS 13 to 17).
static unsigned ChakraSecureMask(void) {
    static unsigned mask;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 120, 34)];
            field.secureTextEntry = YES;
            [field layoutIfNeeded];
            NSMutableArray<CALayer *> *queue = [NSMutableArray arrayWithObject:field.layer];
            NSUInteger looked = 0;
            while (queue.count && !mask && looked++ < 60) {
                CALayer *layer = queue.firstObject;
                [queue removeObjectAtIndex:0];
                long long m = ChakraIntMsg(layer, @"disableUpdateMask", 0);
                if (m > 0) mask = (unsigned)m;
                if (layer.sublayers.count) [queue addObjectsFromArray:layer.sublayers];
            }
        } @catch (__unused id e) {}
        if (!mask) mask = 0x12;
    });
    return mask;
}

+ (void)keepOutOfScreenshots:(UIWindow *)window {
    if (!window) return;
    unsigned mask = [ChakraSettings shared].hideInShots ? ChakraSecureMask() : 0;
    static BOOL said;
    BOOL sent = ChakraSendInt(window.layer, @"setDisableUpdateMask:", mask);
    if (!said) {
        said = YES;
        ChakraLog(@"screenshots: %@ (mark %#x)", !sent ? @"this iOS has no way to keep a layer out" : (mask ? @"Chakra stays out of them" : @"Chakra shows in them"), mask);
    }
}

// Same ranking Wingman Plus and Dynamic Stage+ settled on: on Dynamic Island phones SpringBoard has a
// second foreground scene, and a window put there does not show.
+ (UIWindowScene *)mainScene {
    UIWindowScene *best = nil;
    NSUInteger bestRank = NSUIntegerMax;
    Class main = NSClassFromString(@"SBWindowScene");
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        NSUInteger rank = 0;
        if (!(main && [ws class] == main)) rank += 8;
        if ([NSStringFromClass([ws class]) containsString:@"Aperture"]) rank += 4;
        if (ws.screen != UIScreen.mainScreen) rank += 2;
        if (ws.activationState != UISceneActivationStateForegroundActive) rank += 1;
        if (rank < bestRank) { bestRank = rank; best = ws; }
    }
    return best;
}

// nativeBounds never turns with the interface, so this is the portrait size whatever is in front.
+ (CGSize)screenSize {
    UIScreen *screen = UIScreen.mainScreen;
    CGFloat scale = screen.nativeScale > 0 ? screen.nativeScale : MAX(1, screen.scale);
    CGSize native = screen.nativeBounds.size;
    CGSize sz = CGSizeMake(native.width / scale, native.height / scale);
    if (sz.width < 200 || sz.height < 300) {
        sz = screen.bounds.size;
        if (sz.width > sz.height) sz = CGSizeMake(sz.height, sz.width);
    }
    return CGSizeMake(round(sz.width), round(sz.height));
}

+ (UIEdgeInsets)safeInsets {
    static UIEdgeInsets cached;
    static BOOL have;
    if (have) return cached;
    CGSize sz = [self screenSize];
    UIEdgeInsets best = UIEdgeInsetsZero;
    for (UIWindow *w in [self mainScene].windows) {
        if (fabs(w.bounds.size.width - sz.width) > 1 || fabs(w.bounds.size.height - sz.height) > 1) continue;
        UIEdgeInsets i = w.safeAreaInsets;
        best.top = MAX(best.top, i.top);
        best.bottom = MAX(best.bottom, i.bottom);
    }
    if (best.top > 0) { cached = best; have = YES; return best; }
    // nothing to ask yet: a phone without a Home button is taller than 800 pt
    return sz.height >= 800 ? UIEdgeInsetsMake(50, 0, 34, 0) : UIEdgeInsetsMake(20, 0, 0, 0);
}

+ (BOOL)isLocked {
    id mgr = ChakraSingleton(@"SBLockScreenManager");
    if (ChakraShape(mgr, NSSelectorFromString(@"isUILocked"), "Bc", 0)) return ChakraBoolMsg(mgr, @"isUILocked", NO);
    return ChakraBoolMsg(UIApplication.sharedApplication, @"isLocked", NO);
}

+ (long long)interfaceOrientation {
    long long o = ChakraIntMsg(UIApplication.sharedApplication, @"activeInterfaceOrientation", UIInterfaceOrientationPortrait);
    return (o >= 1 && o <= 4) ? o : UIInterfaceOrientationPortrait;
}

// Chakra's windows stay in portrait; this is how far a view has to turn to read upright.
+ (CGFloat)interfaceAngle {
    switch ([self interfaceOrientation]) {
        case UIInterfaceOrientationLandscapeRight:     return M_PI_2;
        case UIInterfaceOrientationLandscapeLeft:      return -M_PI_2;
        case UIInterfaceOrientationPortraitUpsideDown: return M_PI;
        default:                                       return 0;
    }
}

+ (NSString *)frontmostBundleID {
    @try {
        id front = ChakraMsg(UIApplication.sharedApplication, @"_accessibilityFrontMostApplication");
        NSString *bid = ChakraMsg(front, @"bundleIdentifier");
        return ([bid isKindOfClass:NSString.class] && bid.length) ? bid : nil;
    } @catch (__unused id e) {}
    return nil;
}

+ (id)applicationForBundleID:(NSString *)bid {
    if (bid.length == 0) return nil;
    id ctl = ChakraSingleton(@"SBApplicationController");
    SEL s = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!ChakraShape(ctl, s, "@", 1)) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(ctl, s, bid); } @catch (__unused id e) {}
    return nil;
}

+ (NSString *)displayNameForBundleID:(NSString *)bid {
    NSString *n = ChakraMsg([self applicationForBundleID:bid], @"displayName");
    if ([n isKindOfClass:NSString.class] && n.length) return n;
    for (NSDictionary *a in [self installedApps]) if ([a[@"id"] isEqualToString:bid]) return a[@"name"];
    return bid ?: @"";
}

+ (UIImage *)iconForBundleID:(NSString *)bid {
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (bid.length == 0 || ![UIImage respondsToSelector:s]) return nil;
    @try {
        // format 2 = the 60 pt Home Screen icon, already masked
        return ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)(UIImage.class, s, bid, 2, UIScreen.mainScreen.scale);
    } @catch (__unused id e) {}
    return nil;
}

+ (BOOL)launchApp:(NSString *)bid {
    if (bid.length == 0) return NO;
    UIApplication *app = UIApplication.sharedApplication;
    if ([self isLocked]) {
        // from the lock screen: ask for the unlock, then open
        id service = ChakraMsg(NSClassFromString(@"FBSSystemService"), @"sharedService");
        SEL open = NSSelectorFromString(@"openApplication:options:withResult:");
        if (ChakraShape(service, open, "v", 3)) {
            NSDictionary *options = @{ @"__UnlockDevice": @YES, @"__PromptUnlockDevice": @YES };
            @try { ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, open, bid, options, nil); return YES; } @catch (__unused id e) {}
        }
    }
    SEL s = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (!ChakraShape(app, s, "Bc", 2)) return NO;
    @try { return ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, s, bid, NO); } @catch (__unused id e) {}
    return NO;
}

+ (void)openURL:(NSURL *)url {
    if (!url) return;
    UIApplication *app = UIApplication.sharedApplication;
    // Is there anything that takes this URL? (Otherwise SpringBoard would do nothing, silently.)
    id ws = ChakraMsg(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    SEL takers = NSSelectorFromString(@"applicationsAvailableForOpeningURL:");
    if (ChakraShape(ws, takers, "@", 1)) {
        NSArray *apps = nil;
        @try { apps = ((id (*)(id, SEL, id))objc_msgSend)(ws, takers, url); } @catch (__unused id e) {}
        if ([apps isKindOfClass:NSArray.class] && apps.count == 0) {
            ChakraLog(@"open %@: no app takes this", url.scheme);
            [self toast:[NSString stringWithFormat:@"Nothing on this iPhone opens “%@:” links.", url.scheme ?: @"?"]];
            return;
        }
    }
    // SpringBoard's own way in: the same path a link tapped in a notification takes.
    if (ChakraSendObj(app, @"applicationOpenURL:", url)) {
        ChakraLog(@"open %@ (SpringBoard)", url.scheme);
        return;
    }
    [app openURL:url options:@{} completionHandler:^(BOOL ok) {
        if (ok) { ChakraLog(@"open %@ (UIApplication)", url.scheme); return; }
        SEL sens = NSSelectorFromString(@"openSensitiveURL:withOptions:");
        BOOL done = NO;
        if (ChakraShape(ws, sens, "Bc", 2)) {
            @try { done = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, sens, url, nil); } @catch (__unused id e) {}
        }
        ChakraLog(@"open %@ (LaunchServices) -> %d", url.scheme, done);
        if (!done) [ChakraHost toast:@"That link couldn't be opened."];
    }];
}

+ (void)toast:(NSString *)message {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGSize sz = [ChakraHost screenSize];
        CGFloat angle = [ChakraHost interfaceAngle];
        BOOL sideways = fabs(fabs(angle) - M_PI_2) < 0.01;
        CGFloat room = (sideways ? sz.height : sz.width) - 60;          // the width the words may take, as they are read
        UILabel *t = [UILabel new];
        t.text = message;
        t.textColor = UIColor.whiteColor;
        t.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        t.textAlignment = NSTextAlignmentCenter;
        t.numberOfLines = 0;
        t.layer.cornerRadius = 14;
        t.clipsToBounds = YES;
        CGSize fit = [t sizeThatFits:CGSizeMake(room - 34, 200)];
        CGFloat w = MIN(room, fit.width + 34), h = fit.height + 22;
        t.bounds = CGRectMake(0, 0, w, h);
        // near the top of the screen as the reader sees it
        CGFloat inset = [ChakraHost safeInsets].top + 14 + h / 2.0;
        if (angle == 0)            t.center = CGPointMake(sz.width / 2.0, inset);
        else if (!sideways)        t.center = CGPointMake(sz.width / 2.0, sz.height - inset);
        else if (angle > 0)        t.center = CGPointMake(sz.width - 24 - h / 2.0, sz.height / 2.0);
        else                       t.center = CGPointMake(24 + h / 2.0, sz.height / 2.0);
        t.transform = CGAffineTransformMakeRotation(angle);
        UIWindow *win = [ChakraHost overlayWindowAtLevel:100030];
        win.userInteractionEnabled = NO;
        [win.rootViewController.view addSubview:t];
        win.hidden = NO;
        t.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ t.alpha = 1; }];
        ChakraAfter(2.4, ^{
            [UIView animateWithDuration:0.25 animations:^{ t.alpha = 0; } completion:^(BOOL done) { win.hidden = YES; }];
        });
    });
}

+ (NSArray<NSDictionary *> *)installedApps {
    static NSArray *cache;
    static CFAbsoluteTime at;
    if (cache && CFAbsoluteTimeGetCurrent() - at < 60) return cache;
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id ws = ChakraMsg(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        for (id p in (NSArray *)ChakraMsg(ws, @"allApplications")) {
            NSString *bid = ChakraMsg(p, @"applicationIdentifier");
            NSString *nm = ChakraMsg(p, @"localizedName");
            NSString *type = ChakraMsg(p, @"applicationType");
            if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
            NSArray *tags = ChakraMsg(p, @"appTags");
            if ([tags isKindOfClass:NSArray.class] && [tags containsObject:@"hidden"]) continue;
            // App Store apps are "User"; TrollStore apps register as "System" but are never com.apple.*.
            // Of Apple's own, keep the ones that have a Home Screen icon (no view services, no daemons' apps).
            if ([bid hasPrefix:@"com.apple."] && ![type isEqualToString:@"User"]) {
                id app = [self applicationForBundleID:bid];
                if (!app) continue;
                id info = ChakraMsg(app, @"info");
                if (ChakraBoolMsg(info, @"hasHiddenTag", NO)) continue;
            }
            [out addObject:@{ @"id": bid, @"name": ([nm isKindOfClass:NSString.class] && nm.length) ? nm : bid }];
        }
    } @catch (__unused id e) {}
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    cache = out;
    at = CFAbsoluteTimeGetCurrent();
    return out;
}

+ (void)noteFront {
    NSString *bid = [self frontmostBundleID];
    if (bid.length == 0) return;
    if (!gRecent) gRecent = [NSMutableArray array];
    if ([gRecent.firstObject isEqualToString:bid]) return;
    [gRecent removeObject:bid];
    [gRecent insertObject:bid atIndex:0];
    while (gRecent.count > 8) [gRecent removeLastObject];
}

// The App Switcher's apps, in the order SpringBoard keeps them (bundle ids, each once).
+ (NSArray<NSString *> *)switcherApps {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    @try {
        id coordinator = ChakraSingleton(@"SBMainSwitcherControllerCoordinator");
        NSArray *layouts = ChakraMsg(coordinator, @"recentAppLayouts");
        if (![layouts isKindOfClass:NSArray.class]) return out;
        for (id layout in layouts) {
            NSArray *items = ChakraMsg(layout, @"allItems");
            if (![items isKindOfClass:NSArray.class]) continue;
            for (id item in items) {
                NSString *bid = ChakraMsg(item, @"bundleIdentifier");
                if ([bid isKindOfClass:NSString.class] && bid.length && ![out containsObject:bid]) [out addObject:bid];
            }
        }
    } @catch (__unused id e) {}
    return out;
}

+ (NSArray<NSString *> *)seenApps { return gRecent ? [gRecent copy] : @[]; }

// The app before the one in front.
//   1. SpringBoard's App Switcher list knows it exactly, and survives a respring. Which end of
//      that list is "newest" is not taken on trust: the app in front must be at one end of it,
//      and its neighbour is the answer.
//   2. Otherwise, what Chakra itself has seen in front since it started (newest first).
//   3. On the Home Screen with nothing seen yet: the head of the switcher list.
+ (NSString *)previousApp {
    [self noteFront];
    NSString *front = [self frontmostBundleID];
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (NSString *bid in [self switcherApps]) if ([self applicationForBundleID:bid]) [list addObject:bid];
    if (front && list.count > 1) {
        NSUInteger at = [list indexOfObject:front];
        if (at == 0) return list[1];
        if (at == list.count - 1) return list[at - 1];
    }
    for (NSString *bid in gRecent) {
        if (front && [bid isEqualToString:front]) continue;
        if ([self applicationForBundleID:bid]) return bid;
    }
    for (NSString *bid in list) {
        if (front && [bid isEqualToString:front]) continue;
        return bid;
    }
    return nil;
}

@end
