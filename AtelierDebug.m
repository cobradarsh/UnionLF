/*  AtelierDebug.m — test commands, so the bench can be driven without touching the screen.

    On while the debug log is on (Settings → Atelier → Debug Log). Command file:
    <log dir>/atelier_cmd.txt, one command per line. SpringBoard notices the file appear (it
    watches the folder; nothing polls), deletes it and runs the lines in order:

        open | close | toggle           the bench, as the edge swipe would
        apps <bundle id> …              open the bench with exactly these apps (first = main)
        add <bundle id>                 what "Open in Atelier" in the icon menu does
        layout side|top|split|next
        main <n>                        slot n changes places with the main (0 = main, 1… = minis)
        closeapp <n> | full <n>         close that app / open it full screen and put the bench away
        replace <n> <bundle id>         n = number of apps adds one
        split <0.3…0.7>                 Split: the first app's share
        menu <n> | menutap <row> | hidemenu
        plus                            what a tap on the "+" tile does
        freeze | touch                  freeze the minis now / what any touch on the bench does
        swipe <n> left|right|up|down    what letting go of mini n swiped that way does (n = its slot, 1…)
        lock <n> | pair <n>             lock or unlock the app in slot n / put it beside the main in Split
        unlockall                       forget every lock
        clock <ISO date> | clock off    the band's clock runs on from that moment, e.g. clock 2026-11-23T10:00:00+05:30
        shortcuts <bundle id> …         the shortcut apps (what the Settings list would save); "shortcuts none" clears
        shortcut <n>                    what a tap on shortcut n does
        badge <bundle id> <n>           give an app a badge (0 clears it)
        where                           log every tile, pill and shortcut with its frame; also → atelier_where.txt
        saveset | sets | picker         save the bench as a set / the Sets sheet / the app picker
        pick <row>                      choose row n of the sheet that is open
        sheetclose
        trigger                         what a swipe on the edge strip does
        iconmenu <bundle id>            log the rows Atelier adds to that app's icon menu
        iconrun <type>                  run one of those rows by its type string
        kbfocus <n>                     ask SpringBoard to point the hardware keyboard at slot n
        set <key> <value> | unset <key> write a setting (number, true/false or text) and apply it
        launch <bundle id> | spawn <bundle id>     open an app / start it in the background
        activate <bundle id>            open the app's existing scene full screen (what Full Screen does)
        home                            go to the Home Screen
        state | scenes | windows        log the bench, every FrontBoard scene, SpringBoard's windows
        classes <part of a name>        log the Objective-C classes whose name contains it
        methods <Class>                 log that class's own methods
        shot [name]                     screenshot → <log dir>/atelier_<name>.jpg
        wait <seconds>                  pause before the next line
        mark <word>                     log "mark: <word>" (a test waits for it to know the lines before it are done)

    Lines run strictly one after another: a file that arrives while an earlier one is still
    running is queued behind it. A line that takes more than a second says so in the log.       */

#import "Atelier.h"
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>

NSArray *AtelierIconMenuItems(NSString *bid);                // Tweak.m
void AtelierIconMenuRun(NSString *type, NSString *bid);

static NSString *AtelierCmdPath(void) { return [AtelierLogDir() stringByAppendingPathComponent:@"atelier_cmd.txt"]; }

static void AtelierShot(NSString *name) {
    UIImage *raw = [AtelierHost screenImage];
    if (!raw) { AtelierLog(@"shot: no screen image"); return; }
    CGSize sz = raw.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    fmt.scale = 1400.0 / MAX(1, MAX(sz.width, sz.height));           // about 1400 px on the long edge
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt]
                    imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [raw drawInRect:CGRectMake(0, 0, sz.width, sz.height)]; }];
    NSData *jpg = UIImageJPEGRepresentation(img, 0.7);
    NSString *file = [NSString stringWithFormat:@"atelier_%@.jpg", name.length ? name : @"shot"];
    BOOL ok = [jpg writeToFile:[AtelierLogDir() stringByAppendingPathComponent:file] atomically:YES];
    AtelierLog(@"shot -> %@ (%lu bytes, source %.0fx%.0f@%.0f)%@", file, (unsigned long)jpg.length, sz.width, sz.height, raw.scale,
               ok ? @"" : @" WRITE FAILED");
}

static id AtelierParseValue(NSString *text) {
    NSString *lower = text.lowercaseString;
    if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"]) return @YES;
    if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"]) return @NO;
    NSScanner *scan = [NSScanner scannerWithString:text];
    double d = 0;
    if ([scan scanDouble:&d] && scan.isAtEnd) return @(d);
    return text;
}

static void AtelierLogLong(NSString *title, NSArray<NSString *> *words) {
    AtelierLog(@"%@: %lu", title, (unsigned long)words.count);
    NSMutableString *line = [NSMutableString string];
    for (NSString *w in words) {
        if (line.length + w.length > 700) { AtelierLog(@"    %@", line); [line setString:@""]; }
        [line appendFormat:@"%@  ", w];
    }
    if (line.length) AtelierLog(@"    %@", line);
}

static void AtelierDumpClasses(NSString *part) {
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = @(class_getName(all[i]));
        if ([name rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound) [hits addObject:name];
    }
    free(all);
    [hits sortUsingSelector:@selector(compare:)];
    AtelierLogLong([NSString stringWithFormat:@"classes with \"%@\"", part], hits);
}

static void AtelierDumpMethods(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) { AtelierLog(@"methods: no class %@", className); return; }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (int pass = 0; pass < 2; pass++) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(pass ? object_getClass(cls) : cls, &n);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++)
            [names addObject:[NSString stringWithFormat:@"%@%s", pass ? @"+" : @"-", sel_getName(method_getName(list[i]))]];
        free(list);
        [names sortUsingSelector:@selector(compare:)];
        [out addObjectsFromArray:names];
    }
    AtelierLogLong([NSString stringWithFormat:@"methods of %@ : %@", className, NSStringFromClass(class_getSuperclass(cls))], out);
}

static void AtelierDumpWindows(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        [lines addObject:[NSString stringWithFormat:@"scene %@ state %ld%@", NSStringFromClass([ws class]), (long)ws.activationState,
                          ws == [AtelierHost mainScene] ? @" (main)" : @""]];
        NSArray<UIWindow *> *windows = [ws.windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
            return a.windowLevel < b.windowLevel ? NSOrderedAscending : (a.windowLevel > b.windowLevel ? NSOrderedDescending : NSOrderedSame);
        }];
        for (UIWindow *w in windows) {
            [lines addObject:[NSString stringWithFormat:@"    %8.1f %@%@%@ %.0fx%.0f root %@", w.windowLevel, NSStringFromClass([w class]),
                              w.hidden ? @" hidden" : @"", w.isKeyWindow ? @" KEY" : @"", w.bounds.size.width, w.bounds.size.height,
                              NSStringFromClass([w.rootViewController class])]];
        }
    }
    AtelierLog(@"windows:\n    %@", [lines componentsJoinedByString:@"\n    "]);
}

// Runs one line; returns how long to wait before the next.
static double AtelierRunLine(NSString *raw) {
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                                  filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *cmd = parts.firstObject ?: @"";
    NSString *a1 = parts.count > 1 ? parts[1] : nil, *a2 = parts.count > 2 ? parts[2] : nil;
    NSArray<NSString *> *rest = parts.count > 1 ? [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] : @[];
    double delay = 0;
    if (cmd.length && ![cmd hasPrefix:@"#"]) AtelierLog(@"cmd> %@", line);
    @try {
        AtelierBench *bench = [AtelierBench shared];
        NSUInteger n = (NSUInteger)MAX(0, a1.integerValue);
        if (cmd.length == 0 || [cmd hasPrefix:@"#"]) {
        } else if ([cmd isEqualToString:@"wait"]) {
            delay = MAX(0, MIN(60, a1.doubleValue));
        } else if ([cmd isEqualToString:@"mark"]) {
            AtelierLog(@"mark: %@", a1 ?: @"");
        } else if ([cmd isEqualToString:@"open"]) {
            [bench open];
        } else if ([cmd isEqualToString:@"close"]) {
            [bench closeAnimated:YES reason:@"test"];
        } else if ([cmd isEqualToString:@"toggle"]) {
            [bench toggle];
        } else if ([cmd isEqualToString:@"apps"]) {
            [bench openWithApps:rest layout:-1];
        } else if ([cmd isEqualToString:@"add"] && a1) {
            [bench openAdding:a1];
        } else if ([cmd isEqualToString:@"layout"] && a1) {
            if ([a1 isEqualToString:@"next"]) [bench cycleLayout];
            else [bench setLayout:([a1 isEqualToString:@"top"] ? AtelierLayoutTop : ([a1 isEqualToString:@"split"] ? AtelierLayoutSplit : AtelierLayoutSide)) animated:YES];
        } else if ([cmd isEqualToString:@"main"] && a1) {
            [bench makeMain:n];
        } else if ([cmd isEqualToString:@"closeapp"] && a1) {
            [bench closeSlot:n];
        } else if ([cmd isEqualToString:@"full"] && a1) {
            [bench fullScreenSlot:n];
        } else if ([cmd isEqualToString:@"replace"] && a2) {
            [bench replaceSlot:n with:a2];
        } else if ([cmd isEqualToString:@"split"] && a1) {
            [bench setSplit:a1.doubleValue];
        } else if ([cmd isEqualToString:@"menu"] && a1) {
            [bench showMenuForSlot:n];
        } else if ([cmd isEqualToString:@"menutap"] && a1) {
            [bench debugMenuTap:n];
        } else if ([cmd isEqualToString:@"hidemenu"]) {
            [bench hideMenu];
        } else if ([cmd isEqualToString:@"plus"]) {
            AtelierSend(bench, @"_plusTapped");
        } else if ([cmd isEqualToString:@"swipe"] && a2) {
            NSArray<NSString *> *ways = @[ @"left", @"right", @"up", @"down" ];
            NSUInteger way = [ways indexOfObject:a2.lowercaseString];
            if (way != NSNotFound) [bench performSwipe:(AtelierSwipe)way onSlot:n];
        } else if ([cmd isEqualToString:@"lock"] && a1) {
            [bench toggleLockSlot:n];
        } else if ([cmd isEqualToString:@"unlockall"]) {
            [[AtelierSettings shared] setLockedApps:@[]];
            AtelierSettingsChanged();
        } else if ([cmd isEqualToString:@"pair"] && a1) {
            [bench pairSlot:n];
        } else if ([cmd isEqualToString:@"clock"] && a1) {
            NSDate *when = nil;
            if (![a1 isEqualToString:@"off"]) {
                NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
                when = [iso dateFromString:a1];
                if (!when) AtelierLog(@"clock: can't read %@ (want e.g. 2026-11-23T10:00:00+05:30)", a1);
            }
            [AtelierBand setDebugNow:when];
            [bench settingsChanged];
            AtelierLog(@"clock: %@", when ? [when description] : @"real time");
        } else if ([cmd isEqualToString:@"shortcuts"]) {
            NSArray<NSString *> *list = (rest.count == 1 && [rest[0] isEqualToString:@"none"]) ? @[] : rest;
            [[AtelierSettings shared] setObject:list forKey:@"shortcutApps"];
            AtelierSettingsChanged();
        } else if ([cmd isEqualToString:@"shortcut"] && a1) {
            NSArray<NSString *> *list = [[AtelierSettings shared] shortcutApps];
            NSMutableArray<NSString *> *shown = [NSMutableArray array];
            for (NSString *bid in list) if ([AtelierHost applicationForBundleID:bid] && shown.count < ATELIER_SHORTCUTS) [shown addObject:bid];
            if (n < shown.count) [bench openShortcut:shown[n]];
            else AtelierLog(@"shortcut %lu: there are %lu", (unsigned long)n, (unsigned long)shown.count);
        } else if ([cmd isEqualToString:@"badge"] && a2) {
            id app = [AtelierHost applicationForBundleID:a1];
            NSInteger count = a2.integerValue;
            BOOL sent = AtelierSendObj(app, @"setBadgeValue:", count > 0 ? @(count) : nil);
            AtelierLog(@"badge %@ = %ld -> %d (now %@)", a1, (long)count, (int)sent, AtelierMsg(app, @"badgeValue"));
            [bench settingsChanged];
        } else if ([cmd isEqualToString:@"where"]) {
            AtelierLog(@"where:\n    %@", [[bench debugWhere] stringByReplacingOccurrencesOfString:@"\n" withString:@"\n    "]);
        } else if ([cmd isEqualToString:@"freeze"]) {
            [bench freezeNow];
        } else if ([cmd isEqualToString:@"touch"]) {
            [bench touched];
        } else if ([cmd isEqualToString:@"saveset"]) {
            [bench saveAsSet];
        } else if ([cmd isEqualToString:@"sets"]) {
            [AtelierSheets showSets];
        } else if ([cmd isEqualToString:@"picker"]) {
            [AtelierSheets pickAppWithTitle:@"Add an app" excluding:[bench apps] then:^(NSString *bid) {
                AtelierLog(@"picked %@", bid);
                [[AtelierBench shared] replaceSlot:[[AtelierBench shared] apps].count with:bid];
            }];
        } else if ([cmd isEqualToString:@"pick"] && a1) {
            [AtelierSheets debugPick:n];
        } else if ([cmd isEqualToString:@"sheetclose"]) {
            [AtelierSheets dismiss];
        } else if ([cmd isEqualToString:@"trigger"]) {
            [[AtelierTrigger shared] debugSwipe];
        } else if ([cmd isEqualToString:@"iconmenu"] && a1) {
            NSMutableArray<NSString *> *rows = [NSMutableArray array];
            for (id item in AtelierIconMenuItems(a1))
                [rows addObject:[NSString stringWithFormat:@"%@ <%@>", AtelierMsg(item, @"localizedTitle"), AtelierMsg(item, @"type")]];
            AtelierLog(@"icon menu for %@: %@", a1, rows.count ? [rows componentsJoinedByString:@" | "] : @"(nothing)");
        } else if ([cmd isEqualToString:@"iconrun"] && a1) {
            AtelierIconMenuRun(a1, a2);
        } else if ([cmd isEqualToString:@"kbfocus"] && a1) {
            NSArray<NSString *> *apps = [bench apps];
            if (n < apps.count) {
                id scene = [AtelierScenes sceneForBundleID:apps[n]];
                int pid = [AtelierHost pidOfApplication:[AtelierHost applicationForBundleID:apps[n]]];
                AtelierLog(@"kbfocus %@ pid %d -> %d", apps[n], pid, (int)[AtelierScenes requestKeyboardFocusForScene:scene pid:pid]);
            }
        } else if ([cmd isEqualToString:@"set"] && a2) {
            NSRange r = [line rangeOfString:a1];
            NSString *value = [[line substringFromIndex:r.location + r.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            [[AtelierSettings shared] setObject:AtelierParseValue(value) forKey:a1];
            AtelierSettingsChanged();
        } else if ([cmd isEqualToString:@"unset"] && a1) {
            [[AtelierSettings shared] setObject:nil forKey:a1];
            AtelierSettingsChanged();
        } else if ([cmd isEqualToString:@"launch"] && a1) {
            AtelierLog(@"launch -> %d", (int)[AtelierHost launchApp:a1 suspended:NO]);
        } else if ([cmd isEqualToString:@"spawn"] && a1) {
            AtelierLog(@"spawn -> %d", (int)[AtelierHost launchApp:a1 suspended:YES]);
        } else if ([cmd isEqualToString:@"activate"] && a1) {
            AtelierLog(@"activate %@ -> %d", a1, (int)[AtelierScenes activateScene:[AtelierScenes sceneForBundleID:a1]]);
        } else if ([cmd isEqualToString:@"home"]) {
            UIApplication *app = UIApplication.sharedApplication;
            SEL s = NSSelectorFromString(@"_simulateHomeButtonPressWithCompletion:");
            if (AtelierShape(app, s, "v", 1)) ((void (*)(id, SEL, id))objc_msgSend)(app, s, nil);
            else AtelierLog(@"home: -> %d", (int)AtelierSend(app, @"_simulateHomeButtonPress"));
        } else if ([cmd isEqualToString:@"state"]) {
            AtelierLog(@"state: %@ · %@ · front %@ · locked %d · switcher %d", [bench debugState], [[AtelierTrigger shared] debugState],
                       [AtelierHost frontmostBundleID] ?: @"home", (int)[AtelierHost isLocked], (int)[AtelierHost switcherVisible]);
        } else if ([cmd isEqualToString:@"scenes"]) {
            AtelierLog(@"scenes: %@", [AtelierScenes describeAll]);
        } else if ([cmd isEqualToString:@"windows"]) {
            AtelierDumpWindows();
        } else if ([cmd isEqualToString:@"classes"] && a1) {
            AtelierDumpClasses(a1);
        } else if ([cmd isEqualToString:@"methods"] && a1) {
            for (NSString *name in rest) AtelierDumpMethods(name);
        } else if ([cmd isEqualToString:@"shot"]) {
            AtelierShot(a1);
        } else {
            AtelierLog(@"cmd: unknown '%@'", line);
        }
    } @catch (NSException *e) {
        AtelierLog(@"cmd '%@' threw %@", line, e.reason);
    }
    CFAbsoluteTime took = CFAbsoluteTimeGetCurrent() - began;
    if (took > 1.0) AtelierLog(@"    (%@ took %.1f s)", cmd, took);
    AtelierLogFlush();
    return delay;
}

static NSMutableArray<NSString *> *gQueue;       // lines still to run (main thread)
static BOOL gRunning;

static void AtelierRunNext(void) {
    if (gQueue.count == 0) { gRunning = NO; return; }
    gRunning = YES;
    NSString *line = gQueue.firstObject;
    [gQueue removeObjectAtIndex:0];
    double delay = AtelierRunLine(line);
    AtelierAfter(delay, ^{ AtelierRunNext(); });
}

static void AtelierCheckCommands(void) {
    if (![AtelierSettings shared].debugLog) return;
    NSString *path = AtelierCmdPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:path error:nil];
    if (text.length == 0) return;
    if (!gQueue) gQueue = [NSMutableArray array];
    [gQueue addObjectsFromArray:[text componentsSeparatedByString:@"\n"]];
    if (!gRunning) AtelierRunNext();
}

// Called at the start and whenever a setting changes: the folder is watched only while the debug log is on.
void AtelierDebugStart(void) {
    static dispatch_source_t source;
    BOOL want = [AtelierSettings shared].debugLog;
    if (!want) {
        if (source) { dispatch_source_cancel(source); source = nil; }
        return;
    }
    if (source) return;
    int fd = open(AtelierLogDir().fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) { AtelierLog(@"tests: can't watch %@", AtelierLogDir()); return; }
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    if (!source) { close(fd); return; }
    dispatch_source_set_event_handler(source, ^{ AtelierCheckCommands(); });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
    AtelierCheckCommands();
}
