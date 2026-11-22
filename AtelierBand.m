/*  AtelierBand.m — the strip above the tiles: a clock, three market flags, shortcut apps.

    Clock      hours and minutes large, in digits that all have the same width so nothing shifts
               as they change; the seconds beside them, smaller and in the accent colour; the
               date under the seconds where there is room. 12 or 24 hours as the phone is set.

    Markets    three flags (India, the UK and the USA unless Settings says otherwise). A market
               in its regular session is in full colour inside a thin accent ring, with the time
               it has left; a closed one is dimmed. Each market's hours are worked out in its
               own time zone (so daylight saving is right), Monday to Friday. There is no
               holiday calendar: on a market holiday the flag lights up all the same.

    Shortcuts  icons of the apps chosen under Settings → Atelier → Shortcut Apps, each with the
               app's badge if it has one (SpringBoard's own badge value). A tap puts that app on
               the bench as the main app.

    Two shapes: two rows in the Side layout (clock and icons above, flags below, left of the
    "..." pill), one compact line in Top and Split.

    Cost: one timer, on the second boundary, only between -start and -stop (the bench on
    screen). With the clock switched off it fires once a minute. The flags and badges are worked
    out when the minute changes, not every second. Hidden, the band does nothing.               */

#import "Atelier.h"

typedef struct {
    const char *code;       // the flag: an ISO country code
    const char *zone;
    int open, close;        // minutes after midnight, in that zone
    const char *name;
} AtelierMarket;

static const AtelierMarket kMarkets[] = {
    { "IN", "Asia/Kolkata",      9 * 60 + 15, 15 * 60 + 30, "NSE" },
    { "GB", "Europe/London",     8 * 60,      16 * 60 + 30, "LSE" },
    { "US", "America/New_York",  9 * 60 + 30, 16 * 60,      "NYSE" },
    { "JP", "Asia/Tokyo",        9 * 60,      15 * 60 + 30, "TSE" },        // the lunch break is ignored
    { "HK", "Asia/Hong_Kong",    9 * 60 + 30, 16 * 60,      "HKEX" },
    { "DE", "Europe/Berlin",     9 * 60,      17 * 60 + 30, "Xetra" },
    { "CN", "Asia/Shanghai",     9 * 60 + 30, 15 * 60,      "SSE" },
    { "SG", "Asia/Singapore",    9 * 60,      17 * 60,      "SGX" },
};

static NSTimeInterval gNowOffset;            // tests: the clock runs on from another moment

static NSDate *AtelierBandNow(void) {
    return [NSDate dateWithTimeIntervalSinceNow:gNowOffset];
}

static const AtelierMarket *AtelierMarketFor(NSString *code) {
    for (size_t i = 0; i < sizeof(kMarkets) / sizeof(kMarkets[0]); i++)
        if ([code caseInsensitiveCompare:@(kMarkets[i].code)] == NSOrderedSame) return &kMarkets[i];
    return &kMarkets[0];
}

// A flag is the two letters of the country code as "regional indicator" characters.
static NSString *AtelierFlag(const char *code) {
    if (!code || strlen(code) != 2) return @"";
    uint32_t pair[2] = { 0x1F1E6 + (uint32_t)(code[0] - 'A'), 0x1F1E6 + (uint32_t)(code[1] - 'A') };
    return [[NSString alloc] initWithBytes:pair length:sizeof(pair) encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
}

// Minutes left in the session at `date`, or -1 when the market is closed.
static NSInteger AtelierMarketMinutesLeft(const AtelierMarket *m, NSDate *date) {
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:@(m->zone)];
    if (!zone) return -1;
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = zone;
    NSDateComponents *c = [cal components:NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
    if (c.weekday == 1 || c.weekday == 7) return -1;                 // Sunday, Saturday
    NSInteger minute = c.hour * 60 + c.minute;
    if (minute < m->open || minute >= m->close) return -1;
    return m->close - minute;
}

static UIColor *AtelierAccent(void) {
    return [UIColor colorWithRed:0.60 green:0.58 blue:1.0 alpha:1];
}

#pragma mark - a market flag

@interface AtelierFlagChip : UIView
@property (nonatomic, strong) UIView *ring;
@property (nonatomic, strong) UILabel *flag;
@property (nonatomic, strong) UILabel *caption;
@property (nonatomic) BOOL open;
@end

@implementation AtelierFlagChip

- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 28, 22)])) return nil;
    self.userInteractionEnabled = NO;
    _ring = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 22)];
    _ring.layer.cornerRadius = 7;
    _ring.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_ring];
    _flag = [[UILabel alloc] initWithFrame:_ring.bounds];
    _flag.font = [UIFont systemFontOfSize:15];
    _flag.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_flag];
    _caption = [UILabel new];
    _caption.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
    _caption.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    [self addSubview:_caption];
    return self;
}

- (void)setOpen:(BOOL)open {
    _open = open;
    _flag.alpha = open ? 1.0 : 0.34;
    _ring.layer.borderWidth = open ? 1.2 : 0;
    _ring.layer.borderColor = AtelierAccent().CGColor;
    _ring.backgroundColor = open ? [AtelierAccent() colorWithAlphaComponent:0.16] : [UIColor colorWithWhite:1 alpha:0.05];
}

@end

#pragma mark - a shortcut app

@interface AtelierShortcutIcon : UIControl
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *badge;
@end

@implementation AtelierShortcutIcon

- (instancetype)initWithBundleID:(NSString *)bid {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 30, 30)])) return nil;
    _bundleID = [bid copy];
    _icon = [[UIImageView alloc] initWithImage:[AtelierHost iconForBundleID:bid]];
    _icon.frame = self.bounds;
    _icon.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _icon.layer.cornerCurve = kCACornerCurveContinuous;
    _icon.clipsToBounds = YES;
    _icon.userInteractionEnabled = NO;
    [self addSubview:_icon];
    _badge = [UILabel new];
    _badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    _badge.textColor = UIColor.whiteColor;
    _badge.textAlignment = NSTextAlignmentCenter;
    _badge.backgroundColor = [UIColor colorWithRed:1 green:0.27 blue:0.23 alpha:1];
    _badge.layer.cornerRadius = 7;
    _badge.clipsToBounds = YES;
    _badge.hidden = YES;
    _badge.userInteractionEnabled = NO;
    [self addSubview:_badge];
    self.accessibilityLabel = [AtelierHost displayNameForBundleID:bid];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _icon.layer.cornerRadius = self.bounds.size.width * 0.235;
    CGFloat w = MAX(14, [_badge sizeThatFits:CGSizeMake(60, 14)].width + 7);
    _badge.frame = CGRectMake(self.bounds.size.width - w + 5, -5, w, 14);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _icon.alpha = highlighted ? 0.55 : 1.0;
}

// The app's badge as SpringBoard holds it: a number, or now and then a string.
- (NSString *)refreshBadge {
    id value = AtelierMsg([AtelierHost applicationForBundleID:_bundleID], @"badgeValue");
    NSString *text = nil;
    if ([value isKindOfClass:NSNumber.class]) {
        NSInteger n = [value integerValue];
        if (n > 0) text = n > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)n];
    } else if ([value isKindOfClass:NSString.class] && [value length]) {
        text = [value length] > 3 ? [[value substringToIndex:3] stringByAppendingString:@"…"] : value;
    }
    if ((text ?: @"").length != (_badge.text ?: @"").length || ![(text ?: @"") isEqualToString:(_badge.text ?: @"")]) {
        _badge.text = text;
        [self setNeedsLayout];
    }
    _badge.hidden = text.length == 0;
    return text;
}

@end

#pragma mark - the band

@implementation AtelierBand {
    UILabel *_hm, *_sec, *_ampm, *_date;
    NSMutableArray<AtelierFlagChip *> *_chips;
    NSMutableArray<AtelierShortcutIcon *> *_icons;
    NSArray<NSString *> *_marketCodes;
    NSTimer *_timer;
    NSDateFormatter *_hmFormat, *_ampmFormat, *_dateFormat;
    NSCalendar *_calendar;
    BOOL _compact, _running, _showClock, _showMarkets;
    CGFloat _flagsWidth;
    NSInteger _lastMinute;
}

+ (BOOL)wanted {
    AtelierSettings *s = [AtelierSettings shared];
    return s.showClock || s.showMarkets || [s shortcutApps].count > 0;
}

+ (void)setDebugNow:(NSDate *)date {
    gNowOffset = date ? [date timeIntervalSinceNow] : 0;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _chips = [NSMutableArray array];
    _icons = [NSMutableArray array];
    _lastMinute = -1;
    _hm = [UILabel new];
    _hm.textColor = UIColor.whiteColor;
    _sec = [UILabel new];
    _sec.textColor = AtelierAccent();
    _ampm = [UILabel new];
    _ampm.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    _date = [UILabel new];
    _date.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    for (UILabel *l in @[ _hm, _sec, _ampm, _date ]) { l.userInteractionEnabled = NO; [self addSubview:l]; }
    return self;
}

// Only the shortcut icons take touches; anywhere else a finger goes through to the backdrop.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.05) return nil;
    for (AtelierShortcutIcon *icon in _icons) {
        if (CGRectContainsPoint(CGRectInset(icon.frame, -4, -6), point)) return icon;
    }
    return nil;
}

#pragma mark contents

- (void)reload {
    AtelierSettings *s = [AtelierSettings shared];
    _showClock = s.showClock;
    _showMarkets = s.showMarkets;
    for (UILabel *l in @[ _hm, _sec, _ampm, _date ]) l.hidden = !_showClock;

    // 12 or 24 hours, as the phone is set
    NSLocale *locale = NSLocale.autoupdatingCurrentLocale;
    BOOL twelve = [[NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:locale] containsString:@"a"];
    _hmFormat = [NSDateFormatter new];
    _hmFormat.locale = locale;
    _hmFormat.dateFormat = twelve ? @"h:mm" : @"HH:mm";
    _ampmFormat = twelve ? [NSDateFormatter new] : nil;
    _ampmFormat.locale = locale;
    _ampmFormat.dateFormat = @"a";
    _dateFormat = [NSDateFormatter new];
    _dateFormat.locale = locale;
    [_dateFormat setLocalizedDateFormatFromTemplate:@"EEEdMMM"];
    _calendar = [NSCalendar autoupdatingCurrentCalendar];

    for (AtelierFlagChip *chip in _chips) [chip removeFromSuperview];
    [_chips removeAllObjects];
    _marketCodes = _showMarkets ? [s markets] : @[];
    for (NSString *code in _marketCodes) {
        AtelierFlagChip *chip = [AtelierFlagChip new];
        chip.flag.text = AtelierFlag(AtelierMarketFor(code)->code);
        [self addSubview:chip];
        [_chips addObject:chip];
    }

    for (AtelierShortcutIcon *icon in _icons) [icon removeFromSuperview];
    [_icons removeAllObjects];
    for (NSString *bid in [s shortcutApps]) {
        if (_icons.count >= ATELIER_SHORTCUTS) break;
        if (![AtelierHost applicationForBundleID:bid]) continue;
        AtelierShortcutIcon *icon = [[AtelierShortcutIcon alloc] initWithBundleID:bid];
        [icon addTarget:self action:@selector(_shortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:icon];
        [_icons addObject:icon];
    }
    _lastMinute = -1;
    [self _tick];
    if (_running) [self _schedule];
}

- (void)_shortcutTapped:(AtelierShortcutIcon *)icon {
    AtelierHapticPlay(AtelierHapticTick);
    if (self.onShortcut) self.onShortcut(icon.bundleID);
}

- (void)debugTapShortcut:(NSUInteger)index {
    if (index < _icons.count) [self _shortcutTapped:_icons[index]];
    else AtelierLog(@"shortcut %lu: there are %lu", (unsigned long)index, (unsigned long)_icons.count);
}

#pragma mark the clock

- (void)start {
    _running = YES;
    _lastMinute = -1;
    [self _tick];
    [self _schedule];
}

- (void)stop {
    _running = NO;
    [_timer invalidate];
    _timer = nil;
}

- (void)_schedule {
    [_timer invalidate];
    _timer = nil;
    if (!_showClock && !_showMarkets && _icons.count == 0) return;      // nothing that changes with time
    NSTimeInterval period = _showClock ? 1.0 : 60.0;
    NSTimeInterval shown = [AtelierBandNow() timeIntervalSinceReferenceDate];
    NSTimeInterval wait = period - fmod(shown, period);                  // to the next whole second (or minute)
    __weak typeof(self) weak = self;
    _timer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:wait] interval:period repeats:YES block:^(NSTimer *t) {
        @try { [weak _tick]; } @catch (NSException *e) { AtelierLog(@"band clock threw %@", e.reason); }
    }];
    _timer.tolerance = _showClock ? 0.02 : 2.0;
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)_tick {
    NSDate *now = [AtelierBandNow() dateByAddingTimeInterval:0.02];      // the timer may fire a hair early
    NSDateComponents *c = [(_calendar ?: NSCalendar.currentCalendar) components:NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:now];
    if (_showClock) _sec.text = [NSString stringWithFormat:@"%02ld", (long)c.second];
    if (c.minute == _lastMinute) return;
    _lastMinute = c.minute;
    if (_showClock) {
        _hm.text = [_hmFormat stringFromDate:now];
        _ampm.text = _ampmFormat ? [[_ampmFormat stringFromDate:now] uppercaseString] : nil;
        _date.text = [_dateFormat stringFromDate:now];
    }
    for (NSUInteger i = 0; i < _chips.count && i < _marketCodes.count; i++) {
        NSInteger left = AtelierMarketMinutesLeft(AtelierMarketFor(_marketCodes[i]), now);
        AtelierFlagChip *chip = _chips[i];
        chip.open = left >= 0;
        chip.caption.text = left < 0 ? nil : (left >= 60 ? [NSString stringWithFormat:@"%ldh %02ldm", (long)(left / 60), (long)(left % 60)]
                                                         : [NSString stringWithFormat:@"%ldm", (long)left]);
    }
    for (AtelierShortcutIcon *icon in _icons) [icon refreshBadge];
    [self setNeedsLayout];
}

#pragma mark layout

- (void)setCompact:(BOOL)compact flagsWidth:(CGFloat)width {
    _compact = compact;
    _flagsWidth = width;
    [self setNeedsLayout];
}

- (void)_styleClock {
    CGFloat big = _compact ? 20 : 31, small = _compact ? 12 : 15;
    _hm.font = [UIFont monospacedDigitSystemFontOfSize:big weight:UIFontWeightSemibold];
    // a little tighter than the font's own spacing
    if (_hm.text.length) {
        _hm.attributedText = [[NSAttributedString alloc] initWithString:_hm.text attributes:@{
            NSFontAttributeName: _hm.font, NSKernAttributeName: @(_compact ? -0.4 : -0.9), NSForegroundColorAttributeName: UIColor.whiteColor }];
    }
    _sec.font = [UIFont monospacedDigitSystemFontOfSize:small weight:UIFontWeightSemibold];
    _ampm.font = [UIFont systemFontOfSize:_compact ? 9 : 10 weight:UIFontWeightSemibold];
    _date.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat x = 0;

    // shortcut icons, right-aligned on the first line
    CGFloat side = _compact ? 24 : 30, pitch = side + (_compact ? 6 : 7), top = 3;
    NSUInteger n = _icons.count;
    for (NSUInteger i = 0; i < n; i++) {
        _icons[i].frame = CGRectMake(W - side - (n - 1 - i) * pitch, top, side, side);
    }
    CGFloat iconsLeft = n ? W - side - (n - 1) * pitch - 10 : W;

    if (_showClock) {
        [self _styleClock];
        CGSize hm = [_hm sizeThatFits:CGSizeMake(300, 60)];
        CGSize sec = [_sec sizeThatFits:CGSizeMake(100, 40)];
        if (_compact) {
            _hm.frame = CGRectMake(0, 2, ceil(hm.width), 26);
            _sec.frame = CGRectMake(CGRectGetMaxX(_hm.frame) + 3, 9, ceil(sec.width), 16);
            CGSize ap = [_ampm sizeThatFits:CGSizeMake(60, 20)];
            _ampm.frame = CGRectMake(CGRectGetMaxX(_sec.frame) + 3, 11, ceil(ap.width), 13);
            _date.hidden = YES;
            x = (_ampm.text.length ? CGRectGetMaxX(_ampm.frame) : CGRectGetMaxX(_sec.frame)) + 12;
        } else {
            _hm.frame = CGRectMake(0, -2, ceil(hm.width), 40);
            CGFloat sx = CGRectGetMaxX(_hm.frame) + 6;
            _sec.frame = CGRectMake(sx, 3, ceil(sec.width), 18);
            CGSize ap = [_ampm sizeThatFits:CGSizeMake(60, 20)];
            _ampm.frame = CGRectMake(CGRectGetMaxX(_sec.frame) + 4, 6, ceil(ap.width), 13);
            CGSize d = [_date sizeThatFits:CGSizeMake(200, 20)];
            _date.frame = CGRectMake(sx, 21, ceil(d.width), 14);
            _date.hidden = CGRectGetMaxX(_date.frame) > iconsLeft;          // no room beside the icons: the date goes
        }
    }

    // flags: after the clock on the compact line, or on the second row left of the pill
    CGFloat fx = _compact ? x : 0, fy = _compact ? 4 : 38;
    CGFloat room = _compact ? iconsLeft - fx : (_flagsWidth > 0 ? _flagsWidth : W);
    CGFloat withCaptions = 0;
    for (AtelierFlagChip *chip in _chips) {
        CGFloat cw = chip.caption.text.length ? ceil([chip.caption sizeThatFits:CGSizeMake(80, 20)].width) + 5 : 0;
        withCaptions += 28 + cw + 8;
    }
    BOOL captions = !_compact && withCaptions - 8 <= room;
    for (AtelierFlagChip *chip in _chips) {
        CGFloat cw = (captions && chip.caption.text.length) ? ceil([chip.caption sizeThatFits:CGSizeMake(80, 20)].width) : 0;
        chip.caption.hidden = cw == 0;
        chip.caption.frame = CGRectMake(28 + 5, 0, cw, 22);
        chip.frame = CGRectMake(fx, fy, 28 + (cw ? cw + 5 : 0), 22);
        chip.hidden = CGRectGetMaxX(chip.frame) > (_compact ? iconsLeft : room) + 0.5;      // no room: this flag goes
        fx = CGRectGetMaxX(chip.frame) + 8;
    }
}

#pragma mark tests

- (NSArray<NSDictionary *> *)debugFrames {
    [self layoutIfNeeded];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (_showClock) [out addObject:@{ @"name": @"clock", @"frame": [NSValue valueWithCGRect:CGRectUnion(_hm.frame, _sec.frame)] }];
    for (NSUInteger i = 0; i < _chips.count; i++)
        [out addObject:@{ @"name": [NSString stringWithFormat:@"flag%lu", (unsigned long)i], @"frame": [NSValue valueWithCGRect:_chips[i].frame] }];
    for (NSUInteger i = 0; i < _icons.count; i++)
        [out addObject:@{ @"name": [NSString stringWithFormat:@"shortcut%lu", (unsigned long)i], @"frame": [NSValue valueWithCGRect:_icons[i].frame] }];
    return out;
}

- (NSString *)debugState {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (_showClock) [parts addObject:[NSString stringWithFormat:@"clock %@:%@%@%@ %@", _hm.text ?: @"?", _sec.text ?: @"?",
                                      _ampm.text.length ? @" " : @"", _ampm.text ?: @"", _date.hidden ? @"(no date)" : (_date.text ?: @"")]];
    for (NSUInteger i = 0; i < _chips.count && i < _marketCodes.count; i++) {
        AtelierFlagChip *chip = _chips[i];
        [parts addObject:[NSString stringWithFormat:@"%@ %@%@", _marketCodes[i], chip.open ? @"open " : @"closed",
                          chip.open ? (chip.caption.text ?: @"") : @""]];
    }
    NSMutableArray<NSString *> *icons = [NSMutableArray array];
    for (AtelierShortcutIcon *icon in _icons)
        [icons addObject:[NSString stringWithFormat:@"%@%@", icon.bundleID, icon.badge.hidden ? @"" : [NSString stringWithFormat:@"(%@)", icon.badge.text]]];
    [parts addObject:[NSString stringWithFormat:@"shortcuts [%@]", [icons componentsJoinedByString:@" "]]];
    return [NSString stringWithFormat:@"band %@%@ timer %@ · %@", _compact ? @"compact" : @"tall", self.hidden ? @" hidden" : @"",
            _timer ? @"on" : @"off", [parts componentsJoinedByString:@" · "]];
}

@end
