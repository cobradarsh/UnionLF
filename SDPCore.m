/*  SDPCore.m — logging, Darwin-notify helpers, settings, SpringBoard host helpers.  */

#import "SDPlus.h"

BOOL gSDPIsSpringBoard = NO;

#pragma mark - log

static NSString *const kLogPath = @"/var/mobile/Library/Logs/StageDuoPlus.log";

void SDPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[StageDuo+] %@", msg);
    // Only SpringBoard writes the file (apps are sandboxed, and their side is tiny).
    if (!gSDPIsSpringBoard || ![SDPSettings shared].debugLog) return;
    static dispatch_queue_t q;
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.adarsh.sdplus.log", DISPATCH_QUEUE_SERIAL);
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];
    dispatch_async(q, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kLogPath]) [fm createFileAtPath:kLogPath contents:nil attributes:nil];
        NSDictionary *attrs = [fm attributesOfItemAtPath:kLogPath error:nil];
        if ([attrs fileSize] > 256 * 1024) {           // keep it small: drop the older half
            NSData *all = [NSData dataWithContentsOfFile:kLogPath];
            [[all subdataWithRange:NSMakeRange(all.length / 2, all.length - all.length / 2)]
                writeToFile:kLogPath atomically:YES];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    });
}

#pragma mark - notify

void SDPPost(const char *name, uint64_t state) {
    static NSMutableDictionary<NSString *, NSNumber *> *tokens;   // one token per name, kept for life
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tokens = [NSMutableDictionary dictionary]; });
    NSString *key = @(name);
    int token = 0;
    @synchronized (tokens) {
        NSNumber *t = tokens[key];
        if (t) token = t.intValue;
        else if (notify_register_check(name, &token) == NOTIFY_STATUS_OK) tokens[key] = @(token);
        else token = -1;
    }
    if (token >= 0) notify_set_state(token, state);
    notify_post(name);
}

uint64_t SDPState(int token) {
    uint64_t v = 0;
    notify_get_state(token, &v);
    return v;
}

#pragma mark - settings

@implementation SDPSettings {
    NSDictionary *_p;
}

+ (instancetype)shared {
    static SDPSettings *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [SDPSettings new]; s->_p = @{}; });
    return s;
}

- (BOOL)_b:(NSString *)k def:(BOOL)d { id v = _p[k]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : d; }
- (double)_d:(NSString *)k def:(double)d { id v = _p[k]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d; }

- (void)reload {
    CFStringRef dom = (__bridge CFStringRef)SDP_DOMAIN;
    CFPreferencesAppSynchronize(dom);
    NSDictionary *d = nil;
    CFArrayRef keys = CFPreferencesCopyKeyList(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        d = CFBridgingRelease(CFPreferencesCopyMultiple(keys, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        CFRelease(keys);
    }
    if (d.count == 0) {   // cfprefsd hiccup: read the file directly
        d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.adarsh.stageduoplus.plist"];
    }
    _p = d ?: @{};
    [self _publish];
}

// Apps can't read another app's preferences from inside their sandbox, so SpringBoard
// publishes what they need as one notify-state bitmask. notify state lives in notifyd
// and stays readable as long as SpringBoard holds a token for the name (it always does).
- (void)_publish {
    if (!gSDPIsSpringBoard) return;
    uint64_t bits = SDPConfigValid;
    if (self.enabled) {
        if (self.keyboardButton) bits |= SDPConfigKeyboardButton;
        if (self.swapMode == SDPSwapTyping) bits |= SDPConfigSwapTyping;
        if (self.swapMode == SDPSwapTouch)  bits |= SDPConfigSwapTouch;
    }
    SDPPost(SDP_N_CONFIG, bits);
}

- (BOOL)enabled                   { return [self _b:@"enabled" def:YES]; }
- (BOOL)keyboardButton            { return [self _b:@"kbButton" def:YES]; }
- (BOOL)keyboardButtonOnlyInStage { return [self _b:@"kbOnlyInStage" def:NO]; }
- (CGFloat)keyboardButtonSize     { return MAX(34, MIN(70, [self _d:@"kbButtonSize" def:46])); }
- (SDPSwapMode)swapMode           { NSInteger m = (NSInteger)[self _d:@"swapMode" def:0]; return (m >= 0 && m <= 2) ? (SDPSwapMode)m : SDPSwapOff; }
- (BOOL)refocusAfterSwap          { return [self _b:@"refocusAfterSwap" def:YES]; }
- (BOOL)pairsEnabled              { return [self _b:@"pairsEnabled" def:YES]; }
- (BOOL)debugLog                  { return [self _b:@"debugLog" def:YES]; }

- (NSArray<NSDictionary *> *)pairs {
    NSMutableArray *out = [NSMutableArray array];
    id raw = _p[@"pairs"];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id p in raw) {
        if (![p isKindOfClass:NSDictionary.class]) continue;
        NSString *t = p[@"top"], *b = p[@"bottom"];
        if ([t isKindOfClass:NSString.class] && [b isKindOfClass:NSString.class] && t.length && b.length)
            [out addObject:@{ @"top": t, @"bottom": b }];
    }
    return out;
}

- (void)setPairs:(NSArray<NSDictionary *> *)pairs {
    CFStringRef dom = (__bridge CFStringRef)SDP_DOMAIN;
    CFPreferencesSetAppValue(CFSTR("pairs"), (__bridge CFArrayRef)(pairs ?: @[]), dom);
    CFPreferencesAppSynchronize(dom);
    NSMutableDictionary *m = [_p mutableCopy] ?: [NSMutableDictionary dictionary];
    m[@"pairs"] = pairs ?: @[];
    _p = m;
}

@end

#pragma mark - SpringBoard host helpers

@implementation SDPHost

static NSMutableArray<NSString *> *gRecent;

+ (NSString *)frontmostBundleID {
    @try {
        id front = SDPMsg([UIApplication sharedApplication], @"_accessibilityFrontMostApplication");
        NSString *bid = SDPMsg(front, @"bundleIdentifier");
        return [bid isKindOfClass:NSString.class] && bid.length ? bid : nil;
    } @catch (__unused id e) {}
    return nil;
}

+ (id)_appController {
    return SDPMsg(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
}

+ (id)applicationForBundleID:(NSString *)bid {
    if (bid.length == 0) return nil;
    id ctl = [self _appController];
    SEL s = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (![ctl respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(ctl, s, bid);
}

+ (pid_t)_pidOfApp:(id)app {
    id ps = SDPMsg(app, @"processState");
    SEL s = NSSelectorFromString(@"pid");
    if (!ps || ![ps respondsToSelector:s]) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(ps, s);
}

+ (pid_t)pidForBundleID:(NSString *)bid { return [self _pidOfApp:[self applicationForBundleID:bid]]; }

+ (NSString *)bundleIDForPid:(pid_t)pid {
    if (pid <= 0) return nil;
    id ctl = [self _appController];
    SEL s = NSSelectorFromString(@"applicationWithPid:");
    if ([ctl respondsToSelector:s]) {
        id app = ((id (*)(id, SEL, int))objc_msgSend)(ctl, s, pid);
        NSString *bid = SDPMsg(app, @"bundleIdentifier");
        if (bid.length) return bid;
    }
    return nil;
}

+ (NSString *)displayNameForBundleID:(NSString *)bid {
    NSString *n = SDPMsg([self applicationForBundleID:bid], @"displayName");
    if ([n isKindOfClass:NSString.class] && n.length) return n;
    for (NSDictionary *a in [self installedApps]) if ([a[@"id"] isEqualToString:bid]) return a[@"name"];
    return bid;
}

+ (UIImage *)iconForBundleID:(NSString *)bid {
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (bid.length == 0 || ![UIImage respondsToSelector:s]) return nil;
    return ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)(UIImage.class, s, bid, 2, UIScreen.mainScreen.scale);
}

+ (BOOL)launchApp:(NSString *)bid {
    if (bid.length == 0) return NO;
    SEL s = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    id app = [UIApplication sharedApplication];
    if (![app respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, s, bid, NO);
}

// Same ranking Wingman Plus 1.0.24 settled on: SpringBoard has a second foreground scene on
// Dynamic Island phones, and windows put there don't show (or crash focus requests).
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

+ (void)toast:(NSString *)msg {
    if (msg.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect b = [UIScreen mainScreen].bounds;
        UILabel *t = [UILabel new];
        t.text = msg;
        t.textColor = UIColor.whiteColor;
        t.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        t.textAlignment = NSTextAlignmentCenter;
        t.numberOfLines = 0;
        t.layer.cornerRadius = 12;
        t.clipsToBounds = YES;
        CGSize fit = [t sizeThatFits:CGSizeMake(b.size.width - 100, 200)];
        CGFloat w = MIN(b.size.width - 60, fit.width + 32), h = fit.height + 22;
        t.frame = CGRectMake((b.size.width - w) / 2, 70, w, h);
        UIWindowScene *scene = [SDPHost mainScene];
        UIWindow *win = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:b];
        win.frame = b;
        win.windowLevel = 100003;
        win.backgroundColor = UIColor.clearColor;
        win.userInteractionEnabled = NO;
        win.rootViewController = [UIViewController new];
        win.rootViewController.view.backgroundColor = UIColor.clearColor;
        [win.rootViewController.view addSubview:t];
        win.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            win.hidden = YES; (void)win;
        });
    });
}

+ (void)noteFront:(NSString *)bid {
    if (bid.length == 0) return;
    if (!gRecent) gRecent = [NSMutableArray array];
    if ([gRecent.firstObject isEqualToString:bid]) return;
    [gRecent removeObject:bid];
    [gRecent insertObject:bid atIndex:0];
    while (gRecent.count > 8) [gRecent removeLastObject];
}

+ (NSArray<NSString *> *)recentApps { return gRecent ? [gRecent copy] : @[]; }

+ (NSArray<NSDictionary *> *)installedApps {
    static NSArray *cache; static CFAbsoluteTime at;
    if (cache && CFAbsoluteTimeGetCurrent() - at < 60) return cache;
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id ws = SDPMsg(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        for (id p in (NSArray *)SDPMsg(ws, @"allApplications")) {
            NSString *bid = SDPMsg(p, @"applicationIdentifier");
            NSString *nm = SDPMsg(p, @"localizedName");
            NSString *type = SDPMsg(p, @"applicationType");
            if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
            BOOL apple = [bid hasPrefix:@"com.apple."];
            // App Store apps are "User"; TrollStore apps register as "System" but are never com.apple.*.
            // Keep the Apple apps people actually split with (Safari, Notes, Messages, …): visible ones only.
            if (apple && ![type isEqualToString:@"User"]) {
                NSArray *tags = SDPMsg(p, @"appTags");
                if ([tags isKindOfClass:NSArray.class] && [tags containsObject:@"hidden"]) continue;
                id app = [self applicationForBundleID:bid];
                if (!app) continue;
                id info = SDPMsg(app, @"info");
                SEL hid = NSSelectorFromString(@"hasHiddenTag");
                if (info && [info respondsToSelector:hid] && ((BOOL (*)(id, SEL))objc_msgSend)(info, hid)) continue;
            }
            [out addObject:@{ @"id": bid, @"name": ([nm isKindOfClass:NSString.class] && nm.length) ? nm : bid }];
        }
    } @catch (__unused id e) {}
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    cache = out; at = CFAbsoluteTimeGetCurrent();
    return out;
}

@end
