/*  WPFocus.m — let Wingman's own sheet take the keyboard over the app in front.

    On iOS 16 the keyboard goes to whichever scene SpringBoard's keyboard-focus
    controller picks, and with an app in front that's the app. So a text box in a
    SpringBoard overlay becomes first responder but no keyboard ever appears (the sheet
    only worked through its Paste buttons). SpringBoard has calls that let its own
    windows take focus over an app (iOS 16.5, SBWorkspaceKeyboardFocusController):
        requestFocusStealingForSpringBoardWindow:forReason:
        lockFocusToSpringBoardWindowScene:forReason:
    Both are private, so they're looked up at runtime, the method signature is checked
    before each call, and calls are wrapped in @try. A call is only made if it returns an
    object - the focus lock - which we invalidate when the sheet hides. Focus must never
    stay stuck on SpringBoard, or the app below would lose its keyboard. Every attempt
    is logged to /var/mobile/wingman_keyboard.txt.                                   */

#import "WPlus.h"
#import <objc/message.h>

static NSString *const kWPFocusReason = @"WingmanPlusSheet";
static NSMutableArray *gWPFocusLocks;   // what SpringBoard handed back; all invalidated in giveKeyboardBack
static NSMutableString *gWPFocusLog;

static void WPFocusLog(NSString *s) {
    if (!gWPFocusLog || gWPFocusLog.length > 8000) gWPFocusLog = [NSMutableString string];
    [gWPFocusLog appendFormat:@"%@  %@\n", [NSDate date], s];
    @try {
        [gWPFocusLog writeToFile:@"/var/mobile/wingman_keyboard.txt" atomically:YES
                        encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused id e) {}
}

// "return <- arg arg" type codes of a method, for the log.
static NSString *WPSigText(NSMethodSignature *sig) {
    NSMutableString *m = [NSMutableString stringWithFormat:@"%s <-", sig.methodReturnType];
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++)
        [m appendFormat:@" %s", [sig getArgumentTypeAtIndex:i]];
    return m;
}

// Call a no-argument getter only when the runtime says it returns an object.
static id WPGet(id target, NSString *name) {
    SEL s = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:s]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:s];
    if (sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;
    id result = nil;
    @try { result = ((id (*)(id, SEL))objc_msgSend)(target, s); } @catch (__unused id e) { result = nil; }
    return result;
}

// SpringBoard's keyboard-focus controller, wherever this iOS version keeps it.
static id WPFocusController(void) {
    NSMutableArray *hosts = [NSMutableArray array];
    if (UIApplication.sharedApplication) [hosts addObject:UIApplication.sharedApplication];
    for (NSString *cls in @[ @"SBMainWorkspace", @"SBWorkspace" ]) {
        Class c = NSClassFromString(cls);
        for (NSString *getter in @[ @"sharedInstance", @"mainWorkspace" ]) {
            id o = WPGet(c, getter);
            if (o) [hosts addObject:o];
        }
    }
    for (id h in hosts) {
        id fc = WPGet(h, @"keyboardFocusController");
        if (fc) return fc;
    }
    return WPGet(NSClassFromString(@"SBWorkspaceKeyboardFocusController"), @"sharedInstance");
}

@implementation WPFocus

+ (void)takeKeyboardForWindow:(UIWindow *)window {
    [self giveKeyboardBack];                         // start clean: never stack locks across sheets
    if (!window) return;
    id fc = WPFocusController();
    WPFocusLog([NSString stringWithFormat:@"take: controller=%@ window=%@ scene=%@",
                fc ? NSStringFromClass([fc class]) : @"(not found)",
                NSStringFromClass([window class]),
                window.windowScene ? NSStringFromClass([window.windowScene class]) : @"(none)"]);
    if (!fc) return;

    // Both calls are tried and every lock returned is kept: either one may be what routes the
    // keyboard to this window, and all of them are invalidated together in giveKeyboardBack.
    gWPFocusLocks = [NSMutableArray array];
    NSArray<NSArray *> *tries = @[
        @[ @"requestFocusStealingForSpringBoardWindow:forReason:", window ],
        @[ @"lockFocusToSpringBoardWindowScene:forReason:", window.windowScene ?: (id)[NSNull null] ],
    ];
    for (NSArray *t in tries) {
        NSString *name = t[0];
        id arg = t[1];
        SEL s = NSSelectorFromString(name);
        if (arg == (id)[NSNull null]) { WPFocusLog([name stringByAppendingString:@" skipped: window has no scene"]); continue; }
        if (![fc respondsToSelector:s]) { WPFocusLog([name stringByAppendingString:@" not available"]); continue; }
        NSMethodSignature *sig = [fc methodSignatureForSelector:s];
        NSString *sigText = WPSigText(sig);
        // Only a call that takes (object, object) and returns an object: the object is the lock we
        // release later. A call returning nothing would leave nothing to release, so it's skipped.
        BOOL shape = sig.numberOfArguments == 4 && sig.methodReturnType[0] == '@'
                  && [sig getArgumentTypeAtIndex:2][0] == '@' && [sig getArgumentTypeAtIndex:3][0] == '@';
        if (!shape) { WPFocusLog([NSString stringWithFormat:@"%@ skipped: signature %@", name, sigText]); continue; }
        id lock = nil;
        @try { lock = ((id (*)(id, SEL, id, id))objc_msgSend)(fc, s, arg, kWPFocusReason); }
        @catch (NSException *e) {
            WPFocusLog([NSString stringWithFormat:@"%@ threw %@: %@", name, e.name, e.reason]);
            continue;
        }
        WPFocusLog([NSString stringWithFormat:@"%@ (%@) -> %@, invalidatable=%d", name, sigText,
                    lock ? NSStringFromClass([lock class]) : @"nil",
                    [lock respondsToSelector:NSSelectorFromString(@"invalidate")]]);
        if (lock) [gWPFocusLocks addObject:lock];
    }
}

+ (void)giveKeyboardBack {
    NSArray *locks = gWPFocusLocks;
    gWPFocusLocks = nil;
    if (locks.count == 0) return;
    SEL inv = NSSelectorFromString(@"invalidate");
    NSUInteger ended = 0;
    for (id lock in locks) {
        @try {
            if ([lock respondsToSelector:inv]) { ((void (*)(id, SEL))objc_msgSend)(lock, inv); ended++; }
        } @catch (NSException *e) {
            WPFocusLog([NSString stringWithFormat:@"release threw %@: %@", e.name, e.reason]);
        }
    }
    WPFocusLog([NSString stringWithFormat:@"released: invalidated %lu of %lu lock(s)",
                (unsigned long)ended, (unsigned long)locks.count]);
}

@end
