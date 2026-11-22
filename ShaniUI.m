/*  ShaniUI.m — Shani's own pictures: the Saturn glyph and the small confirmation pill.

    The pill appears for a moment at the top of the screen after a tap on Shani ("Paytm · Shani
    on · held 1 hour at a time"). It is in a window of its own that never takes a touch, and is
    marked secure so that it also shows over the Lock Screen.                                  */

#import "Shani.h"

#pragma mark - Saturn

// A ringed planet, drawn as a template image (it takes the colour of wherever it is put).
UIImage *ShaniGlyph(CGFloat side) {
    if (side < 8) side = 8;
    static NSCache<NSNumber *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *known = [cache objectForKey:@(side)];
    if (known) return known;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGPoint mid = CGPointMake(side / 2, side / 2);
        CGFloat planet = side * 0.26;
        CGFloat line = MAX(1.0, side * 0.075);
        CGFloat rx = side * 0.5 - line / 2 - side * 0.01, ry = side * 0.15;
        CGAffineTransform place = CGAffineTransformRotate(CGAffineTransformMakeTranslation(mid.x, mid.y), -0.38);    // up at the right
        [UIColor.blackColor setFill];
        [UIColor.blackColor setStroke];

        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-rx, -ry, 2 * rx, 2 * ry)];
        [ring applyTransform:place];
        ring.lineWidth = line;
        [ring stroke];

        // the planet hides the far side of the ring, with a little air around it
        CGContextSetBlendMode(c, kCGBlendModeClear);
        [[UIBezierPath bezierPathWithArcCenter:mid radius:planet + line * 0.95 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        CGContextSetBlendMode(c, kCGBlendModeNormal);
        [[UIBezierPath bezierPathWithArcCenter:mid radius:planet startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];

        // the near side of the ring crosses in front
        UIBezierPath *front = [UIBezierPath bezierPathWithArcCenter:CGPointZero radius:rx startAngle:0 endAngle:M_PI clockwise:YES];
        [front applyTransform:CGAffineTransformScale(place, 1, ry / rx)];
        front.lineCapStyle = kCGLineCapButt;
        front.lineWidth = line * 2.7;
        CGContextSetBlendMode(c, kCGBlendModeClear);
        [front stroke];
        CGContextSetBlendMode(c, kCGBlendModeNormal);
        front.lineWidth = line;
        [front stroke];
    }];
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (image) [cache setObject:image forKey:@(side)];
    return image;
}

#pragma mark - the pill

@interface ShaniToastWindow : UIWindow
@end

@implementation ShaniToastWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }      // never in the way of a touch
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface ShaniToastController : UIViewController
@end

@implementation ShaniToastController
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)prefersStatusBarHidden { return NO; }
@end

// Same ranking the other tweaks settled on: on Dynamic Island phones SpringBoard has a second
// foreground scene, and a window put there does not show.
static UIWindowScene *ShaniMainScene(void) {
    UIWindowScene *best = nil;
    NSUInteger bestRank = NSUIntegerMax;
    Class main = NSClassFromString(@"SBWindowScene");
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        NSUInteger rank = 0;
        if (!(main && [ws class] == main)) rank += 8;
        if ([NSStringFromClass([ws class]) containsString:@"Aperture"]) rank += 4;
        if (ws.screen != UIScreen.mainScreen) rank += 2;
        if (ws.activationState != UISceneActivationStateForegroundActive) rank += 1;
        if (rank < bestRank) { bestRank = rank; best = ws; }
    }
    return best;
}

static CGFloat ShaniTopInset(UIWindowScene *scene) {
    CGFloat top = 0;
    for (UIWindow *w in scene.windows) top = MAX(top, w.safeAreaInsets.top);
    if (top <= 0) top = UIScreen.mainScreen.bounds.size.height >= 800 ? 50 : 20;
    return top;
}

void ShaniToast(NSString *title, NSString *detail) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ ShaniToast(title, detail); }); return; }
    static ShaniToastWindow *window;
    static NSUInteger turn;
    @try {
        UIWindowScene *scene = ShaniMainScene();
        if (!scene) { ShaniLog(@"pill: no scene to show it in"); return; }
        if (!window || window.windowScene != scene) {
            window = [[ShaniToastWindow alloc] initWithWindowScene:scene];
            window.windowLevel = 1400;                                     // above the Lock Screen and banners
            window.backgroundColor = UIColor.clearColor;
            window.opaque = NO;
            window.userInteractionEnabled = NO;
            window.rootViewController = [ShaniToastController new];
            window.rootViewController.view.backgroundColor = UIColor.clearColor;
            window.rootViewController.view.userInteractionEnabled = NO;
            ShaniSendBool(window, @"_setSecure:", YES);                    // drawn while the phone is locked too
        }
        UIView *host = window.rootViewController.view;
        for (UIView *old in [host.subviews copy]) [old removeFromSuperview];
        NSUInteger mine = ++turn;

        UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        pill.layer.cornerRadius = 24;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.masksToBounds = YES;
        pill.layer.borderWidth = 1.0 / MAX(1, UIScreen.mainScreen.scale);
        pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;

        UIImageView *glyph = [[UIImageView alloc] initWithImage:ShaniGlyph(30)];
        glyph.tintColor = [UIColor colorWithRed:0.96 green:0.80 blue:0.42 alpha:1];        // Saturn's pale gold
        glyph.contentMode = UIViewContentModeScaleAspectFit;

        UILabel *top = [UILabel new];
        top.text = title;
        top.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        top.textColor = UIColor.whiteColor;
        UILabel *bottom = [UILabel new];
        bottom.text = detail;
        bottom.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        bottom.textColor = [UIColor colorWithWhite:1 alpha:0.72];
        for (UILabel *l in @[ top, bottom ]) { l.lineBreakMode = NSLineBreakByTruncatingTail; l.numberOfLines = 1; }

        CGFloat screenW = host.bounds.size.width > 0 ? host.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
        CGFloat maxText = screenW - 40 - 16 - 30 - 10 - 20;
        CGFloat textW = MIN(maxText, MAX([top sizeThatFits:CGSizeMake(maxText, 20)].width, [bottom sizeThatFits:CGSizeMake(maxText, 18)].width));
        CGFloat w = 16 + 30 + 10 + ceil(textW) + 20, h = 52;
        pill.frame = CGRectMake(round((screenW - w) / 2), ShaniTopInset(scene) + 6, w, h);
        glyph.frame = CGRectMake(16, (h - 30) / 2, 30, 30);
        top.frame = CGRectMake(56, 8, ceil(textW), 19);
        bottom.frame = CGRectMake(56, 27, ceil(textW), 17);
        [pill.contentView addSubview:glyph];
        [pill.contentView addSubview:top];
        [pill.contentView addSubview:bottom];
        [host addSubview:pill];

        window.hidden = NO;
        pill.alpha = 0;
        pill.transform = CGAffineTransformMakeTranslation(0, -14);
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ pill.alpha = 1; pill.transform = CGAffineTransformIdentity; } completion:nil];
        ShaniAfter(2.6, ^{
            if (mine != turn) return;
            [UIView animateWithDuration:0.3 animations:^{ pill.alpha = 0; pill.transform = CGAffineTransformMakeTranslation(0, -10); }
                             completion:^(BOOL done) {
                if (mine != turn) return;
                [pill removeFromSuperview];
                window.hidden = YES;
            }];
        });
    } @catch (NSException *e) {
        ShaniLog(@"pill threw %@", e.reason);
    }
}
