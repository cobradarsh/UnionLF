/*  AtelierToggles.m — the dock under the tiles: six switches and the credit line.

    Switch            Read                                   Set
    Wi-Fi             -[SBWiFiManager wiFiEnabled]           -setWiFiEnabled:                      (as Chakra)
    Bluetooth         -[BluetoothManager powered]            -setPowered: and -setEnabled:         (as Chakra)
    Mobile Data       CTCellularDataPlanGetIsEnabled()       CTCellularDataPlanSetIsEnabled()      (CoreTelephony)
    Do Not Disturb    -[DNDStateService queryCurrentStateWithError:] isActive
                                                             on:  -[DNDModeAssertionService takeModeAssertionWithDetails:error:]
                                                                  with the default mode, under Control Centre's client name
                                                             off: -invalidateAllActiveModeAssertionsWithError:
    Keep Awake        a flag of Atelier's own                while it is on and the bench is up, the idle timer is
                                                             reset every 10 s (-[SBIdleTimerGlobalCoordinator resetIdleTimer])
    Low Power Mode    NSProcessInfo.lowPowerModeEnabled      -[_PMLowPowerMode setPowerMode:fromSource:]   (as Chakra)

    Every name is in the phone's iOS 16.5 cache and is looked up at run time; a switch whose calls
    are missing is not shown at all. Mobile Data and Do Not Disturb talk to other processes, so
    they are read and set on a queue of their own, never on SpringBoard's main thread.

    Keep Awake holds nothing: there is no assertion to forget. The bench's own half-second clock
    calls +benchTick, and that clock stops when the bench goes away, by whatever road (closed,
    another app, lock button, screen off). The switch itself goes back to off each time, so the
    screen is never kept on by a choice made days ago.

    States are read when the bench comes up, after a tap (at once, and again a moment later for
    the slower radios), and every three seconds while the bench is on screen; nothing is read or
    watched while it is not. Every action is logged with the state before and after.

    The credit line sits in the same strip: in one line where there is room for it, else as two
    short lines (the name over the rest), so that it never costs the apps any height.          */

#import "Atelier.h"
#import <dlfcn.h>

static NSString *const kCredit = @"created by Adarsh Somashekar";

static BOOL gDataOn, gDNDOn, gAwakeOn, gAwakeSaid;
static BOOL gFake[AtelierToggleCount], gFakeOn[AtelierToggleCount];       // tests: a look without the deed
static CFAbsoluteTime gLastIdleReset;

static dispatch_queue_t AtelierSlowQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.adarsh.atelier.toggles", DISPATCH_QUEUE_SERIAL); });
    return q;
}

#pragma mark - the pieces

static id AtelierLowPower(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{      // SpringBoard only loads this once its Control Centre module is first shown
        dlopen("/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode", RTLD_LAZY);
    });
    return AtelierSingleton(@"_PMLowPowerMode");
}

static BOOL AtelierTakes(id target, NSString *selName, const char *argTypes) {
    SEL s = NSSelectorFromString(selName);
    NSUInteger n = strlen(argTypes);
    if (!AtelierShape(target, s, "v@#BcCqQiIlLsSfd", n)) return NO;
    for (NSUInteger i = 0; i < n; i++) {
        char want[2] = { argTypes[i], 0 };
        const char *ok = want[0] == 'B' ? "Bc" : (want[0] == 'q' ? "qQiIlL" : want);
        if (!AtelierArgIs(target, s, i + 2, ok)) return NO;
    }
    return YES;
}

// Mobile data: two plain functions of CoreTelephony.
typedef BOOL (*AtelierDataGet)(void);
typedef void (*AtelierDataSet)(BOOL);
static AtelierDataGet AtelierDataGetter(void) { return (AtelierDataGet)dlsym(RTLD_DEFAULT, "CTCellularDataPlanGetIsEnabled"); }
static AtelierDataSet AtelierDataSetter(void) { return (AtelierDataSet)dlsym(RTLD_DEFAULT, "CTCellularDataPlanSetIsEnabled"); }

// Do Not Disturb: the services Control Centre's Focus button uses, under its client name, so
// that what this switch turns on Control Centre can turn off and the other way round.
static NSString *const kDNDClient = @"com.apple.donotdisturb.control-center.module";
static NSString *const kDNDMode = @"com.apple.donotdisturb.mode.default";

static id AtelierDNDService(NSString *className) {
    static NSMutableDictionary<NSString *, id> *made;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ made = [NSMutableDictionary dictionary]; });
    id service = nil;
    @synchronized (made) {                               // asked for from the main thread and from the slow queue
        service = made[className];
        if (!service) {
            service = AtelierMsgObj(NSClassFromString(className), @"serviceForClientIdentifier:", kDNDClient);
            if (service) made[className] = service;
        }
    }
    return service;
}

static BOOL AtelierDNDAvailable(void) {
    Class details = NSClassFromString(@"DNDModeAssertionDetails");
    id assertions = AtelierDNDService(@"DNDModeAssertionService"), states = AtelierDNDService(@"DNDStateService");
    return details && [details respondsToSelector:NSSelectorFromString(@"userRequestedAssertionDetailsWithIdentifier:modeIdentifier:lifetime:")]
        && [assertions respondsToSelector:NSSelectorFromString(@"takeModeAssertionWithDetails:error:")]
        && [assertions respondsToSelector:NSSelectorFromString(@"invalidateAllActiveModeAssertionsWithError:")]
        && [states respondsToSelector:NSSelectorFromString(@"queryCurrentStateWithError:")];
}

static BOOL AtelierDNDRead(void) {                       // on the slow queue
    @try {
        id states = AtelierDNDService(@"DNDStateService");
        SEL query = NSSelectorFromString(@"queryCurrentStateWithError:");
        if (![states respondsToSelector:query]) return NO;
        NSError *error = nil;
        id state = ((id (*)(id, SEL, NSError **))objc_msgSend)(states, query, &error);
        return AtelierBoolMsg(state, @"isActive", NO);
    } @catch (__unused id e) {}
    return NO;
}

static NSString *AtelierDNDWrite(BOOL on) {              // on the slow queue; nil when it went through
    @try {
        id assertions = AtelierDNDService(@"DNDModeAssertionService");
        NSError *error = nil;
        if (on) {
            Class cls = NSClassFromString(@"DNDModeAssertionDetails");
            SEL make = NSSelectorFromString(@"userRequestedAssertionDetailsWithIdentifier:modeIdentifier:lifetime:");
            SEL take = NSSelectorFromString(@"takeModeAssertionWithDetails:error:");
            if (![cls respondsToSelector:make] || ![assertions respondsToSelector:take]) return @"no such call";
            id details = ((id (*)(id, SEL, id, id, id))objc_msgSend)(cls, make, @"com.apple.control-center.manual-toggle", kDNDMode, nil);
            if (!details) return @"no details";
            id assertion = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(assertions, take, details, &error);
            return assertion ? nil : (error.localizedDescription ?: @"no assertion came back");
        }
        SEL drop = NSSelectorFromString(@"invalidateAllActiveModeAssertionsWithError:");
        if (![assertions respondsToSelector:drop]) return @"no such call";
        ((void (*)(id, SEL, NSError **))objc_msgSend)(assertions, drop, &error);
        return error ? (error.localizedDescription ?: @"an error") : nil;
    } @catch (NSException *e) {
        return e.reason ?: @"threw";
    }
}

// What resets SpringBoard's idle timer, as a touch would.
static BOOL AtelierIdleReset(BOOL really) {
    NSArray<NSArray<NSString *> *> *ways = @[ @[ @"SBIdleTimerGlobalCoordinator", @"resetIdleTimer" ],
                                             @[ @"SBBacklightController", @"resetIdleTimer" ],
                                             @[ @"SBBacklightController", @"resetIdleTimerAndUndim" ] ];
    for (NSArray<NSString *> *way in ways) {
        id target = AtelierSingleton(way[0]);
        if (!AtelierShape(target, NSSelectorFromString(way[1]), "v@Bc", 0)) continue;
        if (really) AtelierSend(target, way[1]);
        return YES;
    }
    return NO;
}

#pragma mark - the switches

@implementation AtelierToggles

+ (NSString *)name:(AtelierToggleKind)kind {
    static NSArray<NSString *> *names;
    if (!names) names = @[ @"Wi-Fi", @"Bluetooth", @"Mobile Data", @"Do Not Disturb", @"Keep Awake", @"Low Power Mode" ];
    return (kind >= 0 && kind < AtelierToggleCount) ? names[(NSUInteger)kind] : @"?";
}

+ (NSString *)key:(AtelierToggleKind)kind {
    static NSArray<NSString *> *keys;
    if (!keys) keys = @[ @"wifi", @"bluetooth", @"data", @"dnd", @"awake", @"lowpower" ];
    return (kind >= 0 && kind < AtelierToggleCount) ? keys[(NSUInteger)kind] : @"?";
}

+ (AtelierToggleKind)kindForKey:(NSString *)key {
    for (NSInteger k = 0; k < AtelierToggleCount; k++) if ([[self key:(AtelierToggleKind)k] isEqualToString:key.lowercaseString]) return (AtelierToggleKind)k;
    return AtelierToggleCount;
}

+ (BOOL)available:(AtelierToggleKind)kind {
    @try {
        switch (kind) {
            case AtelierToggleWifi: {
                id wifi = AtelierSingleton(@"SBWiFiManager");
                return AtelierTakes(wifi, @"setWiFiEnabled:", "B") && AtelierShape(wifi, NSSelectorFromString(@"wiFiEnabled"), "Bc", 0);
            }
            case AtelierToggleBluetooth: {
                id bt = AtelierSingleton(@"BluetoothManager");
                return AtelierTakes(bt, @"setPowered:", "B") && AtelierShape(bt, NSSelectorFromString(@"powered"), "Bc", 0);
            }
            case AtelierToggleData:     return AtelierDataGetter() != NULL && AtelierDataSetter() != NULL;
            case AtelierToggleDND:      return AtelierDNDAvailable();
            case AtelierToggleAwake:    return AtelierIdleReset(NO);
            case AtelierToggleLowPower: return AtelierTakes(AtelierLowPower(), @"setPowerMode:fromSource:", "q@");
            default: break;
        }
    } @catch (__unused id e) {}
    return NO;
}

+ (BOOL)isOn:(AtelierToggleKind)kind {
    if (kind >= 0 && kind < AtelierToggleCount && gFake[kind]) return gFakeOn[kind];
    switch (kind) {
        case AtelierToggleWifi:      return AtelierBoolMsg(AtelierSingleton(@"SBWiFiManager"), @"wiFiEnabled", NO);
        case AtelierToggleBluetooth: return AtelierBoolMsg(AtelierSingleton(@"BluetoothManager"), @"powered", NO);
        case AtelierToggleData:      return gDataOn;
        case AtelierToggleDND:       return gDNDOn;
        case AtelierToggleAwake:     return gAwakeOn;
        case AtelierToggleLowPower:  return [NSProcessInfo processInfo].lowPowerModeEnabled;
        default: break;
    }
    return NO;
}

// The two states that live in other processes are read off the main thread; `then` runs on it.
+ (void)refresh:(void (^)(void))then {
    static BOOL reading;                                 // main thread
    if (reading) { if (then) then(); return; }           // the last read is still out: what is known will do
    BOOL data = [self available:AtelierToggleData], dnd = [self available:AtelierToggleDND];
    if (!data && !dnd) { if (then) then(); return; }
    reading = YES;
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    dispatch_async(AtelierSlowQueue(), ^{
        BOOL dataOn = NO, dndOn = NO;
        @try {
            AtelierDataGet get = AtelierDataGetter();
            if (data && get) dataOn = get();
        } @catch (__unused id e) {}
        if (dnd) dndOn = AtelierDNDRead();
        dispatch_async(dispatch_get_main_queue(), ^{
            reading = NO;
            gDataOn = dataOn;
            gDNDOn = dndOn;
            double took = CFAbsoluteTimeGetCurrent() - began;
            if (took > 1.0) AtelierLog(@"toggles: reading Mobile Data and Do Not Disturb took %.1f s", took);
            if (then) then();
        });
    });
}

+ (void)setOn:(BOOL)on kind:(AtelierToggleKind)kind then:(void (^)(void))then {
    if (kind < 0 || kind >= AtelierToggleCount) return;
    NSString *name = [self name:kind];
    BOOL before = [self isOn:kind];
    if (gFake[kind]) { gFakeOn[kind] = on; AtelierLog(@"toggle %@: test look only, %@", name, on ? @"on" : @"off"); if (then) then(); return; }
    if (![self available:kind]) { AtelierLog(@"toggle %@: this iOS has no way to set it", name); if (then) then(); return; }
    __block NSString *problem = nil;
    void (^after)(void) = ^{
        // the radios take a moment: read again shortly, and say what came of it
        AtelierAfter(0.7, ^{
            [AtelierToggles refresh:^{
                BOOL now = [AtelierToggles isOn:kind];
                AtelierLog(@"toggle %@: was %@, asked for %@, now %@%@", name, before ? @"on" : @"off", on ? @"on" : @"off", now ? @"on" : @"off",
                           problem ? [NSString stringWithFormat:@" (%@)", problem] : (now == on ? @"" : @" (not yet, or refused)"));
                if (then) then();
            }];
        });
    };
    @try {
        switch (kind) {
            case AtelierToggleWifi:
                AtelierSendBool(AtelierSingleton(@"SBWiFiManager"), @"setWiFiEnabled:", on);
                break;
            case AtelierToggleBluetooth: {
                id bt = AtelierSingleton(@"BluetoothManager");
                AtelierSendBool(bt, @"setPowered:", on);
                AtelierSendBool(bt, @"setEnabled:", on);
                break;
            }
            case AtelierToggleLowPower:
                ((void (*)(id, SEL, long long, id))objc_msgSend)(AtelierLowPower(), NSSelectorFromString(@"setPowerMode:fromSource:"), on ? 1 : 0, @"SpringBoard");
                break;
            case AtelierToggleAwake:
                gAwakeOn = on && [AtelierBench shared].visible;      // only ever while the bench is up
                gAwakeSaid = NO;
                gLastIdleReset = 0;
                if (gAwakeOn) [self benchTick];
                break;
            case AtelierToggleData:
            case AtelierToggleDND:
                dispatch_async(AtelierSlowQueue(), ^{
                    @try {
                        if (kind == AtelierToggleData) { AtelierDataSet set = AtelierDataSetter(); if (set) set(on); else problem = @"no such call"; }
                        else problem = AtelierDNDWrite(on);
                    } @catch (NSException *e) { problem = e.reason; }
                    dispatch_async(dispatch_get_main_queue(), after);
                });
                return;
            default: break;
        }
    } @catch (NSException *e) {
        problem = e.reason;
    }
    after();
}

+ (void)benchTick {
    if (!gAwakeOn) return;
    if (![AtelierBench shared].visible) { [self benchWentAway]; return; }       // belt and braces: never without the bench
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastIdleReset < 10) return;
    gLastIdleReset = now;
    BOOL done = AtelierIdleReset(YES);
    if (!gAwakeSaid) {                                   // once for each time it is switched on
        gAwakeSaid = YES;
        AtelierLog(@"toggle Keep Awake: idle timer reset%@; again every 10 s while the bench is up", done ? @"" : @" FAILED (no such call)");
    }
}

+ (void)benchWentAway {
    if (gAwakeOn) AtelierLog(@"toggle Keep Awake: off, the bench went away");
    gAwakeOn = NO;
    gAwakeSaid = NO;
    gLastIdleReset = 0;
}

+ (void)debugFake:(AtelierToggleKind)kind look:(NSInteger)look {
    if (kind < 0 || kind >= AtelierToggleCount) { memset(gFake, 0, sizeof(gFake)); return; }       // any other kind: forget every test look
    gFake[kind] = look >= 0;
    gFakeOn[kind] = look > 0;
}

@end

#pragma mark - one round button

@interface AtelierToggleButton : UIControl
@property (nonatomic) AtelierToggleKind kind;
@property (nonatomic) BOOL on;
@property (nonatomic, strong) UIImageView *glyph;
@end

@implementation AtelierToggleButton

+ (UIImage *)bluetoothGlyph:(CGFloat)size {              // there is no SF Symbol for it on iOS 16: Chakra's drawing
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGPoint (^pt)(CGFloat, CGFloat) = ^CGPoint(CGFloat u, CGFloat v) { return CGPointMake(u * size, v * size); };
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:pt(0.28, 0.30)];
        [p addLineToPoint:pt(0.71, 0.70)];
        [p addLineToPoint:pt(0.50, 0.92)];
        [p addLineToPoint:pt(0.50, 0.08)];
        [p addLineToPoint:pt(0.71, 0.30)];
        [p addLineToPoint:pt(0.28, 0.70)];
        p.lineWidth = MAX(1.25, size * 0.088);
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [UIColor.blackColor set];
        [p stroke];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIColor *)tint:(AtelierToggleKind)kind {
    UIColor *(^rgb)(int) = ^UIColor *(int hex) {
        return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
    };
    switch (kind) {
        case AtelierToggleWifi: case AtelierToggleBluetooth: return rgb(0x0A84FF);
        case AtelierToggleData:     return rgb(0x30D158);
        case AtelierToggleDND:      return rgb(0x5E5CE6);
        case AtelierToggleAwake:    return rgb(0xFF9F0A);
        case AtelierToggleLowPower: return rgb(0xF2A900);
        default: break;
    }
    return rgb(0x8E8E93);
}

- (instancetype)initWithKind:(AtelierToggleKind)kind {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 30, 30)])) return nil;
    _kind = kind;
    static NSArray<NSString *> *symbols;
    if (!symbols) symbols = @[ @"wifi", @"", @"antenna.radiowaves.left.and.right", @"moon.fill", @"cup.and.saucer.fill", @"battery.25" ];
    UIImage *image = kind == AtelierToggleBluetooth ? [AtelierToggleButton bluetoothGlyph:17]
        : [[UIImage systemImageNamed:symbols[(NSUInteger)kind]
                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12.5 weight:UIImageSymbolWeightSemibold]]
           imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _glyph = [[UIImageView alloc] initWithImage:image];
    _glyph.contentMode = UIViewContentModeCenter;
    _glyph.userInteractionEnabled = NO;
    [self addSubview:_glyph];
    self.accessibilityLabel = [AtelierToggles name:kind];
    self.on = NO;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _glyph.frame = self.bounds;
    self.layer.cornerRadius = self.bounds.size.height / 2.0;
}

- (void)setOn:(BOOL)on {
    _on = on;
    self.backgroundColor = on ? [AtelierToggleButton tint:_kind] : [UIColor colorWithWhite:1 alpha:0.11];
    _glyph.tintColor = on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.6];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1.0;
}

// a little more to aim at than the 30 points that show
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -4, -4), point);
}

@end

#pragma mark - the dock

@implementation AtelierDock {
    NSMutableArray<AtelierToggleButton *> *_buttons;
    UILabel *_credit;
    BOOL _compact;
}

static NSArray<NSNumber *> *AtelierShownToggles(void) {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    AtelierSettings *s = [AtelierSettings shared];
    for (NSInteger k = 0; k < AtelierToggleCount; k++) {
        if (![s showsToggle:[AtelierToggles key:(AtelierToggleKind)k]]) continue;
        if (![AtelierToggles available:(AtelierToggleKind)k]) continue;
        [out addObject:@(k)];
    }
    return out;
}

// "HyperTrade created by Adarsh Somashekar": in one line, or the name over the rest.
static NSAttributedString *AtelierCreditText(BOOL stacked, NSTextAlignment alignment) {
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.alignment = alignment;
    para.lineSpacing = 0;
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:ATELIER_NAME attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:stacked ? 10.5 : 9.5 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.62], NSKernAttributeName: @(stacked ? 0.5 : 0.2),
        NSParagraphStyleAttributeName: para }];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[(stacked ? @"\n" : @" ") stringByAppendingString:kCredit] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:stacked ? 9 : 9.5 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.42], NSKernAttributeName: @0.1,
        NSParagraphStyleAttributeName: para }]];
    return text;
}

static CGFloat AtelierCreditWidth(BOOL stacked) {
    return ceil([AtelierCreditText(stacked, NSTextAlignmentCenter) boundingRectWithSize:CGSizeMake(1000, 100)
                                                  options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.width);
}

// How tall the dock is for what it shows: a row of 30-point switches (28 in Top and Split), or
// just the credit line when every switch is off in Settings. The credit never adds to it.
+ (CGFloat)heightForWidth:(CGFloat)width compact:(BOOL)compact {
    NSUInteger n = AtelierShownToggles().count;
    if (n == 0) return 12;
    return compact ? 28 : 30;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _buttons = [NSMutableArray array];
    _credit = [UILabel new];
    _credit.numberOfLines = 2;
    _credit.userInteractionEnabled = NO;
    [self addSubview:_credit];
    return self;
}

// Only the buttons take touches; a finger beside them goes through to the backdrop.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.05) return nil;
    for (AtelierToggleButton *b in _buttons) {
        if ([b pointInside:[self convertPoint:point toView:b] withEvent:event]) return b;
    }
    return nil;
}

- (void)setCompact:(BOOL)compact {
    _compact = compact;
    [self setNeedsLayout];
}

- (void)reload {
    for (AtelierToggleButton *b in _buttons) [b removeFromSuperview];
    [_buttons removeAllObjects];
    for (NSNumber *k in AtelierShownToggles()) {
        AtelierToggleButton *b = [[AtelierToggleButton alloc] initWithKind:(AtelierToggleKind)k.integerValue];
        [b addTarget:self action:@selector(_tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
        [_buttons addObject:b];
    }
    [self _paint];
    [self setNeedsLayout];
}

- (void)_paint {
    for (AtelierToggleButton *b in _buttons) b.on = [AtelierToggles isOn:b.kind];
}

- (void)refresh {
    [self _paint];                                       // what is known at once
    __weak typeof(self) weak = self;
    [AtelierToggles refresh:^{ [weak _paint]; }];        // and the two that have to be asked for
}

- (void)_tapped:(AtelierToggleButton *)button {
    BOOL want = !button.on;
    AtelierHapticPlay(AtelierHapticTick);
    button.on = want;                                    // at once; put right below if it did not take
    __weak typeof(self) weak = self;
    [AtelierToggles setOn:want kind:button.kind then:^{
        [weak _paint];
        AtelierAfter(1.6, ^{ [weak refresh]; });         // Bluetooth and Wi-Fi settle a little later still
    }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    NSUInteger n = _buttons.count;
    if (n == 0) {
        _credit.attributedText = AtelierCreditText(NO, NSTextAlignmentCenter);
        _credit.hidden = NO;
        _credit.frame = CGRectMake(0, MAX(0, H - 12), W, 12);
        return;
    }
    if (_compact) {
        // Top and Split: the switches in one group on the left, the credit against the right edge
        CGFloat side = 28, gap = 7, x = 0;
        for (AtelierToggleButton *b in _buttons) { b.frame = CGRectMake(x, (H - side) / 2.0, side, side); x += side + gap; }
        CGFloat room = W - x - 4;
        BOOL stacked = room < AtelierCreditWidth(NO);
        _credit.attributedText = AtelierCreditText(stacked, NSTextAlignmentRight);
        _credit.hidden = room < AtelierCreditWidth(stacked);
        _credit.frame = CGRectMake(W - room, 0, room, H);
        return;
    }
    // Side: the first two on the left, the others against the right edge, the credit between them
    CGFloat side = 30, gap = 8;
    NSUInteger left = MIN((NSUInteger)2, n);
    for (NSUInteger i = 0; i < left; i++) _buttons[i].frame = CGRectMake(i * (side + gap), 0, side, side);
    for (NSUInteger i = left; i < n; i++) _buttons[i].frame = CGRectMake(W - side - (n - 1 - i) * (side + gap), 0, side, side);
    CGFloat from = left * (side + gap), to = n > left ? W - (n - left) * (side + gap) : W;
    CGFloat room = MAX(0, to - from);
    BOOL stacked = room < AtelierCreditWidth(NO);
    _credit.attributedText = AtelierCreditText(stacked, NSTextAlignmentCenter);
    _credit.hidden = room < AtelierCreditWidth(stacked);
    _credit.frame = CGRectMake(from, 0, room, H);
}

#pragma mark tests

- (void)debugTap:(NSString *)key {
    AtelierToggleKind kind = [AtelierToggles kindForKey:key];
    for (AtelierToggleButton *b in _buttons) if (b.kind == kind) { [self _tapped:b]; return; }
    AtelierLog(@"toggle %@: not in the dock (%@)", key, kind == AtelierToggleCount ? @"no such switch" :
               ([AtelierToggles available:kind] ? @"switched off in Settings" : @"this iOS has no calls for it"));
}

- (NSArray<NSDictionary *> *)debugFrames {
    [self layoutIfNeeded];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (AtelierToggleButton *b in _buttons)
        [out addObject:@{ @"name": [@"toggle-" stringByAppendingString:[AtelierToggles key:b.kind]], @"frame": [NSValue valueWithCGRect:b.frame] }];
    if (!_credit.hidden) [out addObject:@{ @"name": @"credit", @"frame": [NSValue valueWithCGRect:_credit.frame] }];
    return out;
}

- (NSString *)debugState {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (AtelierToggleButton *b in _buttons) [parts addObject:[NSString stringWithFormat:@"%@ %@", [AtelierToggles key:b.kind], b.on ? @"ON" : @"off"]];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSInteger k = 0; k < AtelierToggleCount; k++) if (![AtelierToggles available:(AtelierToggleKind)k]) [missing addObject:[AtelierToggles key:(AtelierToggleKind)k]];
    return [NSString stringWithFormat:@"dock %@ [%@]%@ credit %@", _compact ? @"compact" : @"tall", [parts componentsJoinedByString:@" · "],
            missing.count ? [NSString stringWithFormat:@" (no calls here for: %@)", [missing componentsJoinedByString:@" "]] : @"",
            _credit.hidden ? @"hidden" : [NSString stringWithFormat:@"\"%@\" in %.0f pt",
                                          [_credit.attributedText.string stringByReplacingOccurrencesOfString:@"\n" withString:@" / "], _credit.frame.size.width]];
}

@end
