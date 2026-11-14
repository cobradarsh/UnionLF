/*  SDPApp.m — the small part that runs inside apps.

    • Reports "keyboard up / down" to SpringBoard so the hide-keyboard button can show.
    • Reports "you started typing here" (a text box took focus right after a tap) and,
      in Any Tap mode, "you touched here", so SpringBoard can swap this app to the top
      when it's the one in the stage window.
    • Drops its keyboard when SpringBoard asks, and can re-open it after a swap.

    It only posts what SpringBoard's config bits ask for, and never more than about
    once a second, so it costs nothing in apps you aren't using with Dynamic Stage. */

#import "SDPlus.h"

static int gCfgToken = -1;
static uint64_t gCfg;
static BOOL gKbUp;
static CFAbsoluteTime gLastTouch, gLastTouchPost, gLastTypingPost;
BOOL gSDPTouchHookOK;                   // Tweak.m sets this once -[UIApplication sendEvent:] is hooked
static __weak UIResponder *gLastFR;     // the text box you were typing in (for re-focus after a swap)
static __weak UIResponder *gFoundFR;

@interface UIResponder (SDPFirstResponder)
- (void)sdp_captureFirstResponder:(id)sender;
@end

@implementation UIResponder (SDPFirstResponder)
- (void)sdp_captureFirstResponder:(id)sender { gFoundFR = self; }
@end

static UIResponder *SDPFirstResponder(void) {
    gFoundFR = nil;
    [[UIApplication sharedApplication] sendAction:@selector(sdp_captureFirstResponder:) to:nil from:nil forEvent:nil];
    return gFoundFR;
}

static void SDPReadConfig(void) {
    if (gCfgToken >= 0) gCfg = SDPState(gCfgToken);
}

static void SDPDismissKeyboard(void) {
    UIApplication *app = [UIApplication sharedApplication];
    [app sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) [w endEditing:YES];
    }
}

// "Typing" = a text box took focus within 1.5 s of a real tap in this app. The tap
// requirement keeps focus that comes back on its own (an app re-activating, or moving
// between the stage and the top window) from triggering a swap.
static void SDPMaybeTyping(void) {
    if (!(gCfg & SDPConfigSwapTyping) && !(gCfg & SDPConfigSwapTouch)) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gSDPTouchHookOK && now - gLastTouch > 1.5) return;
    if (now - gLastTypingPost < 1.0) return;
    gLastTypingPost = now;
    UIResponder *fr = SDPFirstResponder();
    if (fr) gLastFR = fr;
    SDPPost(SDP_N_TYPING, (uint64_t)getpid());
}

void SDPAppTouch(UIEvent *event) {
    if (event.type != UIEventTypeTouches) return;
    BOOL began = NO;
    for (UITouch *t in event.allTouches) if (t.phase == UITouchPhaseBegan) { began = YES; break; }
    if (!began) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    gLastTouch = now;
    if ((gCfg & SDPConfigSwapTouch) && now - gLastTouchPost > 1.0) {
        gLastTouchPost = now;
        SDPPost(SDP_N_TOUCH, (uint64_t)getpid());
    }
}

void SDPAppHelperStart(void) {
    // config from SpringBoard: read now, and again whenever it changes
    notify_register_dispatch(SDP_N_CONFIG, &gCfgToken, dispatch_get_main_queue(), ^(int t) { SDPReadConfig(); });
    SDPReadConfig();

    int tok;
    notify_register_dispatch(SDP_N_KB_DISMISS, &tok, dispatch_get_main_queue(), ^(int t) {
        uint64_t target = SDPState(t);
        if (target != 0 && target != (uint64_t)getpid()) return;
        if (gKbUp || target != 0) SDPDismissKeyboard();
    });
    notify_register_dispatch(SDP_N_REFOCUS, &tok, dispatch_get_main_queue(), ^(int t) {
        if (SDPState(t) != (uint64_t)getpid()) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIResponder *r = gLastFR;
            if ([r isKindOfClass:UIView.class] && ((UIView *)r).window && !r.isFirstResponder) [r becomeFirstResponder];
        });
    });

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *mq = [NSOperationQueue mainQueue];
    [nc addObserverForName:UIKeyboardWillShowNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
        NSNumber *local = n.userInfo[UIKeyboardIsLocalUserInfoKey];
        if (local && !local.boolValue) return;            // another app's keyboard
        gKbUp = YES;
        // posted on every show (SpringBoard just records the pid), so a missed hide can't stick
        if (gCfg & SDPConfigKeyboardButton) SDPPost(SDP_N_KB_SHOW, (uint64_t)getpid());
        SDPMaybeTyping();
    }];
    [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
        NSNumber *local = n.userInfo[UIKeyboardIsLocalUserInfoKey];
        if (local && !local.boolValue) return;
        if (gKbUp) SDPPost(SDP_N_KB_HIDE, (uint64_t)getpid());
        gKbUp = NO;
    }];
    for (NSString *name in @[ UITextFieldTextDidBeginEditingNotification, UITextViewTextDidBeginEditingNotification ]) {
        [nc addObserverForName:name object:nil queue:mq usingBlock:^(NSNotification *n) { SDPMaybeTyping(); }];
    }
    for (NSString *name in @[ UIApplicationDidBecomeActiveNotification, UISceneDidActivateNotification,
                              UISceneWillEnterForegroundNotification ]) {
        [nc addObserverForName:name object:nil queue:mq usingBlock:^(NSNotification *n) { SDPReadConfig(); }];
    }
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
        if (gKbUp) SDPPost(SDP_N_KB_HIDE, (uint64_t)getpid());
        gKbUp = NO;
    }];
}
