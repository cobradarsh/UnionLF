// Test commands. Off unless a marker file exists when Photos starts:
//   on the phone   <jailbreak root>/var/mobile/Library/GuestMode/diag     (tools/phone.sh diag on)
//   in tests       $GUESTMODE_DIR/diag
// While it exists, Photos looks twice a second for cmd.txt in that folder. Its first line is a
// token; a file is run once per token. The answers go to the log (guestmode.log in Photos'
// temporary folder, or the test folder).
//
// None of these gets past Face ID: "tap" and "choose" ask for it exactly as a finger would.
// (Only the simulator build, compiled with GM_TEST, has "auth pass|fail|real".)
//
//   state            phase, how many chosen, the button, the gallery, the windows
//   pick             open the photo picker
//   dismiss          close the picker or the menu
//   select <n>       choose the newest n items of the library without the picker
//   clear            forget the selection (not in Guest Mode)
//   tap              what a tap on the button does
//   menu             the entries of the button's hold menu
//   choose <title>   run the menu entry whose title starts so
//   open <i>         Guest Mode only: show item i full screen
//   grid             back to the grid
//   bars             what a tap on a photo does: hide or show the bars and the button
//   wait <seconds>, mark <text>
#import "GuestMode.h"
#ifdef GM_TEST
#import <objc/runtime.h>

// Tests only: a fresh simulator's Photos asks to send notifications, and that system alert would sit
// over every picture the test takes (nothing can tap it away). The question is answered "no" unasked.
static void GMQuietNotificationQuestion(void) {
    Class center = NSClassFromString(@"UNUserNotificationCenter");
    SEL sel = NSSelectorFromString(@"requestAuthorizationWithOptions:completionHandler:");
    Method method = center ? class_getInstanceMethod(center, sel) : NULL;
    if (!method) return;
    method_setImplementation(method, imp_implementationWithBlock(^(id me, NSUInteger options, void (^done)(BOOL, NSError *)) {
        if (done) done(NO, nil);
    }));
}
#endif

static NSMutableArray<NSString *> *gLines;
static BOOL gRunning;
static NSString *gLastToken;

static NSString *GMDebugFolder(void) {
    return GMTestFolder() ?: [GMRoot() stringByAppendingPathComponent:@"var/mobile/Library/GuestMode"];
}

static void GMRunNext(void);

static void GMAfter(double seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GMRunNext(); });
}

static void GMLogState(void) {
    GMState *state = GMState.shared;
    NSArray<NSString *> *names = @[@"idle", @"chosen", @"GUEST"];
    GMLog(@"state: phase %@, %d chosen, %d still in the library, enabled %d", names[state.phase], (int)state.identifiers.count,
          (int)[state assets].count, GMEnabled());
    GMLog(@"%@", [GMButtonController.shared describe]);
    GMLog(@"%@", [GMGallery.shared describe]);
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            GMLog(@"  window %@ level %.0f%@%@ root %@", NSStringFromClass(window.class), window.windowLevel, window.hidden ? @" hidden" : @"",
                  window.isKeyWindow ? @" KEY" : @"", NSStringFromClass(window.rootViewController.class));
        }
    }
}

static void GMRunLine(NSString *line) {
    NSArray<NSString *> *words = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *verb = words.firstObject;
    NSString *rest = words.count > 1 ? [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "] : @"";
    GMButtonController *button = GMButtonController.shared;
    double pause = 0.6;

    if ([verb isEqualToString:@"state"]) {
        GMLogState();
        pause = 0.1;
    } else if ([verb isEqualToString:@"pick"]) {
        [button presentPicker];
        pause = 2.5;
    } else if ([verb isEqualToString:@"dismiss"]) {
        [button dismissPresented];
        pause = 1.0;
    } else if ([verb isEqualToString:@"select"]) {
        PHFetchOptions *options = GMFetchOptions();
        options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        options.fetchLimit = MAX(1, rest.integerValue);
        PHFetchResult<PHAsset *> *found = [PHAsset fetchAssetsWithOptions:options];
        NSMutableArray<NSString *> *ids = [NSMutableArray new];
        [found enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger index, BOOL *stop) { [ids addObject:asset.localIdentifier]; }];
        GMLog(@"select: asked for %d, the library gave %d", (int)options.fetchLimit, (int)ids.count);
        [GMState.shared choose:ids];
    } else if ([verb isEqualToString:@"clear"]) {
        [GMState.shared choose:@[]];
    } else if ([verb isEqualToString:@"tap"]) {
        [button buttonTapped];
        pause = 1.5;
    } else if ([verb isEqualToString:@"menu"]) {
        [button presentMenu];
        pause = 0.1;
    } else if ([verb isEqualToString:@"choose"]) {
        BOOL ran = NO;
        for (UIMenuElement *element in [button menuActions]) {
            if (![element isKindOfClass:UIAction.class] || ![element.title hasPrefix:rest]) continue;
            if (@available(iOS 16.0, *)) {
                [(UIAction *)element performWithSender:nil target:nil];
                ran = YES;
            }
            break;
        }
        GMLog(@"choose: \"%@\" %@", rest, ran ? @"run" : @"NOT found");
        pause = 1.5;
    } else if ([verb isEqualToString:@"open"]) {
        GMLog(@"open: item %d %@", (int)rest.integerValue, [GMGallery.shared openItemAtIndex:rest.integerValue] ? @"shown" : @"NOT shown");
        pause = 2.0;
    } else if ([verb isEqualToString:@"grid"]) {
        [GMGallery.shared backToGrid];
    } else if ([verb isEqualToString:@"bars"]) {
        [GMGallery.shared toggleBars];
#ifdef GM_TEST
    } else if ([verb isEqualToString:@"auth"]) {
        GMAuthSetTestAnswer(rest);
        GMLog(@"auth: the next checks answer \"%@\"", rest);
        pause = 0.1;
#endif
    } else if ([verb isEqualToString:@"wait"]) {
        pause = MAX(0.1, rest.doubleValue);
    } else if ([verb isEqualToString:@"mark"]) {
        GMLog(@"mark: %@", rest);
        pause = 0.1;
    } else if (verb.length) {
        GMLog(@"unknown command: %@", line);
        pause = 0.1;
    }
    GMAfter(pause);
}

static void GMRunNext(void) {
    if (!gLines.count) {
        gRunning = NO;
        return;
    }
    NSString *line = gLines.firstObject;
    [gLines removeObjectAtIndex:0];
    @try {
        GMRunLine(line);
    } @catch (NSException *e) {
        GMLog(@"command \"%@\" threw %@: %@", line, e.name, e.reason);
        GMAfter(0.1);
    }
}

static void GMPoll(void) {
    if (gRunning || !GMDiag()) return;
    NSString *path = [GMDebugFolder() stringByAppendingPathComponent:@"cmd.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return;
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] mutableCopy];
    NSString *token = lines.firstObject;
    if (!token.length || [token isEqualToString:gLastToken]) return;
    gLastToken = token;
    [lines removeObjectAtIndex:0];
    gLines = lines;
    gRunning = YES;
    GMRunNext();
}

void GMDebugStart(void) {
#ifdef GM_TEST
    GMQuietNotificationQuestion();
#endif
    if (!GMDiag()) return;
    // the token of a command file that was already there is remembered, not run again
    NSString *path = [GMDebugFolder() stringByAppendingPathComponent:@"cmd.txt"];
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    gLastToken = [old componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { GMPoll(); }];
    });
}
