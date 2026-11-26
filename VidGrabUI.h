// VidGrab 2 — the parts that live on screen (apps only).
#import "VidGrab.h"
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - what plays (VGCapture.m)

/// Puts in the three AVFoundation hooks and starts keeping the download buttons up to date.
void VGCaptureInstall(void);
NSString *VGCaptureHookSummary(void);
/// Every player layer the app has made that is still alive.
NSArray<AVPlayerLayer *> *VGKnownPlayerLayers(void);
/// What the layer's player is playing, when it is something VidGrab can save.
VGSource *_Nullable VGSourceForPlayerLayer(AVPlayerLayer *layer);
/// The layer's frame in its window, CGRectNull when it is not on screen in that window.
CGRect VGLayerFrameInWindow(CALayer *layer, UIWindow *window);
/// The player layer with a video under this point of the window.
AVPlayerLayer *_Nullable VGPlayerLayerAtPoint(UIWindow *window, CGPoint point);
/// The layer (a video's or a picture's) whose download button is under this point.
CALayer *_Nullable VGBadgeLayerAtPoint(UIWindow *window, CGPoint point);
/// What the button on that layer saves: its video or its picture.
VGSource *_Nullable VGSourceForBadgeLayer(CALayer *_Nullable layer);
/// The button's frame in the window (CGRectNull while it is hidden).
CGRect VGBadgeFrameInWindow(CALayer *layer, UIWindow *window);
/// Shows, hides and places the button on a layer (picture: where the layer draws it, or CGRectNull).
void VGPlaceBadge(CALayer *layer, BOOL show, CGRect picture);
BOOL VGHasBadge(CALayer *layer);
/// Buttons on videos or pictures are switched on (and VidGrab is, in this app).
BOOL VGButtonsWanted(void);
/// The view a layer belongs to (its own, or the nearest one above it).
UIView *_Nullable VGHostView(CALayer *layer);
/// YES when something opaque of the app lies over that point of the layer.
BOOL VGLayerCoveredAtPoint(CALayer *layer, UIWindow *window, CGPoint point);
/// Looks at every known layer again, soon, on the main queue. Cheap; call freely.
void VGRefreshBadgesSoon(void);
/// Keeps the buttons on their videos while the screen scrolls (call on each touch, main thread).
void VGFollowScrolling(void);

#pragma mark - pictures (VGPicture.m)

/// Hooks -[UIImageView setImage:] (and, in apps built with Texture, its display layer's
/// setContents:) to learn which layers show pictures. No hold on pictures: only the button.
void VGPicturesInstall(void);
/// Places or hides the button on every picture known (main thread; cheap enough for each frame).
void VGLayoutPictures(void);
/// Asks for VGLayoutPictures on the main queue soon, once however often it is asked.
void VGLayoutPicturesSoon(void);
NSArray<CALayer *> *VGKnownPictureLayers(void);
/// The picture a layer shows, when it is one VidGrab would put a button on.
VGSource *_Nullable VGSourceForPictureLayer(CALayer *layer);
/// A job that fetches a picture (its original where the address tells, else what is on screen).
VGJob *VGMakePictureJob(VGSource *source);
/// Tests: one line about a picture layer, and a walk through the window for anything drawn as a picture.
NSString *VGDescribePictureLayer(CALayer *layer, UIWindow *window);
void VGLogPictureScan(UIWindow *window);

#pragma mark - touch (VGUI.m)

void VGGesturesInstall(void);
/// What a hold or a tap on the button does: the menu, or the action chosen in Settings.
void VGTrigger(VGSource *source, UIWindow *window, CGRect anchor);

typedef NS_ENUM(NSInteger, VGDelivery) { VGDeliverPhotos = 1, VGDeliverShare = 2, VGDeliverStash = 3, VGDeliverNothing = 9 };

/// The window VidGrab draws in: the progress pill, menus, the share sheet. Touches elsewhere pass through.
@interface VGOverlay : NSObject
+ (void)present:(UIViewController *)controller from:(UIWindow *)window;
+ (void)dismissPresented:(void (^_Nullable)(void))completion;
+ (nullable UIViewController *)presented;
+ (void)releaseIfIdle;
+ (nullable UIWindow *)window;
@end

@interface VGPill : NSObject
+ (void)showProgress:(double)fraction text:(NSString *)text from:(nullable UIWindow *)window onCancel:(void (^_Nullable)(void))cancel;
+ (void)update:(double)fraction text:(NSString *)text;
+ (void)succeed:(NSString *)text;
+ (void)fail:(NSString *)text;
+ (void)note:(NSString *)text from:(nullable UIWindow *)window;       // a short message, no progress
+ (void)hide;
+ (NSString *)stateForLog;
@end

/// A menu whose entries can also be run by name (the tests do).
@interface VGMenu : NSObject
+ (instancetype)menuWithTitle:(nullable NSString *)title message:(nullable NSString *)message;
- (void)add:(NSString *)title run:(void (^)(void))run;
- (void)presentFrom:(UIWindow *)window anchor:(CGRect)anchor;
+ (nullable VGMenu *)current;
@property (nonatomic, readonly) NSArray<NSString *> *titles;
- (BOOL)choose:(NSString *)titlePrefix;
@end

#pragma mark - downloads (VGDeliver.m)

NSString *VGAppName(void);
void VGStartDownload(VGSource *source, VGDelivery delivery, VGVariant *_Nullable variant, UIWindow *_Nullable window);
BOOL VGDownloadRunning(void);
/// Downloads asked for while one runs wait their turn and start one after another.
NSUInteger VGQueueCount(void);
NSUInteger VGClearQueue(void);
void VGCancelDownload(void);
NSString *VGLastDownloadResult(void);

#pragma mark - tests (VGDebug.m)

/// The app's windows that carry VidGrab's recognizers, the key window first.
NSArray<UIWindow *> *VGAppWindows(void);
/// A window of the app's that VidGrab watches (not its own, not the keyboard's).
BOOL VGWindowIsWatched(UIWindow *_Nullable window);
NSString *VGDescribeTouchAt(UIWindow *window, CGPoint point);

void VGDebugStart(void);

NS_ASSUME_NONNULL_END
