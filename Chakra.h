/*  Chakra.h — a wheel of your apps, parked on the edge of the screen.

    One dylib in SpringBoard. Nothing is injected into apps and there is no helper process.

      ChakraBall     the ball docked on a screen edge: tap it, slide from it, or hold and drag it
      ChakraWheel    the menu it opens: apps, system actions and shortcuts on rings around the ball
      ChakraEditor   the sheet behind a long press: add, remove and reorder what is on the wheel
      ChakraItems    what an entry is (app / action / shortcut) and how to draw and run it
      ChakraActions  the system actions (Home, Lock, Screenshot, Flashlight…)
      ChakraGlyphs   the drawn icons: the wheel mark, glyph discs, the Bluetooth rune
      ChakraArt      the golden sun wheel on the ball, a picture made by tools/make_art.py
      ChakraGlass    the pane behind the wheel: glass, or the darker frosted look
      ChakraLayout   where things go: rings that grow with the number of items and bend away from corners
      ChakraCore     log, settings, SpringBoard helpers

    Every private class and method is looked up at run time and its shape is checked before it
    is called, so on an iOS build where one is missing that one action says so instead of taking
    SpringBoard down. No method is hooked.                                    Adarsh · 2026   */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <TargetConditionals.h>

#define CHAKRA_VERSION    @"1.0.4"                      // keep in step with control
#define CHAKRA_DOMAIN     @"com.adarsh.chakra"
#define CHAKRA_N_PREFS    "com.adarsh.chakra/prefs"     // Settings -> SpringBoard (PostNotification)
#define CHAKRA_MAX_ITEMS  16
#define CHAKRA_SLOTS      4                             // shortcuts you can define in Settings

typedef NS_ENUM(NSInteger, ChakraEdge)   { ChakraEdgeLeft = 0, ChakraEdgeRight = 1 };
typedef NS_ENUM(NSInteger, ChakraStyle)  { ChakraStyleWheel = 0, ChakraStyleColumn = 1 };
typedef NS_ENUM(NSInteger, ChakraKind)   { ChakraKindApp = 0, ChakraKindAction = 1, ChakraKindShortcut = 2 };
typedef NS_ENUM(NSInteger, ChakraHaptic) { ChakraHapticOpen = 0, ChakraHapticTick, ChakraHapticCommit, ChakraHapticLift };

// ── log ──
NSString *ChakraLogDir(void);                              // /var/mobile/Library/Logs (a folder of your choice in the simulator)
void ChakraLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void ChakraLogFlush(void);                             // returns once every line logged so far is in the file

// ── careful messaging: each of these only sends when the method exists with the expected shape ──
BOOL ChakraShape(id target, SEL sel, const char *returns, NSUInteger args);
id ChakraMsg(id target, NSString *selName);                               // -> object, no argument
BOOL ChakraBoolMsg(id target, NSString *selName, BOOL fallback);          // -> BOOL, no argument
long long ChakraIntMsg(id target, NSString *selName, long long fallback); // -> integer, no argument
BOOL ChakraSend(id target, NSString *selName);                            // no argument; YES if it was sent
BOOL ChakraSendBool(id target, NSString *selName, BOOL arg);
BOOL ChakraSendInt(id target, NSString *selName, long long arg);
BOOL ChakraSendObj(id target, NSString *selName, id arg);

id ChakraSingleton(NSString *className);                                   // a SpringBoard controller, never created early
void ChakraAfter(double seconds, dispatch_block_t block);                 // on the main queue
void ChakraHapticPlay(ChakraHaptic event);

// ── settings (Settings → Chakra, plus what the tweak itself remembers) ──
@interface ChakraSettings : NSObject
+ (instancetype)shared;
- (void)reload;
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) CGFloat ballSize;
@property (nonatomic, readonly) CGFloat idleAlpha;
@property (nonatomic, readonly) BOOL tuck;                    // slide part-way off the edge while idle
@property (nonatomic, readonly) NSInteger accent;
@property (nonatomic, readonly) NSInteger ballIcon;              // on the ball: 0 the golden sun wheel, 1 the plain wheel mark
@property (nonatomic, strong, readonly) UIColor *accentColor;
@property (nonatomic, readonly) ChakraStyle style;
@property (nonatomic, readonly) CGFloat iconSize;
@property (nonatomic, readonly) BOOL labels;
@property (nonatomic, readonly) BOOL dim;
@property (nonatomic, readonly) NSInteger haptics;            // 0 off … 3 firm
@property (nonatomic, readonly) BOOL lockScreen;
@property (nonatomic, readonly) BOOL hideLandscape;
@property (nonatomic, readonly) BOOL debugLog;
@property (nonatomic, readonly) BOOL glass;                   // the pane behind the wheel: glass (or frosted)
@property (nonatomic, readonly) BOOL hideInShots;             // keep Chakra out of screenshots and recordings
@property (nonatomic, readonly) BOOL editEntry;               // an "Edit" entry at the end of the wheel
@property (nonatomic, readonly) BOOL dragMoves;               // dragging the ball moves it (instead of picking from the wheel)
@property (nonatomic, readonly) BOOL lockPosition;            // the ball can't be dragged anywhere
- (NSString *)gesture:(NSString *)which;                      // which = Double | Triple | Hold -> none | app | action:<id> | shortcut:<n>
- (NSString *)gestureApp:(NSString *)which;                   // the bundle id picked for "app"
- (NSArray<NSString *> *)pickedApps;                          // Settings -> Apps on the Wheel; nil until that list has been written
@property (nonatomic, readonly) ChakraEdge ballEdge;
@property (nonatomic, readonly) CGFloat ballY;                // centre, as a fraction of the screen height
- (void)setBallEdge:(ChakraEdge)edge y:(CGFloat)y;
- (NSArray<NSDictionary *> *)savedItems;                      // nil until the wheel has been edited
- (void)setSavedItems:(NSArray<NSDictionary *> *)items;
- (NSString *)slotName:(NSInteger)slot;                       // slot = 1 … CHAKRA_SLOTS
- (NSString *)slotTarget:(NSInteger)slot;
- (NSString *)slotGlyph:(NSInteger)slot;
- (void)setObject:(id)value forKey:(NSString *)key;           // nil removes; for the editor and tests
@end

// A controller that keeps its window in portrait. Chakra's windows never turn with the app in
// front; what is drawn on them is turned instead (ChakraHost interfaceAngle).
@interface ChakraPortraitController : UIViewController
@end

// ── SpringBoard helpers ──
@interface ChakraHost : NSObject
+ (UIWindowScene *)mainScene;                         // SpringBoard's main scene, never the Dynamic Island's
+ (UIWindow *)overlayWindowAtLevel:(UIWindowLevel)level;   // clear, in the main scene, hidden until asked
+ (void)keepOutOfScreenshots:(UIWindow *)window;      // per the setting: screenshots and recordings leave the window out
+ (CGSize)screenSize;                                 // in points, always portrait
+ (UIEdgeInsets)safeInsets;                           // portrait
+ (BOOL)isLocked;                                     // the lock screen is up
+ (long long)interfaceOrientation;                    // of whatever is in front (UIInterfaceOrientation)
+ (CGFloat)interfaceAngle;                            // how far to turn a view so it reads upright
+ (NSString *)frontmostBundleID;                      // nil on the Home Screen
+ (id)applicationForBundleID:(NSString *)bid;         // SBApplication
+ (NSString *)displayNameForBundleID:(NSString *)bid;
+ (UIImage *)iconForBundleID:(NSString *)bid;
+ (BOOL)launchApp:(NSString *)bid;
+ (void)openURL:(NSURL *)url;
+ (void)toast:(NSString *)message;
+ (NSArray<NSDictionary *> *)installedApps;           // @[ @{ @"id", @"name" } ] A–Z, the ones you can open
+ (void)noteFront;                                    // remember what is in front (called every tick)
+ (NSString *)previousApp;                            // the app used before the one in front
+ (NSArray<NSString *> *)switcherApps;                // the App Switcher's apps, in SpringBoard's order
+ (NSArray<NSString *> *)seenApps;                    // apps Chakra has seen in front, newest first
@end

// ── drawn icons ──
NSData *ChakraSunPNG(void);                                 // the golden sun wheel as PNG data (ChakraArt.m)
@interface ChakraGlyphs : NSObject
+ (UIImage *)glyphNamed:(NSString *)name pointSize:(CGFloat)pointSize;   // an SF Symbol, or ck.chakra / ck.bluetooth
+ (UIImage *)chakraWithSize:(CGFloat)size;                               // the wheel mark (template image)
+ (UIImage *)sunWithSize:(CGFloat)size;                                  // the golden sun wheel; nil if its picture cannot be read
+ (UIImage *)discWithGlyph:(NSString *)glyph size:(CGFloat)size fill:(UIColor *)fill;
@end

// ── the pane behind the wheel ──
@interface ChakraGlassView : UIView
@property (nonatomic, strong, readonly) UIView *contentView;     // for what is drawn on the pane
+ (BOOL)canDrawGlass;
- (instancetype)initWithFrame:(CGRect)frame cornerRadius:(CGFloat)radius glass:(BOOL)glass accent:(UIColor *)accent;
@end

// ── system actions ──
@interface ChakraAction : NSObject
@property (nonatomic, copy, readonly) NSString *ident;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *glyph;       // while on, or always for a plain action
@property (nonatomic, copy, readonly) NSString *glyphOff;    // toggles only: nil = same glyph
@property (nonatomic, strong, readonly) UIColor *tint;
@property (nonatomic, readonly) BOOL toggle;
@end

@interface ChakraActions : NSObject
+ (NSArray<ChakraAction *> *)all;
+ (ChakraAction *)actionWithID:(NSString *)ident;
+ (BOOL)available:(NSString *)ident;                  // this iOS has what the action needs
+ (BOOL)isOn:(NSString *)ident;                       // toggles
+ (void)perform:(NSString *)ident;                    // after the wheel has closed
+ (NSString *)report;                                 // one line per action: available / what is missing
@end

// ── wheel entries ──
@interface ChakraItem : NSObject
@property (nonatomic, readonly) ChakraKind kind;
@property (nonatomic, copy, readonly) NSString *ident;       // bundle id, action id, or shortcut slot number
+ (instancetype)itemWithKind:(ChakraKind)kind ident:(NSString *)ident;
+ (instancetype)itemFromDictionary:(NSDictionary *)d;
- (NSDictionary *)dictionary;
- (NSString *)key;                                    // "app:com.apple.mobilesafari"
- (NSString *)title;
- (NSString *)subtitle;                               // for the editor
- (BOOL)available;                                    // installed / supported / filled in
- (BOOL)isToggle;
- (BOOL)isOn;
- (UIImage *)iconWithSize:(CGFloat)size;
- (void)perform;
@end

@interface ChakraItems : NSObject
+ (NSArray<ChakraItem *> *)all;                           // in wheel order, including ones that can't be shown now
+ (NSArray<ChakraItem *> *)visible;                       // what the wheel shows
+ (void)save:(NSArray<ChakraItem *> *)items;
+ (NSArray<ChakraItem *> *)starterItems;
+ (void)flushIcons;                                   // settings changed: draw the glyph discs again
+ (void)warmIcons;                                    // load the wheel's icons ahead of the first open
+ (void)syncPickedApps;                               // bring the wheel in line with Settings -> Apps on the Wheel
+ (ChakraItem *)itemForGesture:(NSString *)which;     // what a double tap, triple tap or hold is set to (nil = nothing)
@end

// ── layout ──
typedef struct {
    CGPoint hub;            // the ball's centre while it is out of the edge
    ChakraEdge edge;
    CGSize screen;
    UIEdgeInsets safe;
    CGFloat icon;
    CGFloat ball;
    BOOL labels;
    ChakraStyle style;
} ChakraLayoutInput;

@interface ChakraLayout : NSObject
@property (nonatomic, strong, readonly) NSArray<NSValue *> *centers;     // icon centres on screen, in item order
@property (nonatomic, strong, readonly) NSArray<NSNumber *> *ringRadii;  // wheel: one per ring in use
@property (nonatomic, readonly) CGFloat plateRadius;             // wheel: the frosted disc
@property (nonatomic, readonly) CGRect plateRect;                // column: the frosted panel
+ (instancetype)layoutForCount:(NSUInteger)count input:(ChakraLayoutInput)input;
@end

// ── the menu ──
@interface ChakraWheel : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL isOpen;
- (void)openFromHub:(CGPoint)hub edge:(ChakraEdge)edge;
- (void)closeAnimated:(BOOL)animated completion:(dispatch_block_t)completion;
- (void)hoverAtScreenPoint:(CGPoint)point;            // the finger, while sliding from the ball
- (BOOL)commitHover;                                  // the finger lifted: run what is under it (NO = nothing was)
- (void)clearHover;
- (void)closeIfFrontChanged;                          // every tick: the app underneath is no longer the one it opened over
- (NSUInteger)itemCount;
- (CGPoint)centerOfIndex:(NSUInteger)index;           // where entry n sits on screen (tests)
- (void)debugTapIndex:(NSUInteger)index;
- (void)debugHoverIndex:(NSUInteger)index;
- (NSString *)debugState;
@end

// ── the ball ──
@interface ChakraBall : NSObject
+ (instancetype)shared;
- (void)refresh;                                      // settings, lock state or orientation changed
- (void)wheelDidOpen;
- (void)wheelDidClose;
- (CGPoint)hub;
@property (nonatomic) BOOL suppressed;                // hidden for a moment (screenshot, editor)
- (void)debugMoveToEdge:(ChakraEdge)edge y:(CGFloat)y;
- (void)debugTap;
- (void)debugTouch:(NSInteger)phase at:(CGPoint)point;    // 0 down, 1 moved, 2 up, 3 cancelled: a finger on the ball (tests)
- (void)debugSlideToIndex:(NSUInteger)index;              // slide from the ball to entry n and lift (tests)
- (NSString *)debugState;
@end

// ── the editor sheet ──
@interface ChakraEditor : NSObject
+ (BOOL)isOpen;
+ (void)present;
+ (void)dismiss;
+ (void)debugPushAdd:(NSInteger)kind;                 // show an "add" list: 0 apps, 1 actions, 2 shortcuts (tests)
@end

void ChakraSettingsChanged(void);                          // re-read the settings and redraw (Tweak.m)

// ── tests ──
void ChakraDebugStart(void);                              // runs <log dir>/chakra_cmd.txt, but only while <log dir>/chakra_test exists
