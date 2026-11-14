/*  Tweak.m — BluetoothNoClicks for iOS 16 (RootHide). Loads into SpringBoard only.

    Keyboard clicks
      While audio is routed to a Bluetooth device (AirPods, a speaker, a car), the system's
      own Settings → Sounds & Haptics → Keyboard Feedback → Sound switch is turned off, and
      put back the way it was once the route leaves Bluetooth.

      MiRO's original (iOS 13-14) flipped the KEYBOARD_SOUND_SWITCH row of
      SHSSoundsPrefController. On a phone with keyboard haptics, iOS 16 replaces that row
      with the Keyboard Feedback page, so the lookup finds nothing and the tweak does
      nothing. This writes what that page's Sound switch writes instead: keyboard-audio in
      com.apple.preferences.sounds, then the Darwin notifications that make running apps
      read it again.

    Notification sounds on calls
      While a call is up, SBNCSoundController is stopped from playing notification sounds
      (optionally only while the call is on the earpiece). Alarms, timers, critical alerts
      and anything else that is allowed through Silent Mode still play.

    Only the three small hooks run on SpringBoard's own threads, and they just read cached
    flags. The audio route, the call list and the preferences all live on one private queue. */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CallKit/CallKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <notify.h>
#import <stdatomic.h>
#import <substrate.h>

#pragma mark - private classes (only messaged, never linked against)

@interface TLAlertConfiguration : NSObject
@property (nonatomic) BOOL shouldIgnoreRingerSwitch;
@end

@interface NCNotificationSound : NSObject
@property (nonatomic, copy, readonly) TLAlertConfiguration *alertConfiguration;
@end

@interface NCNotificationAlertOptions : NSObject
- (BOOL)shouldSuppress;
@end

@interface NCNotificationRequest : NSObject
@property (nonatomic, copy, readonly) NSString *sectionIdentifier;
@property (nonatomic, copy, readonly) NSString *notificationIdentifier;
@property (nonatomic, readonly) NCNotificationSound *sound;
@property (nonatomic, readonly) NCNotificationAlertOptions *alertOptions;
@property (nonatomic, readonly, getter=isCriticalAlert) BOOL criticalAlert;
@end

#pragma mark - state

static CFStringRef const kSoundsDomain  = CFSTR("com.apple.preferences.sounds");
static CFStringRef const kKeyboardAudio = CFSTR("keyboard-audio");
static CFStringRef const kOwnDomain     = CFSTR("com.adarsh.bluetoothnoclicks");
static CFStringRef const kTurnedOffKey  = CFSTR("clicksTurnedOffByTweak");
static const char *const kPrefsNote     = "com.adarsh.bluetoothnoclicks/prefs";
static NSString *const kLogPath         = @"/var/mobile/Library/Logs/BluetoothNoClicks.log";

typedef NS_ENUM(int, BNCRoute) {
    BNCRouteUnknown = 0,     // no output reported (audio server busy, route mid-change): leave things alone
    BNCRouteBluetooth,
    BNCRouteReceiver,        // the earpiece
    BNCRouteOther,           // speaker, wired headphones, AirPlay, CarPlay…
};

static dispatch_queue_t gQueue;              // everything except the hooks runs here
static _Atomic(int)  gRoute;                 // BNCRoute, as last read
static _Atomic(bool) gOnCall;

// Settings → BluetoothNoClicks. Written on gQueue, read by the hooks.
static _Atomic(bool) gKbClicks     = true;
static _Atomic(bool) gCallMute     = true;
static _Atomic(bool) gEarpieceOnly = false;
static _Atomic(bool) gVibrate      = true;
static _Atomic(bool) gDebugLog     = true;

#pragma mark - log

static void BNCLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void BNCLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[BluetoothNoClicks] %@", msg);
    if (!atomic_load(&gDebugLog)) return;

    static dispatch_queue_t q;
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.adarsh.bluetoothnoclicks.log", DISPATCH_QUEUE_SERIAL);
        df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    NSDate *now = [NSDate date];
    dispatch_async(q, ^{
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:now], msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kLogPath]) [fm createFileAtPath:kLogPath contents:nil attributes:nil];
        if ([[fm attributesOfItemAtPath:kLogPath error:nil] fileSize] > 128 * 1024) {   // keep it small: drop the older half
            NSData *all = [NSData dataWithContentsOfFile:kLogPath];
            [[all subdataWithRange:NSMakeRange(all.length / 2, all.length - all.length / 2)]
                writeToFile:kLogPath atomically:YES];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    });
}

#pragma mark - preferences

static BOOL BNCOwnBool(CFStringRef key, BOOL fallback) {
    Boolean valid = false;
    Boolean value = CFPreferencesGetAppBooleanValue(key, kOwnDomain, &valid);
    return valid ? (BOOL)value : fallback;
}

static void BNCSetOwnBool(CFStringRef key, BOOL value) {
    CFPreferencesSetAppValue(key, value ? kCFBooleanTrue : kCFBooleanFalse, kOwnDomain);
    CFPreferencesAppSynchronize(kOwnDomain);
}

static void BNCReloadSettings(void) {
    CFPreferencesAppSynchronize(kOwnDomain);
    atomic_store(&gKbClicks,     BNCOwnBool(CFSTR("kbClicks"), YES));
    atomic_store(&gCallMute,     BNCOwnBool(CFSTR("callMute"), YES));
    atomic_store(&gEarpieceOnly, BNCOwnBool(CFSTR("callEarpieceOnly"), NO));
    atomic_store(&gVibrate,      BNCOwnBool(CFSTR("callVibrate"), YES));
    atomic_store(&gDebugLog,     BNCOwnBool(CFSTR("debugLog"), YES));
}

#pragma mark - keyboard clicks

static BOOL BNCKeyboardSoundOn(void) {
    CFPreferencesAppSynchronize(kSoundsDomain);
    Boolean valid = false;
    Boolean on = CFPreferencesGetAppBooleanValue(kKeyboardAudio, kSoundsDomain, &valid);
    return valid ? (BOOL)on : YES;            // never set = on, same as Settings shows it
}

// What the Sound switch on the Keyboard Feedback page does (PSRootController writePreference:).
static void BNCSetKeyboardSound(BOOL on) {
    CFPreferencesSetValue(kKeyboardAudio, on ? kCFBooleanTrue : kCFBooleanFalse, kSoundsDomain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kSoundsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post("com.apple.preferences.sounds.changed");                  // the switch's PostNotification
    notify_post("com.apple.preferences.sounds.keyboard-audio.changed");   // newer iOS posts this one too
}

static void BNCApplyKeyboardClicks(BNCRoute route) {
    BOOL enabled = atomic_load(&gKbClicks);
    if (enabled && route == BNCRouteBluetooth) {
        if (BNCKeyboardSoundOn()) {
            BNCSetOwnBool(kTurnedOffKey, YES);    // remembered first, so a respring in between still restores
            BNCSetKeyboardSound(NO);
            BNCLog(@"keyboard clicks: off (Bluetooth)");
        }
    } else if (!enabled || route != BNCRouteUnknown) {
        // Only undo our own change: if you keep keyboard sounds off yourself, they stay off.
        if (BNCOwnBool(kTurnedOffKey, NO)) {
            BNCSetKeyboardSound(YES);
            BNCSetOwnBool(kTurnedOffKey, NO);
            BNCLog(@"keyboard clicks: back on");
        }
    }
}

#pragma mark - audio route

static BNCRoute BNCReadRoute(NSString **description) {
    NSArray<AVAudioSessionPortDescription *> *outputs = [[[AVAudioSession sharedInstance] currentRoute] outputs];
    if (outputs.count == 0) {
        if (description) *description = @"no output";
        return BNCRouteUnknown;
    }
    BNCRoute kind = BNCRouteOther;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in outputs) {
        NSString *type = port.portType;
        [names addObject:[NSString stringWithFormat:@"%@ \"%@\"", type, port.portName]];
        if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
            kind = BNCRouteBluetooth;
        } else if (kind != BNCRouteBluetooth && [type isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
            kind = BNCRouteReceiver;
        }
    }
    if (description) *description = [names componentsJoinedByString:@" + "];
    return kind;
}

static void BNCEvaluate(NSString *why) {
    @autoreleasepool {
        @try {
            NSString *description = nil;
            BNCRoute route = BNCReadRoute(&description);
            if (atomic_exchange(&gRoute, (int)route) != (int)route) BNCLog(@"route: %@ (%@)", description, why);
            BNCApplyKeyboardClicks(route);
        } @catch (NSException *e) {
            BNCLog(@"evaluate failed: %@", e);
        }
    }
}

// Route notifications arrive in bursts: look once, shortly after the last one.
static void BNCSchedule(NSString *why) {
    static _Atomic(unsigned) generation;
    unsigned mine = atomic_fetch_add(&generation, 1) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), gQueue, ^{
        if (mine == atomic_load(&generation)) BNCEvaluate(why);
    });
}

#pragma mark - calls

@interface BNCCallWatcher : NSObject <CXCallObserverDelegate>
@end

static CXCallObserver *gCallObserver;
static BNCCallWatcher *gCallWatcher;
static NSMutableSet<NSUUID *> *gActiveCalls;     // gQueue only
static unsigned gCallEpoch;                      // gQueue only: bumped by every CallKit update

// Answered, or dialling out. An incoming call that is still ringing doesn't count.
static BOOL BNCCallCounts(CXCall *call) {
    return !call.hasEnded && (call.hasConnected || call.isOutgoing);
}

static void BNCCallsChanged(NSString *why) {     // gQueue
    bool on = gActiveCalls.count > 0;
    if (atomic_exchange(&gOnCall, on) == on) return;
    BNCLog(@"call: %@ (%@)", on ? @"in progress" : @"none", why);
    BNCSchedule(@"call");
    // The route often settles a moment after the call connects (speaker → earpiece).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), gQueue, ^{
        BNCEvaluate(@"call settled");
    });
}

@implementation BNCCallWatcher
- (void)callObserver:(CXCallObserver *)callObserver callChanged:(CXCall *)call {
    gCallEpoch++;
    if (BNCCallCounts(call)) [gActiveCalls addObject:call.UUID];
    else [gActiveCalls removeObject:call.UUID];
    BNCCallsChanged(@"update");
}
@end

// Rebuild the list from CallKit: once at start, and again each time a sound is muted, so a
// lost "call ended" can cost one notification sound at most, never all of them.
static void BNCResyncCalls(NSString *why) {
    dispatch_async(gQueue, ^{
        unsigned epoch = gCallEpoch;
        CXCallObserver *observer = gCallObserver;
        if (!observer) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSArray<CXCall *> *calls = observer.calls;      // can wait for CallKit, so not on gQueue
            dispatch_async(gQueue, ^{
                if (epoch != gCallEpoch) return;            // CallKit reported something newer meanwhile
                [gActiveCalls removeAllObjects];
                for (CXCall *call in calls) {
                    if (BNCCallCounts(call)) [gActiveCalls addObject:call.UUID];
                }
                BNCCallsChanged(why);
            });
        });
    });
}

#pragma mark - notification sounds

static SEL sCanPlaySel;
static BOOL (*orig_canPlay)(id, SEL, NCNotificationRequest *);
static void (*orig_playIfPossible)(id, SEL, NCNotificationRequest *, id);
static void (*orig_play)(id, SEL, NCNotificationRequest *, id);

// Sounds that are meant to get through Silent Mode are never touched.
static BOOL BNCBreaksThroughSilent(NCNotificationRequest *request) {
    @try {
        if ([request respondsToSelector:@selector(isCriticalAlert)] && [request isCriticalAlert]) return YES;
        if ([request respondsToSelector:@selector(sectionIdentifier)] &&
            [[request sectionIdentifier] isEqualToString:@"com.apple.mobiletimer"]) return YES;   // alarms, timers
        if ([request respondsToSelector:@selector(sound)]) {
            NCNotificationSound *sound = [request sound];
            if ([sound respondsToSelector:@selector(alertConfiguration)]) {
                TLAlertConfiguration *config = [sound alertConfiguration];
                if ([config respondsToSelector:@selector(shouldIgnoreRingerSwitch)] &&
                    [config shouldIgnoreRingerSwitch]) return YES;
            }
        }
    } @catch (...) {
        return YES;          // anything unexpected: leave the sound alone
    }
    return NO;
}

static BOOL BNCShouldMute(NCNotificationRequest *request) {
    if (!request || !atomic_load(&gCallMute) || !atomic_load(&gOnCall)) return NO;
    if (atomic_load(&gEarpieceOnly) && atomic_load(&gRoute) != BNCRouteReceiver) return NO;
    return !BNCBreaksThroughSilent(request);
}

// A sound that SpringBoard was about to play has been stopped: buzz instead, once.
static void BNCDidMute(NCNotificationRequest *request) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSString *lastID;
    static CFAbsoluteTime lastAt;

    NSString *ident = [request respondsToSelector:@selector(notificationIdentifier)] ? [request notificationIdentifier] : nil;
    NSString *section = [request respondsToSelector:@selector(sectionIdentifier)] ? [request sectionIdentifier] : nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    os_unfair_lock_lock(&lock);
    BOOL sameAgain = ident && lastID && [ident isEqualToString:lastID] && now - lastAt < 10.0;   // re-alert, or two hooks
    BOOL burst = now - lastAt < 1.0;                                                            // several at once
    if (!sameAgain) {
        lastID = [ident copy];
        lastAt = now;
    }
    os_unfair_lock_unlock(&lock);
    if (sameAgain) return;

    BOOL buzz = atomic_load(&gVibrate) && !burst;
    if (buzz) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    BNCLog(@"muted notification sound from %@%@", section ?: @"?", buzz ? @", buzzed" : @"");
    BNCResyncCalls(@"recheck");
}

// The gate every notification sound passes. Saying no here is enough to keep it silent.
static BOOL hook_canPlay(id self, SEL _cmd, NCNotificationRequest *request) {
    BOOL can = orig_canPlay ? orig_canPlay(self, _cmd, request) : YES;
    return (can && BNCShouldMute(request)) ? NO : can;
}

// Where an arriving notification asks for its sound.
static void hook_playIfPossible(id self, SEL _cmd, NCNotificationRequest *request, id destination) {
    if (!BNCShouldMute(request)) {
        if (orig_playIfPossible) orig_playIfPossible(self, _cmd, request, destination);
        return;
    }
    // Was a sound due at all? Ask the real gate; ours would say no.
    BOOL due = orig_canPlay ? orig_canPlay(self, sCanPlaySel, request) : YES;
    if (due && [request respondsToSelector:@selector(alertOptions)]) {
        NCNotificationAlertOptions *options = [request alertOptions];
        if ([options respondsToSelector:@selector(shouldSuppress)] && [options shouldSuppress]) due = NO;   // a Focus has it
    }
    if (due) BNCDidMute(request);
}

// Anything that skips the gate and asks for the sound directly.
static void hook_play(id self, SEL _cmd, NCNotificationRequest *request, id destination) {
    if (!BNCShouldMute(request)) {
        if (orig_play) orig_play(self, _cmd, request, destination);
        return;
    }
    BNCDidMute(request);
}

// Hook only a method that exists and has the shape we expect; otherwise say so and move on.
static BOOL BNCHook(Class cls, const char *name, char returns, unsigned args, IMP replacement, IMP *original) {
    SEL sel = sel_registerName(name);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) {
        BNCLog(@"hook skipped: -[SBNCSoundController %s] not found", name);
        return NO;
    }
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type) - 1);
    BOOL typeOK = type[0] == returns || (returns == 'B' && type[0] == 'c');
    if (!typeOK || method_getNumberOfArguments(method) != args) {
        BNCLog(@"hook skipped: -[SBNCSoundController %s] looks different here (%s)", name,
               method_getTypeEncoding(method) ?: "?");
        return NO;
    }
    MSHookMessageEx(cls, sel, replacement, original);
    return YES;
}

static void BNCInstallHooks(void) {
    static _Atomic(bool) done;
    if (atomic_load(&done)) return;
    Class cls = NSClassFromString(@"SBNCSoundController");
    if (!cls) return;                                        // tried again from BNCStart
    if (atomic_exchange(&done, true)) return;

    sCanPlaySel = sel_registerName("canPlaySoundForNotificationRequest:");
    BOOL gate = BNCHook(cls, "canPlaySoundForNotificationRequest:", 'B', 3,
                        (IMP)hook_canPlay, (IMP *)&orig_canPlay);
    BOOL ask  = BNCHook(cls, "playSoundIfPossibleForNotificationRequest:presentingDestination:", 'v', 4,
                        (IMP)hook_playIfPossible, (IMP *)&orig_playIfPossible);
    BOOL play = BNCHook(cls, "playSoundForNotificationRequest:presentingDestination:", 'v', 4,
                        (IMP)hook_play, (IMP *)&orig_play);
    BNCLog(@"notification sound hooks: gate=%d ask=%d play=%d", gate, ask, play);
}

#pragma mark - start

static void BNCStart(void) {     // gQueue, a few seconds after SpringBoard came up
    BNCReloadSettings();
    BNCInstallHooks();

    // Audio route. The first is the public notification. The last is a private name for the
    // same event (exported by Celestial on 16.5): a second chance, free if it is never posted here.
    static NSMutableArray *observers;
    observers = [NSMutableArray array];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[AVAudioSessionRouteChangeNotification,
                             AVAudioSessionMediaServicesWereResetNotification,
                             @"AVSystemController_ActiveAudioRouteDidChangeNotification"]) {
        [observers addObject:[center addObserverForName:name object:nil queue:nil
                                              usingBlock:^(NSNotification *note) { BNCSchedule(name); }]];
    }

    int token = 0;
    notify_register_dispatch(kPrefsNote, &token, gQueue, ^(int t) {
        BNCReloadSettings();
        BNCLog(@"settings: clicks=%d callMute=%d earpieceOnly=%d vibrate=%d",
               (int)atomic_load(&gKbClicks), (int)atomic_load(&gCallMute),
               (int)atomic_load(&gEarpieceOnly), (int)atomic_load(&gVibrate));
        BNCEvaluate(@"settings");
    });
    // Safety net: look again on every lock and unlock, so a missed route change can't stick.
    notify_register_dispatch("com.apple.springboard.lockstate", &token, gQueue, ^(int t) {
        BNCSchedule(@"lock state");
    });

    gActiveCalls = [NSMutableSet set];
    gCallWatcher = [BNCCallWatcher new];
    gCallObserver = [CXCallObserver new];
    [gCallObserver setDelegate:gCallWatcher queue:gQueue];
    BNCResyncCalls(@"start");

    BNCLog(@"started: clicks=%d callMute=%d earpieceOnly=%d vibrate=%d",
           (int)atomic_load(&gKbClicks), (int)atomic_load(&gCallMute),
           (int)atomic_load(&gEarpieceOnly), (int)atomic_load(&gVibrate));
    BNCEvaluate(@"start");
}

__attribute__((constructor)) static void BNCInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        gQueue = dispatch_queue_create("com.adarsh.bluetoothnoclicks", DISPATCH_QUEUE_SERIAL);
        BNCInstallHooks();
        // The audio and call services are touched late and off the main thread, so a slow
        // start of either can never hold SpringBoard up.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), gQueue, ^{
            BNCStart();
        });
    }
}
