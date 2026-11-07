#import "WKAppDelegate.h"

// The container app exists only to host the keyboard extension and to tell you how to
// turn it on. All the real work happens in the keyboard (WingmanKeyboard.appex).
@implementation WKAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:1];

    UILabel *title = [UILabel new];
    title.text = @"Wingman Keyboard";
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *body = [UILabel new];
    body.numberOfLines = 0;
    body.font = [UIFont systemFontOfSize:16];
    body.textColor = [UIColor colorWithWhite:0.9 alpha:1];
    body.text = @"Turn it on once:\n\n"
                 "1.  Settings  ›  General  ›  Keyboard  ›  Keyboards\n"
                 "2.  Add New Keyboard…  ›  Wingman\n"
                 "3.  Tap  Wingman  ›  turn on  Allow Full Access\n\n"
                 "Then in any chat, hold the  🌐  globe key and pick  Wingman. "
                 "The replies you generated with the Wingman bubble appear as buttons — "
                 "tap one to type it straight in.";
    body.translatesAutoresizingMaskIntoConstraints = NO;

    [vc.view addSubview:title];
    [vc.view addSubview:body];
    UILayoutGuide *g = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:g.topAnchor constant:32],
        [title.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24],
        [body.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [body.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
    ]];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
