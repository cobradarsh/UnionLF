// Knows what is playing and marks it.
//
// Three hooks, all on AVFoundation classes that apps cannot rename:
//   -[AVURLAsset initWithURL:options:]   keeps the request headers the app plays a video with
//   -[AVPlayerLayer setPlayer:]          learns that a layer shows video
//   -[AVPlayerLayer layoutSublayers]     puts the download button in its corner when the layer changes size
// A layer's video is found through its player at the moment it is asked for, so nothing is
// recorded while the app plays and nothing is kept about videos that were merely loaded.
#import "VidGrabUI.h"
#import <objc/runtime.h>
#include <stdatomic.h>

static char kHeadersKey, kBadgeKey;
static const CGFloat kBadgeSize = 30;
static const CGFloat kBadgeMargin = 10;
static const CGFloat kBadgeReach = 9;               // how far outside the drawn button a touch still counts

static atomic_bool gEnabled, gBadgeOn;
static atomic_int gCorner;
static NSInteger gHooks;

static NSHashTable<AVPlayerLayer *> *VGLayers(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

NSArray<AVPlayerLayer *> *VGKnownPlayerLayers(void) {
    NSHashTable *table = VGLayers();
    @synchronized (table) { return table.allObjects; }
}

#pragma mark - what a layer plays

static NSSet<NSString *> *VGSoundEndings(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"mp3", @"m4a", @"aac", @"wav", @"caf", @"opus", @"ogg", @"flac", @"aiff"]]; });
    return set;
}

static VGSource *VGSourceForItem(AVPlayerItem *item) {
    AVAsset *asset = item.asset;
    if (!asset) return nil;
    VGSource *source = [VGSource new];
    if ([asset isKindOfClass:AVURLAsset.class]) {
        NSURL *url = ((AVURLAsset *)asset).URL;
        if (![url isKindOfClass:NSURL.class] || !url.scheme.length) return nil;
        if ([VGSoundEndings() containsObject:url.pathExtension.lowercaseString]) return nil;
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"data"] || [scheme isEqualToString:@"blob"] || [scheme isEqualToString:@"about"]) return nil;
        source.url = url;
        NSDictionary *headers = objc_getAssociatedObject(asset, &kHeadersKey);
        if ([headers isKindOfClass:NSDictionary.class]) source.headers = headers;
        source.asset = asset;
        return source;
    }
    // a video the app put together itself (no link): it can still be copied out of the player
    if ([asset isKindOfClass:AVComposition.class] || [NSStringFromClass(asset.class) containsString:@"Movie"]) {
        source.asset = asset;
        return source;
    }
    return nil;
}

VGSource *VGSourceForPlayerLayer(AVPlayerLayer *layer) {
    return VGSourceForItem(layer.player.currentItem);
}

static UIView *VGHostView(CALayer *layer) {
    for (CALayer *l = layer; l; l = l.superlayer) {
        id delegate = l.delegate;
        if ([delegate isKindOfClass:UIView.class]) return delegate;
    }
    return nil;
}

/// The part of the layer that can be seen, in the layer's own coordinates: cut by every container
/// that clips (apps draw videos zoomed in, inside a card that cuts them off), by the window and by
/// the status bar. CGRectNull when nothing of it shows in that window.
static CGRect VGVisibleRectInLayer(CALayer *layer, UIWindow *window) {
    CALayer *root = window.layer;
    if (!root || !layer) return CGRectNull;
    CGRect visible = layer.bounds;
    for (CALayer *l = layer; l; l = l.superlayer) {
        if (l.isHidden || l.opacity < 0.02f) return CGRectNull;
        if (l != layer && l.masksToBounds) visible = CGRectIntersection(visible, [layer convertRect:l.bounds fromLayer:l]);
        if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return CGRectNull;
        if (l == root) {
            CGRect screen = root.bounds;
            CGFloat top = window.safeAreaInsets.top;
            screen.origin.y += top;
            screen.size.height -= top;
            visible = CGRectIntersection(visible, [layer convertRect:screen fromLayer:root]);
            return CGRectIsNull(visible) || CGRectIsEmpty(visible) ? CGRectNull : visible;
        }
    }
    return CGRectNull;                                       // in another window, or in none
}

CGRect VGLayerFrameInWindow(CALayer *layer, UIWindow *window) {
    CGRect visible = VGVisibleRectInLayer(layer, window);
    if (CGRectIsNull(visible)) return CGRectNull;
    return [layer convertRect:visible toLayer:window.layer];
}

BOOL VGLayerCoveredAtPoint(AVPlayerLayer *layer, UIWindow *window, CGPoint point) {
    UIView *host = VGHostView(layer);
    if (!host || host.window != window) return NO;
    UIView *hit = [window hitTest:point withEvent:nil];
    if (!hit || hit == host || [hit isDescendantOfView:host] || [host isDescendantOfView:hit]) return NO;
    UIView *common = host.superview;
    while (common && ![hit isDescendantOfView:common]) common = common.superview;
    CGRect video = VGLayerFrameInWindow(layer, window);
    // from what the touch lands on up to where its branch meets the video's: is any of it solid?
    for (UIView *view = hit; view && view != common; view = view.superview) {
        if (view.isHidden || view.alpha < 0.6) continue;
        if ([view isKindOfClass:UIVisualEffectView.class]) return YES;
        CGColorRef colour = view.backgroundColor.CGColor;
        if (colour && CGColorGetAlpha(colour) > 0.6) return YES;
        if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) {
            CGRect frame = [view convertRect:view.bounds toView:nil];
            CGRect shared = CGRectIntersection(frame, video);
            if (!CGRectIsNull(shared) && shared.size.width * shared.size.height > 0.6 * video.size.width * video.size.height) return YES;
        }
    }
    return NO;
}

AVPlayerLayer *VGPlayerLayerAtPoint(UIWindow *window, CGPoint point) {
    AVPlayerLayer *best = nil;
    BOOL bestPlaying = NO;
    CGFloat bestArea = 0;
    for (AVPlayerLayer *layer in VGKnownPlayerLayers()) {
        CGRect frame = VGLayerFrameInWindow(layer, window);
        if (CGRectIsNull(frame) || !CGRectContainsPoint(frame, point)) continue;
        if (frame.size.width < 60 || frame.size.height < 60) continue;
        if (!VGSourceForPlayerLayer(layer)) continue;
        if (VGLayerCoveredAtPoint(layer, window, point)) continue;
        BOOL playing = layer.player.rate != 0;
        CGFloat area = frame.size.width * frame.size.height;
        // the one that plays; among equals the smaller one (a clip inside a bigger player's frame)
        if (!best || (playing && !bestPlaying) || (playing == bestPlaying && area < bestArea)) {
            best = layer;
            bestPlaying = playing;
            bestArea = area;
        }
    }
    return best;
}

#pragma mark - the download button

static CGImageRef VGBadgeImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(kBadgeSize, kBadgeSize);
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.opaque = NO;
        image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGRect circle = CGRectInset((CGRect){CGPointZero, size}, 0.5, 0.5);
            [[UIColor colorWithWhite:0 alpha:0.55] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:circle] fill];
            [[UIColor colorWithWhite:1 alpha:0.28] setStroke];
            UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(circle, 0.25, 0.25)];
            ring.lineWidth = 1;
            [ring stroke];
            // an arrow down onto a line
            UIBezierPath *arrow = [UIBezierPath bezierPath];
            CGFloat cx = size.width / 2;
            [arrow moveToPoint:CGPointMake(cx, 7.5)];
            [arrow addLineToPoint:CGPointMake(cx, 18)];
            [arrow moveToPoint:CGPointMake(cx - 4.6, 13.6)];
            [arrow addLineToPoint:CGPointMake(cx, 18.2)];
            [arrow addLineToPoint:CGPointMake(cx + 4.6, 13.6)];
            [arrow moveToPoint:CGPointMake(cx - 5.6, 22)];
            [arrow addLineToPoint:CGPointMake(cx + 5.6, 22)];
            arrow.lineWidth = 2;
            arrow.lineCapStyle = kCGLineCapRound;
            arrow.lineJoinStyle = kCGLineJoinRound;
            [UIColor.whiteColor setStroke];
            [arrow stroke];
        }];
    });
    return image.CGImage;
}

static BOOL VGLayerWantsBadge(AVPlayerLayer *layer) {
    if (!atomic_load(&gEnabled) || !atomic_load(&gBadgeOn)) return NO;
    CGRect bounds = layer.bounds;
    if (bounds.size.width < 120 || bounds.size.height < 90) return NO;
    if (!layer.isReadyForDisplay) return NO;
    return VGSourceForPlayerLayer(layer) != nil;
}

/// Shows, hides and places the layer's button. Main thread.
static void VGLayoutBadge(AVPlayerLayer *layer) {
    CALayer *badge = objc_getAssociatedObject(layer, &kBadgeKey);
    BOOL show = VGLayerWantsBadge(layer);
    if (!show) {
        if (badge && !badge.isHidden) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            badge.hidden = YES;
            [CATransaction commit];
        }
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!badge) {
        badge = [CALayer layer];
        badge.name = @"VidGrabButton";
        badge.contents = (__bridge id)VGBadgeImage();
        badge.contentsScale = UIScreen.mainScreen.scale;
        badge.zPosition = 10000;
        badge.actions = @{@"position": NSNull.null, @"bounds": NSNull.null, @"hidden": NSNull.null, @"opacity": NSNull.null};
        objc_setAssociatedObject(layer, &kBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (badge.superlayer != layer) [layer addSublayer:badge];
    // the corner of what is seen of the picture: the picture can be smaller than the layer
    // (letterboxing) or larger (zoomed in and cut off by its card), and part of it can be scrolled away
    UIWindow *window = VGHostView(layer).window;
    CGRect area = window ? VGVisibleRectInLayer(layer, window) : CGRectNull;
    if (CGRectIsNull(area) || area.size.width < kBadgeSize + 2 * kBadgeMargin || area.size.height < kBadgeSize + 2 * kBadgeMargin) {
        badge.hidden = YES;
        [CATransaction commit];
        return;
    }
    CGRect picture = layer.videoRect;
    if (!CGRectIsEmpty(picture) && !CGRectIsInfinite(picture) && !isnan(picture.origin.x) && !isnan(picture.size.width)) {
        CGRect shared = CGRectIntersection(area, picture);
        if (!CGRectIsNull(shared) && shared.size.width >= kBadgeSize + 2 * kBadgeMargin && shared.size.height >= kBadgeSize + 2 * kBadgeMargin) area = shared;
    }
    int corner = atomic_load(&gCorner);
    BOOL right = corner == 1 || corner == 3, bottom = corner == 2 || corner == 3;
    CGFloat x = right ? CGRectGetMaxX(area) - kBadgeMargin - kBadgeSize : CGRectGetMinX(area) + kBadgeMargin;
    CGFloat y = bottom ? CGRectGetMaxY(area) - kBadgeMargin - kBadgeSize : CGRectGetMinY(area) + kBadgeMargin;
    badge.frame = CGRectMake(round(x), round(y), kBadgeSize, kBadgeSize);
    badge.hidden = NO;
    [CATransaction commit];
}

CGRect VGBadgeFrameInWindow(AVPlayerLayer *layer, UIWindow *window) {
    CALayer *badge = objc_getAssociatedObject(layer, &kBadgeKey);
    if (!badge || badge.isHidden || badge.superlayer != layer) return CGRectNull;
    if (CGRectIsNull(VGLayerFrameInWindow(layer, window))) return CGRectNull;
    return [badge convertRect:badge.bounds toLayer:window.layer];
}

AVPlayerLayer *VGBadgeLayerAtPoint(UIWindow *window, CGPoint point) {
    if (!atomic_load(&gEnabled) || !atomic_load(&gBadgeOn)) return nil;
    for (AVPlayerLayer *layer in VGKnownPlayerLayers()) {
        CGRect frame = VGBadgeFrameInWindow(layer, window);
        if (CGRectIsNull(frame)) continue;
        if (!CGRectContainsPoint(CGRectInset(frame, -kBadgeReach, -kBadgeReach), point)) continue;
        if (VGLayerCoveredAtPoint(layer, window, point)) continue;
        return layer;
    }
    return nil;
}

@interface VGFollower : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) CFTimeInterval until;
@end

@implementation VGFollower
- (void)tick:(CADisplayLink *)link {
    for (AVPlayerLayer *layer in VGKnownPlayerLayers()) {
        if (objc_getAssociatedObject(layer, &kBadgeKey) || layer.player.rate != 0) VGLayoutBadge(layer);
    }
    if (CACurrentMediaTime() > self.until) {
        [self.link invalidate];
        self.link = nil;
    }
}
@end

/// Scrolling moves a video without the video laying itself out again, so after each touch the
/// buttons are placed every frame (at 20 a second) until the scroll has surely come to rest.
void VGFollowScrolling(void) {
    if (!NSThread.isMainThread) return;
    static VGFollower *follower;
    if (!follower) follower = [VGFollower new];
    follower.until = CACurrentMediaTime() + 3.0;
    if (!follower.link && atomic_load(&gEnabled) && atomic_load(&gBadgeOn)) {
        follower.link = [CADisplayLink displayLinkWithTarget:follower selector:@selector(tick:)];
        follower.link.preferredFramesPerSecond = 20;
        [follower.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

void VGRefreshBadgesSoon(void) {
    static atomic_bool pending;
    static atomic_int burst;
    if (atomic_exchange(&pending, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&pending, false);
        for (AVPlayerLayer *layer in VGKnownPlayerLayers()) VGLayoutBadge(layer);
        // A layer says "ready" a moment after its player starts, and nothing announces that moment.
        // So each occasion is followed by three more looks; a newer occasion replaces the older one's.
        int mine = atomic_fetch_add(&burst, 1) + 1;
        for (NSNumber *delay in @[@0.3, @1.0, @2.5]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (atomic_load(&burst) != mine) return;
                for (AVPlayerLayer *layer in VGKnownPlayerLayers()) VGLayoutBadge(layer);
            });
        }
    });
}

#pragma mark - hooks

static id (*gAssetInit)(__unsafe_unretained id, SEL, NSURL *, NSDictionary *);
static id VGAssetInit(__unsafe_unretained id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    id asset = gAssetInit(self, _cmd, url, options);
    if (asset && [options isKindOfClass:NSDictionary.class] && options.count) {
        NSDictionary *headers = options[@"AVURLAssetHTTPHeaderFieldsKey"];
        if ([headers isKindOfClass:NSDictionary.class] && headers.count) {
            objc_setAssociatedObject(asset, &kHeadersKey, [headers copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return asset;
}

static void (*gSetPlayer)(AVPlayerLayer *, SEL, AVPlayer *);
static void VGSetPlayer(AVPlayerLayer *self, SEL _cmd, AVPlayer *player) {
    gSetPlayer(self, _cmd, player);
    if (player) {
        NSHashTable *table = VGLayers();
        @synchronized (table) { [table addObject:self]; }
    }
    VGRefreshBadgesSoon();
}

static void (*gLayout)(AVPlayerLayer *, SEL);
static void VGLayout(AVPlayerLayer *self, SEL _cmd) {
    gLayout(self, _cmd);
    if (!NSThread.isMainThread) return;
    if (objc_getAssociatedObject(self, &kBadgeKey)) VGLayoutBadge(self);
    else if (atomic_load(&gEnabled) && atomic_load(&gBadgeOn) && self.player) VGRefreshBadgesSoon();     // no button yet: maybe it is due
}

NSString *VGCaptureHookSummary(void) {
    return [NSString stringWithFormat:@"%ld of 3 hooks", (long)gHooks];
}

static void VGReadSettings(void) {
    atomic_store(&gEnabled, [VGPrefs enabled]);
    atomic_store(&gBadgeOn, [VGPrefs badge]);
    atomic_store(&gCorner, (int)[VGPrefs badgeCorner]);
}

void VGCaptureInstall(void) {
    VGReadSettings();
    gHooks = 0;
    if (VGHook(AVURLAsset.class, @selector(initWithURL:options:), (IMP)VGAssetInit, (IMP *)&gAssetInit)) gHooks++;
    if (VGHook(AVPlayerLayer.class, @selector(setPlayer:), (IMP)VGSetPlayer, (IMP *)&gSetPlayer)) gHooks++;
    if (VGHook(AVPlayerLayer.class, @selector(layoutSublayers), (IMP)VGLayout, (IMP *)&gLayout)) gHooks++;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:VGPrefsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        VGReadSettings();
        VGRefreshBadgesSoon();
    }];
    // Playback starting, looping or jumping is when a button may have to appear or go: no timers.
    for (NSNotificationName name in @[AVPlayerItemTimeJumpedNotification, AVPlayerItemNewAccessLogEntryNotification,
                                      AVPlayerItemDidPlayToEndTimeNotification, AVPlayerItemFailedToPlayToEndTimeNotification]) {
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { VGRefreshBadgesSoon(); }];
    }
}
