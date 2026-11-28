// What every part needs: where the jailbreak lives, the settings, the log, the hook helper.
// Foundation only, so the engine test can link it on a Mac.
#import "VidGrab.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <notify.h>

NSString *const VGPrefsChangedNotification = @"VGPrefsChangedNotification";

NSString *VGRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = @"";
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr((const void *)&VGRoot, &info) && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            for (NSString *marker in @[@"/usr/lib/TweakInject/", @"/Library/MobileSubstrate/DynamicLibraries/"]) {
                NSRange range = [path rangeOfString:marker];
                if (range.location != NSNotFound) {
                    root = [path substringToIndex:range.location];
                    break;
                }
            }
        }
    });
    return root;
}

NSString *VGTestFolder(void) {
    static NSString *folder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("VIDGRAB_DIR");
        if (value && value[0]) folder = [NSString stringWithUTF8String:value];
    });
    return folder;
}

NSError *VGError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"VidGrab" code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Something went wrong."}];
}

NSString *VGByteString(long long bytes) {
    if (bytes < 1000) return [NSString stringWithFormat:@"%lld B", bytes];
    if (bytes < 1000 * 1000) return [NSString stringWithFormat:@"%.0f KB", bytes / 1000.0];
    if (bytes < 100 * 1000 * 1000) return [NSString stringWithFormat:@"%.1f MB", bytes / 1000000.0];
    if (bytes < 1000LL * 1000 * 1000) return [NSString stringWithFormat:@"%.0f MB", bytes / 1000000.0];
    return [NSString stringWithFormat:@"%.2f GB", bytes / 1000000000.0];
}

BOOL VGHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) {
        VGLog(@"hook skipped: -[%@ %@] not found", cls ? NSStringFromClass(cls) : @"(no class)", NSStringFromSelector(sel));
        return NO;
    }
    *original = method_getImplementation(method);
    // an inherited method gets an override on this class; the class's own method gets the new code
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        *original = method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
    }
    return YES;
}

#pragma mark - settings

static NSDictionary *gPrefs;
static BOOL gDiagMarker;
static NSObject *gPrefsLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *VGPrefsPath(void) {
    NSString *test = VGTestFolder();
    if (test) return [test stringByAppendingPathComponent:@"prefs.plist"];
    return [VGRoot() stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.adarsh.vidgrab.plist"];
}

static NSMutableDictionary *gOverrides;                     // tests: settings changed in this app's memory only

static id VGPref(NSString *key) {
    @synchronized (gPrefsLock()) { return gOverrides[key] ?: gPrefs[key]; }
}

void VGOverridePref(NSString *key, id value) {
    @synchronized (gPrefsLock()) {
        if (!key) {
            [gOverrides removeAllObjects];
        } else {
            if (!gOverrides) gOverrides = [NSMutableDictionary new];
            gOverrides[key] = value;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VGPrefsChangedNotification object:nil];
    });
}
static BOOL VGPrefBool(NSString *key, BOOL fallback) {
    id value = VGPref(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}
static double VGPrefNumber(NSString *key, double fallback) {
    id value = VGPref(key);
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

@implementation VGPrefs

+ (void)reload {
    NSDictionary *read = [NSDictionary dictionaryWithContentsOfFile:VGPrefsPath()] ?: @{};
    NSString *marker = VGTestFolder() ? [VGTestFolder() stringByAppendingPathComponent:@"diag"]
                                      : [VGRoot() stringByAppendingPathComponent:@"var/mobile/Library/VidGrab/diag"];
    BOOL diag = [NSFileManager.defaultManager fileExistsAtPath:marker];
    @synchronized (gPrefsLock()) {
        gPrefs = read;
        gDiagMarker = diag;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VGPrefsChangedNotification object:nil];
    });
}

+ (void)load {
    [self reload];
    int token = 0;
    notify_register_dispatch("com.adarsh.vidgrab/prefs", &token, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int t) {
        [VGPrefs reload];
        // Settings hands the change to a daemon that writes the file a moment later
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [VGPrefs reload];
        });
    });
}

+ (BOOL)enabled {
    if (!VGPrefBool(@"enabled", YES)) return NO;
    NSString *name = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    // one switch per app in Settings, also where an app's program has gone by two names
    NSString *known = @{@"X": @"Twitter", @"Threads": @"Barcelona", @"Reddit": @"RedditApp", @"Consumer": @"LinkedIn"}[name];
    return VGPrefBool([@"app-" stringByAppendingString:known ?: name], YES);
}
+ (BOOL)badge { return VGPrefBool(@"badge", YES); }
+ (BOOL)pictures { return VGPrefBool(@"pictures", YES); }
+ (NSInteger)badgeCorner {
    NSInteger corner = (NSInteger)VGPrefNumber(@"badgeCorner", -1);
    if (corner >= 0 && corner <= 3) return corner;
    // Automatic: top right, except in apps that keep a control of their own there on every video
    // (Pinterest: the sound button), where the bottom right is free
    NSString *name = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    return [@[@"Pinterest"] containsObject:name] ? 3 : 1;
}
+ (NSInteger)holdFingers { return MAX(0, MIN(2, (NSInteger)VGPrefNumber(@"hold", 1))); }
+ (double)holdTime { return MAX(0.25, MIN(2.0, VGPrefNumber(@"holdTime", 0.55))); }
+ (BOOL)blockAppHold { return VGPrefBool(@"blockAppHold", YES); }
+ (NSInteger)action { return (NSInteger)VGPrefNumber(@"action", 0); }
+ (NSInteger)tapAction { return (NSInteger)VGPrefNumber(@"tapAction", 1); }
+ (NSInteger)maxHeight { return MAX(0, (NSInteger)VGPrefNumber(@"quality", 0)); }
+ (BOOL)album { return VGPrefBool(@"album", YES); }
+ (BOOL)haptic { return VGPrefBool(@"haptic", YES); }

@end

#pragma mark - log

BOOL VGLogging(void) {
    if (VGTestFolder()) return YES;
    @synchronized (gPrefsLock()) {
        if (gDiagMarker) return YES;
    }
    return VGPrefBool(@"debug", NO);
}

void VGLog(NSString *format, ...) {
    if (!VGLogging()) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    static dispatch_queue_t queue;
    static NSDateFormatter *stamp;
    static NSString *path;
    static BOOL toStandardError;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.adarsh.vidgrab.log", DISPATCH_QUEUE_SERIAL);
        stamp = [NSDateFormatter new];
        stamp.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        toStandardError = getenv("VIDGRAB_STDERR") != NULL;
        // in the app's own temporary folder: every app may write there, and it is cleared by iOS
        path = [VGTestFolder() ?: NSTemporaryDirectory() stringByAppendingPathComponent:@"vidgrab.log"];
    });
    NSDate *now = NSDate.date;
    dispatch_async(queue, ^{
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [stamp stringFromDate:now], text];
        if (toStandardError) {
            fputs(line.UTF8String, stderr);
            return;
        }
        NSFileManager *files = NSFileManager.defaultManager;
        NSDictionary *attributes = [files attributesOfItemAtPath:path error:NULL];
        if (!attributes || [attributes fileSize] > 512 * 1024) [NSData.data writeToFile:path atomically:NO];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}
