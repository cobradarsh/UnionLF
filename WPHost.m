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

// The last few third-party bundle ids SpringBoard reported in front (newest first). The app picker
// lists them so an app can be enabled by the EXACT id the detector sees, even an unusual one
// (TrollStore builds, dual installs). Main thread only (the 1 s timer and the picker).
static NSMutableArray<NSString *> *gRecentFront;

@implementation WPHost

+ (NSString *)frontmostBundleID {
    @try {
        id app = [UIApplication sharedApplication];
        SEL sel = @selector(_accessibilityFrontMostApplication);
        if (![app respondsToSelector:sel]) return nil;
        id front = ((id(*)(id, SEL))objc_msgSend)(app, sel);
        if (!front) return nil;                       // home screen / SpringBoard itself
        NSString *bid = nil;
        if ([front respondsToSelector:@selector(bundleIdentifier)]) bid = [front bundleIdentifier];
        // some SBApplication builds only expose it as displayIdentifier
        if (bid.length == 0 && [front respondsToSelector:NSSelectorFromString(@"displayIdentifier")])
            bid = (NSString *)[front valueForKey:@"displayIdentifier"];
        return bid.length ? bid : nil;
    } @catch (__unused id e) {}
    return nil;
}

+ (void)_noteFront:(NSString *)bid {
    if (bid.length == 0 || [bid hasPrefix:@"com.apple."]) return;
    if (!gRecentFront) gRecentFront = [NSMutableArray array];
    if ([gRecentFront.firstObject isEqualToString:bid]) return;
    [gRecentFront removeObject:bid];
    [gRecentFront insertObject:bid atIndex:0];
    while (gRecentFront.count > 10) [gRecentFront removeLastObject];
}

+ (NSArray<NSString *> *)recentFrontmostApps { return gRecentFront ? [gRecentFront copy] : @[]; }

+ (BOOL)wingmanEnabledForFrontmost {
    NSString *bid = [self frontmostBundleID];
    if (bid.length == 0) return NO;                   // nothing in front -> no bubble
    [self _noteFront:bid];
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
