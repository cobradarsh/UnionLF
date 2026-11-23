/*  AtelierCore.m — log, careful messaging, settings, SpringBoard helpers.  */

#import "Atelier.h"
#import <dlfcn.h>
#import <stdatomic.h>

static _Atomic(bool) gAtelierDebugLog = true;

#pragma mark - log

NSString *AtelierLogDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#if TARGET_OS_SIMULATOR
        const char *env = getenv("ATELIER_DIR");
        dir = (env && env[0]) ? @(env) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
#else
        dir = @"/var/mobile/Library/Logs";
#endif
    });
    return dir;
}

static dispatch_queue_t AtelierLogQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.adarsh.atelier.log", DISPATCH_QUEUE_SERIAL); });
    return q;
}

void AtelierLogFlush(void) {
    dispatch_sync(AtelierLogQueue(), ^{});
}

void AtelierLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!atomic_load(&gAtelierDebugLog)) return;
    NSLog(@"[Atelier] %@", msg.length > 900 ? [msg substringToIndex:900] : msg);

    static NSDateFormatter *df;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        path = [AtelierLogDir() stringByAppendingPathComponent:@"Atelier.log"];
    });
    NSDate *now = [NSDate date];
    dispatch_async(AtelierLogQueue(), ^{
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:now], msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
#if !TARGET_OS_SIMULATOR
        if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 384 * 1024) {      // keep it small: drop the older half
            NSData *all = [NSData dataWithContentsOfFile:path];
            [[all subdataWithRange:NSMakeRange(all.length / 2, all.length - all.length / 2)] writeToFile:path atomically:YES];
        }
#endif
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    });
}

void AtelierAfter(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

#pragma mark - careful messaging

static const char *AtelierBareType(const char *t) {          // skip const / in / out / oneway…
    while (t && *t && strchr("rnNoORV", *t)) t++;
    return t;
}

// The method exists, takes `args` arguments and returns one of the types in `returns`
// (Objective-C type codes: v void, @ object, B BOOL, q long long…).
BOOL AtelierShape(id target, SEL sel, const char *returns, NSUInteger args) {
    if (!target || !sel) return NO;
    @try {
        if (![target respondsToSelector:sel]) return NO;
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != args + 2) return NO;
        const char *r = AtelierBareType(sig.methodReturnType);
        return r && *r && strchr(returns, *r) != NULL;
    } @catch (__unused id e) {}
    return NO;
}

BOOL AtelierArgIs(id target, SEL sel, NSUInteger index, const char *types) {
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments <= index) return NO;
        const char *t = AtelierBareType([sig getArgumentTypeAtIndex:index]);
        return t && *t && strchr(types, *t) != NULL;
    } @catch (__unused id e) {}
    return NO;
}

// Return types that come back in a register, so the result can simply be ignored.
static const char *const kAtelierPlainReturns = "v@#BcCqQiIlLsSfd";

id AtelierMsg(id target, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, "@#", 0)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, s); } @catch (__unused id e) {}
    return nil;
}

id AtelierMsgObj(id target, NSString *selName, id arg) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, "@#", 1) || !AtelierArgIs(target, s, 2, "@#")) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(target, s, arg); } @catch (NSException *e) { AtelierLog(@"%@ threw %@", selName, e.reason); }
    return nil;
}

BOOL AtelierBoolMsg(id target, NSString *selName, BOOL fallback) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, "Bc", 0)) return fallback;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(target, s); } @catch (__unused id e) {}
    return fallback;
}

long long AtelierIntMsg(id target, NSString *selName, long long fallback) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, "qQiIlLsSBc", 0)) return fallback;
    @try {
        const char *r = AtelierBareType([target methodSignatureForSelector:s].methodReturnType);
        switch (*r) {
            case 'q': case 'Q': return ((long long (*)(id, SEL))objc_msgSend)(target, s);
            case 'i': case 'I': case 'l': case 'L': return ((int (*)(id, SEL))objc_msgSend)(target, s);
            case 's': case 'S': return ((short (*)(id, SEL))objc_msgSend)(target, s);
            default: return ((BOOL (*)(id, SEL))objc_msgSend)(target, s) ? 1 : 0;
        }
    } @catch (__unused id e) {}
    return fallback;
}

BOOL AtelierSend(id target, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, kAtelierPlainReturns, 0)) return NO;
    @try { ((void (*)(id, SEL))objc_msgSend)(target, s); return YES; } @catch (NSException *e) { AtelierLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL AtelierSendBool(id target, NSString *selName, BOOL arg) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, kAtelierPlainReturns, 1) || !AtelierArgIs(target, s, 2, "Bc")) return NO;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(target, s, arg); return YES; } @catch (NSException *e) { AtelierLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL AtelierSendInt(id target, NSString *selName, long long arg) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, kAtelierPlainReturns, 1) || !AtelierArgIs(target, s, 2, "qQiIlL")) return NO;
    @try {
        const char *t = AtelierBareType([[target methodSignatureForSelector:s] getArgumentTypeAtIndex:2]);
        if (*t == 'q' || *t == 'Q') ((void (*)(id, SEL, long long))objc_msgSend)(target, s, arg);
        else ((void (*)(id, SEL, int))objc_msgSend)(target, s, (int)arg);
        return YES;
    } @catch (NSException *e) { AtelierLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL AtelierSendObj(id target, NSString *selName, id arg) {
    SEL s = NSSelectorFromString(selName);
    if (!AtelierShape(target, s, kAtelierPlainReturns, 1) || !AtelierArgIs(target, s, 2, "@#")) return NO;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, s, arg); return YES; } @catch (NSException *e) { AtelierLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

// SpringBoard's shared controller of a class. Where the class can say whether its controller
// exists yet, it is asked that way, so Atelier never creates one of SpringBoard's own controllers
// before SpringBoard has.
id AtelierSingleton(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    if ([cls respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")]) return AtelierMsg(cls, @"sharedInstanceIfExists");
    return AtelierMsg(cls, @"sharedInstance");
}

// A method replaced with the Objective-C runtime alone. The same few calls a hooking library
// makes for a message hook; doing it here means the simulator build is the same code, and the
// dylib links nothing but iOS's own libraries.
BOOL AtelierHook(NSString *className, NSString *selName, BOOL classMethod, IMP replacement, IMP *original) {
    Class c = NSClassFromString(className);
    if (classMethod && c) c = object_getClass(c);
    SEL s = NSSelectorFromString(selName);
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) {
        AtelierLog(@"hook skipped: %@%@ %@ not found", classMethod ? @"+" : @"-", className, selName);
        return NO;
    }
    *original = method_getImplementation(m);
    // an inherited method gets an override on this class; its own method gets the new code
    if (!class_addMethod(c, s, replacement, method_getTypeEncoding(m))) {
        Method own = class_getInstanceMethod(c, s);
        *original = method_setImplementation(own, replacement);
    }
    return YES;
}

// One letter for what a type is, so that a method can be compared with what it is expected to be.
static char AtelierTypeKind(const char *type) {
    const char *t = AtelierBareType(type);
    if (!t || !*t) return '?';
    switch (*t) {
        case '@': case '#': return '@';
        case 'd': case 'f': return 'd';
        case 'q': case 'Q': case 'i': case 'I': case 'l': case 'L': case 's': case 'S': return 'q';
        case 'B': case 'c': case 'C': return 'B';
        default: return *t;
    }
}

BOOL AtelierHookShaped(NSString *className, NSString *selName, const char *shape, IMP replacement, IMP *original,
                       NSString *__autoreleasing *why) {
    Class c = NSClassFromString(className);
    SEL s = NSSelectorFromString(selName);
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) {
        if (why) *why = c ? @"this iOS has the class but not the method" : @"this iOS has no such class";
        return NO;
    }
    NSMutableString *is = [NSMutableString string];
    char *returns = method_copyReturnType(m);
    [is appendFormat:@"%c", AtelierTypeKind(returns)];
    free(returns);
    unsigned int count = method_getNumberOfArguments(m);         // self and _cmd are the first two
    for (unsigned int i = 2; i < count; i++) {
        char *arg = method_copyArgumentType(m, i);
        [is appendFormat:@"%c", AtelierTypeKind(arg)];
        free(arg);
    }
    size_t want = strlen(shape);
    BOOL fits = is.length == want;
    for (NSUInteger i = 0; fits && i < want; i++) {
        if (shape[i] != '?' && shape[i] != (char)[is characterAtIndex:i]) fits = NO;
    }
    if (!fits) {
        if (why) *why = [NSString stringWithFormat:@"it looks different on this iOS (%@, expected %s): left alone", is, shape];
        return NO;
    }
    return AtelierHook(className, selName, NO, replacement, original);
}

#pragma mark - haptics

void AtelierHapticPlay(AtelierHaptic kind) {
    NSInteger level = [AtelierSettings shared].haptics;
    if (level <= 0) return;
    @try {
        if (kind == AtelierHapticTick) {
            static UISelectionFeedbackGenerator *tick;
            if (!tick) tick = [UISelectionFeedbackGenerator new];
            [tick selectionChanged];
            return;
        }
        UIImpactFeedbackStyle style = UIImpactFeedbackStyleLight;
        if (level == 2) style = UIImpactFeedbackStyleMedium;
        if (level >= 3) style = UIImpactFeedbackStyleHeavy;
        if (kind == AtelierHapticOpen && level == 1) style = UIImpactFeedbackStyleMedium;
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:style] impactOccurred];
    } @catch (__unused id e) {}
}

#pragma mark - settings

@implementation AtelierSettings {
    NSDictionary *_p;
}

+ (instancetype)shared {
    static AtelierSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [AtelierSettings new]; s->_p = @{}; });
    return s;
}

- (BOOL)_b:(NSString *)k def:(BOOL)d { id v = _p[k]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : d; }
- (double)_d:(NSString *)k def:(double)d { id v = _p[k]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d; }

- (void)reload {
    CFStringRef dom = (__bridge CFStringRef)ATELIER_DOMAIN;
    CFPreferencesAppSynchronize(dom);
    NSDictionary *d = nil;
    CFArrayRef keys = CFPreferencesCopyKeyList(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        d = CFBridgingRelease(CFPreferencesCopyMultiple(keys, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        CFRelease(keys);
    }
    _p = [d isKindOfClass:NSDictionary.class] ? d : @{};
    atomic_store(&gAtelierDebugLog, (bool)self.debugLog);
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (key.length == 0) return;
    CFStringRef dom = (__bridge CFStringRef)ATELIER_DOMAIN;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, dom);
    CFPreferencesAppSynchronize(dom);
    NSMutableDictionary *m = [_p mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) m[key] = value; else [m removeObjectForKey:key];
    _p = m;
    atomic_store(&gAtelierDebugLog, (bool)self.debugLog);
}

static NSInteger AtelierClampInt(double v, NSInteger lo, NSInteger hi, NSInteger fallback) {
    NSInteger i = (NSInteger)v;
    return (i >= lo && i <= hi) ? i : fallback;
}

- (BOOL)enabled                        { return [self _b:@"enabled" def:YES]; }
- (AtelierLayoutKind)defaultLayout     { return (AtelierLayoutKind)AtelierClampInt([self _d:@"defaultLayout" def:0], 0, 2, 0); }
- (AtelierMiniMode)miniMode            { return (AtelierMiniMode)AtelierClampInt([self _d:@"miniMode" def:0], 0, 2, 0); }
- (double)freezeAfter                  { return MAX(5.0, MIN(120.0, [self _d:@"freezeAfter" def:20.0])); }
- (BOOL)trigger                        { return [self _b:@"trigger" def:YES]; }
- (NSInteger)triggerSide               { return AtelierClampInt([self _d:@"triggerSide" def:1], 0, 1, 1); }
- (CGFloat)triggerSize                 { return MAX(60, MIN(220, [self _d:@"triggerSize" def:110])); }
- (NSInteger)triggerMode               { return AtelierClampInt([self _d:@"triggerMode" def:0], 0, 1, 0); }
- (BOOL)showHandle                     { return [self _b:@"showHandle" def:YES]; }
- (BOOL)addFront                       { return [self _b:@"addFront" def:YES]; }
- (BOOL)makeRoom                       { return [self _b:@"makeRoom" def:YES]; }
- (BOOL)resizeApps                     { return [self _b:@"resizeApps" def:NO]; }
- (BOOL)iconMenu                       { return [self _b:@"iconMenu" def:YES]; }
- (NSInteger)haptics                   { return AtelierClampInt([self _d:@"haptics" def:1], 0, 3, 1); }
- (BOOL)debugLog                       { return [self _b:@"debugLog" def:YES]; }
- (BOOL)showClock                      { return [self _b:@"showClock" def:YES]; }
- (BOOL)showMarkets                    { return [self _b:@"showMarkets" def:YES]; }
- (BOOL)showIndices                    { return [self _b:@"showIndices" def:YES]; }
- (void)setShortcutApps:(NSArray<NSString *> *)apps { [self setObject:(apps ?: @[]) forKey:@"shortcutApps"]; }

- (BOOL)showsToggle:(NSString *)key {
    static NSDictionary<NSString *, NSString *> *names;
    if (!names) names = @{ @"wifi": @"toggleWifi", @"bluetooth": @"toggleBluetooth", @"data": @"toggleData",
                           @"dnd": @"toggleDND", @"awake": @"toggleAwake", @"lowpower": @"toggleLowPower" };
    NSString *name = names[key ?: @""];
    return name ? [self _b:name def:YES] : NO;
}
- (AtelierSwipeDown)swipeDown          { return (AtelierSwipeDown)AtelierClampInt([self _d:@"swipeDown" def:0], 0, 3, 0); }

- (NSArray<NSString *> *)markets {
    NSArray<NSString *> *fallback = @[ @"IN", @"GB", @"US" ];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        id v = _p[[NSString stringWithFormat:@"market%lu", (unsigned long)(i + 1)]];
        [out addObject:([v isKindOfClass:NSString.class] && [v length] == 2) ? [v uppercaseString] : fallback[i]];
    }
    return out;
}

- (NSString *)extraHolidays {
    id v = _p[@"extraHolidays"];
    return [v isKindOfClass:NSString.class] ? v : @"";
}

// AltList's list saves the bundle ids that are switched on, as an array.
- (NSArray<NSString *> *)shortcutApps {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    id raw = _p[@"shortcutApps"];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id bid in (NSArray *)raw) {
        if (![bid isKindOfClass:NSString.class] || [bid length] == 0 || [out containsObject:bid]) continue;
        [out addObject:bid];
    }
    return out;
}

- (NSArray<NSString *> *)lockedApps {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    id raw = _p[@"locked"];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id bid in (NSArray *)raw) if ([bid isKindOfClass:NSString.class] && [bid length] && ![out containsObject:bid]) [out addObject:bid];
    return out;
}
- (void)setLockedApps:(NSArray<NSString *> *)apps { [self setObject:(apps ?: @[]) forKey:@"locked"]; }
- (double)tune:(NSString *)key fallback:(double)fallback { return [self _d:key def:fallback]; }

static NSArray<NSString *> *AtelierCleanApps(id raw) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id bid in (NSArray *)raw) {
        if (![bid isKindOfClass:NSString.class] || [bid length] == 0 || [out containsObject:bid]) continue;
        if (out.count >= ATELIER_MAX_SLOTS) break;
        [out addObject:bid];
    }
    return out;
}

- (NSArray<NSString *> *)slots { return AtelierCleanApps(_p[@"slots"]); }
- (void)setSlots:(NSArray<NSString *> *)slots { [self setObject:AtelierCleanApps(slots) forKey:@"slots"]; }

- (AtelierLayoutKind)layout {
    id v = _p[@"layout"];
    if (![v respondsToSelector:@selector(integerValue)]) return self.defaultLayout;
    return (AtelierLayoutKind)AtelierClampInt([v doubleValue], 0, 2, self.defaultLayout);
}
- (void)setLayout:(AtelierLayoutKind)layout { [self setObject:@((NSInteger)layout) forKey:@"layout"]; }

- (NSArray<NSDictionary *> *)sets {
    NSMutableArray *out = [NSMutableArray array];
    id raw = _p[@"sets"];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id d in (NSArray *)raw) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        NSArray<NSString *> *apps = AtelierCleanApps(d[@"apps"]);
        if (apps.count < 2) continue;
        NSString *name = [d[@"name"] isKindOfClass:NSString.class] ? d[@"name"] : @"";
        NSInteger layout = AtelierClampInt([d[@"layout"] respondsToSelector:@selector(doubleValue)] ? [d[@"layout"] doubleValue] : 0, 0, 2, 0);
        [out addObject:@{ @"name": name, @"apps": apps, @"layout": @(layout) }];
    }
    return out;
}
- (void)setSets:(NSArray<NSDictionary *> *)sets { [self setObject:(sets ?: @[]) forKey:@"sets"]; }

@end

#pragma mark - windows

@implementation AtelierPortraitController
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }
- (BOOL)prefersHomeIndicatorAutoHidden { return NO; }
@end

@implementation AtelierWindow

// UIKit asks this before making a window key. Atelier's windows have no text fields, and the
// key window is where SpringBoard's keyboard focus goes: it has to stay where it was.
- (BOOL)_canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeKeyWindow { return NO; }

- (void)sendEvent:(UIEvent *)event {
    if (self.onTouch && event.type == UIEventTypeTouches) {
        for (UITouch *t in event.allTouches) {
            if (t.phase == UITouchPhaseBegan) { self.onTouch(); break; }
        }
    }
    [super sendEvent:event];
}

@end

@implementation AtelierKeyWindow
- (BOOL)_canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeKeyWindow { return YES; }
@end

#pragma mark - SpringBoard helpers

@implementation AtelierHost

#pragma mark keyboard focus

// With an app in front, iOS 16 sends the keyboard to that app: a text field in a SpringBoard
// window becomes first responder and no keyboard appears. SpringBoard's keyboard focus
// controller has two calls that let one of SpringBoard's own windows have it; each returns an
// object, the hold, which is invalidated to give the keyboard back. This is the recipe Wingman
// Plus has used on this phone since 1.0.24 (WPFocus.m), with its hard-won rule: only for a
// window in SpringBoard's main scene. Given the Dynamic Island's scene the second call does not
// throw, it traps, and SpringBoard restarts.
static NSMutableArray *gFocusHolds;

static id AtelierFocusController(void) {
    NSMutableArray *hosts = [NSMutableArray array];
    if (UIApplication.sharedApplication) [hosts addObject:UIApplication.sharedApplication];
    for (NSString *name in @[ @"SBMainWorkspace", @"SBWorkspace" ]) {
        Class c = NSClassFromString(name);
        for (NSString *getter in @[ @"sharedInstance", @"mainWorkspace" ]) {
            id o = AtelierMsg(c, getter);
            if (o) [hosts addObject:o];
        }
    }
    for (id host in hosts) {
        id controller = AtelierMsg(host, @"keyboardFocusController");
        if (controller) return controller;
    }
    return AtelierMsg(NSClassFromString(@"SBWorkspaceKeyboardFocusController"), @"sharedInstance");
}

+ (BOOL)takeKeyboardForWindow:(UIWindow *)window {
    [self giveKeyboardBack];                             // never two sets of holds
    if (!window) return NO;
    UIWindowScene *scene = window.windowScene;
    Class main = NSClassFromString(@"SBWindowScene");
    if (!scene || !main || [scene class] != main || scene != [self mainScene]) {
        AtelierLog(@"keyboard: left alone, the window is not in SpringBoard's main scene (%@)", scene ? NSStringFromClass([scene class]) : @"none");
        return NO;
    }
    id controller = AtelierFocusController();
    if (!controller) { AtelierLog(@"keyboard: no focus controller on this iOS"); return NO; }
    gFocusHolds = [NSMutableArray array];
    NSMutableArray<NSString *> *said = [NSMutableArray array];
    NSArray<NSArray *> *tries = @[ @[ @"requestFocusStealingForSpringBoardWindow:forReason:", window ],
                                   @[ @"lockFocusToSpringBoardWindowScene:forReason:", scene ] ];
    for (NSArray *t in tries) {
        SEL s = NSSelectorFromString(t[0]);
        // only a call that takes two objects and returns one: the object is what is released later
        if (!AtelierShape(controller, s, "@", 2) || !AtelierArgIs(controller, s, 2, "@") || !AtelierArgIs(controller, s, 3, "@")) {
            [said addObject:[NSString stringWithFormat:@"%@ not there", t[0]]];
            continue;
        }
        id hold = nil;
        @try { hold = ((id (*)(id, SEL, id, id))objc_msgSend)(controller, s, t[1], @"HyperTradePicker"); }
        @catch (NSException *e) { [said addObject:[NSString stringWithFormat:@"%@ threw %@", t[0], e.reason]]; continue; }
        [said addObject:[NSString stringWithFormat:@"%@ -> %@", t[0], hold ? NSStringFromClass([hold class]) : @"nil"]];
        if (hold) [gFocusHolds addObject:hold];
    }
    AtelierLog(@"keyboard: taken for %@ (%@)", NSStringFromClass([window class]), [said componentsJoinedByString:@" · "]);
    return gFocusHolds.count > 0;
}

+ (void)giveKeyboardBack {
    NSArray *holds = gFocusHolds;
    gFocusHolds = nil;
    if (holds.count == 0) return;
    NSUInteger ended = 0;
    for (id hold in holds) if (AtelierSend(hold, @"invalidate")) ended++;
    AtelierLog(@"keyboard: given back (%lu of %lu holds released)", (unsigned long)ended, (unsigned long)holds.count);
}

#pragma mark SporeX's hidden apps

// SporeX keeps its switch and its list in its own settings: `Enabled` and `HiddenApps` (bundle
// ids as an array, or as a dictionary of id -> YES). Only the settings are read; nothing of
// SporeX's is called. No SporeX, or SporeX switched off: nothing is hidden.
static NSSet<NSString *> *gHiddenApps;

+ (void)reloadHiddenApps {
    NSMutableSet<NSString *> *hidden = [NSMutableSet set];
    @try {
        CFStringRef domain = CFSTR("com.adarsh.sporex");
        CFPreferencesAppSynchronize(domain);
        id enabled = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Enabled"), domain));
        id list = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("HiddenApps"), domain));
        // a list without the switch counts as switched on: showing a hidden app is the worse mistake
        BOOL on = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : (list != nil);
        if (on && [list isKindOfClass:NSArray.class]) {
            for (id bid in (NSArray *)list) if ([bid isKindOfClass:NSString.class] && [bid length]) [hidden addObject:bid];
        } else if (on && [list isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)list enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                if (![key isKindOfClass:NSString.class] || [key length] == 0) return;
                if (![value respondsToSelector:@selector(boolValue)] || [value boolValue]) [hidden addObject:key];
            }];
        }
    } @catch (NSException *e) {
        AtelierLog(@"SporeX settings threw %@", e.reason);
    }
    if (![hidden isEqualToSet:gHiddenApps ?: [NSSet set]]) AtelierLog(@"hidden apps (SporeX): %lu", (unsigned long)hidden.count);   // the count only: their names stay out of the log
    gHiddenApps = hidden;
}

+ (BOOL)isHiddenApp:(NSString *)bid {
    if (!gHiddenApps) [self reloadHiddenApps];
    return bid.length && [gHiddenApps containsObject:bid];
}

// Is this one of the apps people mean by "social media"? The well-known ones by bundle id, and
// whatever the App Store files under Social Networking. Used for one thing only: choosing what a
// full bench lets go of.
+ (BOOL)isSocialApp:(NSString *)bid {
    if (bid.length == 0) return NO;
    static NSSet<NSString *> *known;
    static NSMutableDictionary<NSString *, NSNumber *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = [NSSet setWithArray:@[
            @"net.whatsapp.whatsapp", @"net.whatsapp.whatsappsmb", @"ph.telegra.telegraph", @"org.whispersystems.signal",
            @"com.atebits.tweetie2", @"com.reddit.reddit", @"com.burbn.instagram", @"com.burbn.barcelona",
            @"com.facebook.facebook", @"com.facebook.messenger", @"com.toyopagroup.picaboo", @"com.linkedin.linkedin",
            @"com.hammerandchisel.discord", @"com.zhiliaoapp.musically", @"pinterest", @"com.tumblr.tumblr",
            @"xyz.blueskyweb.app", @"org.joinmastodon.app", @"com.tencent.xin", @"jp.naver.line", @"com.viber",
            @"com.christianselig.apollo",
        ]];
        seen = [NSMutableDictionary dictionary];
    });
    NSNumber *hit = seen[bid];
    if (hit) return hit.boolValue;
    BOOL social = [known containsObject:bid.lowercaseString];
    if (!social) {
        // the App Store's genre for the app, where it has one (6005 is Social Networking); the return
        // type is read first, so an object is never taken for a number or the other way round
        @try {
            Class cls = NSClassFromString(@"LSApplicationProxy");
            SEL make = NSSelectorFromString(@"applicationProxyForIdentifier:");
            id proxy = [cls respondsToSelector:make] ? ((id (*)(id, SEL, id))objc_msgSend)(cls, make, bid) : nil;
            SEL genre = NSSelectorFromString(@"genreID");
            Method m = proxy ? class_getInstanceMethod(object_getClass(proxy), genre) : NULL;
            if (m) {
                char type[8] = { 0 };
                method_getReturnType(m, type, sizeof(type));
                long long g = 0;
                if (type[0] == '@') {
                    id v = ((id (*)(id, SEL))objc_msgSend)(proxy, genre);
                    if ([v respondsToSelector:@selector(longLongValue)]) g = [v longLongValue];
                } else if (type[0] == 'q' || type[0] == 'Q') {
                    g = ((long long (*)(id, SEL))objc_msgSend)(proxy, genre);
                } else if (type[0] == 'i' || type[0] == 'I') {
                    g = ((int (*)(id, SEL))objc_msgSend)(proxy, genre);
                }
                social = (g == 6005);
            }
        } @catch (__unused id e) {}
    }
    seen[bid] = @(social);
    return social;
}

+ (NSUInteger)hiddenAppCount {
    if (!gHiddenApps) [self reloadHiddenApps];
    return gHiddenApps.count;
}

#pragma mark windows

static NSMutableArray<NSString *> *gRecent;       // apps seen in front, newest first (main thread)

+ (AtelierWindow *)windowAtLevel:(UIWindowLevel)level {
    return [self windowAtLevel:level key:NO];
}

+ (AtelierWindow *)windowAtLevel:(UIWindowLevel)level key:(BOOL)key {
    CGSize sz = [self screenSize];
    CGRect screen = CGRectMake(0, 0, sz.width, sz.height);
    UIWindowScene *scene = [self mainScene];
    Class cls = key ? AtelierKeyWindow.class : AtelierWindow.class;
    AtelierWindow *w = scene ? [[cls alloc] initWithWindowScene:scene] : [[cls alloc] initWithFrame:screen];
    w.frame = screen;
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    w.opaque = NO;
    w.rootViewController = [AtelierPortraitController new];
    w.rootViewController.view.backgroundColor = UIColor.clearColor;
    w.hidden = YES;
    return w;
}

// Same ranking Wingman Plus, Dynamic Stage+ and Chakra settled on: on Dynamic Island phones
// SpringBoard has a second foreground scene, and a window put there does not show.
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
    id mgr = AtelierSingleton(@"SBLockScreenManager");
    if (AtelierShape(mgr, NSSelectorFromString(@"isUILocked"), "Bc", 0)) return AtelierBoolMsg(mgr, @"isUILocked", NO);
    return AtelierBoolMsg(UIApplication.sharedApplication, @"isLocked", NO);
}

+ (BOOL)switcherVisible {
    return AtelierBoolMsg(AtelierSingleton(@"SBMainSwitcherControllerCoordinator"), @"isAnySwitcherVisible", NO);
}

+ (NSString *)frontmostBundleID {
    @try {
        id front = AtelierMsg(UIApplication.sharedApplication, @"_accessibilityFrontMostApplication");
        NSString *bid = AtelierMsg(front, @"bundleIdentifier");
        return ([bid isKindOfClass:NSString.class] && bid.length) ? bid : nil;
    } @catch (__unused id e) {}
    return nil;
}

+ (id)applicationForBundleID:(NSString *)bid {
    if (bid.length == 0) return nil;
    return AtelierMsgObj(AtelierSingleton(@"SBApplicationController"), @"applicationWithBundleIdentifier:", bid);
}

+ (int)pidOfApplication:(id)app {
    id state = AtelierMsg(app, @"processState");
    return state ? (int)AtelierIntMsg(state, @"pid", 0) : 0;
}

+ (NSString *)displayNameForBundleID:(NSString *)bid {
    NSString *n = AtelierMsg([self applicationForBundleID:bid], @"displayName");
    if ([n isKindOfClass:NSString.class] && n.length) return n;
    for (NSDictionary *a in [self installedApps]) if ([a[@"id"] isEqualToString:bid]) return a[@"name"];
    return bid ?: @"";
}

+ (UIImage *)iconForBundleID:(NSString *)bid {
    static NSCache<NSString *, UIImage *> *cache;
    if (!cache) cache = [NSCache new];
    if (bid.length == 0) return nil;
    UIImage *hit = [cache objectForKey:bid];
    if (hit) return hit;
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:s]) return nil;
    @try {
        // format 2 = the 60 pt Home Screen icon, already masked
        UIImage *img = ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)(UIImage.class, s, bid, 2, UIScreen.mainScreen.scale);
        if (img) [cache setObject:img forKey:bid];
        return img;
    } @catch (__unused id e) {}
    return nil;
}

+ (BOOL)launchApp:(NSString *)bid suspended:(BOOL)suspended {
    if (bid.length == 0) return NO;
    UIApplication *app = UIApplication.sharedApplication;
    SEL s = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (!AtelierShape(app, s, "Bc", 2)) return NO;
    @try { return ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, s, bid, suspended); } @catch (NSException *e) { AtelierLog(@"launch %@ threw %@", bid, e.reason); }
    return NO;
}

+ (void)toast:(NSString *)message {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGSize sz = [AtelierHost screenSize];
        UILabel *t = [UILabel new];
        t.text = message;
        t.textColor = UIColor.whiteColor;
        t.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        t.textAlignment = NSTextAlignmentCenter;
        t.numberOfLines = 0;
        t.layer.cornerRadius = 14;
        t.clipsToBounds = YES;
        CGSize fit = [t sizeThatFits:CGSizeMake(sz.width - 94, 200)];
        CGFloat w = MIN(sz.width - 60, fit.width + 34), h = fit.height + 22;
        t.frame = CGRectMake((sz.width - w) / 2.0, [AtelierHost safeInsets].top + 14, w, h);
        AtelierWindow *win = [AtelierHost windowAtLevel:100030];
        win.userInteractionEnabled = NO;
        [win.rootViewController.view addSubview:t];
        win.hidden = NO;
        t.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ t.alpha = 1; }];
        AtelierAfter(2.4, ^{
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
        id ws = AtelierMsg(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        for (id p in (NSArray *)AtelierMsg(ws, @"allApplications")) {
            NSString *bid = AtelierMsg(p, @"applicationIdentifier");
            NSString *nm = AtelierMsg(p, @"localizedName");
            NSString *type = AtelierMsg(p, @"applicationType");
            if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
            NSArray *tags = AtelierMsg(p, @"appTags");
            if ([tags isKindOfClass:NSArray.class] && [tags containsObject:@"hidden"]) continue;
            // App Store apps are "User"; TrollStore apps register as "System" but are never com.apple.*.
            // Of Apple's own, keep the ones that have a Home Screen icon (no view services, no daemons' apps).
            if ([bid hasPrefix:@"com.apple."] && ![type isEqualToString:@"User"]) {
                id app = [self applicationForBundleID:bid];
                if (!app) continue;
                if (AtelierBoolMsg(AtelierMsg(app, @"info"), @"hasHiddenTag", NO)) continue;
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

+ (NSArray<NSDictionary *> *)listedApps {
    NSArray<NSDictionary *> *all = [self installedApps];
    if ([self hiddenAppCount] == 0) return all;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:all.count];
    for (NSDictionary *a in all) if (![self isHiddenApp:a[@"id"]]) [out addObject:a];
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

// Apps Atelier has seen in front, then the App Switcher's own list (bundle ids, each once).
+ (NSArray<NSString *> *)recentApps {
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithArray:gRecent ?: @[]];
    @try {
        NSArray *layouts = AtelierMsg(AtelierSingleton(@"SBMainSwitcherControllerCoordinator"), @"recentAppLayouts");
        if ([layouts isKindOfClass:NSArray.class]) {
            for (id layout in layouts) {
                NSArray *items = AtelierMsg(layout, @"allItems");
                if (![items isKindOfClass:NSArray.class]) continue;
                for (id item in items) {
                    NSString *bid = AtelierMsg(item, @"bundleIdentifier");
                    if ([bid isKindOfClass:NSString.class] && bid.length && ![out containsObject:bid]) [out addObject:bid];
                }
                if (out.count >= 12) break;
            }
        }
    } @catch (__unused id e) {}
    if ([self hiddenAppCount]) {
        NSMutableArray<NSString *> *shown = [NSMutableArray array];
        for (NSString *bid in out) if (![self isHiddenApp:bid]) [shown addObject:bid];
        return shown;
    }
    return out;
}

+ (UIImage *)screenImage {
    typedef void *(*RotFn)(long);
    typedef void *(*PlainFn)(void);
    static RotFn rot;
    static PlainFn plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rot = (RotFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImageWithRotation");
        plain = (PlainFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    });
    @try {
        void *owned = rot ? rot(0) : (plain ? plain() : NULL);
        return (__bridge_transfer UIImage *)owned;
    } @catch (__unused id e) {}
    return nil;
}

@end
