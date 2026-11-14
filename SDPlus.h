/*  SDPlus.h — Dynamic Stage+ (add-on for tomt000's Dynamic Stage 1.2)

    One dylib, loaded into SpringBoard AND into apps (filter: com.apple.UIKit).

    SpringBoard side
      • floating "hide keyboard" button (same look as the Wingman bubble)
      • auto-swap: the bottom (stage) app jumps to the top when you type / tap in it
      • App Pairs: long-press an app icon → "Open with <other app>"
    App side (tiny)
      • tells SpringBoard when its keyboard shows/hides and when you engage with it
      • dismisses its keyboard when SpringBoard asks

    The two sides talk over Darwin notifications. A notification can't carry a
    payload, so the sender puts one 64-bit value in the name's notify "state"
    (its pid, or a bitmask) right before posting.                Adarsh · 2026   */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

#define SDP_N_CONFIG      "com.adarsh.sdplus.config"         // SB -> apps   state = SDPConfigBits
#define SDP_N_KB_SHOW     "com.adarsh.sdplus.kb.show"        // app -> SB    state = pid
#define SDP_N_KB_HIDE     "com.adarsh.sdplus.kb.hide"        // app -> SB    state = pid
#define SDP_N_KB_DISMISS  "com.adarsh.sdplus.kb.dismiss"     // SB -> apps   state = target pid (0 = every app)
#define SDP_N_TYPING      "com.adarsh.sdplus.engage.typing"  // app -> SB    state = pid
#define SDP_N_TOUCH       "com.adarsh.sdplus.engage.touch"   // app -> SB    state = pid
#define SDP_N_REFOCUS     "com.adarsh.sdplus.refocus"        // SB -> apps   state = pid that should re-open its keyboard
#define SDP_N_PREFS       "com.adarsh.stageduoplus/prefs"    // Settings -> SB (PostNotification)
#define SDP_DOMAIN        @"com.adarsh.stageduoplus"
#define SDP_VERSION       @"1.0.10"                          // keep in step with control

typedef NS_OPTIONS(uint64_t, SDPConfigBits) {
    SDPConfigKeyboardButton = 1 << 0,   // apps report keyboard show/hide
    SDPConfigSwapTyping     = 1 << 1,   // apps report "started typing"
    SDPConfigSwapTouch      = 1 << 2,   // apps report "touched"
    SDPConfigValid          = 1 << 7,   // SpringBoard has published a config
};

typedef NS_ENUM(NSInteger, SDPSwapMode) { SDPSwapOff = 0, SDPSwapTyping = 1, SDPSwapTouch = 2 };

extern BOOL gSDPIsSpringBoard;

void SDPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void SDPPost(const char *name, uint64_t state);       // set the name's state, then post it
uint64_t SDPState(int token);                         // read the state behind a registered token

// Send a no-argument message that returns an object, only if the target answers it.
static inline id SDPMsg(id target, NSString *selName) {
    if (!target) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![target respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, s);
}

// ── settings (SpringBoard reads them; apps only ever see the config bits) ──
@interface SDPSettings : NSObject
+ (instancetype)shared;
- (void)reload;                                   // re-read prefs, republish config bits
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL keyboardButton;
@property (nonatomic, readonly) BOOL keyboardButtonOnlyInStage;
@property (nonatomic, readonly) CGFloat keyboardButtonSize;
@property (nonatomic, readonly) SDPSwapMode swapMode;
@property (nonatomic, readonly) BOOL refocusAfterSwap;
@property (nonatomic, readonly) BOOL pairsEnabled;
@property (nonatomic, readonly) BOOL swapButton;
@property (nonatomic, readonly) BOOL debugLog;
- (NSArray<NSDictionary *> *)pairs;               // @[ @{ @"top": bundleID, @"bottom": bundleID } ]
- (void)setPairs:(NSArray<NSDictionary *> *)pairs;
@end

// ── SpringBoard helpers ──
@interface SDPHost : NSObject
+ (NSString *)frontmostBundleID;                  // app on top, nil on the home screen
+ (id)applicationForBundleID:(NSString *)bid;     // SBApplication
+ (pid_t)pidForBundleID:(NSString *)bid;          // 0 if not running
+ (NSString *)bundleIDForPid:(pid_t)pid;
+ (NSString *)displayNameForBundleID:(NSString *)bid;
+ (UIImage *)iconForBundleID:(NSString *)bid;
+ (BOOL)launchApp:(NSString *)bid;                // bring an app to the front (top window)
+ (UIWindowScene *)mainScene;                     // SpringBoard's main scene (never the Dynamic Island's)
+ (void)toast:(NSString *)msg;
+ (void)noteFront:(NSString *)bid;                // remember recently used apps for the pair picker
+ (NSArray<NSString *> *)recentApps;
+ (NSArray<NSDictionary *> *)installedApps;       // @[ @{ @"id", @"name" } ] A–Z, no Apple system apps
@end

// Swap/pair knobs, adjustable at runtime from the debug command file (SDPDebug.m).
typedef struct {
    double settle;        // seconds to wait after Dynamic Stage settles before opening the old top app
    BOOL openOldTop;      // open the old top app in the stage if Dynamic Stage didn't move it there
    BOOL guardKills;      // skip Dynamic Stage's kills of the two apps during a swap
    BOOL guardPairs;      // same during a pair launch
    double revealTo;      // synthetic reveal swipe ends at this fraction of the screen height
    int revealFrames;     // ... over this many 60 Hz frames
    int revealHold;       // then this many frames holding still before the finger lifts
    int revealEndGap;     // frames between the last move and "ended" (a real finger never has 0)
    double revealReset;   // seconds after "ended" before the recognizer resets to Possible (<0 = never)
    BOOL revealShouldBegin; // ask the gesture view gestureRecognizerShouldBegin: first, like Dynamic Stage's own hook
    double fitFrac;       // top window height as a fraction of the screen (0.497 = the native split measured on device)
    double fitDelay;      // seconds after the reveal before the top app is fitted
    int revealViewMode;   // view the synthetic swipe reports: 0 gesture view, 1 its window, 2 its superview
    BOOL revealCleanup;   // if Dynamic Stage leaves the card in its "dragging" look, finish it ourselves
    int guardSwap;        // skip Dynamic Stage's kills during a swap: 0 none, 1 the app moving down (default), 2 both
    int swapStyle;        // 2 = expand, open old top while it's in the background, reveal, fit (default)
                          // 0 = open top in the stage first, raise bottom, reveal; 1 = native expand only
} SDPTune;
extern SDPTune gSDPTune;

// ── bridge to Dynamic Stage's (obfuscated) classes ──
@interface SDPStage : NSObject
+ (BOOL)available;                                // Dynamic Stage 1.2 classes are present
+ (BOOL)isOpen;                                   // an app is showing in the stage window
+ (NSString *)stageBundleID;                      // that app (the bottom one)
+ (CGRect)stageFrame;                             // the stage window on screen (zero if none)
+ (BOOL)openInStage:(NSString *)bid;              // what tapping an app in Dynamic Stage's strip does
+ (void)swapWithReason:(NSString *)why refocus:(BOOL)refocus;
+ (BOOL)nativeExpand;                             // Dynamic Stage's own "bring the stage app to the front"
+ (BOOL)revealStage;                              // a synthetic swipe-up: shows a hidden stage window
+ (void)stopGesture;                              // Dynamic Stage's own gesture "stop" (un-sticks the card)
+ (id)debugTarget:(NSString *)name;               // gv | card | pane | mgr | helper (for test commands)
+ (void)fitTopApp:(NSString *)bid;               // store the top-window frame for bid and relaunch it (sub_95e44)
+ (NSString *)relaunchInfo;                       // Dynamic Stage's stored relaunch bundle + frame
+ (void)finishCard;                               // clear the drag look: blur, tint, scale, animation loop
+ (id)lastSwipe;
+ (void)engagementFromPid:(pid_t)pid typing:(BOOL)typing;
+ (void)launchPairTop:(NSString *)top bottom:(NSString *)bottom;
+ (BOOL)isKillGuarded:(NSString *)bid;            // YES while a swap/pair is moving this app
+ (NSString *)diagnostics;                        // one line for the log
@end

// ── the floating hide-keyboard button ──
@interface SDPKeyboardButton : NSObject
+ (instancetype)shared;
- (void)keyboardShownInPid:(pid_t)pid;
- (void)keyboardHiddenInPid:(pid_t)pid;
- (void)refresh;                                  // re-evaluate visibility (timer, prefs change)
@end

// ── the floating swap button (shows while two apps are open) ──
@interface SDPSwapButton : NSObject
+ (instancetype)shared;
- (void)refresh;
@end

// ── App Pairs manager sheet (opened from the icon menu) ──
@interface SDPPairsSheet : UIViewController
+ (void)presentForBundleID:(NSString *)bid;
@end

void SDPSpringBoardStart(void);
void SDPAppHelperStart(void);
void SDPAppTouch(UIEvent *event);              // called from the -[UIApplication sendEvent:] hook
extern BOOL gSDPTouchHookOK;
void SDPDebugInstall(void);                        // call tracing (SpringBoard)
void SDPDebugTick(void);                           // runs /var/mobile/Library/Logs/sdp_cmd.txt
NSString *SDPBacktrace(NSUInteger skip, NSUInteger count);
