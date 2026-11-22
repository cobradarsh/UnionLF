/*  ShaniHooks.m — the six places where Shani stands in iOS's notification code.

    1-3. -[NCNotificationDispatcher postNotificationWithRequest:]      every notification on its way to
         -[NCNotificationDispatcher modifyNotificationWithRequest:]    banner, Lock Screen and Notification
         -[NCNotificationDispatcher withdrawNotificationWithRequest:]  Centre passes here. An app that is
         being silenced: its notification stops here and waits in ShaniEngine.

    4.   -[NCNotificationGroupList supplementaryActionsForNotificationListCell:]
         the buttons behind a notification swiped to the left (Options, Clear) on the Lock Screen and
         in Notification Centre. Shani's button is put before the last one.

    5.   -[NCNotificationRequestContentProvider currentActions]
         the actions under a notification that is held down or pulled down (Reply, Mark as Read…).
         Shani's is added at the end. It is an ordinary NCNotificationAction whose runner is ours,
         so the system treats a tap on it like a tap on any app's action.

    6.   -[NCNotificationRequestContentProvider _iconImageForNotificationAction:]
         the small picture beside that action: Saturn.

    All six are in the phone's iOS 16.5 (20F66) and in the 16.4 simulator. Each replacement calls
    the original and adds to its answer; if anything of ours throws, the original's answer is
    what the system gets.                                                                        */

#import "Shani.h"

static NSString *const kShaniSwipeID = @"com.adarsh.shani.swipe";

#pragma mark - 1-3: the dispatcher

static void (*orig_post)(id, SEL, id);
static void hook_post(id self, SEL _cmd, id request) {
    BOOL held = NO;
    if (request) {
        @try {
            ShaniEngine *engine = [ShaniEngine shared];
            engine.dispatcher = self;
            held = [engine holdsNewRequest:request];
        } @catch (NSException *e) {
            ShaniLog(@"post hook threw %@", e.reason);
            held = NO;
        }
    }
    if (!held) orig_post(self, _cmd, request);
}

static void (*orig_modify)(id, SEL, id);
static void hook_modify(id self, SEL _cmd, id request) {
    BOOL held = NO;
    if (request) {
        @try { held = [[ShaniEngine shared] holdsModifiedRequest:request]; }
        @catch (NSException *e) { ShaniLog(@"modify hook threw %@", e.reason); held = NO; }
    }
    if (!held) orig_modify(self, _cmd, request);
}

static void (*orig_withdraw)(id, SEL, id);
static void hook_withdraw(id self, SEL _cmd, id request) {
    if (request) {
        @try { [[ShaniEngine shared] requestWithdrawn:request]; }
        @catch (NSException *e) { ShaniLog(@"withdraw hook threw %@", e.reason); }
    }
    orig_withdraw(self, _cmd, request);
}

#pragma mark - 4: the swipe buttons

static BOOL ShaniIsAction(id object) {
    return [object isKindOfClass:UIAction.class];
}

// The system's own Clear (or Clear All) among the buttons beside ours.
static UIAction *ShaniFindClear(id list, id request, NSArray *system) {
    NSMutableSet<NSString *> *titles = [NSMutableSet set];
    SEL make = NSSelectorFromString(@"_clearActionForRequest:clearAll:");
    if (ShaniShape(list, make, "@", 2) && ShaniArgIs(list, make, 3, "Bc")) {
        for (int all = 0; all < 2; all++) {
            @try {
                id a = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(list, make, request, (BOOL)all);
                if (ShaniIsAction(a) && [(UIAction *)a title].length) [titles addObject:[(UIAction *)a title]];
            } @catch (__unused id e) {}
        }
    }
    for (id a in system.reverseObjectEnumerator) {
        if (!ShaniIsAction(a)) continue;
        NSString *identifier = [(UIAction *)a identifier];
        if ([titles containsObject:[(UIAction *)a title]] || [identifier.lowercaseString containsString:@"clear"]) return a;
    }
    return nil;
}

static void ShaniSwipeTapped(id list, id cell, id request, NSArray *system) {
    ShaniEngine *engine = [ShaniEngine shared];
    ShaniSettings *s = [ShaniSettings shared];
    BOOL turningOn = ![engine isSilencing:ShaniBundleOf(request)];
    BOOL clear = turningOn && s.clearOnTap;
    [engine tapOnRequest:request via:@"swipe" systemClears:YES];          // the clearing is done here, the system's way
    BOOL cleared = NO;
    if (clear) {
        UIAction *system_clear = ShaniFindClear(list, request, system);
        SEL perform = NSSelectorFromString(@"performWithSender:target:");
        if (system_clear && ShaniShape(system_clear, perform, "v", 2)) {
            @try { ((void (*)(id, SEL, id, id))objc_msgSend)(system_clear, perform, nil, nil); cleared = YES; }
            @catch (NSException *e) { ShaniLog(@"the system's Clear threw %@", e.reason); }
        }
        if (!cleared) cleared = ShaniSendObj(list, @"_executeClearActionForRequest:", request);
        if (!cleared) { [engine clearRequests:@[ request ]]; cleared = YES; }
    }
    if (!clear) {
        SEL hide = NSSelectorFromString(@"hideActionButtonsAnimated:fastAnimation:completion:");
        if (ShaniShape(cell, hide, "v", 3)) {
            @try { ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(cell, hide, YES, NO, nil); } @catch (__unused id e) {}
        }
    }
}

static NSArray *(*orig_supplementary)(id, SEL, id);
static NSArray *hook_supplementary(id self, SEL _cmd, id cell) {
    NSArray *orig = orig_supplementary(self, _cmd, cell);
    @try {
        ShaniSettings *s = [ShaniSettings shared];
        if (!s.enabled || !s.swipeButton) return orig;
        if (![orig isKindOfClass:NSArray.class] || orig.count == 0) return orig;      // a cell that has no buttons keeps none
        id request = ShaniMsgObj(self, @"_requestForListCell:", cell);
        NSString *bid = ShaniBundleOf(request);
        if (!request || bid.length == 0) return orig;
        for (id a in orig) {
            if (!ShaniIsAction(a)) return orig;                                        // not what we know: leave it alone
            if ([[(UIAction *)a identifier] isEqualToString:kShaniSwipeID]) return orig;
        }
        static BOOL noted;
        if (!noted) {
            noted = YES;
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (UIAction *a in orig) [names addObject:[NSString stringWithFormat:@"\"%@\" (%@)", a.title, a.identifier]];
            ShaniLog(@"swipe buttons as iOS makes them: %@", [names componentsJoinedByString:@", "]);
        }
        __weak id weakList = self;
        __weak id weakCell = cell;
        NSArray *system = orig;
        UIAction *mine = [UIAction actionWithTitle:[[ShaniEngine shared] buttonTitleFor:bid] image:nil identifier:kShaniSwipeID
                                           handler:^(__kindof UIAction *action) {
            @try { ShaniSwipeTapped(weakList, weakCell, request, system); }
            @catch (NSException *e) { ShaniLog(@"swipe tap threw %@", e.reason); }
        }];
        NSMutableArray *out = [orig mutableCopy];
        [out insertObject:mine atIndex:out.count - 1];                                 // before the last one, which is Clear
        return out;
    } @catch (NSException *e) {
        ShaniLog(@"swipe buttons hook threw %@", e.reason);
    }
    return orig;
}

#pragma mark - 5-6: the action under a notification held down

// The system calls the action's runner when the action is tapped.
@interface ShaniActionRunner : NSObject
@property (nonatomic) BOOL shouldForwardAction;
@property (nonatomic, strong) id request;
@end

@implementation ShaniActionRunner
- (void)executeAction:(id)action fromOrigin:(id)origin endpoint:(id)endpoint withParameters:(id)parameters completion:(void (^)(BOOL))completion {
    id request = self.request;
    ShaniLog(@"long-press action tapped (origin %@)", origin);
    dispatch_block_t work = ^{
        @try { if (request) [[ShaniEngine shared] tapOnRequest:request via:@"long press" systemClears:NO]; }
        @catch (NSException *e) { ShaniLog(@"long-press tap threw %@", e.reason); }
        if (completion) completion(YES);
    };
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}
@end

static char kShaniRunnerKey;
static char kShaniCachedKey;

id ShaniMakeAction(id request, NSString *title, BOOL dismisses) {
    Class cls = NSClassFromString(@"NCMutableNotificationAction");
    if (!cls || !request) return nil;
    id action = [cls new];
    if (!ShaniSendObj(action, @"setIdentifier:", SHANI_ACTION_ID) || !ShaniSendObj(action, @"setTitle:", title)) return nil;
    ShaniActionRunner *runner = [ShaniActionRunner new];
    runner.request = request;
    if (!ShaniSendObj(action, @"setActionRunner:", runner)) return nil;
    objc_setAssociatedObject(action, &kShaniRunnerKey, runner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ShaniSendInt(action, @"setActivationMode:", 2);                    // 2 is what an app's own background actions carry on 16.4: no app is opened
    ShaniSendBool(action, @"setRequiresAuthentication:", NO);          // works on the Lock Screen
    ShaniSendBool(action, @"setShouldDismissNotification:", dismisses);
    ShaniSendBool(action, @"setDestructiveAction:", NO);
    ShaniSendObj(action, @"setIconImageName:", @"hourglass");          // shown only if hook 6 is not asked
    return action;
}

static NSArray *(*orig_currentActions)(id, SEL);
static NSArray *hook_currentActions(id self, SEL _cmd) {
    NSArray *orig = orig_currentActions(self, _cmd);
    @try {
        ShaniSettings *s = [ShaniSettings shared];
        if (!s.enabled || !s.longPressButton) return orig;
        if (orig && ![orig isKindOfClass:NSArray.class]) return orig;
        id request = ShaniMsg(self, @"notificationRequest");
        NSString *bid = ShaniBundleOf(request);
        if (!request || bid.length == 0) return orig;
        for (id a in orig) if ([ShaniStr(a, @"identifier") isEqualToString:SHANI_ACTION_ID]) return orig;
        NSString *title = [[ShaniEngine shared] buttonTitleFor:bid];
        // one action per provider, request and wording: the system asks for this list often
        NSDictionary *cached = objc_getAssociatedObject(self, &kShaniCachedKey);
        id action = nil;
        if ([cached[@"title"] isEqualToString:title] && [cached[@"request"] nonretainedObjectValue] == request) action = cached[@"action"];
        if (!action) {
            action = ShaniMakeAction(request, title, YES);
            if (!action) return orig;
            objc_setAssociatedObject(self, &kShaniCachedKey,
                                     @{ @"title": title, @"request": [NSValue valueWithNonretainedObject:request], @"action": action },
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return orig ? [orig arrayByAddingObject:action] : @[ action ];
    } @catch (NSException *e) {
        ShaniLog(@"actions hook threw %@", e.reason);
    }
    return orig;
}

static id (*orig_iconForAction)(id, SEL, id);
static id hook_iconForAction(id self, SEL _cmd, id action) {
    @try {
        if ([ShaniStr(action, @"identifier") isEqualToString:SHANI_ACTION_ID]) {
            UIImage *glyph = ShaniGlyph(24);
            if (glyph) return glyph;
        }
    } @catch (__unused id e) {}
    return orig_iconForAction(self, _cmd, action);
}

#pragma mark - install

BOOL ShaniInstallUIHooks(void) {
    BOOL post = ShaniHook(@"NCNotificationDispatcher", @"postNotificationWithRequest:", (IMP)hook_post, (IMP *)&orig_post);
    if (!post) {
        ShaniLog(@"the dispatcher's post method is missing: Shani cannot hold anything on this iOS");
        return NO;
    }
    [ShaniEngine shared].post = ^(id dispatcher, id request) {
        orig_post(dispatcher, NSSelectorFromString(@"postNotificationWithRequest:"), request);
    };
    BOOL modify = ShaniHook(@"NCNotificationDispatcher", @"modifyNotificationWithRequest:", (IMP)hook_modify, (IMP *)&orig_modify);
    BOOL withdraw = ShaniHook(@"NCNotificationDispatcher", @"withdrawNotificationWithRequest:", (IMP)hook_withdraw, (IMP *)&orig_withdraw);
    BOOL swipe = ShaniHook(@"NCNotificationGroupList", @"supplementaryActionsForNotificationListCell:", (IMP)hook_supplementary, (IMP *)&orig_supplementary);
    BOOL actions = ShaniHook(@"NCNotificationRequestContentProvider", @"currentActions", (IMP)hook_currentActions, (IMP *)&orig_currentActions);
    BOOL icon = ShaniHook(@"NCNotificationRequestContentProvider", @"_iconImageForNotificationAction:", (IMP)hook_iconForAction, (IMP *)&orig_iconForAction);
    ShaniLog(@"hooks: post %d, modify %d, withdraw %d, swipe buttons %d, long-press actions %d, action icon %d",
             (int)post, (int)modify, (int)withdraw, (int)swipe, (int)actions, (int)icon);
    return YES;
}
