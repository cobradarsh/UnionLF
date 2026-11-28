// Where the jailbreak lives, the settings, the log, and the state with its file.
#import "GuestMode.h"
#include <dlfcn.h>
#include <notify.h>

NSNotificationName const GMStateChangedNotification = @"GMStateChangedNotification";
NSNotificationName const GMSettingsChangedNotification = @"GMSettingsChangedNotification";

NSString *GMRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = @"";
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr((const void *)&GMRoot, &info) && info.dli_fname) {
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

NSString *GMTestFolder(void) {
    static NSString *folder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("GUESTMODE_DIR");
        if (value && value[0]) folder = [NSString stringWithUTF8String:value];
    });
    return folder;
}

#pragma mark - settings

static NSDictionary *gSettings;
static BOOL gDiag;
static NSObject *GMSettingsLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static void GMReloadSettings(void) {
    NSString *test = GMTestFolder();
    NSString *path = test ? [test stringByAppendingPathComponent:@"prefs.plist"]
                          : [GMRoot() stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.adarsh.guestmode.plist"];
    NSString *marker = test ? [test stringByAppendingPathComponent:@"diag"]
                            : [GMRoot() stringByAppendingPathComponent:@"var/mobile/Library/GuestMode/diag"];
    NSDictionary *read = [NSDictionary dictionaryWithContentsOfFile:path] ?: @{};
    BOOL diag = [NSFileManager.defaultManager fileExistsAtPath:marker];
    @synchronized (GMSettingsLock()) {
        gSettings = read;
        gDiag = diag;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:GMSettingsChangedNotification object:nil];
    });
}

static id GMSetting(NSString *key) {
    @synchronized (GMSettingsLock()) { return gSettings[key]; }
}

BOOL GMDiag(void) {
    @synchronized (GMSettingsLock()) { return gDiag; }
}

BOOL GMEnabled(void) {
    id value = GMSetting(@"enabled");
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
}

NSInteger GMButtonSize(void) {
    id value = GMSetting(@"buttonSize");
    NSInteger size = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 46;
    return MAX(36, MIN(64, size));
}

double GMButtonDim(void) {
    id value = GMSetting(@"buttonDim");
    double dim = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.85;
    return MAX(0.3, MIN(1.0, dim));
}

#pragma mark - log

void GMLog(NSString *format, ...) {
    if (!GMDiag()) return;
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static dispatch_queue_t queue;
    static NSDateFormatter *stamp;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.adarsh.guestmode.log", DISPATCH_QUEUE_SERIAL);
        stamp = [NSDateFormatter new];
        stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        stamp.dateFormat = @"MM-dd HH:mm:ss.SSS";
        path = [(GMTestFolder() ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"guestmode.log"];
    });
    NSDate *now = [NSDate date];
    dispatch_async(queue, ^{
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [stamp stringFromDate:now], text];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            [data writeToFile:path atomically:NO];
            return;
        }
        @try {
            if ([handle seekToEndOfFile] > 512 * 1024) [handle truncateFileAtOffset:0];
            [handle writeData:data];
        } @catch (NSException *e) {
        }
        [handle closeFile];
    });
}

#pragma mark - symbols

UIImage *GMSymbol(NSArray<NSString *> *names, CGFloat pointSize, UIImageSymbolWeight weight) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight];
    for (NSString *name in names) {
        UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
        if (image) return image;
    }
    return [UIImage systemImageNamed:@"circle" withConfiguration:config];
}

#pragma mark - state

@implementation GMState {
    GMPhase _phase;
    NSArray<NSString *> *_identifiers;
}

+ (instancetype)shared {
    static GMState *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [GMState new]; });
    return shared;
}

// Inside Photos' own data folder: nothing outside the app can switch Guest Mode off by editing it.
static NSString *GMStatePath(void) {
    NSString *test = GMTestFolder();
    if (test) return [test stringByAppendingPathComponent:@"state.plist"];
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [[library stringByAppendingPathComponent:@"GuestMode"] stringByAppendingPathComponent:@"state.plist"];
}

- (instancetype)init {
    if ((self = [super init])) {
        _identifiers = @[];
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:GMStatePath()];
        NSArray *ids = saved[@"identifiers"];
        if ([saved[@"guest"] respondsToSelector:@selector(boolValue)] && [saved[@"guest"] boolValue] && [ids isKindOfClass:NSArray.class]) {
            NSMutableArray<NSString *> *clean = [NSMutableArray new];
            for (id one in ids) {
                if ([one isKindOfClass:NSString.class] && clean.count < GM_MAX_ITEMS) [clean addObject:one];
            }
            _identifiers = [clean copy];
            _phase = GMPhaseGuest;                           // also with nothing left to show: only Face ID ends it
        }
    }
    return self;
}

- (GMPhase)phase { return _phase; }
- (NSArray<NSString *> *)identifiers { return _identifiers; }

- (BOOL)save {
    NSString *path = GMStatePath();
    if (_phase != GMPhaseGuest) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return ![NSFileManager.defaultManager fileExistsAtPath:path];
    }
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *state = @{@"guest": @YES, @"identifiers": _identifiers, @"since": [NSDate date]};
    return [state writeToFile:path atomically:YES];
}

- (void)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:GMStateChangedNotification object:self];
}

- (void)choose:(NSArray<NSString *> *)identifiers {
    if (_phase == GMPhaseGuest) return;
    NSMutableArray<NSString *> *clean = [NSMutableArray new];
    for (NSString *one in identifiers) {
        if (one.length && ![clean containsObject:one] && clean.count < GM_MAX_ITEMS) [clean addObject:one];
    }
    _identifiers = [clean copy];
    _phase = clean.count ? GMPhaseChosen : GMPhaseIdle;
    GMLog(@"state: %@", clean.count ? [NSString stringWithFormat:@"%d chosen", (int)clean.count] : @"nothing chosen");
    [self changed];
}

- (void)enterGuest {
    if (_phase != GMPhaseChosen) return;
    _phase = GMPhaseGuest;
    BOOL saved = [self save];
    GMLog(@"state: Guest Mode ON with %d item(s)%@", (int)_identifiers.count, saved ? @"" : @" (the state file could not be written: a restart of Photos would end it)");
    [self changed];
}

- (void)leaveGuest {
    if (_phase != GMPhaseGuest) return;
    _phase = GMPhaseIdle;
    _identifiers = @[];
    BOOL saved = [self save];
    GMLog(@"state: Guest Mode OFF%@", saved ? @"" : @" (the state file could not be removed)");
    [self changed];
}

- (NSArray<PHAsset *> *)assets {
    if (!_identifiers.count) return @[];
    PHFetchOptions *options = [PHFetchOptions new];
    options.includeHiddenAssets = YES;
    options.includeAllBurstAssets = YES;
    PHFetchResult<PHAsset *> *found = [PHAsset fetchAssetsWithLocalIdentifiers:_identifiers options:options];
    NSMutableDictionary<NSString *, PHAsset *> *byId = [NSMutableDictionary new];
    [found enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger index, BOOL *stop) {
        if (asset.localIdentifier) byId[asset.localIdentifier] = asset;
    }];
    NSMutableArray<PHAsset *> *ordered = [NSMutableArray new];
    for (NSString *one in _identifiers) {
        PHAsset *asset = byId[one];
        if (asset) [ordered addObject:asset];
    }
    return ordered;
}

@end

#pragma mark - start

static __weak UIWindowScene *gSceneHint;

UIWindowScene *GMActiveScene(void) {
    UIWindowScene *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *one = (UIWindowScene *)scene;
        if (one.screen != UIScreen.mainScreen) continue;
        if (one.activationState == UISceneActivationStateForegroundActive) return one;
        if (!best) best = one;
    }
    return best ?: gSceneHint;
}

static void GMBringUp(void) {
    // Guest Mode that was on when Photos was closed is on again before the first frame is drawn.
    if (GMState.shared.phase == GMPhaseGuest) [GMGallery.shared showAnimated:NO];
    [GMButtonController.shared attach];
}

__attribute__((constructor)) static void GMInit(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (!GMTestFolder() && ![bundle isEqualToString:@"com.apple.mobileslideshow"]) return;
        GMReloadSettings();
        int token = 0;
        notify_register_dispatch("com.adarsh.guestmode/prefs", &token, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int t) {
            GMReloadSettings();
            // Settings hands the change to a daemon that writes the file a moment later
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                GMReloadSettings();
            });
        });
        GMLog(@"Guest Mode %s in %@ (pid %d), root \"%@\", saved state: %@", GM_VERSION, bundle, getpid(), GMRoot(),
              GMState.shared.phase == GMPhaseGuest ? [NSString stringWithFormat:@"GUEST with %d item(s)", (int)GMState.shared.identifiers.count] : @"normal");
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[UISceneWillConnectNotification, UISceneDidActivateNotification,
                                          UIApplicationDidFinishLaunchingNotification, UIApplicationDidBecomeActiveNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([note.object isKindOfClass:UIWindowScene.class] && ((UIWindowScene *)note.object).screen == UIScreen.mainScreen) gSceneHint = note.object;
                GMBringUp();
            }];
        }
        GMDebugStart();
    }
}
