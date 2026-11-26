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
/// The player layer whose download button is under this point.
AVPlayerLayer *_Nullable VGBadgeLayerAtPoint(UIWindow *window, CGPoint point);
/// The button's frame in the window (CGRectNull while it is hidden).
CGRect VGBadgeFrameInWindow(AVPlayerLayer *layer, UIWindow *window);
/// YES when something opaque of the app lies over that point of the layer.
BOOL VGLayerCoveredAtPoint(AVPlayerLayer *layer, UIWindow *window, CGPoint point);
/// Looks at every known layer again, soon, on the main queue. Cheap; call freely.
void VGRefreshBadgesSoon(void);
/// Keeps the buttons on their videos while the screen scrolls (call on each touch, main thread).
void VGFollowScrolling(void);

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
void VGCancelDownload(void);
NSString *VGLastDownloadResult(void);

#pragma mark - tests (VGDebug.m)

/// The app's windows that carry VidGrab's recognizers, the key window first.
NSArray<UIWindow *> *VGAppWindows(void);
NSString *VGDescribeTouchAt(UIWindow *window, CGPoint point);

void VGDebugStart(void);

NS_ASSUME_NONNULL_END
