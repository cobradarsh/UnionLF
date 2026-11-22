/*  ShaniCore.m — debug log, careful messaging, settings, the hook helper.  */

#import "Shani.h"
#import <stdatomic.h>

static _Atomic(bool) gShaniDebugLog = true;
static _Atomic(long long) gShaniClockShift = 0;          // milliseconds; tests only

#pragma mark - log

static dispatch_queue_t ShaniLogQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.adarsh.shani.log", DISPATCH_QUEUE_SERIAL); });
    return q;
}

void ShaniLogFlush(void) {
    dispatch_sync(ShaniLogQueue(), ^{});
}

// Never notification text: only what Shani did, to which app.
void ShaniLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!atomic_load(&gShaniDebugLog)) return;

    static NSDateFormatter *df;
    static NSString *path, *who;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        path = [ShaniLogDir() stringByAppendingPathComponent:@"Shani.log"];
        // ShaniPrefs.dylib writes to the same file from the Settings app
        who = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"] ? @"[Settings] " : @"";
    });
    NSDate *now = [NSDate date];
    dispatch_async(ShaniLogQueue(), ^{
        NSString *line = [NSString stringWithFormat:@"%@  %@%@\n", [df stringFromDate:now], who, msg.length > 1400 ? [msg substringToIndex:1400] : msg];
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

void ShaniAfter(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

double ShaniNow(void) {
    return [[NSDate date] timeIntervalSince1970] + (double)atomic_load(&gShaniClockShift) / 1000.0;
}

void ShaniDebugShiftClock(double seconds) {
    atomic_fetch_add(&gShaniClockShift, (long long)(seconds * 1000.0));
}

#pragma mark - careful messaging

static const char *ShaniBareType(const char *t) {          // skip const / in / out / oneway…
    while (t && *t && strchr("rnNoORV", *t)) t++;
    return t;
}

// The method exists, takes `args` arguments and returns one of the types in `returns`
// (Objective-C type codes: v void, @ object, B BOOL, q long long…).
BOOL ShaniShape(id target, SEL sel, const char *returns, NSUInteger args) {
    if (!target || !sel) return NO;
    @try {
        if (![target respondsToSelector:sel]) return NO;
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != args + 2) return NO;
        const char *r = ShaniBareType(sig.methodReturnType);
        return r && *r && strchr(returns, *r) != NULL;
    } @catch (__unused id e) {}
    return NO;
}

BOOL ShaniArgIs(id target, SEL sel, NSUInteger index, const char *types) {
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments <= index) return NO;
        const char *t = ShaniBareType([sig getArgumentTypeAtIndex:index]);
        return t && *t && strchr(types, *t) != NULL;
    } @catch (__unused id e) {}
    return NO;
}

// Return types that come back in a register, so the result can simply be ignored.
static const char *const kShaniPlainReturns = "v@#BcCqQiIlLsSfd";

id ShaniMsg(id target, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, "@#", 0)) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, s); } @catch (__unused id e) {}
    return nil;
}

id ShaniMsgObj(id target, NSString *selName, id arg) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, "@#", 1) || !ShaniArgIs(target, s, 2, "@#")) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(target, s, arg); } @catch (NSException *e) { ShaniLog(@"%@ threw %@", selName, e.reason); }
    return nil;
}

NSString *ShaniStr(id target, NSString *selName) {
    id v = ShaniMsg(target, selName);
    return [v isKindOfClass:NSString.class] ? v : nil;
}

BOOL ShaniBoolMsg(id target, NSString *selName, BOOL fallback) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, "Bc", 0)) return fallback;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(target, s); } @catch (__unused id e) {}
    return fallback;
}

long long ShaniIntMsg(id target, NSString *selName, long long fallback) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, "qQiIlLsSBc", 0)) return fallback;
    @try {
        const char *r = ShaniBareType([target methodSignatureForSelector:s].methodReturnType);
        switch (*r) {
            case 'q': case 'Q': return ((long long (*)(id, SEL))objc_msgSend)(target, s);
            case 'i': case 'I': case 'l': case 'L': return ((int (*)(id, SEL))objc_msgSend)(target, s);
            case 's': case 'S': return ((short (*)(id, SEL))objc_msgSend)(target, s);
            default: return ((BOOL (*)(id, SEL))objc_msgSend)(target, s) ? 1 : 0;
        }
    } @catch (__unused id e) {}
    return fallback;
}

BOOL ShaniSend(id target, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, kShaniPlainReturns, 0)) return NO;
    @try { ((void (*)(id, SEL))objc_msgSend)(target, s); return YES; } @catch (NSException *e) { ShaniLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL ShaniSendBool(id target, NSString *selName, BOOL arg) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, kShaniPlainReturns, 1) || !ShaniArgIs(target, s, 2, "Bc")) return NO;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(target, s, arg); return YES; } @catch (NSException *e) { ShaniLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL ShaniSendInt(id target, NSString *selName, long long arg) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, kShaniPlainReturns, 1) || !ShaniArgIs(target, s, 2, "qQiIlL")) return NO;
    @try {
        const char *t = ShaniBareType([[target methodSignatureForSelector:s] getArgumentTypeAtIndex:2]);
        if (*t == 'q' || *t == 'Q') ((void (*)(id, SEL, long long))objc_msgSend)(target, s, arg);
        else ((void (*)(id, SEL, int))objc_msgSend)(target, s, (int)arg);
        return YES;
    } @catch (NSException *e) { ShaniLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

BOOL ShaniSendObj(id target, NSString *selName, id arg) {
    SEL s = NSSelectorFromString(selName);
    if (!ShaniShape(target, s, kShaniPlainReturns, 1) || !ShaniArgIs(target, s, 2, "@#")) return NO;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(target, s, arg); return YES; } @catch (NSException *e) { ShaniLog(@"%@ threw %@", selName, e.reason); }
    return NO;
}

// An instance method replaced with the Objective-C runtime alone: the same few calls a hooking
// library makes for a message hook. Doing it here means the simulator build is the same code,
// and the library links nothing but iOS's own libraries.
BOOL ShaniHook(NSString *className, NSString *selName, IMP replacement, IMP *original) {
    Class c = NSClassFromString(className);
    SEL s = NSSelectorFromString(selName);
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) {
        ShaniLog(@"hook skipped: -[%@ %@] not found", className, selName);
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

#pragma mark - settings

@implementation ShaniSettings {
    NSDictionary *_p;
}

+ (instancetype)shared {
    static ShaniSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ShaniSettings new]; s->_p = @{}; });
    return s;
}

// The hooks may run off the main thread: every read takes the dictionary as it is at that moment.
- (NSDictionary *)_now { @synchronized (self) { return _p; } }
- (BOOL)_b:(NSString *)k def:(BOOL)d { id v = [self _now][k]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : d; }
- (double)_d:(NSString *)k def:(double)d { id v = [self _now][k]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d; }

- (void)reload {
    CFStringRef dom = (__bridge CFStringRef)SHANI_DOMAIN;
    CFPreferencesAppSynchronize(dom);
    NSDictionary *d = nil;
    CFArrayRef keys = CFPreferencesCopyKeyList(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        d = CFBridgingRelease(CFPreferencesCopyMultiple(keys, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        CFRelease(keys);
    }
    @synchronized (self) { _p = [d isKindOfClass:NSDictionary.class] ? d : @{}; }
    atomic_store(&gShaniDebugLog, (bool)self.debugLog);
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (key.length == 0) return;
    CFStringRef dom = (__bridge CFStringRef)SHANI_DOMAIN;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, dom);
    CFPreferencesAppSynchronize(dom);
    @synchronized (self) {
        NSMutableDictionary *m = [_p mutableCopy] ?: [NSMutableDictionary dictionary];
        if (value) m[key] = value; else [m removeObjectForKey:key];
        _p = m;
    }
    atomic_store(&gShaniDebugLog, (bool)self.debugLog);
}

- (BOOL)enabled            { return [self _b:@"enabled" def:YES]; }
- (BOOL)swipeButton        { return [self _b:@"swipeButton" def:YES]; }
- (BOOL)longPressButton    { return [self _b:@"longPressButton" def:YES]; }
- (BOOL)clearOnTap         { return [self _b:@"clearOnTap" def:YES]; }
- (BOOL)toast              { return [self _b:@"toast" def:YES]; }
- (BOOL)haptic             { return [self _b:@"haptic" def:YES]; }
- (BOOL)debugLog           { return [self _b:@"debugLog" def:YES]; }

// "Custom" (a number of minutes typed in) wins over the list when it is a sensible number.
- (NSInteger)minutes {
    id custom = [self _now][@"customMinutes"];
    double c = [custom respondsToSelector:@selector(doubleValue)] ? [custom doubleValue] : 0;
    if (c >= 1 && c <= 7 * 1440) return (NSInteger)c;
    double m = [self _d:@"minutes" def:60];
    return (m >= 1 && m <= 7 * 1440) ? (NSInteger)m : 60;
}

- (ShaniMode)mode {
    return ((NSInteger)[self _d:@"mode" def:0] == 1) ? ShaniModeOncePerTap : ShaniModeEveryTime;
}

- (ShaniReleaseStyle)releaseStyle {
    NSInteger v = (NSInteger)[self _d:@"release" def:0];
    return (v >= 0 && v <= 3) ? (ShaniReleaseStyle)v : ShaniReleaseOneAlert;
}

- (NSInteger)logLimit {
    NSInteger v = (NSInteger)[self _d:@"logLimit" def:300];
    return MAX(20, MIN(5000, v));
}

- (NSArray<NSString *> *)apps {
    return ShaniCleanList([self _now][@"apps"]);
}

- (void)setApps:(NSArray<NSString *> *)apps {
    [self setObject:ShaniCleanList(apps) forKey:@"apps"];
}

@end
