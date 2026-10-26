/*  Tweak.x — Wingman entry point

    ElleKit offers the dylib to every UIKit app. In each real app (never in
    extensions) we listen for the app becoming active and decide then whether
    the bubble belongs here, so Settings changes (new extra app, auto-detect
    off) apply as soon as you switch back to that app, no relaunch needed.
    If you hide the bubble, it comes back the next time the app is opened.  */

#import "Wingman.h"

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundlePath hasSuffix:@".app"]) return;   // keyboards, widgets...

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue *main = [NSOperationQueue mainQueue];

        [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:main
                    usingBlock:^(NSNotification *n) { [[WMBubble shared] appWillEnterForeground]; }];

        void (^refresh)(NSNotification *) = ^(NSNotification *n) {
            // let the app finish laying out its windows first
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [[WMBubble shared] refresh]; });
        };
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:refresh];
        [nc addObserverForName:UISceneDidActivateNotification object:nil queue:main usingBlock:refresh];
    }
}
