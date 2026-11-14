/*  SDPApp.m — the small part that runs inside apps.

    • Tells SpringBoard while this app's keyboard is REALLY on screen, so the hide-keyboard
      button shows then and only then (see "keyboard lease" below).
    • Reports "you started typing here" (a text box took focus right after a tap) and,
      in Any Tap mode, "you touched here", so SpringBoard can swap this app to the top
      when it's the one in the stage window.
    • Drops its keyboard when SpringBoard asks, and can re-open it after a swap.

    Keyboard lease. Up to 1.0.10 the app posted "shown" / "hidden" events and SpringBoard kept a
    list. Two things made that list lie, and the button then floated over Camera, Contacts and
    everything else:
      1. iOS posts UIKeyboardWillShow for more than a keyboard: a chat app's message bar is an
         "input accessory view" and counts as a 60-100 pt tall keyboard with no keys at all.
      2. iOS posts UIKeyboardWillShow again while an app is being sent to the background (it
         redraws the keyboard for the app-switcher snapshots), after the app had said "hidden".
         The app is then frozen, never says "hidden" again, and stays on the list for hours.
    Now nothing is remembered. While the keyboard is up, this process stamps the current uptime
    into its own notify state once a second (SDP_N_KB_STATE + pid) and SpringBoard only believes a
    stamp younger than 3 s. A frozen, backgrounded or killed app cannot stamp, so it drops out by
    itself, and "up" means: the keyboard minus any accessory bar is at least 150 pt tall, the app
    is in the foreground and it is active (not behind Control Center or the app switcher).

    It only reports what SpringBoard's config bits ask for, so it costs nothing in apps you
    aren't typing in. */

#import "SDPlus.h"

static int gCfgToken = -1;
static uint64_t gCfg;
static BOOL gKbUp;                      // the keyboard itself (not just an accessory bar) is showing here
static BOOL gResigned;                  // between willResignActive and didBecomeActive
static BOOL gKbPublished;               // what SpringBoard was last told
static int gKbLeaseToken = -1;          // this process's lease (see above)
static NSTimer *gKbBeat;
static NSUInteger gKbDownGen;           // cancels a pending "hidden" when the keyboard comes straight back
static CGFloat gKbHeight, gKbAccessory; // last measured, for the debug report
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

static void SDPDismissKeyboard(void) {
    UIApplication *app = [UIApplication sharedApplication];
    [app sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) [w endEditing:YES];
    }
}

#pragma mark - keyboard lease

// Height of the bar an app pins above its keyboard (WhatsApp's message box, Safari's form
// bar…). iOS counts it as part of the keyboard, and as the whole "keyboard" when there are no keys.
static CGFloat SDPAccessoryHeight(void) {
    CGFloat h = 0;
    @try {
        UIResponder *fr = SDPFirstResponder();
        UIView *acc = fr.inputAccessoryView ?: fr.inputAccessoryViewController.view;
        if ([acc isKindOfClass:UIView.class]) h = acc.bounds.size.height;
    } @catch (__unused NSException *e) {}
    return h;
}

static CGFloat SDPMinKeyboardHeight(void) {
    CGFloat h = ((gCfg >> SDPConfigKbMinShift) & 0xFF) * 2.0;   // SpringBoard can tune it live
    return h >= 40 ? h : 150;                                   // shortest real iPhone keyboard is ~160 pt
}

static BOOL SDPKeyboardVisible(void) {
    if (!gKbUp || !(gCfg & SDPConfigKeyboardButton)) return NO;
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return NO;
    if (gResigned && (gCfg & SDPConfigStrictActive)) return NO;
    return YES;
}

static void SDPKeyboardReport(SDPKbEvent ev) {
    if (!(gCfg & SDPConfigDebug)) return;
    // what UIKit itself says, logged next to our own answer (not used to decide anything)
    uint64_t uikit = 0;
    Class kb = NSClassFromString(@"UIKeyboard");
    SEL onScreen = NSSelectorFromString(@"isOnScreen");
    if (kb && [kb respondsToSelector:onScreen]) uikit = 1 | (((BOOL (*)(id, SEL))objc_msgSend)(kb, onScreen) ? 2 : 0);
    uint64_t v = ((uint64_t)getpid() & 0x3FFFFF) | (uikit << 51)
               | ((uint64_t)(gKbUp ? 1 : 0) << 22) | ((uint64_t)(gKbPublished ? 1 : 0) << 23)
               | ((uint64_t)(gResigned ? 1 : 0) << 24)
               | ((uint64_t)([UIApplication sharedApplication].applicationState & 3) << 25)
               | ((uint64_t)MIN(1023, (int)lround(gKbHeight)) << 27)
               | ((uint64_t)MIN(1023, (int)lround(gKbAccessory)) << 37)
               | ((uint64_t)(ev & 0xF) << 47);
    SDPPost(SDP_N_APPDBG, v);
}

// Stamp the lease (or clear it) and tell SpringBoard to look. Also the 1 Hz beat.
static void SDPPublishKeyboard(SDPKbEvent ev) {
    BOOL visible = SDPKeyboardVisible();
    if (gKbLeaseToken >= 0) notify_set_state(gKbLeaseToken, visible ? MAX((uint64_t)1, SDPUptimeDs()) : 0);
    if (visible) {
        gKbDownGen++;
        SDPPost(SDP_N_KB_SHOW, (uint64_t)getpid());            // every beat, so a lost ping heals within a second
        if (!gKbBeat) {
            gKbBeat = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { SDPPublishKeyboard(SDPKbBeat); }];
            [[NSRunLoop mainRunLoop] addTimer:gKbBeat forMode:NSRunLoopCommonModes];   // keeps beating while you scroll
        }
    } else {
        if (gKbPublished) SDPPost(SDP_N_KB_HIDE, (uint64_t)getpid());
        [gKbBeat invalidate];
        gKbBeat = nil;
    }
    BOOL changed = visible != gKbPublished;
    gKbPublished = visible;
    // Debug Log: every keyboard event and every change, but not each app's comings and goings
    BOOL kbEvent = ev == SDPKbWillShow || ev == SDPKbDidShow || ev == SDPKbWillHide || ev == SDPKbDidHide;
    if (changed || kbEvent || (gKbUp && ev != SDPKbBeat)) SDPKeyboardReport(ev);
}

// Moving between two text boxes can post "will hide" and "will show" back to back; waiting a
// moment before saying "hidden" keeps the button from blinking.
static void SDPPublishKeyboardSoon(SDPKbEvent ev) {
    if (SDPKeyboardVisible() || !gKbPublished) { SDPPublishKeyboard(ev); return; }
    SDPKeyboardReport(ev);
    NSUInteger gen = ++gKbDownGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == gKbDownGen) SDPPublishKeyboard(SDPKbBeat);
    });
}

static void SDPMaybeTyping(void);

static void SDPKeyboardNote(NSNotification *n, BOOL showing, SDPKbEvent ev) {
    NSNumber *local = n.userInfo[UIKeyboardIsLocalUserInfoKey];
    if (local && !local.boolValue) return;                      // another process's keyboard
    BOOL up = NO;
    if (showing) {
        NSValue *end = n.userInfo[UIKeyboardFrameEndUserInfoKey];
        gKbHeight = end ? end.CGRectValue.size.height : 0;
        gKbAccessory = SDPAccessoryHeight();
        up = (gKbHeight - gKbAccessory) >= SDPMinKeyboardHeight();
    } else {
        gKbHeight = 0;
        gKbAccessory = 0;
    }
    gKbUp = up;
    SDPPublishKeyboardSoon(ev);
    if (up && ev == SDPKbWillShow) SDPMaybeTyping();            // a real keyboard, not a message bar
}

static void SDPReadConfig(void) {
    if (gCfgToken < 0) return;
    uint64_t was = gCfg;
    gCfg = SDPState(gCfgToken);
    if (gCfg != was) SDPPublishKeyboard(SDPKbConfig);
}

#pragma mark - engagement (auto-swap)

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

#pragma mark - test helper (Debug Log only)

static UIView *SDPFindTextInput(UIView *v, int depth) {
    if (depth > 40 || v.hidden || v.alpha < 0.01) return nil;
    if ([v isKindOfClass:UISearchBar.class]) return ((UISearchBar *)v).searchTextField;
    if ([v isKindOfClass:UITextField.class] && ((UITextField *)v).enabled && v.userInteractionEnabled) return v;
    if ([v isKindOfClass:UITextView.class] && ((UITextView *)v).editable && v.userInteractionEnabled) return v;
    for (UIView *s in v.subviews) {
        UIView *r = SDPFindTextInput(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

#pragma mark - start

void SDPAppHelperStart(void) {
    dispatch_queue_t mq = dispatch_get_main_queue();

    NSString *lease = [NSString stringWithFormat:@"%s%d", SDP_N_KB_STATE, getpid()];
    if (notify_register_check(lease.UTF8String, &gKbLeaseToken) == NOTIFY_STATUS_OK) notify_set_state(gKbLeaseToken, 0);
    else gKbLeaseToken = -1;

    // config from SpringBoard: read now, and again whenever it changes
    notify_register_dispatch(SDP_N_CONFIG, &gCfgToken, mq, ^(int t) { SDPReadConfig(); });
    SDPReadConfig();

    int tok;
    notify_register_dispatch(SDP_N_KB_DISMISS, &tok, mq, ^(int t) {
        uint64_t target = SDPState(t);
        if (target != 0 && target != (uint64_t)getpid()) return;
        if (gKbUp || target != 0) SDPDismissKeyboard();
    });
    notify_register_dispatch(SDP_N_REFOCUS, &tok, mq, ^(int t) {
        if (SDPState(t) != (uint64_t)getpid()) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), mq, ^{
            UIResponder *r = gLastFR;
            if ([r isKindOfClass:UIView.class] && ((UIView *)r).window && !r.isFirstResponder) [r becomeFirstResponder];
        });
    });
    // tests: "focus any text box you have" (only honoured while Debug Log is on)
    notify_register_dispatch(SDP_N_DBG_FOCUS, &tok, mq, ^(int t) {
        if (!(gCfg & SDPConfigDebug) || SDPState(t) != (uint64_t)getpid()) return;
        UIView *input = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!input && !w.hidden) input = SDPFindTextInput(w, 0);
            }
        }
        gKbHeight = [input becomeFirstResponder] ? 1 : 0;       // reported as h=1 (focused) / h=0 (nothing to focus)
        gKbAccessory = 0;
        SDPKeyboardReport(SDPKbFocus);
    });

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *q = [NSOperationQueue mainQueue];
    [nc addObserverForName:UIKeyboardWillShowNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        SDPKeyboardNote(n, YES, SDPKbWillShow);
    }];
    [nc addObserverForName:UIKeyboardDidShowNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        SDPKeyboardNote(n, YES, SDPKbDidShow);                  // sizes are final now: measure again
    }];
    [nc addObserverForName:UIKeyboardWillHideNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        SDPKeyboardNote(n, NO, SDPKbWillHide);
    }];
    [nc addObserverForName:UIKeyboardDidHideNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        SDPKeyboardNote(n, NO, SDPKbDidHide);
    }];
    for (NSString *name in @[ UITextFieldTextDidBeginEditingNotification, UITextViewTextDidBeginEditingNotification ]) {
        [nc addObserverForName:name object:nil queue:q usingBlock:^(NSNotification *n) { SDPMaybeTyping(); }];
    }

    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        gResigned = YES;
        SDPPublishKeyboard(SDPKbResign);
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        gResigned = NO;
        SDPReadConfig();
        SDPPublishKeyboard(SDPKbActive);
    }];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        SDPPublishKeyboard(SDPKbBackground);                    // gKbUp is kept: iOS brings the keyboard back with the app
    }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:q usingBlock:^(NSNotification *n) {
        SDPReadConfig();
        SDPPublishKeyboard(SDPKbForeground);
    }];
    for (NSString *name in @[ UISceneDidActivateNotification, UISceneWillEnterForegroundNotification ]) {
        [nc addObserverForName:name object:nil queue:q usingBlock:^(NSNotification *n) { SDPReadConfig(); }];
    }
}
