/*  probe/main.m — a small app for the simulator test: an app that may send notifications.

    On launch it asks for permission to notify and writes the answer to Documents/probe.log.
    It asks for provisional permission first (iOS grants that without showing an alert), then
    for the full one (which shows the "Would Like to Send You Notifications" alert; the test
    presses Allow). It registers two actions, so its notifications have a "Mark as Paid" and a
    "Remind Me" under them when held down, like a real app's. The test then sends it push
    notifications with `xcrun simctl push`: those travel the same road as a real app's.       */

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

static void ProbeLog(NSString *line) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"probe.log"];
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [[old stringByAppendingFormat:@"%@\n", line] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[ShaniProbe] %@", line);
}

@interface ProbeDelegate : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemTealColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 24, 120)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    label.textColor = UIColor.whiteColor;
    label.text = @"PayDemo\n(Shani's test app)";
    [vc.view addSubview:label];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    UNNotificationAction *paid = [UNNotificationAction actionWithIdentifier:@"paid" title:@"Mark as Paid" options:UNNotificationActionOptionNone];
    UNNotificationAction *later = [UNNotificationAction actionWithIdentifier:@"later" title:@"Remind Me" options:UNNotificationActionOptionNone];
    UNNotificationCategory *category = [UNNotificationCategory categoryWithIdentifier:@"offer" actions:@[ paid, later ] intentIdentifiers:@[]
                                                                              options:UNNotificationCategoryOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:category]];

    BOOL full = [NSProcessInfo.processInfo.arguments containsObject:@"--full"];
    UNAuthorizationOptions wanted = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
    if (!full) wanted |= UNAuthorizationOptionProvisional;
    ProbeLog([NSString stringWithFormat:@"launched, asking for %@ permission", full ? @"full" : @"provisional"]);
    [center requestAuthorizationWithOptions:wanted completionHandler:^(BOOL granted, NSError *error) {
        ProbeLog([NSString stringWithFormat:@"permission: granted %d error %@", (int)granted, error.localizedDescription ?: @"none"]);
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            ProbeLog([NSString stringWithFormat:@"settings: authorization %ld alert %ld lock screen %ld centre %ld sound %ld", (long)settings.authorizationStatus,
                      (long)settings.alertSetting, (long)settings.lockScreenSetting, (long)settings.notificationCenterSetting, (long)settings.soundSetting]);
        }];
    }];
    return YES;
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))done {
    ProbeLog([NSString stringWithFormat:@"response: %@", response.actionIdentifier]);
    done();
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class));
    }
}
