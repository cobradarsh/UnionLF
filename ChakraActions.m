/*  ChakraActions.m — the system actions an entry on the wheel can be.

    All of these go through SpringBoard's own classes, which is what makes them work from a tweak
    where an app could not do them. Names were checked on the phone this was written for
    (iPhone 14 Pro Max, iOS 16.5, build 20F66) and against iOS 17 headers. Where the two differ
    the 16.5 spelling is tried first and the other one after it:

      Home            -[SpringBoard _simulateHomeButtonPressWithCompletion:]   (older: _simulateHomeButtonPress)
      App Switcher    -[SBMainSwitcherControllerCoordinator toggleMainSwitcherNoninteractivelyWithSource:animated:]
                      (iOS 17 adds a windowScene: argument)
      Low Power Mode  -[_PMLowPowerMode setPowerMode:fromSource:]            (iOS 16.5 has no _CDBatterySaver)

    Nothing here is assumed: a class that is missing, or a method whose arguments are not the
    ones expected, makes that one action "not available" (it is left out of the Add list) rather
    than a crash.                                                                              */

#import "Chakra.h"
#import <dlfcn.h>

// Declared so ARC knows this is an init (it consumes the alloc and returns +1).
@interface NSObject (ChakraPrivateInits)
- (instancetype)initWithDelegate:(id)delegate;
@end

static const char *const kPlain = "v@#BcCqQiIlLsSfd";      // return types that can simply be ignored

// The method exists, returns something ignorable, and takes exactly these arguments
// (one letter each: q = an integer, B = a BOOL, @ = an object or a block).
static BOOL ChakraTakes(id target, NSString *selName, const char *args) {
    SEL sel = NSSelectorFromString(selName);
    NSUInteger n = strlen(args);
    if (!ChakraShape(target, sel, kPlain, n)) return NO;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        for (NSUInteger i = 0; i < n; i++) {
            const char *t = [sig getArgumentTypeAtIndex:i + 2];
            while (t && *t && strchr("rnNoORV", *t)) t++;
            if (!t || !*t) return NO;
            const char *ok = (args[i] == 'q') ? "qQiIlL" : (args[i] == 'B') ? "Bc" : "@#";
            if (!strchr(ok, *t)) return NO;
        }
        return YES;
    } @catch (__unused id e) {}
    return NO;
}

static id ChakraShared(NSString *className) { return ChakraSingleton(className); }

static UIColor *ChakraHex(int hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
}

#pragma mark - the pieces

static id ChakraLowPower(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{      // SpringBoard only loads this once its Control Centre module is first shown
        dlopen("/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode", RTLD_LAZY);
    });
    return ChakraShared(@"_PMLowPowerMode");
}

static id ChakraStyleMode(void) {
    static id mode;
    if (mode) return mode;
    Class cls = NSClassFromString(@"UISUserInterfaceStyleMode");
    if (!cls) return nil;
    @try {
        id nobody = nil;        // (a variable: some SDK class declares its own initWithDelegate: as taking nonnull)
        if ([cls instancesRespondToSelector:@selector(initWithDelegate:)]) mode = [[cls alloc] initWithDelegate:nobody];
        else mode = [[cls alloc] init];
    } @catch (__unused id e) { mode = nil; }
    return mode;
}

static id ChakraSwitcher(void) { return ChakraShared(@"SBMainSwitcherControllerCoordinator"); }

static NSString *ChakraSwitcherSelector(void) {
    id sw = ChakraSwitcher();
    if (ChakraTakes(sw, @"toggleMainSwitcherNoninteractivelyWithSource:animated:", "qB")) return @"toggleMainSwitcherNoninteractivelyWithSource:animated:";
    if (ChakraTakes(sw, @"toggleMainSwitcherNoninteractivelyWithSource:animated:windowScene:", "qB@")) return @"toggleMainSwitcherNoninteractivelyWithSource:animated:windowScene:";
    if (ChakraTakes(sw, @"activateMainSwitcherNoninteractivelyWithSource:animated:", "qB")) return @"activateMainSwitcherNoninteractivelyWithSource:animated:";
    return nil;
}

static BOOL ChakraCanRespring(void) {
    Class action = NSClassFromString(@"SBSRelaunchAction");
    id service = ChakraMsg(NSClassFromString(@"FBSSystemService"), @"sharedService");
    return action && ChakraShape(action, NSSelectorFromString(@"actionWithReason:options:targetURL:"), "@", 3)
        && ChakraTakes(action, @"actionWithReason:options:targetURL:", "@q@")
        && ChakraTakes(service, @"sendActions:withResult:", "@@");
}

#pragma mark - the list

@implementation ChakraAction

+ (instancetype)ident:(NSString *)ident title:(NSString *)title glyph:(NSString *)glyph off:(NSString *)off tint:(int)hex toggle:(BOOL)toggle {
    ChakraAction *a = [ChakraAction new];
    a->_ident = [ident copy];
    a->_title = [title copy];
    a->_glyph = [glyph copy];
    a->_glyphOff = [off copy];
    a->_tint = ChakraHex(hex);
    a->_toggle = toggle;
    return a;
}

@end

@implementation ChakraActions

+ (NSArray<ChakraAction *> *)all {
    static NSArray<ChakraAction *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            [ChakraAction ident:@"home"          title:@"Home"                glyph:@"house.fill"                  off:nil                      tint:0x0A84FF toggle:NO],
            [ChakraAction ident:@"switcher"      title:@"App Switcher"        glyph:@"square.stack.fill"           off:nil                      tint:0x5E5CE6 toggle:NO],
            [ChakraAction ident:@"lastapp"       title:@"Last App"            glyph:@"arrow.left.arrow.right"      off:nil                      tint:0x30B0C7 toggle:NO],
            [ChakraAction ident:@"lock"          title:@"Lock Screen"         glyph:@"lock.fill"                   off:nil                      tint:0x636366 toggle:NO],
            [ChakraAction ident:@"screenshot"    title:@"Screenshot"          glyph:@"camera.viewfinder"           off:nil                      tint:0xFF375F toggle:NO],
            [ChakraAction ident:@"controlcentre" title:@"Control Centre"      glyph:@"switch.2"                    off:nil                      tint:0x8E8E93 toggle:NO],
            [ChakraAction ident:@"notifications" title:@"Notification Centre" glyph:@"bell.fill"                   off:nil                      tint:0xFF453A toggle:NO],
            [ChakraAction ident:@"reachability"  title:@"Reachability"        glyph:@"arrow.down.to.line"          off:nil                      tint:0x32ADE6 toggle:NO],
            [ChakraAction ident:@"flashlight"    title:@"Torch"               glyph:@"flashlight.on.fill"          off:@"flashlight.off.fill"   tint:0xF2A900 toggle:YES],
            [ChakraAction ident:@"rotation"      title:@"Rotation Lock"       glyph:@"lock.rotation"               off:@"lock.rotation.open"    tint:0xFF453A toggle:YES],
            [ChakraAction ident:@"lowpower"      title:@"Low Power Mode"      glyph:@"battery.25"                  off:nil                      tint:0xF2A900 toggle:YES],
            [ChakraAction ident:@"darkmode"      title:@"Dark Mode"           glyph:@"circle.lefthalf.filled"      off:nil                      tint:0x5856D6 toggle:YES],
            [ChakraAction ident:@"wifi"          title:@"Wi-Fi"               glyph:@"wifi"                        off:@"wifi.slash"            tint:0x0A84FF toggle:YES],
            [ChakraAction ident:@"bluetooth"     title:@"Bluetooth"           glyph:@"ck.bluetooth"                off:nil                      tint:0x0A84FF toggle:YES],
            [ChakraAction ident:@"airplane"      title:@"Aeroplane Mode"      glyph:@"airplane"                    off:nil                      tint:0xFF9F0A toggle:YES],
            [ChakraAction ident:@"respring"      title:@"Respring"            glyph:@"arrow.triangle.2.circlepath" off:nil                      tint:0x636366 toggle:NO],
            [ChakraAction ident:@"edit"          title:@"Edit"                glyph:@"slider.horizontal.3"         off:nil                      tint:0x48484A toggle:NO],
        ];
    });
    return list;
}

+ (ChakraAction *)actionWithID:(NSString *)ident {
    if (ident.length == 0) return nil;
    for (ChakraAction *a in [self all]) if ([a.ident isEqualToString:ident]) return a;
    return nil;
}

// nil = available; otherwise what this iOS lacks
+ (NSString *)_missingFor:(NSString *)ident {
    UIApplication *app = UIApplication.sharedApplication;
#if TARGET_OS_SIMULATOR
    // no torch, radios or battery in a simulator: leave their controllers alone there
    if ([@[ @"flashlight", @"wifi", @"bluetooth", @"airplane", @"lowpower" ] containsObject:ident]) return @"hardware a simulator does not have";
#endif
    if ([ident isEqualToString:@"home"]) {
        return (ChakraTakes(app, @"_simulateHomeButtonPressWithCompletion:", "@") || ChakraTakes(app, @"_simulateHomeButtonPress", "")) ? nil : @"_simulateHomeButtonPress";
    }
    if ([ident isEqualToString:@"switcher"])      return ChakraSwitcherSelector() ? nil : @"SBMainSwitcherControllerCoordinator toggle";
    if ([ident isEqualToString:@"lastapp"])       return ChakraTakes(app, @"launchApplicationWithIdentifier:suspended:", "@B") ? nil : @"launchApplicationWithIdentifier:suspended:";
    if ([ident isEqualToString:@"lock"])          return ChakraTakes(app, @"_simulateLockButtonPress", "") ? nil : @"_simulateLockButtonPress";
    if ([ident isEqualToString:@"screenshot"])    return ChakraTakes(app, @"takeScreenshot", "") ? nil : @"takeScreenshot";
    if ([ident isEqualToString:@"controlcentre"]) return ChakraTakes(ChakraShared(@"SBControlCenterController"), @"presentAnimated:", "B") ? nil : @"SBControlCenterController presentAnimated:";
    if ([ident isEqualToString:@"notifications"]) return ChakraTakes(ChakraShared(@"SBCoverSheetPresentationManager"), @"setCoverSheetPresented:animated:withCompletion:", "BB@") ? nil : @"SBCoverSheetPresentationManager setCoverSheetPresented:";
    if ([ident isEqualToString:@"reachability"])  return ChakraTakes(ChakraShared(@"SBReachabilityManager"), @"toggleReachability", "") ? nil : @"SBReachabilityManager toggleReachability";
    if ([ident isEqualToString:@"flashlight"]) {
        id torch = ChakraShared(@"SBUIFlashlightController");
        return (ChakraTakes(torch, @"turnFlashlightOnForReason:", "@") && ChakraTakes(torch, @"turnFlashlightOffForReason:", "@")
                && ChakraShape(torch, NSSelectorFromString(@"level"), "qQiI", 0)) ? nil : @"SBUIFlashlightController";
    }
    if ([ident isEqualToString:@"rotation"]) {
        id lock = ChakraShared(@"SBOrientationLockManager");
        return (ChakraTakes(lock, @"lock", "") && ChakraTakes(lock, @"unlock", "") && ChakraShape(lock, NSSelectorFromString(@"isUserLocked"), "Bc", 0)) ? nil : @"SBOrientationLockManager";
    }
    if ([ident isEqualToString:@"lowpower"])      return ChakraTakes(ChakraLowPower(), @"setPowerMode:fromSource:", "q@") ? nil : @"_PMLowPowerMode setPowerMode:fromSource:";
    if ([ident isEqualToString:@"darkmode"]) {
        id mode = ChakraStyleMode();
        return (ChakraTakes(mode, @"setModeValue:", "q") && ChakraShape(mode, NSSelectorFromString(@"modeValue"), "qQiI", 0)) ? nil : @"UISUserInterfaceStyleMode";
    }
    if ([ident isEqualToString:@"wifi"]) {
        id wifi = ChakraShared(@"SBWiFiManager");
        return (ChakraTakes(wifi, @"setWiFiEnabled:", "B") && ChakraShape(wifi, NSSelectorFromString(@"wiFiEnabled"), "Bc", 0)) ? nil : @"SBWiFiManager";
    }
    if ([ident isEqualToString:@"bluetooth"]) {
        id bt = ChakraShared(@"BluetoothManager");
        return (ChakraTakes(bt, @"setPowered:", "B") && ChakraShape(bt, NSSelectorFromString(@"powered"), "Bc", 0)) ? nil : @"BluetoothManager";
    }
    if ([ident isEqualToString:@"airplane"]) {
        id air = ChakraShared(@"SBAirplaneModeController");
        return (ChakraTakes(air, @"setInAirplaneMode:", "B") && ChakraShape(air, NSSelectorFromString(@"isInAirplaneMode"), "Bc", 0)) ? nil : @"SBAirplaneModeController";
    }
    if ([ident isEqualToString:@"respring"])      return ChakraCanRespring() ? nil : @"SBSRelaunchAction";
    if ([ident isEqualToString:@"edit"])          return nil;                    // Chakra's own sheet
    return @"unknown action";
}

+ (BOOL)available:(NSString *)ident {
    static NSMutableDictionary<NSString *, NSNumber *> *known;      // a yes stays a yes; a no is asked again
    if (ident.length == 0) return NO;
    if (!known) known = [NSMutableDictionary dictionary];
    if (known[ident].boolValue) return YES;
    BOOL ok = NO;
    @try { ok = [self actionWithID:ident] != nil && [self _missingFor:ident] == nil; } @catch (__unused id e) {}
    if (ok) known[ident] = @YES;
    return ok;
}

+ (NSString *)report {
    NSMutableArray *yes = [NSMutableArray array], *no = [NSMutableArray array];
    for (ChakraAction *a in [self all]) {
        NSString *missing = @"threw";
        @try { missing = [self _missingFor:a.ident]; } @catch (__unused id e) {}
        if (!missing) [yes addObject:a.ident];
        else [no addObject:[NSString stringWithFormat:@"%@ (%@)", a.ident, missing]];
    }
    return [NSString stringWithFormat:@"actions available: %@%@", [yes componentsJoinedByString:@" "],
            no.count ? [@" · NOT available: " stringByAppendingString:[no componentsJoinedByString:@", "]] : @""];
}

+ (BOOL)isOn:(NSString *)ident {
    @try {
        if ([ident isEqualToString:@"flashlight"]) return ChakraIntMsg(ChakraShared(@"SBUIFlashlightController"), @"level", 0) > 0;
        if ([ident isEqualToString:@"rotation"])   return ChakraBoolMsg(ChakraShared(@"SBOrientationLockManager"), @"isUserLocked", NO);
        if ([ident isEqualToString:@"lowpower"])   return [NSProcessInfo processInfo].lowPowerModeEnabled;
        if ([ident isEqualToString:@"darkmode"])   return UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        if ([ident isEqualToString:@"wifi"])       return ChakraBoolMsg(ChakraShared(@"SBWiFiManager"), @"wiFiEnabled", NO);
        if ([ident isEqualToString:@"bluetooth"])  return ChakraBoolMsg(ChakraShared(@"BluetoothManager"), @"powered", NO);
        if ([ident isEqualToString:@"airplane"])   return ChakraBoolMsg(ChakraShared(@"SBAirplaneModeController"), @"isInAirplaneMode", NO);
    } @catch (__unused id e) {}
    return NO;
}

+ (void)perform:(NSString *)ident {
    if (![self available:ident]) {
        ChakraLog(@"action %@: not available (%@)", ident, [self _missingFor:ident]);
        [ChakraHost toast:[NSString stringWithFormat:@"“%@” isn't available on this iOS version.", [self actionWithID:ident].title ?: ident]];
        return;
    }
    @try {
        [self _perform:ident];
    } @catch (NSException *e) {
        ChakraLog(@"action %@ threw %@: %@", ident, e.name, e.reason);
    }
}

+ (void)_perform:(NSString *)ident {
    UIApplication *app = UIApplication.sharedApplication;
    BOOL on = [self isOn:ident];

    if ([ident isEqualToString:@"home"]) {
        if (ChakraTakes(app, @"_simulateHomeButtonPressWithCompletion:", "@"))
            ((void (*)(id, SEL, id))objc_msgSend)(app, NSSelectorFromString(@"_simulateHomeButtonPressWithCompletion:"), nil);
        else ChakraSend(app, @"_simulateHomeButtonPress");

    } else if ([ident isEqualToString:@"switcher"]) {
        id sw = ChakraSwitcher();
        NSString *name = ChakraSwitcherSelector();
        SEL sel = NSSelectorFromString(name);
        if ([name hasSuffix:@"windowScene:"]) ((void (*)(id, SEL, long long, BOOL, id))objc_msgSend)(sw, sel, 1, YES, [ChakraHost mainScene]);
        else if (name) ((void (*)(id, SEL, long long, BOOL))objc_msgSend)(sw, sel, 1, YES);

    } else if ([ident isEqualToString:@"lastapp"]) {
        NSString *bid = [ChakraHost previousApp];
        if (bid.length == 0) { [ChakraHost toast:@"No other app has been used yet."]; return; }
        BOOL ok = [ChakraHost launchApp:bid];
        ChakraLog(@"last app: %@ -> %d", bid, ok);
        return;

    } else if ([ident isEqualToString:@"lock"]) {
        ChakraSend(app, @"_simulateLockButtonPress");

    } else if ([ident isEqualToString:@"screenshot"]) {
        // the ball steps out of the picture first
        [ChakraBall shared].suppressed = YES;
        ChakraAfter(0.3, ^{
            ChakraSend(app, @"takeScreenshot");
            ChakraAfter(1.0, ^{ [ChakraBall shared].suppressed = NO; });
        });

    } else if ([ident isEqualToString:@"controlcentre"]) {
        ChakraSendBool(ChakraShared(@"SBControlCenterController"), @"presentAnimated:", YES);

    } else if ([ident isEqualToString:@"notifications"]) {
        id sheet = ChakraShared(@"SBCoverSheetPresentationManager");
        ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(sheet, NSSelectorFromString(@"setCoverSheetPresented:animated:withCompletion:"), YES, YES, nil);

    } else if ([ident isEqualToString:@"reachability"]) {
        id reach = ChakraShared(@"SBReachabilityManager");
        if (ChakraShape(reach, NSSelectorFromString(@"reachabilityEnabled"), "Bc", 0) && !ChakraBoolMsg(reach, @"reachabilityEnabled", YES)) {
            [ChakraHost toast:@"Reachability is off. Turn it on under Settings → Accessibility → Touch."];
            return;
        }
        ChakraSend(reach, @"toggleReachability");

    } else if ([ident isEqualToString:@"flashlight"]) {
        id torch = ChakraShared(@"SBUIFlashlightController");
        if (!on && ChakraShape(torch, NSSelectorFromString(@"isAvailable"), "Bc", 0) && !ChakraBoolMsg(torch, @"isAvailable", YES)) {
            [ChakraHost toast:@"The torch can't be used right now (the camera has it)."];
            return;
        }
        ChakraSendObj(torch, on ? @"turnFlashlightOffForReason:" : @"turnFlashlightOnForReason:", @"Chakra");

    } else if ([ident isEqualToString:@"rotation"]) {
        ChakraSend(ChakraShared(@"SBOrientationLockManager"), on ? @"unlock" : @"lock");

    } else if ([ident isEqualToString:@"lowpower"]) {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(ChakraLowPower(), NSSelectorFromString(@"setPowerMode:fromSource:"), on ? 0 : 1, @"SpringBoard");

    } else if ([ident isEqualToString:@"darkmode"]) {
        ChakraSendInt(ChakraStyleMode(), @"setModeValue:", on ? 1 : 2);        // 1 light, 2 dark (this also ends an automatic schedule)

    } else if ([ident isEqualToString:@"wifi"]) {
        ChakraSendBool(ChakraShared(@"SBWiFiManager"), @"setWiFiEnabled:", !on);

    } else if ([ident isEqualToString:@"bluetooth"]) {
        id bt = ChakraShared(@"BluetoothManager");
        ChakraSendBool(bt, @"setPowered:", !on);
        ChakraSendBool(bt, @"setEnabled:", !on);

    } else if ([ident isEqualToString:@"airplane"]) {
        ChakraSendBool(ChakraShared(@"SBAirplaneModeController"), @"setInAirplaneMode:", !on);

    } else if ([ident isEqualToString:@"edit"]) {
        [ChakraEditor present];
        return;

    } else if ([ident isEqualToString:@"respring"]) {
        Class cls = NSClassFromString(@"SBSRelaunchAction");
        id service = ChakraMsg(NSClassFromString(@"FBSSystemService"), @"sharedService");
        // options 4 = fade to black while SpringBoard restarts
        id action = ((id (*)(id, SEL, id, unsigned long long, id))objc_msgSend)(cls, NSSelectorFromString(@"actionWithReason:options:targetURL:"), @"Chakra", 4ULL, nil);
        if (action) ((void (*)(id, SEL, id, id))objc_msgSend)(service, NSSelectorFromString(@"sendActions:withResult:"), [NSSet setWithObject:action], nil);
    }
    ChakraLog(@"action %@%@", ident, [self actionWithID:ident].toggle ? (on ? @": off" : @": on") : @"");
}

@end
