/*  ShaniDebug.m — test commands, so Shani can be driven and looked at without touching the screen.

    On while the debug log is on (Settings → Shani → Debug Log). Command file:
    <log dir>/shani_cmd.txt, one command per line. SpringBoard notices the file appear (it
    watches the folder; nothing polls), deletes it and runs the lines in order:

        state                           the list, what is held, the timer
        set <key> <value> | unset <key> write a setting (number, true/false or text) and apply it
        apps <bundle id> … | apps none  the list, as Settings would save it
        notify <bundle id> <title> | <text>
                                        post a test notification for that app, the way an app's arrives
        tap <bundle id>                 what a tap on Shani does on that app's newest notification
        release [bundle id]             show what is held now (all apps without a bundle id)
        clock <seconds>                 move Shani's clock forward; "tick" then releases what is due
        tick
        notelog <bundle id>             how many lines that app's log has, and each line's fate (no text)
        cells                           every notification on screen: its app and its swipe buttons
        reveal <n> | hide <n>           show / put away the swipe buttons of notification n
        swipetap <n>                    press Shani's swipe button on notification n
        actions <n>                     the long-press actions of notification n, as the system has them
        longlook <n>                    open notification n the way holding it down does
        runaction <n>                   press Shani's long-press action on notification n
        cover on|off                    pull down / put away the notification list
        lockscreen                      lock the phone (simulator)
        toast <title> | <text>          show the confirmation pill
        allow <bundle id>               (simulator only) give that app permission to notify, with banners
        dests <bundle id>               where that app's newest notification was headed, its sound, its options
        classes <part of a name>        the Objective-C classes whose name contains it
        methods <Class>                 that class's own methods
        impl <selector>                 the classes that implement it
        shot [name]                     screenshot → <log dir>/shani_<name>.jpg
        wait <seconds>                  pause before the next line
        mark <word>                     log "mark: <word>" (a test waits for it)

    Lines run strictly one after another. Notification text never goes into the debug log.      */

#import "Shani.h"
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *ShaniCmdPath(void) { return [ShaniLogDir() stringByAppendingPathComponent:@"shani_cmd.txt"]; }

static id ShaniParseValue(NSString *text) {
    NSString *lower = text.lowercaseString;
    if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"]) return @YES;
    if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"]) return @NO;
    NSScanner *scan = [NSScanner scannerWithString:text];
    double d = 0;
    if ([scan scanDouble:&d] && scan.isAtEnd) return @(d);
    return text;
}

static void ShaniLogLong(NSString *title, NSArray<NSString *> *words) {
    ShaniLog(@"%@: %lu", title, (unsigned long)words.count);
    NSMutableString *line = [NSMutableString string];
    for (NSString *w in words) {
        if (line.length + w.length > 900) { ShaniLog(@"    %@", line); [line setString:@""]; }
        [line appendFormat:@"%@  ", w];
    }
    if (line.length) ShaniLog(@"    %@", line);
}

static void ShaniDumpClasses(NSString *part) {
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = @(class_getName(all[i]));
        if ([name rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound) [hits addObject:name];
    }
    free(all);
    [hits sortUsingSelector:@selector(compare:)];
    ShaniLogLong([NSString stringWithFormat:@"classes with \"%@\"", part], hits);
}

static void ShaniDumpMethods(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) { ShaniLog(@"methods: no class %@", className); return; }
    for (int meta = 0; meta < 2; meta++) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(meta ? object_getClass(cls) : cls, &n);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            [names addObject:[NSString stringWithFormat:@"%@[%s]", NSStringFromSelector(method_getName(list[i])), method_getTypeEncoding(list[i]) ?: "?"]];
        }
        free(list);
        [names sortUsingSelector:@selector(compare:)];
        ShaniLogLong([NSString stringWithFormat:@"%@ %@ (super %@)", meta ? @"+" : @"-", className, NSStringFromClass(class_getSuperclass(cls))], names);
    }
}

static void ShaniDumpImplementers(NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        unsigned int m = 0;
        Method *list = class_copyMethodList(all[i], &m);
        for (unsigned int j = 0; j < m; j++) {
            if (method_getName(list[j]) == sel) { [hits addObject:@(class_getName(all[i]))]; break; }
        }
        free(list);
    }
    free(all);
    [hits sortUsingSelector:@selector(compare:)];
    ShaniLogLong([NSString stringWithFormat:@"classes implementing %@", selName], hits);
}

static void ShaniShot(NSString *name) {
    UIImage *(*grab)(void) = (UIImage *(*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    if (!grab) { ShaniLog(@"shot: no screen grab on this iOS"); return; }
    UIImage *raw = grab();
    if (!raw) { ShaniLog(@"shot: no screen image"); return; }
    CGSize sz = raw.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = 1400.0 / MAX(1, MAX(sz.width, sz.height));           // about 1400 px on the long edge
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt]
                    imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [raw drawInRect:CGRectMake(0, 0, sz.width, sz.height)]; }];
    NSData *jpg = UIImageJPEGRepresentation(img, 0.7);
    NSString *file = [NSString stringWithFormat:@"shani_%@.jpg", name.length ? name : @"shot"];
    BOOL ok = [jpg writeToFile:[ShaniLogDir() stringByAppendingPathComponent:file] atomically:YES];
    ShaniLog(@"shot -> %@ (%lu bytes)%@", file, (unsigned long)jpg.length, ok ? @"" : @" WRITE FAILED");
}

#pragma mark - notifications on screen

static void ShaniCollectCells(UIView *view, Class cellClass, NSMutableArray *out) {
    if ([view isKindOfClass:cellClass]) { [out addObject:view]; return; }
    for (UIView *sub in view.subviews) ShaniCollectCells(sub, cellClass, out);
}

// Notification cells that are in a window and not hidden, top to bottom.
static NSArray<UIView *> *ShaniCells(void) {
    Class cellClass = NSClassFromString(@"NCNotificationListCell");
    NSMutableArray<UIView *> *cells = [NSMutableArray array];
    if (!cellClass) return cells;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [(UIWindowScene *)scene windows]) {
            if (w.hidden) continue;
            ShaniCollectCells(w, cellClass, cells);
        }
    }
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *cell in cells) {
        BOOL shown = cell.window != nil;
        for (UIView *v = cell; v && shown; v = v.superview) if (v.hidden || v.alpha < 0.01) shown = NO;
        if (shown) [visible addObject:cell];
    }
    [visible sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ya = [a convertRect:a.bounds toView:nil].origin.y, yb = [b convertRect:b.bounds toView:nil].origin.y;
        return ya < yb ? NSOrderedAscending : (ya > yb ? NSOrderedDescending : NSOrderedSame);
    }];
    return visible;
}

static UIView *ShaniCellAt(NSString *index) {
    NSArray<UIView *> *cells = ShaniCells();
    NSInteger i = index.integerValue;
    if (i < 0 || i >= (NSInteger)cells.count) { ShaniLog(@"no notification %ld on screen (%lu there)", (long)i, (unsigned long)cells.count); return nil; }
    return cells[(NSUInteger)i];
}

static NSArray *ShaniSwipeActions(UIView *cell, id *requestOut) {
    id provider = ShaniMsg(cell, @"actionProvider");
    if (requestOut) *requestOut = ShaniMsgObj(provider, @"_requestForListCell:", cell);
    id actions = ShaniMsgObj(provider, @"supplementaryActionsForNotificationListCell:", cell);
    return [actions isKindOfClass:NSArray.class] ? actions : nil;
}

static NSString *ShaniActionTitles(NSArray *actions) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id a in actions) {
        NSString *title = ShaniStr(a, @"title") ?: NSStringFromClass([a class]);
        [names addObject:[NSString stringWithFormat:@"[%@]", title]];
    }
    return names.count ? [names componentsJoinedByString:@" "] : @"(none)";
}

static void ShaniDumpCells(void) {
    NSArray<UIView *> *cells = ShaniCells();
    ShaniLog(@"cells: %lu on screen", (unsigned long)cells.count);
    NSUInteger i = 0;
    for (UIView *cell in cells) {
        id request = nil;
        NSArray *actions = ShaniSwipeActions(cell, &request);
        CGRect f = [cell convertRect:cell.bounds toView:nil];
        ShaniLog(@"    %lu: %@ at y %.0f h %.0f · provider %@ · swipe buttons %@", (unsigned long)i++, ShaniBundleOf(request).length ? ShaniBundleOf(request) : @"?",
                 f.origin.y, f.size.height, NSStringFromClass([ShaniMsg(cell, @"actionProvider") class]), ShaniActionTitles(actions));
    }
}

static id ShaniViewControllerOf(UIView *cell) {
    id vc = ShaniMsg(cell, @"contentViewController");
    if (!vc) vc = ShaniMsg(cell, @"notificationViewController");
    return vc;
}

static id ShaniContentProviderOf(id vc) {
    id provider = ShaniMsg(vc, @"staticContentProvider");
    if (!provider) provider = ShaniMsg(vc, @"_staticContentProviderLoadingIfNecessary");
    return provider;
}

static void ShaniDumpActions(UIView *cell) {
    id vc = ShaniViewControllerOf(cell);
    id provider = ShaniContentProviderOf(vc);
    ShaniLog(@"actions: view controller %@, content provider %@", NSStringFromClass([vc class]), NSStringFromClass([provider class]));
    id current = ShaniMsg(provider, @"currentActions");
    if ([current isKindOfClass:NSArray.class]) {
        for (id a in (NSArray *)current) {
            ShaniLog(@"    current: [%@] id %@ · activation %lld · needs unlock %d · dismisses %d · destructive %d · icon %@ · runner %@",
                     ShaniStr(a, @"title"), ShaniStr(a, @"identifier"), ShaniIntMsg(a, @"activationMode", -1), (int)ShaniBoolMsg(a, @"requiresAuthentication", NO),
                     (int)ShaniBoolMsg(a, @"shouldDismissNotification", NO), (int)ShaniBoolMsg(a, @"isDestructiveAction", NO),
                     ShaniStr(a, @"iconImageName") ?: @"-", NSStringFromClass([ShaniMsg(a, @"actionRunner") class]));
        }
    } else {
        ShaniLog(@"    currentActions: %@", current ? NSStringFromClass([current class]) : @"nil");
    }
    id interface = ShaniMsg(provider, @"interfaceActions");
    if ([interface isKindOfClass:NSArray.class]) {
        for (id a in (NSArray *)interface) ShaniLog(@"    interface: %@ [%@]", NSStringFromClass([a class]), ShaniStr(a, @"title") ?: @"?");
    } else {
        ShaniLog(@"    interfaceActions: %@", interface ? NSStringFromClass([interface class]) : @"nil");
    }
}

static id ShaniOwnAction(UIView *cell) {
    id current = ShaniMsg(ShaniContentProviderOf(ShaniViewControllerOf(cell)), @"currentActions");
    if (![current isKindOfClass:NSArray.class]) return nil;
    for (id a in (NSArray *)current) if ([ShaniStr(a, @"identifier") isEqualToString:SHANI_ACTION_ID]) return a;
    return nil;
}

#pragma mark - a test notification

static NSUInteger gTestCount;

// Made with the constructor UserNotificationsKit keeps for its own tests, and posted through the
// dispatcher exactly as an app's notification is (so it passes Shani's hook too).
static void ShaniPostTest(NSString *bid, NSString *title, NSString *message) {
    Class cls = NSClassFromString(@"NCNotificationRequest");
    SEL make = NSSelectorFromString(@"notificationRequestWithSectionId:notificationId:threadId:title:message:timestamp:destinations:");
    id dispatcher = [ShaniEngine shared].dispatcher ?: ShaniMsg(ShaniMsg(UIApplication.sharedApplication, @"notificationDispatcher"), @"dispatcher");
    if (!cls || ![cls respondsToSelector:make] || !dispatcher) {
        ShaniLog(@"notify: cannot (class %d, constructor %d, dispatcher %d)", cls != Nil, (int)[cls respondsToSelector:make], dispatcher != nil);
        return;
    }
    NSString *nid = [NSString stringWithFormat:@"shani-test-%lu-%.0f", (unsigned long)++gTestCount, [[NSDate date] timeIntervalSince1970]];
    NSSet *dest = [NSSet setWithObjects:@"BulletinDestinationBanner", @"BulletinDestinationCoverSheet", @"BulletinDestinationNotificationCenter",
                   @"BulletinDestinationLockScreen", nil];
    NSDate *stamp = [NSDate dateWithTimeIntervalSince1970:ShaniNow()];
    id request = ((id (*)(id, SEL, id, id, id, id, id, id, id))objc_msgSend)(cls, make, bid, nid, nil, title, message, stamp, dest);
    if (!request) { ShaniLog(@"notify: no request was made"); return; }
    ShaniLog(@"notify: %@ %@ -> %@", bid, nid, NSStringFromClass([request class]));
    ShaniSendObj(dispatcher, @"postNotificationWithRequest:", request);
}

static void ShaniDumpDestinations(NSString *bid) {
    id request = [[ShaniEngine shared] lastRequestFor:bid];
    if (!request) { ShaniLog(@"dests: nothing seen from %@ since the respring", bid); return; }
    id dest = ShaniMsg(request, @"requestDestinations");
    id options = ShaniMsg(request, @"options");
    ShaniLog(@"dests %@: [%@] · sound %@ · can play sound %d · can wake screen %d · critical %d · level %lld · has bulletin %d · thread %@",
             bid, [[(NSSet *)dest allObjects] componentsJoinedByString:@", "], ShaniMsg(request, @"sound") ? @"yes" : @"no",
             (int)ShaniBoolMsg(options, @"canPlaySound", NO), (int)ShaniBoolMsg(options, @"canTurnOnDisplay", NO),
             (int)ShaniBoolMsg(request, @"isCriticalAlert", NO), ShaniIntMsg(request, @"interruptionLevel", -1),
             ShaniMsg(request, @"bulletin") != nil, NSThread.isMainThread ? @"main" : @"background");
}

static void ShaniDumpNoteLog(NSString *bid) {
    NSArray<NSDictionary *> *all = ShaniReadNoteLog(bid);
    NSMutableArray<NSString *> *fates = [NSMutableArray array];
    for (NSDictionary *e in all) [fates addObject:[NSString stringWithFormat:@"%ld", (long)[e[@"st"] integerValue]]];
    ShaniLog(@"notelog %@: %lu line(s), fates %@", bid, (unsigned long)all.count, [fates componentsJoinedByString:@","]);
}

#pragma mark - permission to notify (simulator only)

#if TARGET_OS_SIMULATOR
@interface NSObject (ShaniSettingsGateway)             // BBSettingsGateway
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (void)getSectionInfoForSectionID:(NSString *)sectionID withCompletion:(void (^)(id info))completion;
- (void)setSectionInfo:(id)info forSectionID:(NSString *)sectionID;
@end

// What "Allow" on the permission alert does, plus banners: the test's own app may then notify
// like any app. Never built into the phone's library.
static void ShaniAllowNotifications(NSString *bid) {
    static id gateway;
    Class cls = NSClassFromString(@"BBSettingsGateway");
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithQueue:)] ||
        ![cls instancesRespondToSelector:@selector(getSectionInfoForSectionID:withCompletion:)] ||
        ![cls instancesRespondToSelector:@selector(setSectionInfo:forSectionID:)]) {
        ShaniLog(@"allow %@: this iOS has no settings gateway of the known shape", bid);
        return;
    }
    if (!gateway) gateway = [(NSObject *)[cls alloc] initWithQueue:dispatch_get_main_queue()];
    [gateway getSectionInfoForSectionID:bid withCompletion:^(id info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!info) { ShaniLog(@"allow %@: no section yet (the app has not asked for permission)", bid); return; }
            long long before = ShaniIntMsg(info, @"authorizationStatus", -1);
            NSMutableArray<NSString *> *did = [NSMutableArray array];
            if (ShaniSendInt(info, @"setAuthorizationStatus:", 2)) [did addObject:@"authorized"];
            if (ShaniSendBool(info, @"setAllowsNotifications:", YES)) [did addObject:@"allowed"];
            if (ShaniSendInt(info, @"setAlertType:", 1)) [did addObject:@"banners"];
            if (ShaniSendInt(info, @"setLockScreenSetting:", 2)) [did addObject:@"lock screen"];
            if (ShaniSendInt(info, @"setNotificationCenterSetting:", 2)) [did addObject:@"centre"];
            if (ShaniSendBool(info, @"setShowsInLockScreen:", YES)) [did addObject:@"shows locked"];
            if (ShaniSendBool(info, @"setShowsInNotificationCenter:", YES)) [did addObject:@"shows in centre"];
            @try { [gateway setSectionInfo:info forSectionID:bid]; }
            @catch (NSException *e) { ShaniLog(@"allow %@ threw %@", bid, e.reason); return; }
            ShaniLog(@"allow %@: authorization %lld -> %lld (%@)", bid, before, ShaniIntMsg(info, @"authorizationStatus", -1), [did componentsJoinedByString:@", "]);
        });
    }];
}
#endif

#pragma mark - the runner

// Runs one line; returns the seconds to wait before the next.
static double ShaniRunLine(NSString *raw) {
    NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (line.length == 0 || [line hasPrefix:@"#"]) return 0;
    NSArray<NSString *> *words = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *cmd = words.firstObject.lowercaseString;
    NSString *a1 = words.count > 1 ? words[1] : nil;
    NSArray<NSString *> *rest = words.count > 1 ? [words subarrayWithRange:NSMakeRange(1, words.count - 1)] : @[];
    ShaniEngine *engine = [ShaniEngine shared];
    ShaniSettings *settings = [ShaniSettings shared];
    double delay = 0.25;
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    @try {
        if ([cmd isEqualToString:@"wait"]) {
            delay = MAX(0, MIN(600, a1.doubleValue));
        } else if ([cmd isEqualToString:@"mark"]) {
            ShaniLog(@"mark: %@", a1 ?: @"");
        } else if ([cmd isEqualToString:@"state"]) {
            ShaniLog(@"state: %@", [engine debugState]);
        } else if ([cmd isEqualToString:@"set"] && words.count >= 3) {
            NSString *value = [[words subarrayWithRange:NSMakeRange(2, words.count - 2)] componentsJoinedByString:@" "];
            [settings setObject:ShaniParseValue(value) forKey:a1];
            [engine settingsChanged];
            ShaniLog(@"set %@ = %@", a1, value);
        } else if ([cmd isEqualToString:@"unset"] && a1) {
            [settings setObject:nil forKey:a1];
            [engine settingsChanged];
            ShaniLog(@"unset %@", a1);
        } else if ([cmd isEqualToString:@"apps"]) {
            NSArray<NSString *> *apps = ([a1 isEqualToString:@"none"] || !a1) ? @[] : rest;
            [settings setApps:apps];
            [engine settingsChanged];
            ShaniLog(@"apps: %lu on the list", (unsigned long)settings.apps.count);
        } else if ([cmd isEqualToString:@"notify"] && a1) {
            NSString *text = words.count > 2 ? [[words subarrayWithRange:NSMakeRange(2, words.count - 2)] componentsJoinedByString:@" "] : @"Test";
            NSArray<NSString *> *parts = [text componentsSeparatedByString:@"|"];
            NSString *title = [parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSString *message = parts.count > 1 ? [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"A test notification from Shani.";
            ShaniPostTest(a1, title, message);
        } else if ([cmd isEqualToString:@"tap"] && a1) {
            id request = [engine lastRequestFor:a1];
            if (request) [engine tapOnRequest:request via:@"test" systemClears:NO];
            else ShaniLog(@"tap: nothing seen from %@ since the respring", a1);
        } else if ([cmd isEqualToString:@"release"]) {
            if (a1) [engine releaseApp:a1 reason:@"test"]; else [engine releaseEverything:@"test"];
        } else if ([cmd isEqualToString:@"clock"] && a1) {
            ShaniDebugShiftClock(a1.doubleValue);
            ShaniLog(@"clock: moved %@ s forward, now %@", a1, ShaniClockText(ShaniNow()));
        } else if ([cmd isEqualToString:@"tick"]) {
            [engine releaseDue];
        } else if ([cmd isEqualToString:@"notelog"] && a1) {
            ShaniLogFlush();
            ShaniDumpNoteLog(a1);
        } else if ([cmd isEqualToString:@"cells"]) {
            ShaniDumpCells();
        } else if ([cmd isEqualToString:@"reveal"] && a1) {
            UIView *cell = ShaniCellAt(a1);
            SEL reveal = NSSelectorFromString(@"revealSupplementaryActionsWithCompletion:");
            if (cell && ShaniShape(cell, reveal, "v", 1)) { ((void (*)(id, SEL, id))objc_msgSend)(cell, reveal, nil); ShaniLog(@"reveal %@", a1); }
            else if (cell) ShaniLog(@"reveal: this cell cannot");
            delay = 1.0;
        } else if ([cmd isEqualToString:@"hide"] && a1) {
            UIView *cell = ShaniCellAt(a1);
            SEL hide = NSSelectorFromString(@"hideActionButtonsAnimated:fastAnimation:completion:");
            if (cell && ShaniShape(cell, hide, "v", 3)) ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(cell, hide, YES, NO, nil);
        } else if ([cmd isEqualToString:@"swipetap"] && a1) {
            UIView *cell = ShaniCellAt(a1);
            id mine = nil;
            for (id a in ShaniSwipeActions(cell, NULL)) {
                if ([a isKindOfClass:UIAction.class] && [[(UIAction *)a identifier] isEqualToString:@"com.adarsh.shani.swipe"]) mine = a;
            }
            SEL perform = NSSelectorFromString(@"performWithSender:target:");
            if (mine && ShaniShape(mine, perform, "v", 2)) { ShaniLog(@"swipetap %@: [%@]", a1, [(UIAction *)mine title]); ((void (*)(id, SEL, id, id))objc_msgSend)(mine, perform, nil, nil); }
            else if (cell) ShaniLog(@"swipetap: Shani's button is not among this notification's");
            delay = 1.0;
        } else if ([cmd isEqualToString:@"actions"] && a1) {
            UIView *cell = ShaniCellAt(a1);
            if (cell) ShaniDumpActions(cell);
        } else if ([cmd isEqualToString:@"longlook"] && a1) {
            UIView *cell = ShaniCellAt(a1);
            id vc = ShaniViewControllerOf(cell);
            SEL present = NSSelectorFromString(@"presentLongLookAnimated:trigger:completion:");
            if (vc && ShaniShape(vc, present, "vBc", 3)) { ((void (*)(id, SEL, BOOL, long long, id))objc_msgSend)(vc, present, YES, 0, nil); ShaniLog(@"longlook %@ asked of %@", a1, NSStringFromClass([vc class])); }
            else if (cell) ShaniLog(@"longlook: %@ cannot", NSStringFromClass([vc class]));
            delay = 1.5;
        } else if ([cmd isEqualToString:@"runaction"] && a1) {
            UIView *cell = ShaniCellAt(a1);
            id vc = ShaniViewControllerOf(cell);
            id action = ShaniOwnAction(cell);
            SEL ask = NSSelectorFromString(@"_askDelegateToExecuteAction:withParameters:animated:");
            if (action && ShaniShape(vc, ask, "v", 3)) { ShaniLog(@"runaction %@: [%@]", a1, ShaniStr(action, @"title")); ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(vc, ask, action, nil, YES); }
            else if (cell) ShaniLog(@"runaction: %@", action ? @"the view controller cannot" : @"Shani's action is not among this notification's");
            delay = 1.0;
        } else if ([cmd isEqualToString:@"cover"] && a1) {
            Class cls = NSClassFromString(@"SBCoverSheetPresentationManager");
            id mgr = [cls respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")] ? ShaniMsg(cls, @"sharedInstanceIfExists") : ShaniMsg(cls, @"sharedInstance");
            SEL set = NSSelectorFromString(@"setCoverSheetPresented:animated:withCompletion:");
            if (ShaniShape(mgr, set, "v", 3)) ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(mgr, set, [a1 isEqualToString:@"on"], YES, nil);
            else ShaniLog(@"cover: not on this iOS");
            delay = 1.5;
        } else if ([cmd isEqualToString:@"lockscreen"]) {
            Class cls = NSClassFromString(@"SBLockScreenManager");
            id mgr = [cls respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")] ? ShaniMsg(cls, @"sharedInstanceIfExists") : ShaniMsg(cls, @"sharedInstance");
            SEL lock = NSSelectorFromString(@"lockUIFromSource:withOptions:");
            if (ShaniShape(mgr, lock, "v", 2)) ((void (*)(id, SEL, int, id))objc_msgSend)(mgr, lock, 1, nil);
            else ShaniLog(@"lockscreen: not on this iOS");
            delay = 2.0;
        } else if ([cmd isEqualToString:@"toast"]) {
            NSArray<NSString *> *parts = [[rest componentsJoinedByString:@" "] componentsSeparatedByString:@"|"];
            ShaniToast([parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet],
                       parts.count > 1 ? [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"Shani on");
#if TARGET_OS_SIMULATOR
        } else if ([cmd isEqualToString:@"allow"] && a1) {
            ShaniAllowNotifications(a1);
#endif
        } else if ([cmd isEqualToString:@"dests"] && a1) {
            ShaniDumpDestinations(a1);
        } else if ([cmd isEqualToString:@"classes"] && a1) {
            ShaniDumpClasses(a1);
        } else if ([cmd isEqualToString:@"methods"] && a1) {
            for (NSString *name in rest) ShaniDumpMethods(name);
        } else if ([cmd isEqualToString:@"impl"] && a1) {
            ShaniDumpImplementers(a1);
        } else if ([cmd isEqualToString:@"shot"]) {
            ShaniShot(a1);
        } else {
            ShaniLog(@"cmd: unknown '%@'", cmd);
        }
    } @catch (NSException *e) {
        ShaniLog(@"cmd '%@' threw %@", cmd, e.reason);
    }
    CFAbsoluteTime took = CFAbsoluteTimeGetCurrent() - began;
    if (took > 1.0) ShaniLog(@"    (%@ took %.1f s)", cmd, took);
    ShaniLogFlush();
    return delay;
}

static NSMutableArray<NSString *> *gQueue;       // lines still to run (main thread)
static BOOL gRunning;

static void ShaniRunNext(void) {
    if (gQueue.count == 0) { gRunning = NO; return; }
    gRunning = YES;
    NSString *line = gQueue.firstObject;
    [gQueue removeObjectAtIndex:0];
    double delay = ShaniRunLine(line);
    ShaniAfter(delay, ^{ ShaniRunNext(); });
}

static void ShaniCheckCommands(void) {
    if (![ShaniSettings shared].debugLog) return;
    NSString *path = ShaniCmdPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:path error:nil];
    if (text.length == 0) return;
    if (!gQueue) gQueue = [NSMutableArray array];
    [gQueue addObjectsFromArray:[text componentsSeparatedByString:@"\n"]];
    if (!gRunning) ShaniRunNext();
}

// Called at the start and whenever a setting changes: the folder is watched only while the debug log is on.
void ShaniDebugStart(void) {
    static dispatch_source_t source;
    BOOL want = [ShaniSettings shared].debugLog;
    if (!want) {
        if (source) { dispatch_source_cancel(source); source = nil; }
        return;
    }
    if (source) return;
    int fd = open(ShaniLogDir().fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) { ShaniLog(@"tests: can't watch %@", ShaniLogDir()); return; }
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    if (!source) { close(fd); return; }
    dispatch_source_set_event_handler(source, ^{ ShaniCheckCommands(); });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
    ShaniCheckCommands();
}
