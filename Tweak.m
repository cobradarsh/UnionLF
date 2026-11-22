/*  Tweak.m — the entry point of HyperTrade (in the code: Atelier, its first name). Loads into
    SpringBoard only.

    The constructor only sets up listeners. Atelier starts a few seconds after SpringBoard
    reports that it has finished starting (com.apple.springboard.finishedstartup), and after
    that everything happens on the main thread, from notifications:

      com.adarsh.atelier/prefs                   a switch was flipped under Settings → HyperTrade
      com.adarsh.atelier.open | close | toggle   another tool asks for the bench
      com.apple.springboard.lockstate            locked: the bench goes away
      com.apple.springboard.hasBlankedScreen     screen off: the bench goes away
      com.adarsh.sporex/reload                   SporeX's hidden apps changed: they leave every list

    While the bench is hidden nothing runs: no timer, no polling. (The bench has a clock of its
    own, which lives only while the bench is on screen.)

    Two methods of SBIconView are replaced, for the Home Screen icon menu ("Open in HyperTrade",
    "HyperTrade Sets…"); both pass everything that isn't Atelier's on to the code that was there.
    Dynamic Stage+ replaces the same two, and the two tweaks chain through each other.

    Start-up guard: each start adds one to <log dir>/Atelier.boot, and the file is cleared once
    Atelier has been running for 25 s. Three starts in a row that never got that far mean
    SpringBoard keeps restarting right after Atelier comes up, so on the fourth Atelier stays
    out of the way until one of its settings is changed.                                      */

#import "Atelier.h"
#import <unistd.h>

static BOOL gStarted, gHeld;
static NSString *gStartReason;

#pragma mark - start-up guard

static NSString *AtelierBootPath(void) { return [AtelierLogDir() stringByAppendingPathComponent:@"Atelier.boot"]; }

static NSInteger AtelierBootCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:AtelierBootPath() encoding:NSUTF8StringEncoding error:nil];
    return MAX(0, s.integerValue);
}

static void AtelierSetBootCount(NSInteger n) {
    [[NSString stringWithFormat:@"%ld\n", (long)n] writeToFile:AtelierBootPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL AtelierGuardOn(void) {
#if TARGET_OS_SIMULATOR
    if (getenv("ATELIER_NO_GUARD")) return NO;           // the simulator test wants to see every start
#endif
    return YES;
}

#pragma mark - Home Screen icon menu

// Declared so ARC knows it's an init (consumes the alloc, returns +1).
@interface NSObject (AtelierShortcutIcon)
- (instancetype)initWithSystemImageName:(NSString *)name;
@end

static NSString *const kTypeOpen = @"com.adarsh.atelier.open";     // type = open
static NSString *const kTypeSets = @"com.adarsh.atelier.sets";
static NSString *const kTypeSet  = @"com.adarsh.atelier.set";      // type = set|<layout>|<bid>,<bid>,…

static NSString *AtelierIconBundleID(id iconView) {
    NSString *bid = AtelierMsg(iconView, @"applicationBundleIdentifierForShortcuts");
    if (![bid isKindOfClass:NSString.class] || bid.length == 0) bid = AtelierMsg(AtelierMsg(iconView, @"icon"), @"applicationBundleID");
    return ([bid isKindOfClass:NSString.class] && bid.length) ? bid : nil;
}

static id AtelierShortcutItem(NSString *type, NSString *title, NSString *subtitle, NSString *symbol) {
    Class itemCls = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!itemCls) return nil;
    id item = [itemCls new];
    @try {
        [item setValue:type forKey:@"type"];
        [item setValue:title forKey:@"localizedTitle"];
        if (subtitle.length) [item setValue:subtitle forKey:@"localizedSubtitle"];
        Class iconCls = NSClassFromString(@"SBSApplicationShortcutSystemPrivateIcon");
        if (iconCls && [iconCls instancesRespondToSelector:NSSelectorFromString(@"initWithSystemImageName:")]) {
            id icon = [[iconCls alloc] initWithSystemImageName:symbol];
            if (icon) [item setValue:icon forKey:@"icon"];
        }
    } @catch (NSException *e) {
        AtelierLog(@"icon menu row failed: %@", e.reason);
        return nil;
    }
    return item;
}

NSArray *AtelierIconMenuItems(NSString *bid) {
    AtelierSettings *s = [AtelierSettings shared];
    if (!s.enabled || !s.iconMenu || bid.length == 0) return nil;
    if (![AtelierHost applicationForBundleID:bid]) return nil;        // folders, widgets, web clips
    if ([AtelierHost isHiddenApp:bid]) return nil;
    NSMutableArray *items = [NSMutableArray array];
    id open = AtelierShortcutItem(kTypeOpen, [@"Open in " stringByAppendingString:ATELIER_NAME], nil, @"rectangle.3.group");
    if (open) [items addObject:open];
    NSUInteger shown = 0;
    for (NSDictionary *set in [s sets]) {
        NSArray<NSString *> *apps = set[@"apps"];
        if (![apps containsObject:bid]) continue;
        NSString *type = [NSString stringWithFormat:@"%@|%@|%@", kTypeSet, set[@"layout"], [apps componentsJoinedByString:@","]];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *other in apps) if (![AtelierHost isHiddenApp:other]) [names addObject:[AtelierHost displayNameForBundleID:other]];
        id item = AtelierShortcutItem(type, [NSString stringWithFormat:@"Open %@", [AtelierSheets setTitle:set]],
                                      [names componentsJoinedByString:@", "], @"square.stack.3d.up");
        if (item) [items addObject:item];
        if (++shown >= 2) break;
    }
    id sets = AtelierShortcutItem(kTypeSets, [ATELIER_NAME stringByAppendingString:@" Sets…"], nil, @"list.bullet.rectangle");
    if (sets) [items addObject:sets];
    return items;
}

void AtelierIconMenuRun(NSString *type, NSString *bid) {
    NSArray<NSString *> *parts = [type componentsSeparatedByString:@"|"];
    NSString *kind = parts.firstObject;
    if ([kind isEqualToString:kTypeOpen] && bid.length) {
        [[AtelierBench shared] openAdding:bid];
    } else if ([kind isEqualToString:kTypeSets]) {
        [AtelierSheets showSets];
    } else if ([kind isEqualToString:kTypeSet] && parts.count == 3) {
        [[AtelierBench shared] openWithApps:[parts[2] componentsSeparatedByString:@","] layout:[parts[1] integerValue]];
    } else {
        AtelierLog(@"icon menu: nothing to do for %@", type);
    }
}

static NSArray *(*orig_shortcutItems)(id, SEL);
static NSArray *hook_shortcutItems(id self, SEL _cmd) {
    NSArray *orig = orig_shortcutItems ? orig_shortcutItems(self, _cmd) : nil;
    NSArray *mine = nil;
    @try { mine = AtelierIconMenuItems(AtelierIconBundleID(self)); } @catch (NSException *e) { AtelierLog(@"icon menu threw %@", e.reason); }
    if (mine.count == 0) return orig;
    return [mine arrayByAddingObjectsFromArray:([orig isKindOfClass:NSArray.class] ? orig : @[])];
}

static void (*orig_activateShortcut)(id, SEL, id, NSString *, id);
static void hook_activateShortcut(id self, SEL _cmd, id item, NSString *bid, id iconView) {
    NSString *type = nil;
    @try { type = AtelierMsg(item, @"type"); } @catch (__unused id e) {}
    if ([type isKindOfClass:NSString.class] && [type hasPrefix:@"com.adarsh.atelier."]) {
        NSString *source = bid ?: AtelierIconBundleID(iconView);
        AtelierLog(@"icon menu: %@ (from %@)", type, source);
        // let the context menu finish closing first
        AtelierAfter(0.3, ^{
            @try { AtelierIconMenuRun(type, source); } @catch (NSException *e) { AtelierLog(@"icon menu action threw %@", e.reason); }
        });
        return;
    }
    if (orig_activateShortcut) orig_activateShortcut(self, _cmd, item, bid, iconView);
}

void AtelierIconMenuInstall(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    if (AtelierHook(@"SBIconView", @"applicationShortcutItems", NO, (IMP)hook_shortcutItems, (IMP *)&orig_shortcutItems))
        AtelierHook(@"SBIconView", @"activateShortcut:withBundleIdentifier:forIconView:", YES,
                    (IMP)hook_activateShortcut, (IMP *)&orig_activateShortcut);
}

#pragma mark - events

void AtelierSettingsChanged(void) {
    [[AtelierSettings shared] reload];
    [[AtelierBench shared] settingsChanged];
    [[AtelierTrigger shared] refresh];
    AtelierDebugStart();
}

static void AtelierLockChanged(void) {
    [[AtelierBench shared] lockChanged];
    [[AtelierTrigger shared] refresh];
}

#pragma mark - start

// Each step of the start is in the log file before the next one begins, so if SpringBoard dies
// during the start the log says how far it got.
static void AtelierStep(NSString *what) {
    AtelierLog(@"start: %@", what);
    AtelierLogFlush();
}

static void AtelierBegin(NSInteger attempt) {
    if (gStarted || gHeld) return;
    if (!UIApplication.sharedApplication || ![AtelierHost mainScene]) {
        if (attempt < 90) AtelierAfter(1.0, ^{ AtelierBegin(attempt + 1); });
        else AtelierLog(@"gave up: SpringBoard never showed a main scene");
        return;
    }

    // The guard counts starts that got this far and then did not last 25 seconds.
    NSInteger failed = AtelierBootCount();
    if (failed >= 3 && AtelierGuardOn()) {
        gHeld = YES;
        AtelierLog(@"standing by: the last %ld times %@ started, SpringBoard restarted within 25 seconds. "
                   "Change any setting under Settings → %@ to start it again.", (long)failed, ATELIER_NAME, ATELIER_NAME);
        AtelierLogFlush();
        return;
    }
    gStarted = YES;
    AtelierSetBootCount(failed + 1);
    AtelierAfter(25.0, ^{ AtelierSetBootCount(0); });

    AtelierSettings *s = [AtelierSettings shared];
    [s reload];
    CGSize sz = [AtelierHost screenSize];
    UIEdgeInsets safe = [AtelierHost safeInsets];
    AtelierStep([NSString stringWithFormat:@"%@ %@ in SpringBoard (pid %d), iOS %@, screen %.0fx%.0f (safe %.0f/%.0f), enabled=%d, start %ld (%@)",
                 ATELIER_NAME, ATELIER_VERSION, (int)getpid(), UIDevice.currentDevice.systemVersion, sz.width, sz.height, safe.top, safe.bottom,
                 (int)s.enabled, (long)(failed + 1), gStartReason ?: @"?"]);

    @try {
        int token = 0;
        dispatch_queue_t mq = dispatch_get_main_queue();
        notify_register_dispatch("com.apple.springboard.lockstate", &token, mq, ^(int t) {
            AtelierLockChanged();
            AtelierAfter(0.7, ^{ AtelierLockChanged(); });      // the lock screen is still on its way in or out
        });
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &token, mq, ^(int t) {
            uint64_t blank = 0;
            notify_get_state(t, &blank);
            if (blank && [AtelierBench shared].visible) [[AtelierBench shared] closeAnimated:NO reason:@"screen off"];
        });
        notify_register_dispatch(ATELIER_N_OPEN, &token, mq, ^(int t) { [[AtelierBench shared] open]; });
        notify_register_dispatch(ATELIER_N_CLOSE, &token, mq, ^(int t) { [[AtelierBench shared] closeAnimated:YES reason:@"asked to"]; });
        notify_register_dispatch(ATELIER_N_TOGGLE, &token, mq, ^(int t) { [[AtelierBench shared] toggle]; });
        // SporeX (the user's app hider) says its list changed. Without SporeX this never comes.
        notify_register_dispatch(ATELIER_N_SPORE, &token, mq, ^(int t) { [[AtelierBench shared] hiddenAppsChanged]; });
    } @catch (NSException *e) {
        AtelierLog(@"start: the observers threw %@", e.reason);
    }
    AtelierStep(@"observers in place");

    @try { AtelierIconMenuInstall(); } @catch (NSException *e) { AtelierLog(@"start: the icon menu threw %@", e.reason); }
    AtelierStep(@"icon menu in place");

    // "Go home" puts the bench away: the places SpringBoard hears it are watched (AtelierGestures.m)
    @try { [AtelierHome install]; } @catch (NSException *e) { AtelierLog(@"start: the Home replacements threw %@", e.reason); }
    AtelierStep(@"Home gesture in place");

    @try { [[AtelierTrigger shared] refresh]; } @catch (NSException *e) { AtelierLog(@"start: the edge strip threw %@", e.reason); }
    AtelierStep([[AtelierTrigger shared] debugState]);

    AtelierDebugStart();
    [AtelierHost reloadHiddenApps];
    AtelierLog(@"started: mini mode %ld, freeze after %.0f s, resize %d, %lu saved app(s), %lu set(s), %lu shortcut(s), %lu hidden by SporeX",
               (long)s.miniMode, s.freezeAfter, (int)s.resizeApps, (unsigned long)[s slots].count, (unsigned long)[s sets].count,
               (unsigned long)[s shortcutApps].count, (unsigned long)[AtelierHost hiddenAppCount]);
    AtelierLogFlush();
}

static void AtelierBoot(void) {
    [[AtelierSettings shared] reload];
    int token = 0;
    notify_register_dispatch(ATELIER_N_PREFS, &token, dispatch_get_main_queue(), ^(int t) {
        if (gHeld) {                                    // the way back in after the start-up guard stepped in
            gHeld = NO;
            AtelierSetBootCount(0);
            AtelierLog(@"a setting changed: starting again");
            AtelierBegin(0);
            return;
        }
        if (!gStarted) return;
        AtelierSettingsChanged();
        AtelierSettings *s = [AtelierSettings shared];
        AtelierLog(@"settings: enabled=%d layout=%ld mini=%ld freeze=%.0f trigger=%d side=%ld size=%.0f addFront=%d resize=%d iconMenu=%d haptics=%ld "
                   "clock=%d flags=%d indices=%d toggles=%d%d%d%d%d%d shortcuts=%lu",
                   (int)s.enabled, (long)[s layout], (long)s.miniMode, s.freezeAfter, (int)s.trigger, (long)s.triggerSide, s.triggerSize,
                   (int)s.addFront, (int)s.resizeApps, (int)s.iconMenu, (long)s.haptics, (int)s.showClock, (int)s.showMarkets, (int)s.showIndices,
                   (int)[s showsToggle:@"wifi"], (int)[s showsToggle:@"bluetooth"], (int)[s showsToggle:@"data"], (int)[s showsToggle:@"dnd"],
                   (int)[s showsToggle:@"awake"], (int)[s showsToggle:@"lowpower"], (unsigned long)[s shortcutApps].count);
    });

    // Atelier starts only once SpringBoard says it has finished starting, and a few seconds after
    // that (Chakra's lesson: touching SpringBoard's controllers during its launch restarted the
    // simulator's SpringBoard five times in a row). Two fallbacks, in case that signal never
    // comes: UIKit's own "finished launching" notice, and half a minute after loading.
    __block BOOL scheduled = NO;
    void (^go)(NSString *) = ^(NSString *why) {
        if (scheduled) return;
        scheduled = YES;
        gStartReason = why;
        AtelierAfter(4.0, ^{ AtelierBegin(0); });
    };
    notify_register_dispatch("com.apple.springboard.finishedstartup", &token, dispatch_get_main_queue(), ^(int t) {
        go(@"SpringBoard finished starting");
    });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                       queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        AtelierAfter(8.0, ^{ go(@"8 s after UIKit's launch notice"); });
    }];
    AtelierAfter(30.0, ^{ go(@"30 s after loading"); });
}

__attribute__((constructor)) static void AtelierInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        // Only listeners are set up here, before SpringBoard has started; they run on the main queue later.
        @try { AtelierBoot(); } @catch (NSException *e) { NSLog(@"[Atelier] start threw %@", e.reason); }
    }
}
