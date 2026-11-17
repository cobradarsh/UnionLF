/*  ChakraDebug.m — test commands. Off unless the file <log dir>/chakra_test exists.

    Command file: <log dir>/chakra_cmd.txt, one command per line. SpringBoard notices the file
    appear (it watches the folder; nothing polls), deletes it and runs the lines in order:

        open | close | toggle       the menu
        tap <n>                     tap entry n of the open menu (0 = first)
        hover <n>                   light entry n up, as a sliding finger would
        balltap                     what a tap on the ball does (twice in a row = a double tap)
        press [<x> <y>]             a finger goes down on the ball (at its centre, or at a screen point) …
        drag <x> <y>                … moves to a screen point …
        dragby <dx> <dy>            … or by so many points …
        release                     … and lifts where it last was
        slide <n>                   slide from the ball to entry n and lift
        move left|right <0…1>       put the ball on an edge, at that fraction of the screen height
        edit | editclose            the editor sheet / close it
        editadd [apps|actions|shortcuts]   one of its three lists to add from
        items <key> <key> …         replace the wheel: app:<bundle id>  action:<id>  shortcut:<1-4>
        items default               forget the saved wheel (back to the starter set)
        set <key> <value>           write a setting (number, true/false or text) and apply it
        unset <key>
        action <id>                 run a system action
        launch <bundle id>          open an app
        url <link>                  open a link the way a shortcut entry would
        shot [name]                 screenshot → <log dir>/chakra_<name>.jpg
        state                       log the ball, the menu, the wheel's entries and what is in front
        actions                     log which actions this iOS supports
        glyphs [name …]             log any of these symbol names (default: the actions' own) that this iOS can't draw
        wait <seconds>              pause before the next line                                 */

#import "Chakra.h"
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>

static CGPoint gFinger;              // where the test finger last was

static NSString *ChakraCmdPath(void) { return [ChakraLogDir() stringByAppendingPathComponent:@"chakra_cmd.txt"]; }

static void ChakraShot(NSString *name) {
    typedef void *(*RotFn)(long);
    typedef void *(*PlainFn)(void);
    RotFn rot = (RotFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImageWithRotation");
    PlainFn plain = (PlainFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    void *owned = rot ? rot(0) : (plain ? plain() : NULL);
    UIImage *raw = (__bridge_transfer UIImage *)owned;
    if (!raw) { ChakraLog(@"shot: no screen image"); return; }
    CGSize sz = raw.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    fmt.scale = 1400.0 / MAX(1, MAX(sz.width, sz.height));           // about 1400 px on the long edge
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt]
                    imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [raw drawInRect:CGRectMake(0, 0, sz.width, sz.height)]; }];
    NSData *jpg = UIImageJPEGRepresentation(img, 0.7);
    NSString *file = [NSString stringWithFormat:@"chakra_%@.jpg", name.length ? name : @"shot"];
    BOOL ok = [jpg writeToFile:[ChakraLogDir() stringByAppendingPathComponent:file] atomically:YES];
    ChakraLog(@"shot -> %@ (%lu bytes)%@", file, (unsigned long)jpg.length, ok ? @"" : @" WRITE FAILED");
}

static id ChakraParseValue(NSString *text) {
    NSString *lower = text.lowercaseString;
    if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"]) return @YES;
    if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"]) return @NO;
    NSScanner *scan = [NSScanner scannerWithString:text];
    double d = 0;
    if ([scan scanDouble:&d] && scan.isAtEnd) return @(d);
    return text;
}

static NSString *ChakraStateLine(void) {
    NSMutableArray *entries = [NSMutableArray array];
    for (ChakraItem *item in [ChakraItems all]) [entries addObject:[NSString stringWithFormat:@"%@%@", item.key, item.available ? @"" : @"(n/a)"]];
    CGSize sz = [ChakraHost screenSize];
    UIEdgeInsets safe = [ChakraHost safeInsets];
    NSArray<NSString *> *switcher = [ChakraHost switcherApps];
    if (switcher.count > 5) switcher = [switcher subarrayWithRange:NSMakeRange(0, 5)];
    return [NSString stringWithFormat:@"%@ · %@ · wheel [%@] · front %@ · previous %@ · switcher starts [%@] · seen [%@] · locked %d · orientation %lld · screen %.0fx%.0f safe %.0f/%.0f · editor %d",
            [[ChakraBall shared] debugState], [[ChakraWheel shared] debugState], [entries componentsJoinedByString:@" "],
            [ChakraHost frontmostBundleID] ?: @"home", [ChakraHost previousApp] ?: @"-",
            [switcher componentsJoinedByString:@" "], [[ChakraHost seenApps] componentsJoinedByString:@" "],
            [ChakraHost isLocked], [ChakraHost interfaceOrientation],
            sz.width, sz.height, safe.top, safe.bottom, [ChakraEditor isOpen]];
}

static void ChakraRun(NSArray<NSString *> *lines, NSUInteger index) {
    if (index >= lines.count) return;
    NSString *line = [lines[index] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                                  filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *cmd = parts.firstObject ?: @"";
    NSString *a1 = parts.count > 1 ? parts[1] : nil, *a2 = parts.count > 2 ? parts[2] : nil;
    double delay = 0;
    if (cmd.length && ![cmd hasPrefix:@"#"]) ChakraLog(@"cmd> %@", line);
    @try {
        ChakraWheel *wheel = [ChakraWheel shared];
        ChakraBall *ball = [ChakraBall shared];
        if (cmd.length == 0 || [cmd hasPrefix:@"#"]) {
        } else if ([cmd isEqualToString:@"wait"]) {
            delay = MAX(0, MIN(30, a1.doubleValue));
        } else if ([cmd isEqualToString:@"open"]) {
            if (!wheel.isOpen) [wheel openFromHub:[ball hub] edge:[ChakraSettings shared].ballEdge];
        } else if ([cmd isEqualToString:@"close"]) {
            [wheel closeAnimated:YES completion:nil];
        } else if ([cmd isEqualToString:@"toggle"] || [cmd isEqualToString:@"balltap"]) {
            [ball debugTap];
        } else if ([cmd isEqualToString:@"tap"] && a1) {
            [wheel debugTapIndex:(NSUInteger)MAX(0, a1.integerValue)];
        } else if ([cmd isEqualToString:@"hover"] && a1) {
            [wheel debugHoverIndex:(NSUInteger)MAX(0, a1.integerValue)];
        } else if ([cmd isEqualToString:@"move"] && a2) {
            [ball debugMoveToEdge:([a1 isEqualToString:@"left"] ? ChakraEdgeLeft : ChakraEdgeRight) y:a2.doubleValue];
        } else if ([cmd isEqualToString:@"edit"]) {
            [ChakraEditor present];
        } else if ([cmd isEqualToString:@"editadd"]) {
            [ChakraEditor debugPushAdd:([a1 isEqualToString:@"actions"] ? 1 : ([a1 isEqualToString:@"shortcuts"] ? 2 : 0))];
        } else if ([cmd isEqualToString:@"press"]) {
            gFinger = a2 ? CGPointMake(a1.doubleValue, a2.doubleValue) : [ball hub];
            [ball debugTouch:0 at:gFinger];
        } else if ([cmd isEqualToString:@"dragby"] && a2) {
            gFinger = CGPointMake(gFinger.x + a1.doubleValue, gFinger.y + a2.doubleValue);
            [ball debugTouch:1 at:gFinger];
        } else if ([cmd isEqualToString:@"drag"] && a2) {
            gFinger = CGPointMake(a1.doubleValue, a2.doubleValue);
            [ball debugTouch:1 at:gFinger];
        } else if ([cmd isEqualToString:@"release"]) {
            [ball debugTouch:2 at:gFinger];
        } else if ([cmd isEqualToString:@"slide"] && a1) {
            [ball debugSlideToIndex:(NSUInteger)MAX(0, a1.integerValue)];
        } else if ([cmd isEqualToString:@"editclose"]) {
            [ChakraEditor dismiss];
        } else if ([cmd isEqualToString:@"items"] && a1) {
            if ([a1 isEqualToString:@"default"]) {
                [[ChakraSettings shared] setObject:nil forKey:@"items"];
            } else {
                NSMutableArray<ChakraItem *> *list = [NSMutableArray array];
                for (NSUInteger i = 1; i < parts.count; i++) {
                    NSRange colon = [parts[i] rangeOfString:@":"];
                    if (colon.location == NSNotFound) continue;
                    NSDictionary *d = @{ @"k": [parts[i] substringToIndex:colon.location], @"id": [parts[i] substringFromIndex:colon.location + 1] };
                    ChakraItem *item = [ChakraItem itemFromDictionary:d];
                    if (item) [list addObject:item];
                }
                [ChakraItems save:list];
            }
            ChakraLog(@"items: %lu saved, %lu showable", (unsigned long)[ChakraItems all].count, (unsigned long)[ChakraItems visible].count);
        } else if ([cmd isEqualToString:@"set"] && a2) {
            NSRange r = [line rangeOfString:a1];
            NSString *rest = [[line substringFromIndex:r.location + r.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            [[ChakraSettings shared] setObject:ChakraParseValue(rest) forKey:a1];
            ChakraSettingsChanged();
        } else if ([cmd isEqualToString:@"unset"] && a1) {
            [[ChakraSettings shared] setObject:nil forKey:a1];
            ChakraSettingsChanged();
        } else if ([cmd isEqualToString:@"action"] && a1) {
            [ChakraActions perform:a1];
        } else if ([cmd isEqualToString:@"launch"] && a1) {
            ChakraLog(@"launch -> %d", [ChakraHost launchApp:a1]);
        } else if ([cmd isEqualToString:@"url"] && a1) {
            [ChakraHost openURL:[NSURL URLWithString:a1]];
        } else if ([cmd isEqualToString:@"shot"]) {
            ChakraShot(a1);
        } else if ([cmd isEqualToString:@"state"]) {
            ChakraLog(@"state: %@", ChakraStateLine());
        } else if ([cmd isEqualToString:@"actions"]) {
            ChakraLog(@"%@", [ChakraActions report]);
        } else if ([cmd isEqualToString:@"glyphs"]) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            if (parts.count > 1) {
                [names addObjectsFromArray:[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]];
            } else {
                for (ChakraAction *a in [ChakraActions all]) {
                    if (a.glyph.length) [names addObject:a.glyph];
                    if (a.glyphOff.length) [names addObject:a.glyphOff];
                }
            }
            NSMutableArray<NSString *> *missing = [NSMutableArray array];
            for (NSString *name in names) if (![ChakraGlyphs glyphNamed:name pointSize:20]) [missing addObject:name];
            ChakraLog(@"glyphs: %lu checked, %lu can't be drawn%@%@", (unsigned long)names.count, (unsigned long)missing.count,
                  missing.count ? @": " : @"", [missing componentsJoinedByString:@" "]);
        } else {
            ChakraLog(@"cmd: unknown '%@'", line);
        }
    } @catch (NSException *e) {
        ChakraLog(@"cmd '%@' threw %@", line, e.reason);
    }
    ChakraAfter(delay, ^{ ChakraRun(lines, index + 1); });
}

static void ChakraCheckCommands(void) {
    NSString *path = ChakraCmdPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;
    if (![fm fileExistsAtPath:[ChakraLogDir() stringByAppendingPathComponent:@"chakra_test"]]) return;     // tests are off
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:path error:nil];
    if (text.length) ChakraRun([text componentsSeparatedByString:@"\n"], 0);
}

void ChakraDebugStart(void) {
    static dispatch_source_t source;
    if (source) return;
    int fd = open(ChakraLogDir().fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) { ChakraLog(@"tests: can't watch %@", ChakraLogDir()); return; }
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    if (!source) { close(fd); return; }
    dispatch_source_set_event_handler(source, ^{ ChakraCheckCommands(); });
    dispatch_resume(source);
    ChakraCheckCommands();
}
