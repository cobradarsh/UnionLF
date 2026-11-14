/*  SDPDebug.m — test commands, screenshots and call tracing (only while Debug Log is on).

    Command file: /var/mobile/Library/Logs/sdp_cmd.txt  (one command per line)
    SpringBoard reads it within half a second, deletes it, and runs the lines in order:

        shot [name]           screenshot → /var/mobile/Library/Logs/sdp_<name>.jpg
        state                 log Dynamic Stage's state
        swap                  swap top and bottom (same as the swap button)
        expand                only Dynamic Stage's native "bring the stage app to the front"
        open <bundle id>      open an app in the stage window
        launch <bundle id>    bring an app to the front
        pair <top> <bottom>   launch an app pair
        set <knob> <value>    settle | openOldTop | guardKills | guardPairs
        wait <seconds>        pause before the next line

    Tracing: every app launch SpringBoard does, every FBProcess kill, and Dynamic Stage's
    open / expand calls are logged with the code that called them
    (library+offset, plus the nearest Dynamic Stage method), so a native gesture can be
    replayed exactly.                                                                 */

#import "SDPlus.h"
#import <dlfcn.h>
#import <ptrauth.h>
#import <substrate.h>

static NSString *const kLogDir  = @"/var/mobile/Library/Logs";
static NSString *const kCmdPath = @"/var/mobile/Library/Logs/sdp_cmd.txt";

static void SDPAfterD(double sec, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

#pragma mark - backtrace

static NSArray<NSArray *> *gDSMethods;   // sorted @[ @[ imp, name ] ] for Dynamic Stage's classes

static void SDPIndexDSMethods(void) {
    if (gDSMethods) return;
    Class card = NSClassFromString(@"DS_IIllIIIIIIIlllIIIIllllllIllIll");
    const char *image = card ? class_getImageName(card) : NULL;
    if (!image) { gDSMethods = @[]; return; }
    unsigned int n = 0;
    const char **names = objc_copyClassNamesForImage(image, &n);
    NSMutableArray *all = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        Class c = objc_getClass(names[i]);
        for (int meta = 0; meta < 2 && c; meta++) {
            Class k = meta ? object_getClass(c) : c;
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(k, &mc);
            for (unsigned int j = 0; j < mc; j++) {
                uintptr_t imp = (uintptr_t)ptrauth_strip((void *)method_getImplementation(ms[j]), ptrauth_key_function_pointer);
                NSString *nm = [NSString stringWithFormat:@"%c[%.10s %@]", meta ? '+' : '-', names[i],
                                NSStringFromSelector(method_getName(ms[j]))];
                [all addObject:@[ @(imp), nm ]];
            }
            free(ms);
        }
    }
    free(names);
    [all sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    gDSMethods = all;
}

static NSString *SDPNearestDS(uintptr_t addr) {
    SDPIndexDSMethods();
    NSArray *best = nil;
    for (NSArray *m in gDSMethods) { if ([m[0] unsignedLongValue] <= addr) best = m; else break; }
    if (!best) return @"";
    return [NSString stringWithFormat:@" ~%@+0x%lx", best[1], (unsigned long)(addr - [best[0] unsignedLongValue])];
}

NSString *SDPBacktrace(NSUInteger skip, NSUInteger count) {
    NSArray<NSNumber *> *addrs = [NSThread callStackReturnAddresses];
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = skip; i < addrs.count && out.count < count; i++) {
        uintptr_t a = (uintptr_t)ptrauth_strip((void *)addrs[i].unsignedLongValue, ptrauth_key_return_address);
        Dl_info info;
        if (!dladdr((void *)a, &info) || !info.dli_fname) continue;
        NSString *lib = [@(info.dli_fname) lastPathComponent];
        NSString *entry = [NSString stringWithFormat:@"%@+0x%lx", lib, (unsigned long)(a - (uintptr_t)info.dli_fbase)];
        if ([lib hasPrefix:@"DynamicStage"]) entry = [entry stringByAppendingString:SDPNearestDS(a)];
        [out addObject:entry];
    }
    return [out componentsJoinedByString:@" < "];
}

#pragma mark - screenshot

static void SDPShot(NSString *name) {
    typedef void *(*RotFn)(long);
    typedef void *(*PlainFn)(void);
    RotFn rot = (RotFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImageWithRotation");
    PlainFn plain = (PlainFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    void *owned = rot ? rot(0) : (plain ? plain() : NULL);
    UIImage *raw = (__bridge_transfer UIImage *)owned;
    if (!raw) { SDPLog(@"shot: no screen image"); return; }
    CGSize sz = raw.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    fmt.scale = 1200.0 / MAX(1, MAX(sz.width, sz.height));     // ~1200 px on the long edge
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt]
                    imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [raw drawInRect:CGRectMake(0, 0, sz.width, sz.height)]; }];
    NSData *jpg = UIImageJPEGRepresentation(img, 0.6);
    NSString *path = [kLogDir stringByAppendingPathComponent:[NSString stringWithFormat:@"sdp_%@.jpg", name.length ? name : @"shot"]];
    BOOL ok = [jpg writeToFile:path atomically:YES];
    SDPLog(@"shot -> %@ (%lu bytes) %@", path.lastPathComponent, (unsigned long)jpg.length, ok ? @"" : @"WRITE FAILED");
}

#pragma mark - command file

static void SDPRunCommands(NSArray<NSString *> *lines, NSUInteger i) {
    if (i >= lines.count) return;
    NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *p = [[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                  filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    double delay = 0;
    NSString *cmd = p.firstObject ?: @"";
    NSString *a1 = p.count > 1 ? p[1] : nil, *a2 = p.count > 2 ? p[2] : nil;
    if (cmd.length) SDPLog(@"cmd> %@", line);
    @try {
        if ([cmd isEqualToString:@"wait"])        delay = MAX(0, MIN(30, a1.doubleValue));
        else if ([cmd isEqualToString:@"shot"])   SDPShot(a1);
        else if ([cmd isEqualToString:@"state"])  SDPLog(@"state %@", [SDPStage diagnostics]);
        else if ([cmd isEqualToString:@"swap"])   [SDPStage swapWithReason:@"cmd" refocus:NO];
        else if ([cmd isEqualToString:@"expand"]) SDPLog(@"expand -> %d", [SDPStage nativeExpand]);
        else if ([cmd isEqualToString:@"open"] && a1)   SDPLog(@"open -> %d", [SDPStage openInStage:a1]);
        else if ([cmd isEqualToString:@"launch"] && a1) SDPLog(@"launch -> %d", [SDPHost launchApp:a1]);
        else if ([cmd isEqualToString:@"pair"] && a2)   [SDPStage launchPairTop:a1 bottom:a2];
        else if ([cmd isEqualToString:@"set"] && a2) {
            if ([a1 isEqualToString:@"settle"])          gSDPTune.settle = a2.doubleValue;
            else if ([a1 isEqualToString:@"openOldTop"]) gSDPTune.openOldTop = a2.boolValue;
            else if ([a1 isEqualToString:@"guardKills"]) gSDPTune.guardKills = a2.boolValue;
            else if ([a1 isEqualToString:@"guardPairs"]) gSDPTune.guardPairs = a2.boolValue;
            SDPLog(@"tune: settle=%.2f openOldTop=%d guardKills=%d guardPairs=%d",
                   gSDPTune.settle, gSDPTune.openOldTop, gSDPTune.guardKills, gSDPTune.guardPairs);
        } else if (cmd.length) SDPLog(@"cmd: unknown '%@'", line);
    } @catch (NSException *e) {
        SDPLog(@"cmd '%@' threw %@", line, e.reason);
    }
    SDPAfterD(delay, ^{ SDPRunCommands(lines, i + 1); });
}

void SDPDebugTick(void) {
    if (![SDPSettings shared].debugLog) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kCmdPath]) return;
    NSString *txt = [NSString stringWithContentsOfFile:kCmdPath encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:kCmdPath error:nil];
    if (txt.length) SDPRunCommands([txt componentsSeparatedByString:@"\n"], 0);
}

#pragma mark - tracing hooks

static BOOL (*orig_sbLaunch)(id, SEL, NSString *, BOOL);
static BOOL hook_sbLaunch(id self, SEL _cmd, NSString *bid, BOOL suspended) {
    SDPLog(@"trace launch %@ suspended=%d  from %@", bid, suspended, SDPBacktrace(1, 5));
    return orig_sbLaunch(self, _cmd, bid, suspended);
}

static void (*orig_dsOpen)(id, SEL, id);
static void hook_dsOpen(id self, SEL _cmd, id arg) {
    id app = [arg isKindOfClass:NSDictionary.class] ? arg[@"app"] : nil;
    SDPLog(@"trace DS open %@  from %@", SDPMsg(app, @"bundleIdentifier") ?: arg, SDPBacktrace(1, 5));
    orig_dsOpen(self, _cmd, arg);
}

static void (*orig_dsExpand)(id, SEL);
static void hook_dsExpand(id self, SEL _cmd) {
    SDPLog(@"trace DS expand %@  from %@", SDPMsg(SDPMsg(self, @"application"), @"bundleIdentifier"), SDPBacktrace(1, 5));
    orig_dsExpand(self, _cmd);
}

static void SDPTraceHook(NSString *cls, NSString *sel, IMP repl, IMP *orig) {
    Class c = NSClassFromString(cls);
    SEL s = NSSelectorFromString(sel);
    if (!c || !class_getInstanceMethod(c, s)) { SDPLog(@"trace hook skipped: %@ %@", cls, sel); return; }
    MSHookMessageEx(c, s, repl, orig);
}

void SDPDebugInstall(void) {
    SDPTraceHook(@"SpringBoard", @"launchApplicationWithIdentifier:suspended:", (IMP)hook_sbLaunch, (IMP *)&orig_sbLaunch);
    SDPTraceHook(@"DS_IIllIIIIIIIlllIIIIllllllIllIll", @"DS_IIlIIlIIlllIlIIIlIIIIlIlIIlIII", (IMP)hook_dsOpen, (IMP *)&orig_dsOpen);
    SDPTraceHook(@"DS_lIllllIllIIlIIlIIllllIIIIIlllI", @"DS_llIIIlIIlIIllIllIIIllllIIlIlll", (IMP)hook_dsExpand, (IMP *)&orig_dsExpand);
}
