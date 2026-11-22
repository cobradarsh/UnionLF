/*  Shani.h — shared declarations.

    Shani adds one button to every notification: "Shani". Tap it and that app goes on Shani's
    list. From then on the app's notifications are kept back for a time you choose in
    Settings → Shani, and come up when the time is over. Everything those apps send is written
    to a log per app.

    Two libraries:
      Shani.dylib       in SpringBoard: the hooks, the holding, the log
      ShaniPrefs.dylib  in the Settings app: the Apps & Log pages (PrefsHelper.m)

    ShaniStore.m is compiled into both: where the files are and how they are read.            */

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define SHANI_VERSION        @"1.0.0"
#define SHANI_DOMAIN         @"com.adarsh.shani"
#define SHANI_NOTE_PREFS     "com.adarsh.shani/prefs"       // Settings → SpringBoard: a setting changed
#define SHANI_NOTE_CHANGED   "com.adarsh.shani/changed"     // SpringBoard → Settings: the list, a log or what is held changed
#define SHANI_NOTE_RELEASE   "com.adarsh.shani/release"     // Settings → SpringBoard: show what is held now
#define SHANI_ACTION_ID      @"com.adarsh.shani.action"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - ShaniStore.m (both libraries)

// What happened to one notification of an app on Shani's list.
typedef NS_ENUM(NSInteger, ShaniFate) {
    ShaniFateShown     = 0,     // came up as usual (nothing was holding the app)
    ShaniFateHeld      = 1,     // being kept back right now
    ShaniFateReleased  = 2,     // was kept back, then shown
    ShaniFateLogOnly   = 3,     // was kept back and never shown ("keep them in the log only")
    ShaniFateWithdrawn = 4,     // the app took it back while it was kept
    ShaniFateTapped    = 5,     // the notification you tapped Shani on
    ShaniFateCritical  = 6,     // a critical alert: never kept back
};

NSString *ShaniDataDir(void);                                   // …/Library/Shani
NSString *ShaniLogDir(void);                                    // …/Library/Logs (debug log, test command file)
NSString *ShaniStatePath(void);
NSString *ShaniNoteLogPath(NSString *bundleID);                 // the notification log of one app
NSArray<NSDictionary *> *ShaniReadNoteLog(NSString *bundleID);  // oldest first
NSArray<NSString *> *ShaniAppsWithNoteLogs(void);
NSDictionary *ShaniReadState(void);
NSString *ShaniFateText(NSDictionary *entry);                   // "Held · shown 4:32 PM"
NSString *ShaniPeriodText(NSInteger minutes);                   // "2 hours"
NSString *ShaniClockText(double epoch);                         // "4:32 PM", with the day when it is not today
NSArray<NSString *> *ShaniCleanList(id _Nullable raw);          // an array of non-empty strings, no repeats

#pragma mark - ShaniCore.m (SpringBoard)

void ShaniLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void ShaniLogFlush(void);
void ShaniAfter(double seconds, dispatch_block_t block);
double ShaniNow(void);                                          // epoch seconds (tests can move it forward)
void ShaniDebugShiftClock(double seconds);

BOOL ShaniShape(id _Nullable target, SEL sel, const char *returns, NSUInteger args);
BOOL ShaniArgIs(id target, SEL sel, NSUInteger index, const char *types);
id _Nullable ShaniMsg(id _Nullable target, NSString *selName);
id _Nullable ShaniMsgObj(id _Nullable target, NSString *selName, id _Nullable arg);
BOOL ShaniBoolMsg(id _Nullable target, NSString *selName, BOOL fallback);
long long ShaniIntMsg(id _Nullable target, NSString *selName, long long fallback);
BOOL ShaniSend(id _Nullable target, NSString *selName);
BOOL ShaniSendBool(id _Nullable target, NSString *selName, BOOL arg);
BOOL ShaniSendInt(id _Nullable target, NSString *selName, long long arg);
BOOL ShaniSendObj(id _Nullable target, NSString *selName, id _Nullable arg);
NSString *_Nullable ShaniStr(id _Nullable target, NSString *selName);       // a string-returning method, or nil
BOOL ShaniHook(NSString *className, NSString *selName, IMP replacement, IMP _Nullable *_Nonnull original);

typedef NS_ENUM(NSInteger, ShaniMode) {
    ShaniModeEveryTime = 0,     // the app stays on the list; every new notification starts (or joins) a hold
    ShaniModeOncePerTap = 1,    // a tap silences the app once, from the tap, for the chosen time
};

typedef NS_ENUM(NSInteger, ShaniReleaseStyle) {
    ShaniReleaseOneAlert = 0,   // all come up, the newest with banner and sound, the others quietly
    ShaniReleaseEachAlerts = 1, // every one comes up as it would have
    ShaniReleaseQuiet = 2,      // all go to Notification Centre without banner or sound
    ShaniReleaseLogOnly = 3,    // they are not shown at all; the log has them
};

@interface ShaniSettings : NSObject
+ (instancetype)shared;
- (void)reload;
- (void)setObject:(nullable id)value forKey:(NSString *)key;
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSInteger minutes;              // the time a hold lasts
@property (nonatomic, readonly) ShaniMode mode;
@property (nonatomic, readonly) ShaniReleaseStyle releaseStyle;
@property (nonatomic, readonly) BOOL swipeButton;
@property (nonatomic, readonly) BOOL longPressButton;
@property (nonatomic, readonly) BOOL clearOnTap;
@property (nonatomic, readonly) BOOL toast;
@property (nonatomic, readonly) BOOL haptic;
@property (nonatomic, readonly) NSInteger logLimit;
@property (nonatomic, readonly) BOOL debugLog;
@property (nonatomic, readonly) NSArray<NSString *> *apps;
- (void)setApps:(NSArray<NSString *> *)apps;
@end

#pragma mark - ShaniEngine.m (SpringBoard)

@interface ShaniEngine : NSObject
+ (instancetype)shared;
- (void)start;
- (void)settingsChanged;

// From the hooks on NCNotificationDispatcher. `post` puts a request through to the system.
@property (nonatomic, copy, nullable) void (^post)(id dispatcher, id request);
@property (nonatomic, weak, nullable) id dispatcher;
- (BOOL)holdsNewRequest:(id)request;                // YES: Shani has it, the system must not see it yet
- (BOOL)holdsModifiedRequest:(id)request;           // YES: it replaced a held one
- (void)requestWithdrawn:(id)request;

// The button.
- (BOOL)isSilencing:(NSString *)bundleID;           // decides whether the button says "Shani" or "Shani Off"
- (NSString *)buttonTitleFor:(NSString *)bundleID;
- (void)tapOnRequest:(id)request via:(NSString *)where systemClears:(BOOL)systemClears;

- (void)releaseApp:(NSString *)bundleID reason:(NSString *)why;
- (void)releaseDue;
- (void)releaseEverything:(NSString *)why;
- (void)clearRequests:(NSArray *)requests;
- (nullable id)lastRequestFor:(NSString *)bundleID; // tests
- (NSString *)debugState;
@end

NSString *ShaniBundleOf(id request);
NSString *ShaniIdentifierOf(id request);
NSString *ShaniAppName(NSString *bundleID);

#pragma mark - ShaniUI.m (SpringBoard)

BOOL ShaniInstallUIHooks(void);
UIImage *ShaniGlyph(CGFloat side);                              // Saturn, as a template image
void ShaniToast(NSString *title, NSString *detail);
id _Nullable ShaniMakeAction(id request, NSString *title, BOOL dismisses);   // an NCNotificationAction of Shani's

#pragma mark - ShaniDebug.m (SpringBoard)

void ShaniDebugStart(void);

NS_ASSUME_NONNULL_END
