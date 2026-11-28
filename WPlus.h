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

@class WPSheet;   // defined below; WPBubble references it

// ── host helpers (frontmost app, installed-app list, clipboard) ──
@interface WPHost : NSObject
+ (NSString *)frontmostBundleID;                 // the app currently in front, or nil
+ (NSString *)frontmostAppName;                  // its name as the home screen shows it, or nil
+ (BOOL)wingmanEnabledForFrontmost;              // YES if the front app should show the bubble
+ (NSArray<NSDictionary *> *)installedApps;      // @[ @{ @"id":bundleID, @"name":display } ], user apps, A–Z
+ (NSArray<NSString *> *)recentFrontmostApps;    // bundle ids recently seen in front, newest first (exact)
+ (void)copyToClipboard:(NSString *)text;        // puts a reply on the general pasteboard
+ (UIWindowScene *)mainScene;                    // SpringBoard's main scene: the bubble, toast and sheet live here
+ (BOOL)isMainScene:(UIWindowScene *)scene;      // YES only for that scene (never the Dynamic Island's)
@end

// ── whole-screen capture from SpringBoard (no app injection) ──
@interface WPCapture : NSObject
// One UIImage of the current screen (the front app), or nil. `hide`/`show`
// blocks let the caller drop its own overlay so the bubble isn't in the shot.
+ (UIImage *)captureScreenHiding:(void(^)(void))hide restore:(void(^)(void))show;
+ (UIImage *)captureNow;                         // capture without toggling any overlay (bubble already hidden)
+ (NSData *)probeSignature;                      // fingerprint of the screen right now, without keeping a frame
+ (NSData *)signatureOf:(UIImage *)img;          // tiny grayscale fingerprint for "did the screen change"
+ (BOOL)signature:(NSData *)a matches:(NSData *)b;  // YES if two frames are effectively the same (reached bottom)
@end

// ── scroll-capture: when is the screen worth a frame (a playing video must not flood or end a capture) ──
@interface WPScrollJudge : NSObject
- (instancetype)initWithFirst:(NSData *)first now:(CFAbsoluteTime)now;   // first: fingerprint of the starting frame, or nil
// Once per probe. mask: one byte per fingerprint cell, non-zero = ignore (our own bubble / hint). YES = keep a
// frame of this screen; settleKept:replacing:now: must follow.
- (BOOL)wantsFrame:(NSData *)probe mask:(NSData *)mask now:(CFAbsoluteTime)now;
// At the frame limit: index of the kept frame the wanted one should replace, or NSNotFound to leave the new one out.
- (NSInteger)frameToReplace;
- (void)settleKept:(BOOL)kept replacing:(NSInteger)idx now:(CFAbsoluteTime)now;
@end

// ── synthesize touch so the app under SpringBoard scrolls itself ──
@interface WPScroll : NSObject
+ (BOOL)available;                  // the private HID functions resolved (says nothing about whether the app moves)
// A synthetic one-finger swipe in normalized portrait coordinates (0..1). Blocks for about duration + hold:
// call it off the main thread. hold = how long the finger stays still before lifting (no fling).
+ (BOOL)swipeFrom:(CGPoint)a to:(CGPoint)b duration:(NSTimeInterval)duration hold:(NSTimeInterval)hold;
+ (void)watchForRealTouch;          // for a few seconds, take the touchscreen's sender ID from a real touch
+ (NSString *)diagnostics;          // one line for the self-test log
@end

// ── on-device checks run over USB SSH (see WPSelfTest.m) ──
@interface WPSelfTest : NSObject
+ (void)start;
+ (void)note:(NSString *)line;   // one line in the self-test log (counts and names only, never screen text)
@end

// ── keyboard focus: a SpringBoard overlay only gets the keyboard if SpringBoard takes focus ──
@interface WPFocus : NSObject
+ (void)takeKeyboardForWindow:(UIWindow *)window;   // call once the overlay window is key and visible
+ (void)giveKeyboardBack;                            // call whenever the overlay hides; the app gets focus back
@end

// ── floating bubble (a SpringBoard window above the front app) ──
@interface WPBubble : NSObject
+ (instancetype)shared;
- (void)start;                 // build once SpringBoard's UI is up
- (void)evaluateVisibility;    // show over enabled apps, hide elsewhere
- (void)beginAppendTo:(WPSheet *)sheet;  // hide the sheet; next tap adds a screen to it
@property (nonatomic, strong) UIWindow *window;
// Self-test only: one auto-scroll capture of the screen in front, forced on whatever the app; reports how it
// went instead of opening the sheet. Ignored if a capture is already running.
- (void)selfTestAutoCapture:(void (^)(NSUInteger frames, NSInteger swipes, NSString *ended))done;
@end

// ── reply sheet (another SpringBoard overlay window) ──
@interface WPSheet : UIViewController
- (instancetype)initWithImage:(UIImage *)shot;   // the captured screen
- (void)appendImage:(UIImage *)shot;             // "capture another screen"
- (void)presentGlobally;
- (void)dismissForAppend;                        // hide (kept alive) to capture another screen
- (void)reshowAfterAppend;                       // bring back after a screen was appended
@end
