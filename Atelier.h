/*  Atelier.h — HyperTrade (the tweak's name since 1.2.0; the code, the package id, the settings
    domain and the files keep the name it began with, Atelier, so that updates install over the
    old version and keep the user's settings): a workbench of live apps for the iPhone
    (iOS 16.5, RootHide).

    One big "main" app and up to five "mini" tiles of other apps, all hosted inside one
    SpringBoard window. Tap a mini and it changes places with the main. Three layouts: minis in
    a column on the left (Side), minis in a row across the top (Top), or two apps next to each
    other, both usable (Split). Saved sets of 2 to 6 apps open together. Above the tiles a band
    with a clock, three stock-market flags that light up while their market is open, and
    shortcut apps.

    One dylib, loaded into SpringBoard only. How the apps get onto the bench:

      AtelierPane    one hosted app: finds (or starts) the app's FrontBoard scene, asks UIKit's
                     scene presentation manager for a presenter, shows the presenter's view, and
                     switches the scene between foreground (live) and background (still)
      AtelierBench   the window: tiles, layouts, the swap, swipes on a mini, the "..." menu,
                     locks, the freeze clock
      AtelierBand    the index numbers, the clock, the market flags and the shortcut apps above
                     the tiles
      AtelierQuotes  the live NIFTY and SENSEX numbers (a public feed, only while the bench is up)
      AtelierDock    the toggles and the credit line under the tiles
      AtelierSheets  the app picker (with a search field) and the Sets list, as bottom sheets
      AtelierTrigger the strip on the edge that opens the bench, and closes it, with a swipe
      AtelierGestures  the fingers: a mini's tap, hold and swipe, the swipe up that closes the
                     bench, and the phone's own Home gesture
      AtelierDebug   test commands from a file, so the bench can be driven over SSH

    Every private call is looked up at run time and skipped (with a log line) when this iOS
    doesn't have it.                                                              Adarsh · 2026  */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

#define ATELIER_VERSION   @"1.2.3"
#define ATELIER_NAME      @"HyperTrade"                     // what the user reads
#define ATELIER_DOMAIN    @"com.adarsh.atelier"
#define ATELIER_N_PREFS   "com.adarsh.atelier/prefs"        // Settings -> SpringBoard (PostNotification)
#define ATELIER_N_OPEN    "com.adarsh.atelier.open"         // anyone -> SpringBoard
#define ATELIER_N_CLOSE   "com.adarsh.atelier.close"
#define ATELIER_N_TOGGLE  "com.adarsh.atelier.toggle"
#define ATELIER_N_SPORE   "com.adarsh.sporex/reload"        // SporeX: its hidden apps changed
#define ATELIER_MAX_SLOTS 6                                 // the main and five minis
#define ATELIER_SHORTCUTS 6                                 // shortcut apps shown in the band

typedef NS_ENUM(NSInteger, AtelierLayoutKind) {
    AtelierLayoutSide  = 0,     // minis in a column on the left, the main on the right
    AtelierLayoutTop   = 1,     // minis in a row across the top, the main below
    AtelierLayoutSplit = 2,     // the first two apps next to each other, both live and usable
};

typedef NS_ENUM(NSInteger, AtelierMiniMode) {
    AtelierMiniSmart  = 0,      // live while the bench is being used, stills after a pause
    AtelierMiniLive   = 1,      // always live
    AtelierMiniStills = 2,      // always stills; only the main runs
};

typedef NS_ENUM(NSInteger, AtelierSwipeDown) {             // what a swipe down on a mini does
    AtelierSwipeDownSplit   = 0,   // pairs it with the main app in Split
    AtelierSwipeDownFull    = 1,   // opens it full screen
    AtelierSwipeDownReplace = 2,   // opens the picker to put another app in its place
    AtelierSwipeDownNothing = 3,
};

typedef NS_ENUM(NSInteger, AtelierHaptic) { AtelierHapticTick = 0, AtelierHapticSwap, AtelierHapticOpen };

typedef NS_ENUM(NSInteger, AtelierMotion) {                // how the bench comes onto the screen and leaves it
    AtelierMotionZoom = 0,         // a small zoom: a menu, an icon, a command
    AtelierMotionFromRight,        // in from the right edge and back out to it: the edge strip
    AtelierMotionFromLeft,
    AtelierMotionLift,             // up and away: a swipe up from the bottom, the Home gesture
};

typedef NS_ENUM(NSInteger, AtelierTouchPhase) { AtelierTouchBegan = 0, AtelierTouchMoved, AtelierTouchEnded, AtelierTouchCancelled };

#pragma mark - core (AtelierCore.m)

NSString *AtelierLogDir(void);
void AtelierLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void AtelierLogFlush(void);                                  // returns once every line so far is in the file
void AtelierAfter(double seconds, dispatch_block_t block);   // on the main queue

// Careful messaging: the call is made only if the target has the method with this shape.
BOOL AtelierShape(id target, SEL sel, const char *returns, NSUInteger args);
BOOL AtelierArgIs(id target, SEL sel, NSUInteger index, const char *types);
id AtelierMsg(id target, NSString *selName);                 // no arguments, returns an object
BOOL AtelierBoolMsg(id target, NSString *selName, BOOL fallback);
long long AtelierIntMsg(id target, NSString *selName, long long fallback);
BOOL AtelierSend(id target, NSString *selName);
BOOL AtelierSendBool(id target, NSString *selName, BOOL arg);
BOOL AtelierSendInt(id target, NSString *selName, long long arg);
BOOL AtelierSendObj(id target, NSString *selName, id arg);
id AtelierMsgObj(id target, NSString *selName, id arg);      // one object argument, returns an object
id AtelierSingleton(NSString *className);                    // sharedInstanceIfExists where there is one
// Replaces a method with plain runtime calls (no hooking library needed). NO if it isn't there.
BOOL AtelierHook(NSString *className, NSString *selName, BOOL classMethod, IMP replacement, IMP *original);
// The same for an instance method, but only if it looks as expected: `shape` is what it returns
// and then its arguments, one letter each (v nothing, @ object, d number with a fraction,
// q whole number, B yes/no, ? anything). *why says what was wrong when it is left alone.
BOOL AtelierHookShaped(NSString *className, NSString *selName, const char *shape, IMP replacement, IMP *original,
                       NSString *__autoreleasing *why);
void AtelierHapticPlay(AtelierHaptic kind);

@interface AtelierSettings : NSObject
+ (instancetype)shared;
- (void)reload;
- (void)setObject:(id)value forKey:(NSString *)key;          // nil removes
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) AtelierLayoutKind defaultLayout;
@property (nonatomic, readonly) AtelierMiniMode miniMode;
@property (nonatomic, readonly) double freezeAfter;          // seconds without a touch before minis freeze (Smart)
@property (nonatomic, readonly) BOOL trigger;                // the corner strip
@property (nonatomic, readonly) NSInteger triggerSide;       // 0 left, 1 right
@property (nonatomic, readonly) CGFloat triggerSize;         // its height in points
@property (nonatomic, readonly) NSInteger triggerMode;       // 0 a strip window, 1 a system gesture (takes no taps)
@property (nonatomic, readonly) BOOL showHandle;             // the faint pill that marks the edge strip
@property (nonatomic, readonly) BOOL addFront;               // the app in front joins the bench when it opens
@property (nonatomic, readonly) BOOL makeRoom;               // a full bench closes its oldest social app for one more app
@property (nonatomic, readonly) BOOL resizeApps;             // beta: give apps the size of their tile
@property (nonatomic, readonly) BOOL iconMenu;               // "Open in Atelier" in the Home Screen icon menu
@property (nonatomic, readonly) NSInteger haptics;           // 0 off … 3 strong
@property (nonatomic, readonly) BOOL showClock;
@property (nonatomic, readonly) BOOL showMarkets;
@property (nonatomic, readonly) BOOL showIndices;            // live NIFTY and SENSEX above the clock
- (BOOL)showsToggle:(NSString *)key;                         // wifi bluetooth data dnd awake lowpower
- (void)setShortcutApps:(NSArray<NSString *> *)apps;
@property (nonatomic, readonly) AtelierSwipeDown swipeDown;
- (NSArray<NSString *> *)markets;                            // three market codes, e.g. IN, GB, US
- (NSString *)extraHolidays;                                 // India: more trading holidays, as typed in Settings
- (NSArray<NSString *> *)shortcutApps;                       // bundle ids chosen in Settings, at most ATELIER_SHORTCUTS
- (NSArray<NSString *> *)lockedApps;                         // apps locked onto the bench
- (void)setLockedApps:(NSArray<NSString *> *)apps;
@property (nonatomic, readonly) BOOL debugLog;
- (double)tune:(NSString *)key fallback:(double)fallback;    // knobs without a Settings row (set from the debug file)
// what is on the bench, and the saved sets
- (NSArray<NSString *> *)slots;
- (void)setSlots:(NSArray<NSString *> *)slots;
- (AtelierLayoutKind)layout;
- (void)setLayout:(AtelierLayoutKind)layout;
- (NSArray<NSDictionary *> *)sets;                           // @[ @{ @"name", @"apps": @[bundle ids], @"layout" } ]
- (void)setSets:(NSArray<NSDictionary *> *)sets;
@end

@interface AtelierPortraitController : UIViewController
@end

// A SpringBoard window that never becomes the key window (the keyboard stays with the app).
@interface AtelierWindow : UIWindow
@property (nonatomic, copy) void (^onTouch)(void);           // any finger that lands on this window
@end

// The one window that does: the app picker's, which has a search field.
@interface AtelierKeyWindow : AtelierWindow
@end

@interface AtelierHost : NSObject
+ (UIWindowScene *)mainScene;                                // SpringBoard's main scene, never the Dynamic Island's
+ (AtelierWindow *)windowAtLevel:(UIWindowLevel)level;       // full screen, clear, hidden, portrait
+ (AtelierWindow *)windowAtLevel:(UIWindowLevel)level key:(BOOL)key;     // key: one that may take the keyboard
// SpringBoard's keyboard goes to the app in front unless SpringBoard itself is asked to keep
// it. These ask (for a window in the main scene only) and give it back.
+ (BOOL)takeKeyboardForWindow:(UIWindow *)window;
+ (void)giveKeyboardBack;
// Apps hidden by SporeX (the user's own tweak) while it is switched on: never listed anywhere.
+ (void)reloadHiddenApps;
+ (BOOL)isHiddenApp:(NSString *)bid;
+ (BOOL)isSocialApp:(NSString *)bid;                         // WhatsApp, Telegram, X, Reddit, Instagram … (see AtelierCore.m)
+ (NSUInteger)hiddenAppCount;
+ (CGSize)screenSize;                                        // portrait, in points
+ (UIEdgeInsets)safeInsets;
+ (BOOL)isLocked;
+ (BOOL)switcherVisible;
+ (NSString *)frontmostBundleID;                             // nil on the Home Screen
+ (id)applicationForBundleID:(NSString *)bid;                // SBApplication
+ (int)pidOfApplication:(id)app;                             // 0 when it isn't running
+ (NSString *)displayNameForBundleID:(NSString *)bid;
+ (UIImage *)iconForBundleID:(NSString *)bid;
+ (BOOL)launchApp:(NSString *)bid suspended:(BOOL)suspended;
+ (void)toast:(NSString *)message;
+ (NSArray<NSDictionary *> *)installedApps;                  // @[ @{ @"id", @"name" } ] A to Z
+ (NSArray<NSDictionary *> *)listedApps;                     // the same without SporeX's hidden apps: what a list may show
+ (void)noteFront;                                           // remember the app in front, for the picker
+ (NSArray<NSString *> *)recentApps;                         // newest first: seen in front, then the App Switcher's
+ (UIImage *)screenImage;                                    // what is on the screen right now (nil if it can't be had)
@end

#pragma mark - one hosted app (AtelierScenes.m)

typedef NS_ENUM(NSInteger, AtelierPaneState) {
    AtelierPaneIdle = 0,        // nothing asked for yet
    AtelierPaneStarting,        // the app is being started, its scene isn't there yet
    AtelierPaneHosted,          // its picture is in the pane's view
    AtelierPaneFailed,          // no such app, or it would not start
};

@interface AtelierPane : NSObject
+ (instancetype)paneWithBundleID:(NSString *)bid;
@property (nonatomic, readonly) NSString *bundleID;
@property (nonatomic, readonly) UIView *view;                // bounds = sceneSize; the bench scales and places it
@property (nonatomic, readonly) AtelierPaneState state;
@property (nonatomic, readonly) BOOL live;                   // the scene is in the foreground on the bench's account
@property (nonatomic, readonly) CGSize sceneSize;
@property (nonatomic, readonly) NSString *failure;
@property (nonatomic, copy) void (^onChange)(AtelierPane *pane);
- (void)attach;                                              // find or start the scene and show it
- (void)setLive:(BOOL)live;                                  // foreground / background
- (void)setSceneSize:(CGSize)size;                           // beta: ask the app to lay out at this size
- (void)detachKeepingForeground:(BOOL)keep;                  // give the scene back to SpringBoard
- (BOOL)check;                                               // NO if the app has gone; puts a strayed scene back in front
- (int)pid;
- (id)scene;                                                 // the FBScene on show, nil unless hosted
- (NSString *)debugState;
@end

@interface AtelierScenes : NSObject
+ (id)sceneForBundleID:(NSString *)bid;                      // FBScene, nil if the app has none
+ (NSString *)describeAll;                                   // every scene FrontBoard has, one per line (tests)
+ (NSString *)describeScene:(id)scene;
+ (BOOL)requestKeyboardFocusForScene:(id)scene pid:(int)pid; // best effort; NO when this iOS has no way in
+ (BOOL)activateScene:(id)scene;                             // bring exactly this scene to the front, full screen
@end

#pragma mark - fingers (AtelierGestures.m)

// A finger, followed from where it came down, in screen points.
@interface AtelierTrack : NSObject
@property (nonatomic, readonly) CGPoint down, now;
@property (nonatomic, readonly) CFTimeInterval downTime, lastTime;
- (void)beginAt:(CGPoint)p time:(CFTimeInterval)t;
- (void)moveTo:(CGPoint)p time:(CFTimeInterval)t;            // also for the lift
- (CGPoint)travel;                                           // now - down
- (CGPoint)velocity;                                         // points a second, over the last 80 ms or so
@end

@class AtelierShield;
@protocol AtelierShieldDelegate <NSObject>
- (void)shieldTapped:(AtelierShield *)shield;
- (void)shieldHeld:(AtelierShield *)shield;                  // 0.4 s without moving 8 points
- (void)shield:(AtelierShield *)shield swipe:(AtelierTouchPhase)phase track:(AtelierTrack *)track;     // from 8 points of movement on
@end

// The view over a mini: it takes the mini's touches and tells a tap, a hold and a swipe apart.
@interface AtelierShield : UIView
@property (nonatomic, weak) id<AtelierShieldDelegate> delegate;
@end

// The lowest strip of the bench: a finger that goes up from it carries the bench away.
@interface AtelierCloseStrip : UIView
@end

// The phone's own Home gesture and "go home": watched, so that they put the bench away.
@interface AtelierHome : NSObject
+ (instancetype)shared;
+ (void)install;                                             // once, at the start: the guarded replacements
+ (void)benchCameUp;                                         // watch SpringBoard's own Home recogniser while the bench is up
+ (void)benchWentAway;
+ (NSString *)debugState;
@end

#pragma mark - the bench (AtelierBench.m)

@class AtelierBand, AtelierDock;

// Where everything goes. Pure arithmetic, checked by tools/layout_check.py against the same numbers.
typedef struct {
    CGRect main;                // the main tile
    CGRect second;              // Split: the other tile
    CGRect minis[5];            // all five mini places (Side and Top), filled or not
    CGRect plus;                // the "+" tile, CGRectZero when the bench is full
    CGRect band;                // index numbers, clock, flags and shortcut apps, above the tiles
    BOOL bandCompact;           // two short lines (Top, Split) instead of four rows (Side)
    CGRect dock;                // the toggles and the credit line, under the tiles
    CGRect closeStrip;          // a swipe up that starts in here closes the bench: the dock and all below it
    CGRect grabber;             // the "..." pill above the main
    CGRect grabber2;            // Split: the pill of the other tile
    CGRect divider;             // Split: the handle between the two
    NSInteger miniCount;        // how many of the places hold an app
    CGSize sceneSize;           // the size every hosted app is laid out at
} AtelierGeometry;

CGFloat AtelierBandHeight(BOOL compact, BOOL indices);
AtelierGeometry AtelierLayoutCompute(AtelierLayoutKind kind, CGSize screen, UIEdgeInsets safe, NSInteger apps,
                                     double split, BOOL resize, double sideScale, BOOL indices, CGFloat dockHeight);

typedef NS_ENUM(NSInteger, AtelierSwipe) { AtelierSwipeLeft = 0, AtelierSwipeRight, AtelierSwipeUp, AtelierSwipeDownward };

@interface AtelierBench : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL visible;
@property (nonatomic, readonly) AtelierLayoutKind layout;
- (void)open;                                                // what was on the bench last time (plus the app in front)
- (void)openWithMotion:(AtelierMotion)motion;
- (void)openWithApps:(NSArray<NSString *> *)bids layout:(NSInteger)layout;   // layout -1 = keep
- (void)openAdding:(NSString *)bid;                          // "Open in Atelier": bid becomes the main
- (void)closeAnimated:(BOOL)animated reason:(NSString *)why;
- (void)closeAnimated:(BOOL)animated reason:(NSString *)why motion:(AtelierMotion)motion;
// Coming and going with a finger. One driver at a time (`owner`); only the Home gesture may take
// over from another. Progress: 0 gone … 1 fully there.
- (BOOL)beginDragOpening:(BOOL)opening motion:(AtelierMotion)motion owner:(id)owner;      // NO: the bench is not free to follow
- (void)dragTo:(CGFloat)progress owner:(id)owner;
// The finger has let go. complete: what it set out to do is done (an opening opens, a closing
// closes); otherwise the bench springs back. velocity: how fast the finger was carrying it that
// way, in progress per second. reason: what the log says if the bench ends up closed.
- (void)endDrag:(BOOL)complete velocity:(CGFloat)velocity reason:(NSString *)why owner:(id)owner;
- (BOOL)dragging;
- (CGFloat)progress;
- (void)homeAction:(NSString *)what;                         // "go home" happened: the bench goes away
- (void)backdropTapped;
- (CGFloat)marginOnRight:(BOOL)right;                        // the room between the tiles and that edge of the screen
- (void)toggle;
- (void)makeMain:(NSUInteger)slot;                           // a mini changes places with the main
- (void)setLayout:(AtelierLayoutKind)layout animated:(BOOL)animated;
- (void)cycleLayout;
- (void)closeSlot:(NSUInteger)slot;
- (void)replaceSlot:(NSUInteger)slot with:(NSString *)bid;   // slot == count adds
- (void)fullScreenSlot:(NSUInteger)slot;                     // open that app the normal way and put the bench away
- (void)pairSlot:(NSUInteger)slot;                           // that app next to the main one, in Split
- (void)toggleLockSlot:(NSUInteger)slot;                     // a locked app can't be swiped away and is never frozen
- (BOOL)isLocked:(NSString *)bid;
- (void)openShortcut:(NSString *)bid;                        // a shortcut app: it becomes the main app
- (void)performSwipe:(AtelierSwipe)swipe onSlot:(NSUInteger)slot;   // what letting go of a swiped mini does
- (NSString *)debugWhere;                                    // tests: every tile, pill and shortcut with its frame
- (void)saveAsSet;
- (void)openSet:(NSDictionary *)set;
- (void)showMenuForSlot:(NSUInteger)slot;
- (void)hideMenu;
- (void)freezeNow;                                           // tests: what the freeze clock does when it runs out
- (void)debugMenuTap:(NSUInteger)index;                      // tests: choose row n of the open menu
- (void)touched;                                             // a finger did something: minis wake, the clock restarts
- (void)setSplit:(double)share;                              // Split: the first app's share of the width, 0.3 to 0.7
- (void)settingsChanged;
- (void)lockChanged;
- (void)hiddenAppsChanged;                                   // SporeX's list changed
- (void)addShortcut:(NSString *)bid;                         // to the end of the shortcut row
- (void)removeShortcut:(NSString *)bid;
- (CGFloat)dockTop;                                          // the dock's top while the bench is up, else 0
- (NSArray<NSString *> *)apps;
- (NSString *)debugState;
- (AtelierBand *)debugBand;
- (AtelierDock *)debugDock;
@end

#pragma mark - the band (AtelierBand.m)

NSDate *AtelierNow(void);                                    // the time the band shows (tests can move it)
BOOL AtelierIndiaSessionOpen(NSDate *date);                  // NSE's regular session, trading holidays taken out
NSString *AtelierIndianNumber(double value);                 // 100412.05 -> "1,00,412.05"

// The strip above the tiles: index numbers, a clock with seconds, three market flags, shortcut
// apps with their badges. One timer on the second boundary while it is on screen, none otherwise.
@interface AtelierBand : UIView
@property (nonatomic, copy) void (^onShortcut)(NSString *bid);
@property (nonatomic, copy) void (^onShortcutHeld)(NSString *bid, CGRect frame);    // a hold on an icon; frame in the band's space
@property (nonatomic, copy) void (^onAddShortcut)(void);     // the "+" at the end of the row
+ (void)setDebugNow:(NSDate *)date;                          // tests: the clock runs on from this moment (nil = real time)
+ (NSArray<NSString *> *)shownShortcuts;                     // the shortcut apps as the row shows them
- (void)setCompact:(BOOL)compact flagsWidth:(CGFloat)width;  // lay out for this frame; `width` is the room left of the pill
- (void)reload;                                              // settings changed
- (void)quotesChanged;                                       // new index numbers, or none
- (void)start;                                               // the bench came up
- (void)stop;                                                // the bench went away
- (void)debugTapShortcut:(NSUInteger)index;
- (void)debugHoldShortcut:(NSUInteger)index;                 // tests: what a hold on shortcut n does
- (void)debugTapPlus;                                        // tests: what a tap on the row's "+" does
- (NSArray<NSDictionary *> *)debugFrames;                    // @{ @"name", @"frame" (NSValue, in the band's own space) }
- (NSString *)debugState;
@end

#pragma mark - index numbers (AtelierQuotes.m)

@interface AtelierQuote : NSObject
@property (nonatomic, copy) NSString *symbol, *label;
@property (nonatomic) double price, previousClose;
@property (nonatomic, strong) NSDate *marketTime;            // when the exchange last traded it
@end

// NIFTY and SENSEX from a public feed. Runs only between -start and -stop (the bench on screen).
@interface AtelierQuotes : NSObject
+ (instancetype)shared;
@property (nonatomic, copy) void (^onChange)(void);          // on the main thread
- (NSArray<AtelierQuote *> *)quotes;                         // NIFTY, SENSEX; empty until the first answer
- (BOOL)failing;                                             // the last try failed: what is shown is old
- (BOOL)running;
- (void)start;
- (void)stop;
- (void)settingsChanged;
- (void)fetchOnce;                                           // tests: one real fetch, logged with what was parsed
- (void)inject:(NSString *)kind;                             // tests: rise fall mixed stale error none off
- (NSString *)debugState;
@end

#pragma mark - toggles and the credit line (AtelierToggles.m)

typedef NS_ENUM(NSInteger, AtelierToggleKind) {
    AtelierToggleWifi = 0, AtelierToggleBluetooth, AtelierToggleData, AtelierToggleDND, AtelierToggleAwake, AtelierToggleLowPower,
    AtelierToggleCount
};

@interface AtelierToggles : NSObject
+ (NSString *)name:(AtelierToggleKind)kind;
+ (NSString *)key:(AtelierToggleKind)kind;
+ (AtelierToggleKind)kindForKey:(NSString *)key;             // AtelierToggleCount when there is none
+ (BOOL)available:(AtelierToggleKind)kind;                   // this iOS has the calls it needs
+ (BOOL)isOn:(AtelierToggleKind)kind;
+ (void)refresh:(void (^)(void))then;                        // reads the slow ones off the main thread, then calls back on it
+ (void)setOn:(BOOL)on kind:(AtelierToggleKind)kind then:(void (^)(void))then;
+ (void)benchTick;                                           // the bench's clock: Keep Awake does its work here
+ (void)benchWentAway;                                       // Keep Awake ends with the bench, always
+ (void)debugFake:(AtelierToggleKind)kind look:(NSInteger)look;     // tests: 1 on, 0 off, -1 real again
@end

@interface AtelierDock : UIView
+ (CGFloat)heightForWidth:(CGFloat)width compact:(BOOL)compact;
- (void)setCompact:(BOOL)compact;
- (void)reload;                                              // settings changed
- (void)refresh;                                             // read the states again
- (void)debugTap:(NSString *)key;
- (NSArray<NSDictionary *> *)debugFrames;
- (NSString *)debugState;
@end

#pragma mark - sheets (AtelierSheets.m)

@interface AtelierSheets : NSObject
+ (BOOL)isOpen;
+ (void)dismiss;
// title, apps to leave out, and what to do with the choice
+ (void)pickAppWithTitle:(NSString *)title excluding:(NSArray<NSString *> *)exclude then:(void (^)(NSString *bid))then;
+ (void)showSets;                                            // open, rename, reorder, delete
+ (void)debugPick:(NSUInteger)row;                           // tests: choose row n of the list on screen
+ (void)debugType:(NSString *)text;                          // tests: put this in the picker's search field, as typing would
+ (void)debugReturn;                                         // tests: the Return key in the search field
+ (NSArray<NSString *> *)debugWhere;                         // tests: the picker's field, keyboard and first rows, on the screen
+ (NSString *)debugState;
+ (NSString *)setTitle:(NSDictionary *)set;                  // its name, or its apps' names
@end

#pragma mark - the corner trigger (AtelierTrigger.m)

@interface AtelierTrigger : NSObject
+ (instancetype)shared;
- (void)refresh;                                             // settings, lock, or the bench changed
- (NSString *)debugState;
- (NSArray<NSString *> *)debugWhere;                         // tests: the strip and its handle, on the screen
- (void)debugSwipe;                                          // tests: what a swipe on the strip does, without a finger
@end

#pragma mark - entry points shared between files

void AtelierSettingsChanged(void);
void AtelierDebugStart(void);                                // watches for the command file while the debug log is on
void AtelierIconMenuInstall(void);                           // Home Screen icon menu items (Tweak.m)
