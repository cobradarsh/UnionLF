/*  Tweak.m — Dynamic Stage+ entry point.

    One dylib, two roles (filter: com.apple.UIKit):
      SpringBoard → keyboard button, auto-swap, App Pairs (icon menu), kill guard
      apps        → keyboard/tap reporting + keyboard dismiss (SDPApp.m)

    Hooks are installed by hand with MSHookMessageEx, and only after checking the
    class and method exist, so a missing method on some iOS build is skipped (and
    logged) instead of taking SpringBoard down.                                    */

#import "SDPlus.h"
#import <substrate.h>

// Declared so ARC knows it's an init (consumes the alloc, returns +1). Calling it through a
// cast objc_msgSend would hide that and over-release whenever init returns a new object.
@interface NSObject (SDPShortcutIcon)
- (instancetype)initWithSystemImageName:(NSString *)name;
@end

static NSString *const kTypePair   = @"com.adarsh.sdplus.pair";     // type = pair|<top>|<bottom>
static NSString *const kTypeManage = @"com.adarsh.sdplus.manage";

static BOOL SDPImplements(Class c, SEL s) {
    if (!c) return NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == s;
    free(list);
    return found;
}

// Hook `sel` on `cls` (instance) or on its metaclass (class method). Skips politely.
static BOOL SDPHook(NSString *clsName, NSString *selName, BOOL classMethod, IMP repl, IMP *orig) {
    Class c = NSClassFromString(clsName);
    if (classMethod && c) c = object_getClass(c);
    SEL s = NSSelectorFromString(selName);
    if (!c || !class_getInstanceMethod(c, s)) {
        SDPLog(@"hook skipped: %@%@ %@ not found", classMethod ? @"+" : @"-", clsName, selName);
        return NO;
    }
    MSHookMessageEx(c, s, repl, orig);
    return YES;
}

#pragma mark - SpringBoard: icon menu (App Pairs)

static NSString *SDPIconBundleID(id iconView) {
    NSString *bid = SDPMsg(iconView, @"applicationBundleIdentifierForShortcuts");
    if (![bid isKindOfClass:NSString.class] || bid.length == 0) bid = SDPMsg(SDPMsg(iconView, @"icon"), @"applicationBundleID");
    return [bid isKindOfClass:NSString.class] && bid.length ? bid : nil;
}

static id SDPShortcutItem(NSString *type, NSString *title, NSString *subtitle, NSString *symbol) {
    Class itemCls = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!itemCls) return nil;
    id item = [itemCls new];
    @try {
        [item setValue:type forKey:@"type"];
        [item setValue:title forKey:@"localizedTitle"];
        if (subtitle.length) [item setValue:subtitle forKey:@"localizedSubtitle"];
        Class iconCls = NSClassFromString(@"SBSApplicationShortcutSystemPrivateIcon");
        SEL init = NSSelectorFromString(@"initWithSystemImageName:");
        if (iconCls && [iconCls instancesRespondToSelector:init]) {
            id icon = [[iconCls alloc] initWithSystemImageName:symbol];
            if (icon) [item setValue:icon forKey:@"icon"];
        }
    } @catch (NSException *e) {
        SDPLog(@"shortcut item failed: %@", e.reason);
        return nil;
    }
    return item;
}

static NSArray *SDPPairItems(id iconView) {
    SDPSettings *s = [SDPSettings shared];
    if (!s.enabled || !s.pairsEnabled) return nil;
    NSString *bid = SDPIconBundleID(iconView);
    if (!bid) return nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *p in s.pairs) {
        if (items.count >= 3) break;
        NSString *top = p[@"top"], *bottom = p[@"bottom"];
        if (![top isEqualToString:bid] && ![bottom isEqualToString:bid]) continue;
        NSString *other = [top isEqualToString:bid] ? bottom : top;
        NSString *type = [NSString stringWithFormat:@"%@|%@|%@", kTypePair, top, bottom];
        NSString *title = [NSString stringWithFormat:@"Open with %@", [SDPHost displayNameForBundleID:other]];
        NSString *sub = [NSString stringWithFormat:@"%@ on top · %@ below",
                         [SDPHost displayNameForBundleID:top], [SDPHost displayNameForBundleID:bottom]];
        id item = SDPShortcutItem(type, title, sub, @"rectangle.split.1x2");
        if (item) [items addObject:item];
    }
    id manage = SDPShortcutItem(kTypeManage, @"App Pairs…", items.count ? nil : @"Pair this app with another", @"square.on.square");
    if (manage) [items addObject:manage];
    return items;
}

static NSArray *(*orig_shortcutItems)(id, SEL);
static NSArray *hook_shortcutItems(id self, SEL _cmd) {
    NSArray *orig = orig_shortcutItems ? orig_shortcutItems(self, _cmd) : nil;
    NSArray *mine = nil;
    @try { mine = SDPPairItems(self); } @catch (NSException *e) { SDPLog(@"pair items threw %@", e.reason); }
    if (mine.count == 0) return orig;
    return [mine arrayByAddingObjectsFromArray:([orig isKindOfClass:NSArray.class] ? orig : @[])];
}

static void (*orig_activateShortcut)(id, SEL, id, NSString *, id);
static void hook_activateShortcut(id self, SEL _cmd, id item, NSString *bid, id iconView) {
    NSString *type = SDPMsg(item, @"type");
    if ([type isKindOfClass:NSString.class] && [type hasPrefix:@"com.adarsh.sdplus."]) {
        NSArray *parts = [type componentsSeparatedByString:@"|"];
        NSString *kind = parts.firstObject;
        NSString *source = bid ?: SDPIconBundleID(iconView);
        SDPLog(@"icon menu: %@ (from %@)", type, source);
        // let the context menu finish closing first
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([kind isEqualToString:kTypePair] && parts.count == 3) [SDPStage launchPairTop:parts[1] bottom:parts[2]];
            else if ([kind isEqualToString:kTypeManage] && source) [SDPPairsSheet presentForBundleID:source];
        });
        return;
    }
    if (orig_activateShortcut) orig_activateShortcut(self, _cmd, item, bid, iconView);
}

#pragma mark - SpringBoard: kill guard

static void (*orig_kill_fb)(id, SEL, long long, BOOL, id);
static void (*orig_kill_fbapp)(id, SEL, long long, BOOL, id);

static BOOL SDPShouldBlockKill(id process, id desc) {
    NSString *bid = SDPMsg(process, @"bundleIdentifier");
    if ([bid isKindOfClass:NSString.class] && [SDPStage isKillGuarded:bid]) {
        SDPLog(@"kept %@ alive while moving it (kill reason: %@)", bid, desc);
        return YES;
    }
    return NO;
}

static void hook_kill_fb(id self, SEL _cmd, long long reason, BOOL report, id desc) {
    if (SDPShouldBlockKill(self, desc)) return;
    orig_kill_fb(self, _cmd, reason, report, desc);
}

static void hook_kill_fbapp(id self, SEL _cmd, long long reason, BOOL report, id desc) {
    if (SDPShouldBlockKill(self, desc)) return;
    orig_kill_fbapp(self, _cmd, reason, report, desc);
}

#pragma mark - SpringBoard: start

static NSString *gLastFront, *gLastStage;
static NSTimer *gTick;

static BOOL SDPSame(NSString *a, NSString *b) { return a == b || [a isEqualToString:b]; }

static void SDPTick(void) {
    NSString *front = [SDPHost frontmostBundleID];
    NSString *stage = [SDPStage isOpen] ? [SDPStage stageBundleID] : nil;
    if (!SDPSame(front, gLastFront) || !SDPSame(stage, gLastStage)) {
        SDPLog(@"front %@ -> %@ · stage %@ -> %@ %@", gLastFront ?: @"home", front ?: @"home",
               gLastStage ?: @"-", stage ?: @"-", [SDPStage diagnostics]);
        gLastFront = front; gLastStage = stage;
    }
    [SDPHost noteFront:stage];
    [SDPHost noteFront:front];
    [[SDPKeyboardButton shared] refresh];
}

void SDPSpringBoardStart(void) {
    [[SDPSettings shared] reload];
    SDPLog(@"Dynamic Stage+ %@ loaded in SpringBoard (Dynamic Stage 1.2 classes %@)",
           SDP_VERSION, [SDPStage available] ? @"found" : @"NOT found yet");

    if (SDPHook(@"SBIconView", @"applicationShortcutItems", NO, (IMP)hook_shortcutItems, (IMP *)&orig_shortcutItems))
        SDPHook(@"SBIconView", @"activateShortcut:withBundleIdentifier:forIconView:", YES,
                (IMP)hook_activateShortcut, (IMP *)&orig_activateShortcut);
    SEL killSel = NSSelectorFromString(@"killForReason:andReport:withDescription:");
    if (SDPImplements(NSClassFromString(@"FBProcess"), killSel))
        SDPHook(@"FBProcess", NSStringFromSelector(killSel), NO, (IMP)hook_kill_fb, (IMP *)&orig_kill_fb);
    if (SDPImplements(NSClassFromString(@"FBApplicationProcess"), killSel))
        SDPHook(@"FBApplicationProcess", NSStringFromSelector(killSel), NO, (IMP)hook_kill_fbapp, (IMP *)&orig_kill_fbapp);

    dispatch_queue_t mq = dispatch_get_main_queue();
    int tok;
    notify_register_dispatch(SDP_N_PREFS, &tok, mq, ^(int t) {
        [[SDPSettings shared] reload];
        SDPSettings *s = [SDPSettings shared];
        SDPLog(@"settings: enabled=%d kbButton=%d onlyInStage=%d swapMode=%ld pairs=%lu",
               s.enabled, s.keyboardButton, s.keyboardButtonOnlyInStage, (long)s.swapMode, (unsigned long)s.pairs.count);
        [[SDPKeyboardButton shared] refresh];
    });
    notify_register_dispatch(SDP_N_KB_SHOW, &tok, mq, ^(int t) {
        [[SDPKeyboardButton shared] keyboardShownInPid:(pid_t)SDPState(t)];
    });
    notify_register_dispatch(SDP_N_KB_HIDE, &tok, mq, ^(int t) {
        [[SDPKeyboardButton shared] keyboardHiddenInPid:(pid_t)SDPState(t)];
    });
    notify_register_dispatch(SDP_N_TYPING, &tok, mq, ^(int t) {
        [SDPStage engagementFromPid:(pid_t)SDPState(t) typing:YES];
    });
    notify_register_dispatch(SDP_N_TOUCH, &tok, mq, ^(int t) {
        [SDPStage engagementFromPid:(pid_t)SDPState(t) typing:NO];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), mq, ^{
        if (gTick) return;
        gTick = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            @try { SDPTick(); } @catch (NSException *e) { SDPLog(@"tick threw %@", e.reason); }
        }];
        SDPLog(@"ready %@", [SDPStage diagnostics]);
    });
}

#pragma mark - apps: touch hook

static void (*orig_sendEvent)(id, SEL, UIEvent *);
static void hook_sendEvent(id self, SEL _cmd, UIEvent *event) {
    orig_sendEvent(self, _cmd, event);
    @try { SDPAppTouch(event); } @catch (__unused NSException *e) {}
}

#pragma mark - constructor

__attribute__((constructor))
static void SDPInit(void) {
    @autoreleasepool {
        NSBundle *mb = [NSBundle mainBundle];
        NSString *bid = mb.bundleIdentifier ?: @"";
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            gSDPIsSpringBoard = YES;
            SDPSpringBoardStart();
        } else if ([mb.bundlePath hasSuffix:@".app"]) {
            gSDPTouchHookOK = SDPHook(@"UIApplication", @"sendEvent:", NO, (IMP)hook_sendEvent, (IMP *)&orig_sendEvent);
            SDPAppHelperStart();
        }
    }
}
