// Guest Mode, the part in SpringBoard: while Guest Mode is on in Photos, the iPhone stays in Photos.
//
//   leaving      the system gestures (Home, App Switcher, Control Centre, Notification Centre) are
//                switched off the way Guided Access does it; whatever still gets another app or the
//                Home Screen in front is sent back to Photos within a quarter of a second
//   notifications are held where they enter SpringBoard and shown when Guest Mode ends
//   calls        an incoming call is declined (it lands in Recents as missed)
//   also off     Siri, screenshots, the double click for Wallet
//
// Photos says when Guest Mode starts and ends (GMCore.m keeps `GuestModeState` in its own
// preferences and posts com.adarsh.guestmode/state); only Face ID in Photos ends it.
//
// Nobody must be locked out of their own phone by a fault here, so the lock-down lets go by
// itself, and locks the screen instead, when Photos will not stay in front (it keeps crashing)
// or is in front without its Guest Mode gallery (the Photos part is not running).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <notify.h>

#define GMSB_VERSION "1.1.0"
static NSString *const kPhotos = @"com.apple.mobileslideshow";
static CFStringRef const kPhotosDomain = CFSTR("com.apple.mobileslideshow");

#pragma mark - where things are, settings, log

static NSString *GMSBRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = @"";
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr((const void *)&GMSBRoot, &info) && info.dli_fname) {
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

static NSString *GMSBTestFolder(void) {
    static NSString *folder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("GUESTMODE_DIR");
        if (value && value[0]) folder = [NSString stringWithUTF8String:value];
    });
    return folder;
}

static NSString *GMSBShared(void) {                         // the folder the marker and the command file are in
    return GMSBTestFolder() ?: [GMSBRoot() stringByAppendingPathComponent:@"var/mobile/Library/GuestMode"];
}

static NSDictionary *gSettings;
static BOOL gDiag;

static void GMSBReloadSettings(void) {
    NSString *test = GMSBTestFolder();
    NSString *path = test ? [test stringByAppendingPathComponent:@"prefs.plist"]
                          : [GMSBRoot() stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.adarsh.guestmode.plist"];
    NSDictionary *read = [NSDictionary dictionaryWithContentsOfFile:path] ?: @{};
    BOOL diag = [NSFileManager.defaultManager fileExistsAtPath:[GMSBShared() stringByAppendingPathComponent:@"diag"]];
    @synchronized (kPhotos) {
        gSettings = read;
        gDiag = diag;
    }
}

static BOOL GMSBSetting(NSString *key, BOOL fallback) {
    id value;
    @synchronized (kPhotos) { value = gSettings[key]; }
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static void GMSBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void GMSBLog(NSString *format, ...) {
    BOOL diag;
    @synchronized (kPhotos) { diag = gDiag; }
    if (!diag) return;
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static dispatch_queue_t queue;
    static NSDateFormatter *stamp;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.adarsh.guestmode.sblog", DISPATCH_QUEUE_SERIAL);
        stamp = [NSDateFormatter new];
        stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        stamp.dateFormat = @"MM-dd HH:mm:ss.SSS";
        path = GMSBTestFolder() ? [GMSBTestFolder() stringByAppendingPathComponent:@"guestmode-sb.log"] : @"/var/mobile/Library/Logs/GuestMode.log";
    });
    NSDate *now = [NSDate date];
    dispatch_async(queue, ^{
        NSData *data = [[NSString stringWithFormat:@"%@  %@\n", [stamp stringFromDate:now], text] dataUsingEncoding:NSUTF8StringEncoding];
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

#pragma mark - small helpers for calls that are not public

static id GMSBShared1(NSString *className, NSString *getter) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(getter);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(cls, sel); } @catch (NSException *e) { return nil; }
}

static BOOL GMSBBool(id target, NSString *selName, BOOL fallback) {
    SEL sel = NSSelectorFromString(selName);
    if (!target || ![target respondsToSelector:sel]) return fallback;
    @try { return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel); } @catch (NSException *e) { return fallback; }
}

static id GMSBObj(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!target || ![target respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, sel); } @catch (NSException *e) { return nil; }
}

static BOOL GMSBSend(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!target || ![target respondsToSelector:sel]) return NO;
    @try { ((void (*)(id, SEL))objc_msgSend)(target, sel); } @catch (NSException *e) { return NO; }
    return YES;
}

// Replaces an instance method; NO (and nothing changed) when this iOS has no such method.
static NSMutableArray<NSString *> *gHooked, *gMissing;
static BOOL GMSBHook(NSString *className, NSString *selName, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selName);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", className, selName];
    if (!method) {
        [gMissing addObject:name];
        return NO;
    }
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        *original = method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
    }
    [gHooked addObject:name];
    return YES;
}

// Runs a completion block whose exact type is not known here, with every argument zero / nil
// ("it did not happen, no error"). Blocks carry their own signature; this reads it.
struct GMSBBlockDescriptor { unsigned long reserved; unsigned long size; void *rest[]; };
struct GMSBBlockLayout { void *isa; int flags; int reserved; void *invoke; struct GMSBBlockDescriptor *descriptor; };
static NSString *GMSBBlockSignature(id block) {
    if (!block) return nil;
    struct GMSBBlockLayout *layout = (__bridge struct GMSBBlockLayout *)block;
    if (!(layout->flags & (1 << 30))) return nil;           // no signature recorded
    void **rest = layout->descriptor->rest;
    if (layout->flags & (1 << 25)) rest += 2;               // copy and dispose helpers come first
    const char *types = (const char *)rest[0];
    return types ? [NSString stringWithUTF8String:types] : nil;
}

static void GMSBCallBlockWithNothing(id block) {
    NSString *types = GMSBBlockSignature(block);
    if (!types) return;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types.UTF8String];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation invokeWithTarget:block];
    } @catch (NSException *e) {
        GMSBLog(@"a completion block (%@) could not be run: %@", types, e.reason);
    }
}

#pragma mark - what SpringBoard is showing

static BOOL GMSBDeviceLocked(void) {
    id manager = GMSBShared1(@"SBLockScreenManager", @"sharedInstance");
    SEL sel = NSSelectorFromString(@"isUILocked");
    if ([manager respondsToSelector:sel]) return GMSBBool(manager, @"isUILocked", NO);
    return GMSBBool(UIApplication.sharedApplication, @"isLocked", NO);
}

static NSString *GMSBFront(void) {
    id front = GMSBObj(UIApplication.sharedApplication, @"_accessibilityFrontMostApplication");
    NSString *bundle = GMSBObj(front, @"bundleIdentifier");
    return ([bundle isKindOfClass:NSString.class] && bundle.length) ? bundle : nil;
}

static int GMSBPhotosPid(void) {
    id controller = GMSBShared1(@"SBApplicationController", @"sharedInstance");
    SEL find = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (![controller respondsToSelector:find]) return 0;
    @try {
        id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, find, kPhotos);
        id state = GMSBObj(app, @"processState");
        SEL pid = NSSelectorFromString(@"pid");
        if (![state respondsToSelector:pid]) return 0;
        return ((int (*)(id, SEL))objc_msgSend)(state, pid);
    } @catch (NSException *e) {
        return 0;
    }
}

// Is Photos still the app on screen, under something SpringBoard put over it (the Face ID or
// passcode sheet, Siri)? Then nothing has to be brought back.
static BOOL GMSBPhotosIsForeground(void) {
    id controller = GMSBShared1(@"SBApplicationController", @"sharedInstance");
    SEL find = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (![controller respondsToSelector:find]) return NO;
    @try {
        id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, find, kPhotos);
        id state = GMSBObj(app, @"processState");
        return GMSBBool(state, @"isRunning", NO) && GMSBBool(state, @"isForeground", NO);
    } @catch (NSException *e) {
        return NO;
    }
}

static BOOL GMSBBringPhotosFront(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (![app respondsToSelector:sel]) return NO;
    @try { return ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, kPhotos, NO); } @catch (NSException *e) { return NO; }
}

static void GMSBSetGesturesOff(BOOL off) {
    id manager = GMSBShared1(@"SBSystemGestureManager", @"mainDisplayManager");
    SEL set = NSSelectorFromString(@"setSystemGesturesDisabledForAccessibility:");
    if (![manager respondsToSelector:set]) return;
    @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, set, off); } @catch (NSException *e) { }
}

static BOOL GMSBGesturesOff(void) {
    return GMSBBool(GMSBShared1(@"SBSystemGestureManager", @"mainDisplayManager"), @"areSystemGesturesDisabledForAccessibility", NO);
}

// What Photos saved: is Guest Mode on, and which process has the gallery up.
static BOOL GMSBPhotosSaysGuest(int *galleryPid) {
    CFPreferencesAppSynchronize(kPhotosDomain);
    id state = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("GuestModeState"), kPhotosDomain));
    id alive = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("GuestModeAlive"), kPhotosDomain));
    if (galleryPid) *galleryPid = [alive respondsToSelector:@selector(intValue)] ? [alive intValue] : 0;
    if (![state isKindOfClass:NSDictionary.class]) return NO;
    id guest = ((NSDictionary *)state)[@"guest"];
    return [guest respondsToSelector:@selector(boolValue)] && [guest boolValue];
}

#pragma mark - the lock-down

static BOOL gLocked;
static BOOL gTestLock;                                      // engaged by the test command: no gallery to wait for
static dispatch_source_t gGuard;
static NSMutableArray<NSDate *> *gBounces;
static CFAbsoluteTime gLastBounce, gNoGallerySince, gLockedAt, gGuardPausedUntil;
static NSUInteger gTicks, gBounceCount, gSiriDismissed, gCallsDeclined, gScreenshotsBlocked, gHeldTotal;

static NSMutableArray<NSDictionary *> *gHeld;               // notifications waiting for Guest Mode to end
static void (*orig_post)(id, SEL, id);

static void GMSBRelease(NSString *why, BOOL lockScreen);

static NSString *GMSBRequestKey(id request) {
    NSString *section = GMSBObj(request, @"sectionIdentifier");
    NSString *ident = GMSBObj(request, @"notificationIdentifier");
    return [NSString stringWithFormat:@"%@|%@", [section isKindOfClass:NSString.class] ? section : @"?", [ident isKindOfClass:NSString.class] ? ident : @"?"];
}

static void GMSBGuardTick(void) {
    if (!gLocked) return;
    gTicks++;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (GMSBDeviceLocked()) {                               // the Lock Screen: nothing to guard until it is unlocked
        gNoGallerySince = 0;
        return;
    }
    if (!GMSBGesturesOff()) GMSBSetGesturesOff(YES);        // something switched them back on

    Class siri = NSClassFromString(@"SBAssistantController");
    if (siri && GMSBBool(siri, @"isVisible", NO)) {
        id controller = GMSBShared1(@"SBAssistantController", @"sharedInstanceIfExists") ?: GMSBShared1(@"SBAssistantController", @"sharedInstance");
        if (!GMSBSend(controller, @"dismissAssistantViewInEverySceneIfNecessary")) GMSBSend(controller, @"dismissAssistantViewIfNecessary");
        gSiriDismissed++;
        GMSBLog(@"guard: Siri was up, dismissed");
    }

    // every 2 s: is Guest Mode still on in Photos, and is its gallery really there
    if (gTicks % 8 == 0 && !gTestLock) {
        int galleryPid = 0;
        if (!GMSBPhotosSaysGuest(&galleryPid) || !GMSBSetting(@"lockdown", YES)) {
            GMSBRelease(@"Guest Mode is no longer on", NO);
            return;
        }
        int photosPid = GMSBPhotosPid();
        if (photosPid > 0 && galleryPid == photosPid) {
            gNoGallerySince = 0;
        } else if ([GMSBFront() isEqualToString:kPhotos]) {
            if (gNoGallerySince == 0) gNoGallerySince = now;
            if (now - gNoGallerySince > 10) {
                GMSBRelease([NSString stringWithFormat:@"Photos (pid %d) is in front without its Guest Mode gallery (gallery pid %d)", photosPid, galleryPid], YES);
                return;
            }
        }
    }

    NSString *front = GMSBFront();
    if ([front isEqualToString:kPhotos]) return;
    if (front && !GMSBSetting(@"declineCalls", YES) && [front isEqualToString:@"com.apple.InCallService"]) return;     // a call the owner lets through
    if (!front && GMSBPhotosIsForeground()) return;         // Photos, under a sheet of SpringBoard's (Face ID, passcode, Siri)
    if (now < gGuardPausedUntil) return;                    // tests: Photos is being restarted by hand
    if (now - gLastBounce < 0.8) return;                    // Photos is on its way
    gLastBounce = now;
    gBounceCount++;
    NSDate *stamp = [NSDate date];
    [gBounces addObject:stamp];
    while (gBounces.count && [stamp timeIntervalSinceDate:gBounces.firstObject] > 20) [gBounces removeObjectAtIndex:0];
    if (gBounces.count > 8) {
        GMSBRelease(@"Photos would not stay in front (8 tries in 20 s)", YES);
        return;
    }
    BOOL sent = GMSBBringPhotosFront();
    GMSBLog(@"guard: %@ was in front, Photos brought back (%@)", front ?: @"the Home Screen or App Switcher", sent ? @"asked" : @"the call is missing");
}

static void GMSBEngage(NSString *why) {
    if (gLocked) return;
    gLocked = YES;
    gLockedAt = CFAbsoluteTimeGetCurrent();
    gTicks = 0;
    gNoGallerySince = 0;
    gLastBounce = 0;
    [gBounces removeAllObjects];
    GMSBSetGesturesOff(YES);
    gGuard = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gGuard, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), (uint64_t)(0.25 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gGuard, ^{ GMSBGuardTick(); });
    dispatch_resume(gGuard);
    GMSBLog(@"lock-down ON (%@): system gestures off %d, notifications %@, calls %@", why, GMSBGesturesOff(),
            GMSBSetting(@"holdNotifications", YES) ? @"held" : @"let through", GMSBSetting(@"declineCalls", YES) ? @"declined" : @"let through");
}

static void GMSBRelease(NSString *why, BOOL lockScreen) {
    if (!gLocked) return;
    gLocked = NO;
    gTestLock = NO;
    if (gGuard) {
        dispatch_source_cancel(gGuard);
        gGuard = nil;
    }
    GMSBSetGesturesOff(NO);
    NSArray<NSDictionary *> *held;
    @synchronized (gHeld) {
        held = [gHeld copy];
        [gHeld removeAllObjects];
    }
    GMSBLog(@"lock-down OFF (%@) after %.0f s: system gestures off %d, %d notification(s) to show now%@", why, CFAbsoluteTimeGetCurrent() - gLockedAt,
            GMSBGesturesOff(), (int)held.count, lockScreen ? @", locking the screen" : @"");
    if (lockScreen) GMSBSend(UIApplication.sharedApplication, @"_simulateLockButtonPress");
    // what was held comes up now, oldest first, a moment apart
    [held enumerateObjectsUsingBlock:^(NSDictionary *one, NSUInteger index, BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.6 + 0.3 * index) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (orig_post) orig_post(one[@"dispatcher"], NSSelectorFromString(@"postNotificationWithRequest:"), one[@"request"]);
            } @catch (NSException *e) {
                GMSBLog(@"a held notification could not be shown: %@", e.reason);
            }
        });
    }];
}

static void GMSBEvaluate(NSString *why) {                   // main thread
    int galleryPid = 0;
    BOOL guest = GMSBPhotosSaysGuest(&galleryPid);
    BOOL want = guest && GMSBSetting(@"lockdown", YES);
    if (want && !gLocked) GMSBEngage(why);
    else if (!want && gLocked && !gTestLock) GMSBRelease(guest ? @"switched off in Settings" : @"Guest Mode ended in Photos", NO);
}

#pragma mark - notifications: held while locked down

static void hook_post(id self, SEL _cmd, id request) {
    if (gLocked && request && GMSBSetting(@"holdNotifications", YES)) {
        @try {
            NSString *key = GMSBRequestKey(request);
            @synchronized (gHeld) {
                NSUInteger old = [gHeld indexOfObjectPassingTest:^BOOL(NSDictionary *one, NSUInteger index, BOOL *stop) { return [one[@"key"] isEqualToString:key]; }];
                NSDictionary *entry = @{@"key": key, @"request": request, @"dispatcher": self};
                if (old != NSNotFound) gHeld[old] = entry; else [gHeld addObject:entry];
                while (gHeld.count > 300) [gHeld removeObjectAtIndex:0];
            }
            gHeldTotal++;
            GMSBLog(@"notification held (%@), %d waiting", GMSBObj(request, @"sectionIdentifier"), (int)gHeld.count);
            return;
        } @catch (NSException *e) {
            GMSBLog(@"holding a notification threw %@: shown instead", e.reason);
        }
    }
    orig_post(self, _cmd, request);
}

static void (*orig_modify)(id, SEL, id);
static void hook_modify(id self, SEL _cmd, id request) {
    if (gLocked && request) {
        @try {
            NSString *key = GMSBRequestKey(request);
            @synchronized (gHeld) {
                NSUInteger old = [gHeld indexOfObjectPassingTest:^BOOL(NSDictionary *one, NSUInteger index, BOOL *stop) { return [one[@"key"] isEqualToString:key]; }];
                if (old != NSNotFound) {                    // a newer version of one that is waiting
                    gHeld[old] = @{@"key": key, @"request": request, @"dispatcher": self};
                    return;
                }
            }
        } @catch (NSException *e) {
        }
    }
    orig_modify(self, _cmd, request);
}

static void (*orig_withdraw)(id, SEL, id);
static void hook_withdraw(id self, SEL _cmd, id request) {
    if (request) {
        @try {
            NSString *key = GMSBRequestKey(request);
            @synchronized (gHeld) {
                NSUInteger old = [gHeld indexOfObjectPassingTest:^BOOL(NSDictionary *one, NSUInteger index, BOOL *stop) { return [one[@"key"] isEqualToString:key]; }];
                if (old != NSNotFound) [gHeld removeObjectAtIndex:old];     // taken back before it was ever shown
            }
        } @catch (NSException *e) {
        }
    }
    orig_withdraw(self, _cmd, request);
}

#pragma mark - calls: declined while locked down

static BOOL GMSBCallIsRinging(void) {
    if (GMSBBool(GMSBShared1(@"SBTelephonyManager", @"sharedTelephonyManager"), @"incomingCallExists", NO)) return YES;
    return GMSBObj(GMSBShared1(@"TUCallCenter", @"sharedInstance"), @"incomingCall") != nil;
}

static void GMSBDeclineRingingCall(NSString *seenBy) {
    if (!gLocked || !GMSBSetting(@"declineCalls", YES)) return;
    BOOL did = NO;
    id telephony = GMSBShared1(@"SBTelephonyManager", @"sharedTelephonyManager");
    if (GMSBBool(telephony, @"incomingCallExists", NO)) did = GMSBSend(telephony, @"disconnectIncomingCall");
    id center = GMSBShared1(@"TUCallCenter", @"sharedInstance");
    id call = GMSBObj(center, @"incomingCall");
    SEL end = NSSelectorFromString(@"disconnectCall:");
    if (call && [center respondsToSelector:end]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(center, end, call);
            did = YES;
        } @catch (NSException *e) {
        }
    }
    if (did) {
        gCallsDeclined++;
        GMSBLog(@"an incoming call was declined (seen by %@)", seenBy);
    }
}

static void (*orig_inCall)(id, SEL, id, id, id, id);
static void hook_inCall(id self, SEL _cmd, id server, id client, id configuration, id completion) {
    if (gLocked && GMSBSetting(@"declineCalls", YES) && GMSBCallIsRinging()) {
        // the call screen is not put up at all; whoever asked is told it was not shown
        GMSBLog(@"call screen asked for by %@ while locked down: not shown (completion %@)", client, GMSBBlockSignature(completion) ?: @"none");
        GMSBDeclineRingingCall(@"the call screen request");
        GMSBCallBlockWithNothing(completion);
        return;
    }
    orig_inCall(self, _cmd, server, client, configuration, completion);
}

#pragma mark - Siri, screenshots, Wallet, the Home button

static void (*orig_siri)(id, SEL, id, id, id);
static void hook_siri(id self, SEL _cmd, id presentation, id options, id handler) {
    orig_siri(self, _cmd, presentation, options, handler);
    if (!gLocked) return;
    // let it come up the proper way, then end it the proper way at once
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLocked) return;
        if (!GMSBSend(self, @"dismissAssistantViewInEverySceneIfNecessary")) GMSBSend(self, @"dismissAssistantViewIfNecessary");
        gSiriDismissed++;
        GMSBLog(@"Siri was asked for while locked down: dismissed");
    });
}

static void (*orig_takeScreenshot)(id, SEL);
static void hook_takeScreenshot(id self, SEL _cmd) {
    if (gLocked) {
        gScreenshotsBlocked++;
        GMSBLog(@"a screenshot was asked for while locked down: not taken");
        return;
    }
    orig_takeScreenshot(self, _cmd);
}

static void (*orig_saveScreenshots)(id, SEL);
static void hook_saveScreenshots(id self, SEL _cmd) {
    if (gLocked) {
        gScreenshotsBlocked++;
        return;
    }
    orig_saveScreenshots(self, _cmd);
}

static void (*orig_saveScreenshotsDone)(id, SEL, id);
static void hook_saveScreenshotsDone(id self, SEL _cmd, id completion) {
    if (gLocked) {
        gScreenshotsBlocked++;
        GMSBLog(@"a screenshot was asked for while locked down: not taken");
        GMSBCallBlockWithNothing(completion);
        return;
    }
    orig_saveScreenshotsDone(self, _cmd, completion);
}

static BOOL (*orig_noDoublePress)(id, SEL, void *);
static BOOL hook_noDoublePress(id self, SEL _cmd, void *reason) {
    if (gLocked) return YES;                                // no double click for Wallet
    return orig_noDoublePress(self, _cmd, reason);
}

static BOOL (*orig_homePress)(id, SEL, id);
static BOOL hook_homePress(id self, SEL _cmd, id scene) {
    if (gLocked && !GMSBDeviceLocked()) return YES;         // "handled": a Home press from anywhere (AssistiveTouch, a tweak) goes nowhere
    return orig_homePress(self, _cmd, scene);
}

static BOOL (*orig_homePressFrom)(id, SEL, id, long long);
static BOOL hook_homePressFrom(id self, SEL _cmd, id scene, long long source) {
    if (gLocked && !GMSBDeviceLocked()) return YES;
    return orig_homePressFrom(self, _cmd, scene, source);
}

#pragma mark - test commands (only while the marker file exists)
//   <shared folder>/sbcmd.txt, first line a token, then:
//   state            locked down or not, gestures, front app, what Photos saved, counters, hooks
//   testlock <s>     lock down for s seconds (at most 60) without Guest Mode, then let go by itself
//   release          let go now (the gallery in Photos stays: only Face ID ends that)
//   guardpause <s>   for s seconds nothing is brought back to the front (tests restart Photos by hand)
//   mark <text>

static NSString *gLastToken;

static void GMSBLogState(void) {
    int galleryPid = 0;
    BOOL guest = GMSBPhotosSaysGuest(&galleryPid);
    GMSBLog(@"state: lock-down %@%@, system gestures off %d, device locked %d, front %@, Photos pid %d foreground %d, Photos says guest %d (gallery pid %d)",
            gLocked ? @"ON" : @"off", gTestLock ? @" (test)" : @"", GMSBGesturesOff(), GMSBDeviceLocked(), GMSBFront() ?: @"none (Home Screen)",
            GMSBPhotosPid(), GMSBPhotosIsForeground(), guest, galleryPid);
    GMSBLog(@"state: settings lockdown %d holdNotifications %d declineCalls %d; %d waiting, %d held in all, %d bounce(s), %d Siri, %d call(s), %d screenshot(s)",
            GMSBSetting(@"lockdown", YES), GMSBSetting(@"holdNotifications", YES), GMSBSetting(@"declineCalls", YES), (int)gHeld.count, (int)gHeldTotal,
            (int)gBounceCount, (int)gSiriDismissed, (int)gCallsDeclined, (int)gScreenshotsBlocked);
    GMSBLog(@"state: %d hook(s) in place%@", (int)gHooked.count, gMissing.count ? [NSString stringWithFormat:@"; NOT on this iOS: %@", [gMissing componentsJoinedByString:@", "]] : @"");
}

static void GMSBPollCommands(void) {
    NSString *path = [GMSBShared() stringByAppendingPathComponent:@"sbcmd.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString *token = lines.firstObject;
    if (!token.length || [token isEqualToString:gLastToken]) return;
    gLastToken = token;
    for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
        NSArray<NSString *> *words = [line componentsSeparatedByString:@" "];
        NSString *verb = words.firstObject;
        NSString *rest = words.count > 1 ? [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "] : @"";
        if ([verb isEqualToString:@"state"]) {
            GMSBLogState();
        } else if ([verb isEqualToString:@"testlock"]) {
            double seconds = MAX(3, MIN(60, rest.doubleValue));
            if (!gLocked) {
                gTestLock = YES;
                GMSBEngage([NSString stringWithFormat:@"test, %.0f s", seconds]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (gTestLock) GMSBRelease(@"the test time is over", NO);
                });
            }
        } else if ([verb isEqualToString:@"release"]) {
            GMSBRelease(@"test command", NO);
        } else if ([verb isEqualToString:@"guardpause"]) {
            gGuardPausedUntil = CFAbsoluteTimeGetCurrent() + MAX(1, MIN(30, rest.doubleValue));
            GMSBLog(@"guard: paused for %.0f s", MAX(1, MIN(30, rest.doubleValue)));
        } else if ([verb isEqualToString:@"mark"]) {
            GMSBLog(@"mark: %@", rest);
        } else if (verb.length) {
            GMSBLog(@"unknown command: %@", line);
        }
    }
}

#pragma mark - start

// Four starts within a minute and a half means SpringBoard keeps dying with this library in it:
// the fifth start does nothing at all.
static BOOL GMSBStartsTooOften(void) {
    if (getenv("GUESTMODE_NO_GUARD")) return NO;
    NSString *path = GMSBTestFolder() ? [GMSBTestFolder() stringByAppendingPathComponent:@"guestmode-sb.boot"] : @"/var/mobile/Library/Logs/GuestMode.boot";
    NSMutableArray<NSNumber *> *starts = [NSMutableArray new];
    double now = [NSDate date].timeIntervalSince1970;
    for (id one in [NSArray arrayWithContentsOfFile:path]) {
        if ([one respondsToSelector:@selector(doubleValue)] && now - [one doubleValue] < 90 && now >= [one doubleValue]) [starts addObject:one];
    }
    BOOL tooOften = starts.count >= 4;
    if (!tooOften) [starts addObject:@(now)];
    [starts writeToFile:path atomically:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];        // it has been running for two minutes: all is well
    });
    return tooOften;
}

static void GMSBStart(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    gHooked = [NSMutableArray new];
    gMissing = [NSMutableArray new];
    gHeld = [NSMutableArray new];
    gBounces = [NSMutableArray new];

    GMSBHook(@"NCNotificationDispatcher", @"postNotificationWithRequest:", (IMP)hook_post, (IMP *)&orig_post);
    GMSBHook(@"NCNotificationDispatcher", @"modifyNotificationWithRequest:", (IMP)hook_modify, (IMP *)&orig_modify);
    GMSBHook(@"NCNotificationDispatcher", @"withdrawNotificationWithRequest:", (IMP)hook_withdraw, (IMP *)&orig_withdraw);
    GMSBHook(@"SBInCallPresentationManager", @"inCallPresentationRequestServer:clientWithIdentifier:requestsPresentationWithConfiguration:completion:", (IMP)hook_inCall, (IMP *)&orig_inCall);
    GMSBHook(@"SBAssistantController", @"siriPresentation:requestsPresentationWithOptions:withHandler:", (IMP)hook_siri, (IMP *)&orig_siri);
    GMSBHook(@"SpringBoard", @"takeScreenshot", (IMP)hook_takeScreenshot, (IMP *)&orig_takeScreenshot);
    GMSBHook(@"SBScreenshotManager", @"saveScreenshots", (IMP)hook_saveScreenshots, (IMP *)&orig_saveScreenshots);
    GMSBHook(@"SBScreenshotManager", @"saveScreenshotsWithCompletion:", (IMP)hook_saveScreenshotsDone, (IMP *)&orig_saveScreenshotsDone);
    GMSBHook(@"SBLockHardwareButtonActions", @"disallowsDoublePressForReason:", (IMP)hook_noDoublePress, (IMP *)&orig_noDoublePress);
    GMSBHook(@"SBUIController", @"handleHomeButtonSinglePressUpForWindowScene:", (IMP)hook_homePress, (IMP *)&orig_homePress);
    GMSBHook(@"SBUIController", @"handleHomeButtonSinglePressUpForWindowScene:withSourceType:", (IMP)hook_homePressFrom, (IMP *)&orig_homePressFrom);

    [NSNotificationCenter.defaultCenter addObserverForName:@"TUCallCenterCallStatusChangedNotification" object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        if (gLocked && GMSBCallIsRinging()) GMSBDeclineRingingCall(@"the call's status change");
    }];

    int token = 0;
    notify_register_dispatch("com.adarsh.guestmode/state", &token, dispatch_get_main_queue(), ^(int t) {
        GMSBEvaluate(@"Photos said so");
        // the preferences daemon may hand the new value over a moment later
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GMSBEvaluate(@"Photos said so"); });
    });
    int prefsToken = 0;
    notify_register_dispatch("com.adarsh.guestmode/prefs", &prefsToken, dispatch_get_main_queue(), ^(int t) {
        GMSBReloadSettings();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GMSBReloadSettings();
            GMSBEvaluate(@"settings changed");
        });
    });

    GMSBLog(@"started: Guest Mode lock-down %s in SpringBoard (pid %d), %d hook(s) in place%@", GMSB_VERSION, getpid(), (int)gHooked.count,
            gMissing.count ? [NSString stringWithFormat:@"; NOT on this iOS: %@", [gMissing componentsJoinedByString:@", "]] : @"");
    GMSBEvaluate(@"Guest Mode was on when SpringBoard started");

    BOOL diag;
    @synchronized (kPhotos) { diag = gDiag; }
    if (diag) {
        NSString *old = [NSString stringWithContentsOfFile:[GMSBShared() stringByAppendingPathComponent:@"sbcmd.txt"] encoding:NSUTF8StringEncoding error:nil];
        gLastToken = [old componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject;
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) { GMSBPollCommands(); }];
    }
}

__attribute__((constructor)) static void GMSBInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        GMSBReloadSettings();
        if (GMSBStartsTooOften()) {
            GMSBLog(@"SpringBoard has started four times in a minute and a half: the lock-down part stays out of this start");
            return;
        }
        // SpringBoard is still coming up when this runs: wait until it says it is done, then a little more
        int token = 0;
        notify_register_dispatch("com.apple.springboard.finishedstartup", &token, dispatch_get_main_queue(), ^(int t) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GMSBStart(); });
        });
        // and in case that word was already given
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ GMSBStart(); });
    }
}
