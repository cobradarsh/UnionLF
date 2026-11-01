/*  WPlus.h — Wingman Plus host layer (SpringBoard-only)

    Wingman Plus NEVER injects into a dating app. Its dylib loads only into
    com.apple.springboard, so Hinge (and any app with jailbreak detection)
    sees nothing foreign in its process and never crashes. From SpringBoard we:
      • float a bubble over whatever app is in front,
      • grab the screen with a private UIKit call (the Snapper 3 method),
      • OCR it on-device and generate a reply,
      • hand the reply back via the clipboard (and, later, the Wingman keyboard).
                                                            Adarsh · 2026   */

#import "Wingman.h"

// ── host helpers (frontmost app, installed-app list, clipboard) ──
@interface WPHost : NSObject
+ (NSString *)frontmostBundleID;                 // the app currently in front, or nil
+ (BOOL)wingmanEnabledForFrontmost;              // YES if the front app should show the bubble
+ (NSArray<NSDictionary *> *)installedApps;      // @[ @{ @"id":bundleID, @"name":display } ], user apps, A–Z
+ (void)copyToClipboard:(NSString *)text;        // puts a reply on the general pasteboard
@end

// ── whole-screen capture from SpringBoard (no app injection) ──
@interface WPCapture : NSObject
// One UIImage of the current screen (the front app), or nil. `hide`/`show`
// blocks let the caller drop its own overlay so the bubble isn't in the shot.
+ (UIImage *)captureScreenHiding:(void(^)(void))hide restore:(void(^)(void))show;
@end

// ── floating bubble (a SpringBoard window above the front app) ──
@interface WPBubble : NSObject
+ (instancetype)shared;
- (void)start;                 // build once SpringBoard's UI is up
- (void)evaluateVisibility;    // show over enabled apps, hide elsewhere
- (void)beginAppendTo:(WPSheet *)sheet;  // hide the sheet; next tap adds a screen to it
@property (nonatomic, strong) UIWindow *window;
@end

// ── reply sheet (another SpringBoard overlay window) ──
@interface WPSheet : UIViewController
- (instancetype)initWithImage:(UIImage *)shot;   // the captured screen
- (void)appendImage:(UIImage *)shot;             // "capture another screen"
- (void)presentGlobally;
- (void)dismissForAppend;                        // hide (kept alive) to capture another screen
- (void)reshowAfterAppend;                       // bring back after a screen was appended
@end
