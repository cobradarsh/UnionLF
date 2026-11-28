// Guest Mode for Photos: hand the phone over with only a few chosen photos and videos to look at.
//
//   GMCore.m     where the jailbreak lives, settings, log, the state (idle / chosen / guest) and its file
//   GMAuth.m     Face ID (or the passcode) through LocalAuthentication
//   GMButton.m   the round button that floats over Photos, and what a tap or a hold on it does
//   GMGallery.m  the locked gallery that covers Photos while Guest Mode is on
//   GMDebug.m    test commands (only while a marker file exists)
//
// Nothing in Photos is hooked: the tweak adds two windows of its own to the app.
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#define GM_VERSION "1.0.0"
#define GM_MAX_ITEMS 10

typedef NS_ENUM(NSInteger, GMPhase) {
    GMPhaseIdle = 0,        // nothing chosen: a tap on the button opens the picker
    GMPhaseChosen = 1,      // items chosen: a tap asks for Face ID and starts Guest Mode
    GMPhaseGuest = 2,       // Guest Mode: only the gallery; a tap asks for Face ID and ends it
};

#pragma mark - GMCore.m

void GMLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *GMRoot(void);                                     // the jailbreak root this library was loaded from ("" if unknown)
NSString *GMTestFolder(void);                               // $GUESTMODE_DIR in tests, else nil
BOOL GMDiag(void);                                          // the marker file exists: log and test commands on
BOOL GMEnabled(void);
NSInteger GMButtonSize(void);                               // points
double GMButtonDim(void);                                   // the button's opacity while nothing is chosen
// The first of these SF Symbols that this iOS has.
UIImage *GMSymbol(NSArray<NSString *> *names, CGFloat pointSize, UIImageSymbolWeight weight);

extern NSNotificationName const GMStateChangedNotification;     // phase or selection changed (main thread)
extern NSNotificationName const GMSettingsChangedNotification;  // the Settings page changed something (main thread)

@interface GMState : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) GMPhase phase;
@property (nonatomic, copy, readonly) NSArray<NSString *> *identifiers;  // PHAsset local identifiers, in the order chosen
- (void)choose:(NSArray<NSString *> *)identifiers;          // idle <-> chosen; ignored in Guest Mode
- (void)enterGuest;                                         // chosen -> guest, written to disk
- (void)leaveGuest;                                         // guest -> idle, the selection is forgotten
- (NSArray<PHAsset *> *)assets;                             // the chosen items that still exist, in order
@end

#pragma mark - GMAuth.m

// Face ID / Touch ID, or the passcode when those fail. `done` runs on the main thread.
// ok is YES only after a successful check (or when the phone has no passcode at all).
void GMAuthenticate(NSString *reason, void (^done)(BOOL ok, NSString *detail));
#ifdef GM_TEST
void GMAuthSetTestAnswer(NSString *answer);                 // tests only: "pass", "fail" or "real"
#endif

#pragma mark - GMButton.m

@interface GMButtonController : NSObject
+ (instancetype)shared;
- (void)attach;                                             // make the button window once the app has a scene
- (void)refresh;
- (void)setTuckedAway:(BOOL)tucked;                         // the gallery hides the button with its bars
- (void)buttonTapped;                                       // what a tap does in the current phase
- (void)presentPicker;
- (NSArray<UIMenuElement *> *)menuActions;                  // what a hold on the button offers right now
- (void)presentMenu;                                        // tests: log those entries
- (void)dismissPresented;
- (NSString *)describe;
@end

#pragma mark - GMGallery.m

@interface GMGallery : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL isUp;
- (void)showAnimated:(BOOL)animated;                        // cover Photos with the gallery
- (void)hideAnimated:(BOOL)animated;
- (BOOL)openItemAtIndex:(NSInteger)index;                   // tests: open one item full screen
- (void)backToGrid;
- (void)toggleBars;
- (NSString *)describe;
@end

UIWindowScene *GMActiveScene(void);

#pragma mark - GMDebug.m

void GMDebugStart(void);
