/*  Atelier.h — a workbench of live apps for the iPhone (iOS 16.5, RootHide).

    One big "main" app and up to four "mini" tiles of other apps, all hosted inside one
    SpringBoard window. Tap a mini and it changes places with the main. Three layouts: minis in
    a column on the left (Side), minis in a row across the top (Top), or two apps next to each
    other, both usable (Split). Saved sets of 2 to 5 apps open together.

    One dylib, loaded into SpringBoard only. How the apps get onto the bench:

      AtelierPane    one hosted app: finds (or starts) the app's FrontBoard scene, asks UIKit's
                     scene presentation manager for a presenter, shows the presenter's view, and
                     switches the scene between foreground (live) and background (still)
      AtelierBench   the window: tiles, layouts, the swap, the "..." menu, the freeze clock
      AtelierSheets  the app picker and the Sets list (bottom sheets, no text fields)
      AtelierTrigger the strip in the bottom corner that opens the bench on a swipe
      AtelierDebug   test commands from a file, so the bench can be driven over SSH

    Every private call is looked up at run time and skipped (with a log line) when this iOS
    doesn't have it.                                                              Adarsh · 2026  */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

#define ATELIER_VERSION   @"1.0.0"                          // keep in step with control
#define ATELIER_DOMAIN    @"com.adarsh.atelier"
#define ATELIER_N_PREFS   "com.adarsh.atelier/prefs"        // Settings -> SpringBoard (PostNotification)
#define ATELIER_N_OPEN    "com.adarsh.atelier.open"         // anyone -> SpringBoard
#define ATELIER_N_CLOSE   "com.adarsh.atelier.close"
#define ATELIER_N_TOGGLE  "com.adarsh.atelier.toggle"
#define ATELIER_MAX_SLOTS 5                                 // the main and four minis

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

typedef NS_ENUM(NSInteger, AtelierHaptic) { AtelierHapticTick = 0, AtelierHapticSwap, AtelierHapticOpen };

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
@property (nonatomic, readonly) BOOL addFront;               // the app in front joins the bench when it opens
@property (nonatomic, readonly) BOOL resizeApps;             // beta: give apps the size of their tile
@property (nonatomic, readonly) BOOL iconMenu;               // "Open in Atelier" in the Home Screen icon menu
@property (nonatomic, readonly) NSInteger haptics;           // 0 off … 3 strong
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

@interface AtelierHost : NSObject
+ (UIWindowScene *)mainScene;                                // SpringBoard's main scene, never the Dynamic Island's
+ (AtelierWindow *)windowAtLevel:(UIWindowLevel)level;       // full screen, clear, hidden, portrait
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

#pragma mark - the bench (AtelierBench.m)

// Where everything goes. Pure arithmetic, checked by tools/layout_check.py against the same numbers.
typedef struct {
    CGRect main;                // the main tile
    CGRect second;              // Split: the other tile
    CGRect minis[4];            // mini tiles (Side and Top)
    CGRect plus;                // the "+" tile, CGRectZero when the bench is full
    CGRect grabber;             // the "..." pill above the main
    CGRect grabber2;            // Split: the pill of the other tile
    CGRect divider;             // Split: the handle between the two
    NSInteger miniCount;
    CGSize sceneSize;           // the size every hosted app is laid out at
} AtelierGeometry;

AtelierGeometry AtelierLayoutCompute(AtelierLayoutKind kind, CGSize screen, UIEdgeInsets safe, NSInteger apps,
                                     double split, BOOL resize, double sideScale);

@interface AtelierBench : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL visible;
@property (nonatomic, readonly) AtelierLayoutKind layout;
- (void)open;                                                // what was on the bench last time (plus the app in front)
- (void)openWithApps:(NSArray<NSString *> *)bids layout:(NSInteger)layout;   // layout -1 = keep
- (void)openAdding:(NSString *)bid;                          // "Open in Atelier": bid becomes the main
- (void)closeAnimated:(BOOL)animated reason:(NSString *)why;
- (void)toggle;
- (void)makeMain:(NSUInteger)slot;                           // a mini changes places with the main
- (void)setLayout:(AtelierLayoutKind)layout animated:(BOOL)animated;
- (void)cycleLayout;
- (void)closeSlot:(NSUInteger)slot;
- (void)replaceSlot:(NSUInteger)slot with:(NSString *)bid;   // slot == count adds
- (void)fullScreenSlot:(NSUInteger)slot;                     // open that app the normal way and put the bench away
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
- (NSArray<NSString *> *)apps;
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
+ (NSString *)setTitle:(NSDictionary *)set;                  // its name, or its apps' names
@end

#pragma mark - the corner trigger (AtelierTrigger.m)

@interface AtelierTrigger : NSObject
+ (instancetype)shared;
- (void)refresh;                                             // settings, lock, or the bench changed
- (NSString *)debugState;
- (void)debugSwipe;                                          // tests: what a swipe on the strip does
@end

#pragma mark - entry points shared between files

void AtelierSettingsChanged(void);
void AtelierDebugStart(void);                                // watches for the command file while the debug log is on
void AtelierIconMenuInstall(void);                           // Home Screen icon menu items (Tweak.m)
