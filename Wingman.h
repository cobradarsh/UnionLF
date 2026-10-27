/*  Wingman.h — master header
    Personal reply-assistant tweak for iOS 16.5 / RootHide + ElleKit
    Adarsh · 2026                                                    */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@class WMBubble, WMSheet, WMAPIClient, WMCapture, WMSettings;

// Our OWN URLSession. Never use [NSURLSession sharedSession] inside a host app:
// its delegate queue is shared with the host (WhatsApp), and our completion
// handlers running there collide with the host's notification/weak-ref locks
// (a recursive os_unfair_lock abort -> SIGTRAP). A private session runs every
// Wingman callback on our own serial queue, fully isolated from the host.
NSURLSession *WMPrivateSession(void);

// ── reply styles (one is picked per generation) ───────────
typedef NS_ENUM(NSInteger, WMReplyMode) {
    WMReplyModeAggressive = 0,
    WMReplyModeDecentRoast,
    WMReplyModeRoastedToHell,
    WMReplyModeInMyFavor,
    WMReplyModeDefendMe,
    WMReplyModeFunny,
    WMReplyModeFlirty,
    WMReplyModeGenZ,
    WMReplyModeLyrical,
    WMReplyModeExcited,
    WMReplyModeFormal,
    WMReplyModeChill,
    WMReplyModeEmojify,
    WMReplyModeRemix,
    // dating / flirt styles (consenting adults)
    WMReplyModePlanDate,
    WMReplyModeRomance,
    WMReplyModeSeduce,
    WMReplyModeSensual,
    WMReplyModeLustful,
    WMReplyModeDirty,
    WMReplyModeCount
};

static WMReplyMode const WMReplyModeFirstDating = WMReplyModePlanDate;

typedef NS_ENUM(NSInteger, WMReplyLength) {
    WMReplyLengthShort = 0,
    WMReplyLengthLong
};

typedef NS_ENUM(NSInteger, WMAPIProvider) {
    WMAPIProviderClaude = 0,
    WMAPIProviderDeepSeek
};

typedef NS_ENUM(NSInteger, WMAppKind) {
    WMAppKindNone = 0,     // Wingman stays hidden
    WMAppKindChat,
    WMAppKindDating,
    WMAppKindManual        // picked by you in Settings (e.g. Hopr)
};

static NSInteger const kWMRepliesPerCall = 3;

// The app's current foreground scene (falls back to any window scene).
// Windows must attach to a live scene or iOS never shows them.
static inline UIWindowScene *WMActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback || s.activationState == UISceneActivationStateForegroundInactive)
            fallback = (UIWindowScene *)s;
    }
    return fallback;
}
static NSInteger const kWMQuickReplyCount = 5;

// ── settings ──────────────────────────────────────────────
@interface WMSettings : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) WMAPIProvider provider;        // default provider
@property (nonatomic, readonly, copy) NSString *claudeKey;
@property (nonatomic, readonly, copy) NSString *claudeModel;
@property (nonatomic, readonly) BOOL claudeSendsScreenshot;     // NO = text transcript only
@property (nonatomic, readonly, copy) NSString *deepseekKey;
@property (nonatomic, readonly, copy) NSString *deepseekModel;
@property (nonatomic, readonly, copy) NSString *deepseekEndpoint; // full .../chat/completions URL
@property (nonatomic, readonly, copy) NSString *soundLikeMe;
@property (nonatomic, readonly) BOOL autoDetectApps;
@property (nonatomic, readonly, copy) NSArray<NSString *> *manualApps;
@property (nonatomic, readonly) BOOL bubbleOnRight;
@property (nonatomic, readonly) CGFloat bubbleAlpha;
@property (nonatomic, readonly, copy) NSString *deepseekBaseURL;  // without /chat/completions

- (void)reload;
- (NSString *)diagnostics;        // which stores were readable, what was found
- (void)clearLocalOverrides;      // forget values saved for this app only

- (NSString *)keyForProvider:(WMAPIProvider)p;
- (NSString *)modelForProvider:(WMAPIProvider)p;
- (BOOL)hasChosenModelForProvider:(WMAPIProvider)p;  // NO = still on the built-in default

// Each returns YES if the value was stored for ALL apps, NO if iOS only let
// this one app keep it (still works here, just not everywhere).
- (BOOL)saveKey:(NSString *)key forProvider:(WMAPIProvider)p;
- (BOOL)saveModel:(NSString *)modelID forProvider:(WMAPIProvider)p;
- (BOOL)saveProvider:(WMAPIProvider)p;   // remembers Claude vs DeepSeek
- (BOOL)setValue:(id)value forSettingKey:(NSString *)key;
@end

// ── model list from your API key ──────────────────────────
@interface WMModels : NSObject
// models = array of @{ @"id": ..., @"name": ... }, newest first for Claude.
// A successful fetch also proves the key is valid, so this doubles as Verify.
+ (void)fetchForProvider:(WMAPIProvider)p
                   force:(BOOL)force
              completion:(void(^)(NSArray<NSDictionary *> *models, NSError *err))done;
// key == nil uses the saved key; pass one to test it before saving
+ (void)fetchForProvider:(WMAPIProvider)p
                     key:(NSString *)key
                   force:(BOOL)force
              completion:(void(^)(NSArray<NSDictionary *> *models, NSError *err))done;
@end

// ── which apps get Wingman ────────────────────────────────
@interface WMApps : NSObject
+ (WMAppKind)kindForBundleID:(NSString *)bundleID;   // reads settings
+ (WMAppKind)currentKind;
+ (NSString *)currentAppName;
@end

// ── per-app quick replies (stored in each app's own defaults) ─
@interface WMQuickReplies : NSObject
+ (NSArray<NSString *> *)repliesForCurrentApp;
+ (void)setReply:(NSString *)text atIndex:(NSInteger)idx;
+ (void)resetCurrentApp;
@end

// ── on-device chat reading (Apple Vision OCR) ─────────────
@interface WMOCR : NSObject
// "THEM: ... / ME: ..." transcript, system + encryption notices removed.
// Returns nil if nothing usable was read.
+ (void)transcriptFromFrames:(NSArray<UIImage *> *)frames
                  completion:(void(^)(NSString *transcript, NSInteger messageCount))done;
// the ignore ruleset (also used by the prompt)
+ (BOOL)isSystemNotice:(NSString *)line;
@end

// ── screen capture ────────────────────────────────────────
@interface WMCapture : NSObject
+ (NSArray<UIImage *> *)screenshotHidingView:(UIView *)viewToHide;
+ (void)scrollCaptureHidingView:(UIView *)viewToHide
                     completion:(void(^)(NSArray<UIImage *> *frames))done;
@end

// ── floating bubble ───────────────────────────────────────
@interface WMBubble : NSObject
+ (instancetype)shared;
- (void)show;            // create or re-show (re-attaches to the live scene)
- (void)hide;            // temporary, e.g. while capturing
- (void)hideUntilReopen; // user dismissed it; comes back next time the app opens
- (void)refresh;         // called when the app becomes active
- (void)appWillEnterForeground;   // clears a user hide
@property (nonatomic, readonly) BOOL userHidden;
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) UIView   *bubbleView;
@end

// ── reply sheet ───────────────────────────────────────────
@interface WMSheet : UIViewController
- (instancetype)initWithImages:(NSArray<UIImage *> *)frames;
- (void)presentGlobally;
@end

// ── API client ────────────────────────────────────────────
@interface WMAPIClient : NSObject
+ (instancetype)shared;
- (void)generateRepliesWithProvider:(WMAPIProvider)provider
                             frames:(NSArray<UIImage *> *)frames
                         transcript:(NSString *)transcript
                            context:(NSString *)context
                               mode:(WMReplyMode)mode
                             length:(WMReplyLength)length
                         completion:(void(^)(NSArray<NSString *> *replies, NSError *err))done;
@end

// ── prompts  (edit WMPrompts.m to change reply style) ─────
@interface WMPrompts : NSObject
+ (NSString *)systemPromptWithSoundLikeMe:(NSString *)style;
+ (NSString *)userPromptForMode:(WMReplyMode)mode
                         length:(WMReplyLength)length
                        context:(NSString *)context
                     transcript:(NSString *)transcript
                      hasImages:(BOOL)hasImages;
+ (NSString *)labelForMode:(WMReplyMode)mode;
+ (NSString *)emojiForMode:(WMReplyMode)mode;
@end
