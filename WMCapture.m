/*  WMCapture.m — screenshot + 3-screen scroll capture

    Token savings: frames are rendered at 1.5x (not the 3x screen scale)
    and sent as separate images. A single stitched 3-screen image gets
    downscaled by the API until the text is unreadable, and costs more.  */

#import "Wingman.h"

static CGFloat const kWMCaptureScale = 1.5;   // ~645 px wide on a Pro Max

@implementation WMCapture

+ (UIImage *)_render:(UIWindow *)win {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale  = kWMCaptureScale;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:win.bounds.size format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:YES];
    }];
}

// ── single screenshot ─────────────────────────────────────
+ (NSArray<UIImage *> *)screenshotHidingView:(UIView *)viewToHide {
    CGFloat prev = viewToHide.alpha;
    viewToHide.alpha = 0;
    UIWindow *win = [self _keyWindow];
    UIImage *img = win ? [self _render:win] : nil;
    viewToHide.alpha = prev;
    return img ? @[img] : @[];
}

// ── scrolling capture (current screen + up to 2 older) ────
+ (void)scrollCaptureHidingView:(UIView *)viewToHide
                     completion:(void(^)(NSArray<UIImage *> *frames))done {

    UIWindow *win = [self _keyWindow];
    UIScrollView *sv = win ? [self _chatScrollViewIn:win] : nil;
    if (!sv) { done([self screenshotHidingView:viewToHide]); return; }

    CGFloat prevAlpha = viewToHide.alpha;
    viewToHide.alpha = 0;

    // Some chat apps draw the list upside down (newest at offset 0).
    BOOL inverted = sv.transform.d < 0;
    CGPoint original = sv.contentOffset;
    CGFloat pageH    = sv.bounds.size.height * 0.85;   // small overlap between frames
    CGFloat minY     = -sv.adjustedContentInset.top;
    CGFloat maxY     = MAX(minY, sv.contentSize.height - sv.bounds.size.height + sv.adjustedContentInset.bottom);

    NSMutableArray<UIImage *> *frames = [NSMutableArray array];
    __block NSInteger remaining = 3;
    __block void (^step)(void);
    __weak __block void (^weakStep)(void);

    step = ^{
        UIImage *f = [self _render:win];
        if (f) [frames insertObject:f atIndex:0];          // oldest first
        remaining--;

        CGFloat y = sv.contentOffset.y;
        BOOL atOldestEnd = inverted ? (y >= maxY - 1) : (y <= minY + 1);

        if (remaining <= 0 || atOldestEnd) {
            [sv setContentOffset:original animated:NO];
            viewToHide.alpha = prevAlpha;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ done(frames); });
            step = nil;   // break retain cycle
            return;
        }

        CGFloat ny = inverted ? MIN(y + pageH, maxY) : MAX(y - pageH, minY);
        [sv setContentOffset:CGPointMake(sv.contentOffset.x, ny) animated:NO];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            void (^s)(void) = weakStep;
            if (s) s();
        });
    };
    weakStep = step;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), step);
}

// ── helpers ───────────────────────────────────────────────
+ (UIWindow *)_keyWindow {
    // the chat app's own window in the live scene (never Wingman's windows)
    UIWindow *fallback = nil;
    for (UIWindow *w in WMActiveScene().windows) {
        if (w.hidden || w == [WMBubble shared].overlayWindow) continue;
        if (w.windowLevel != UIWindowLevelNormal) continue;
        if (w.isKeyWindow) return w;
        if (!fallback) fallback = w;
    }
    return fallback;
}

// the largest vertically scrollable view on screen = the chat list
+ (UIScrollView *)_chatScrollViewIn:(UIView *)root {
    __block UIScrollView *best = nil;
    __block CGFloat bestArea = 0;
    __block void (^walk)(UIView *);
    __weak __block void (^weakWalk)(UIView *);
    walk = ^(UIView *v) {
        if ([v isKindOfClass:[UIScrollView class]] && !v.hidden && v.alpha > 0.01) {
            UIScrollView *s = (UIScrollView *)v;
            CGFloat area = s.bounds.size.width * s.bounds.size.height;
            if (s.bounds.size.height > 200 &&
                s.contentSize.height > s.bounds.size.height + 10 &&
                ![s isKindOfClass:[UITextView class]] &&
                area > bestArea) {
                best = s; bestArea = area;
            }
        }
        for (UIView *sub in v.subviews) weakWalk(sub);
    };
    weakWalk = walk;
    walk(root);
    return best;
}

@end
