/*  WPHost.m — SpringBoard-side helpers.

    None of this touches a dating app's process. Frontmost-app detection uses
    SpringBoard's own accessibility helper; the installed-app list uses
    LSApplicationWorkspace (same list the App Switcher uses).                 */

#import "WPlus.h"
#import <objc/message.h>

// minimal private surface we rely on (all resolved defensively)
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;   // @"User" / @"System"
@end
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

@implementation WPHost

+ (NSString *)frontmostBundleID {
    @try {
        id app = [UIApplication sharedApplication];
        SEL sel = @selector(_accessibilityFrontMostApplication);
        if (![app respondsToSelector:sel]) return nil;
        id front = ((id(*)(id, SEL))objc_msgSend)(app, sel);
        if (!front) return nil;                       // home screen / SpringBoard itself
        if ([front respondsToSelector:@selector(bundleIdentifier)])
            return [front bundleIdentifier];
    } @catch (__unused id e) {}
    return nil;
}

+ (BOOL)wingmanEnabledForFrontmost {
    NSString *bid = [self frontmostBundleID];
    if (bid.length == 0) return NO;                   // nothing in front -> no bubble
    return [WMApps kindForBundleID:bid] != WMAppKindNone;
}

+ (NSArray<NSDictionary *> *)installedApps {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        LSApplicationWorkspace *ws = [cls defaultWorkspace];
        for (LSApplicationProxy *p in [ws allApplications]) {
            NSString *bid = p.applicationIdentifier, *nm = p.localizedName;
            if (bid.length == 0) continue;
            BOOL isApple = [bid hasPrefix:@"com.apple."];
            BOOL isUser  = [p.applicationType isEqualToString:@"User"];
            // Keep normal App Store apps (type "User") AND TrollStore / sideloaded apps
            // (TrollStore registers them as "System" for persistence, but they are never
            // com.apple.*). Skip only genuine Apple system apps.
            if (!isUser && isApple) continue;
            [out addObject:@{ @"id": bid, @"name": nm.length ? nm : bid }];
        }
    } @catch (__unused id e) {}
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    return out;
}

+ (void)copyToClipboard:(NSString *)text {
    if (text.length) [UIPasteboard generalPasteboard].string = text;
}

@end
