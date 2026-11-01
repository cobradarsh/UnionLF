/*  Tweak.x — Wingman Plus entry point.

    Loaded ONLY into com.apple.springboard (see WingmanPlus.plist). We hook
    nothing in any dating app — this hook is on SpringBoard itself, to start the
    floating bubble once SpringBoard's UI exists. A slow timer re-checks which
    app is in front and shows/hides the bubble accordingly.                     */

#import "WPlus.h"

static NSTimer *gVisTimer;

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [[WPBubble shared] start];
            gVisTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                @try { [[WPBubble shared] evaluateVisibility]; } @catch (__unused id e) {}
            }];
        } @catch (__unused id e) {}
    });
}
%end
