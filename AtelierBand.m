/*  AtelierBand.m — the strip above the tiles: index numbers, a clock, three market flags,
    shortcut apps.

    Indices    NIFTY and SENSEX: last price in Indian grouping, the change and the change in
               per cent with an up or down mark, green or red. The numbers come from
               AtelierQuotes.m. A small tag says "Closed" outside India's session, and how old
               the number is when it is more than a minute old during the session; while the
               feed is failing the last numbers stay, dimmed.

    Clock      hours and minutes large, in digits that all have the same width so nothing shifts
               as they change; the seconds beside them, smaller and in the accent colour; the
               date under the seconds where there is room. 12 or 24 hours as the phone is set.

    Markets    three flags (India, the UK and the USA unless Settings says otherwise). A market
               in its regular session is in full colour inside a thin accent ring, with the time
               it has left; a closed one is dimmed. Each market's hours are worked out in its
               own time zone (so daylight saving is right), Monday to Friday. India also
               has its trading holidays: on one of those its flag stays dimmed and says
               "Holiday" (and which, where there is room). The list is AtelierIndiaHolidays()
               below, one table per year, plus the dates typed under Settings → HyperTrade →
               Extra India Holidays. A year without a table is weekdays only. The other markets
               have no holiday list: on their holidays the flag lights up all the same.

    Shortcuts  icons of the chosen apps (up to six), each with the app's badge if it has one
               (SpringBoard's own badge value). A tap puts that app on the bench as the main
               app; a hold offers Open and Remove. While there are fewer than six, a "+" at the
               end adds one from the app picker. (The same list can be edited under Settings.)

    Two shapes. Side: four rows (two index lines; the clock, with the shortcuts on the right;
    the flags, left of the "..." pill). Top and Split: two compact lines (both indices; then
    clock, flags and shortcuts).

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

#pragma mark - India's trading holidays

// NSE / BSE trading holidays, as dates in India (Asia/Kolkata). One table per year; a holiday
// that falls on a weekend needs no line. To add a year: one more table here and one more line in
// AtelierIndiaHolidays(). Special sessions (the Diwali Muhurat hour) are not modelled.
//
// 2026: the exchanges' list as carried on Zerodha's holiday calendar, read on 22 Nov 2026.
static NSDictionary<NSString *, NSString *> *AtelierIndiaHolidays2026(void) {
    return @{
        @"2026-01-15": @"Municipal Elections",          // Municipal Corporation Elections in Maharashtra
        @"2026-01-26": @"Republic Day",
        @"2026-03-03": @"Holi",
        @"2026-03-26": @"Ram Navami",
        @"2026-03-31": @"Mahavir Jayanti",
        @"2026-04-03": @"Good Friday",
        @"2026-04-14": @"Ambedkar Jayanti",
        @"2026-05-01": @"Maharashtra Day",
        @"2026-05-28": @"Bakri Eid",
        @"2026-06-26": @"Moharram",
        @"2026-09-14": @"Ganesh Chaturthi",
        @"2026-10-02": @"Gandhi Jayanti",
        @"2026-10-20": @"Dussehra",
        @"2026-11-10": @"Diwali Balipratipada",
        @"2026-11-24": @"Guru Nanak Jayanti",           // Prakash Gurpurb Sri Guru Nanak Dev
        @"2026-12-25": @"Christmas",
    };
}

// Every known holiday: the built-in tables, and the dates from Settings (YYYY-MM-DD, separated by
// commas or spaces; anything else in the text is skipped).
static NSDictionary<NSString *, NSString *> *AtelierIndiaHolidays(NSString *extra) {
    NSMutableDictionary<NSString *, NSString *> *all = [NSMutableDictionary dictionary];
    [all addEntriesFromDictionary:AtelierIndiaHolidays2026()];
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@", ;\n\t"];
    for (NSString *word in [extra ?: @"" componentsSeparatedByCharactersInSet:breaks]) {
        if (word.length != 10 || [word characterAtIndex:4] != '-' || [word characterAtIndex:7] != '-') continue;
        NSInteger y = [word substringToIndex:4].integerValue, m = [word substringWithRange:NSMakeRange(5, 2)].integerValue,
                  d = [word substringFromIndex:8].integerValue;
        if (y < 2000 || m < 1 || m > 12 || d < 1 || d > 31) continue;
        if (!all[word]) all[word] = @"";
    }
    return all;
}

static NSTimeInterval gNowOffset;            // tests: the clock runs on from another moment

NSDate *AtelierNow(void) {
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

// Minutes left in the session at `date`, or -1 when the market is closed. `holidays` (India's,
// nil for the others) maps a date in the market's own zone to the holiday's name; on such a day
// the market is closed and *holiday gets the name ("" when it has none).
static NSInteger AtelierMarketMinutesLeft(const AtelierMarket *m, NSDate *date, NSDictionary<NSString *, NSString *> *holidays,
                                          NSString *__autoreleasing *holiday) {
    if (holiday) *holiday = nil;
    NSTimeZone *zone = [NSTimeZone timeZoneWithName:@(m->zone)];
    if (!zone) return -1;
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = zone;
    NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday |
                                          NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
    if (c.weekday == 1 || c.weekday == 7) return -1;                 // Sunday, Saturday
    if (holidays.count) {
        NSString *name = holidays[[NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)c.year, (long)c.month, (long)c.day]];
        if (name) { if (holiday) *holiday = name; return -1; }
    }
    NSInteger minute = c.hour * 60 + c.minute;
    if (minute < m->open || minute >= m->close) return -1;
    return m->close - minute;
}

// India's regular session, holidays (built in and typed in Settings) taken out: when the index
// numbers are live.
BOOL AtelierIndiaSessionOpen(NSDate *date) {
    return AtelierMarketMinutesLeft(&kMarkets[0], date ?: AtelierNow(), AtelierIndiaHolidays([[AtelierSettings shared] extraHolidays]), NULL) >= 0;
}

static UIColor *AtelierAccent(void) {
    return [UIColor colorWithRed:0.60 green:0.58 blue:1.0 alpha:1];
}

// 2580060 paise -> "25,800.60"; a lakh and more group the Indian way: "1,00,412.05".
NSString *AtelierIndianNumber(double value) {
    BOOL negative = value < 0;
    long long paise = llround(fabs(value) * 100.0);
    long long whole = paise / 100;
    NSString *digits = [NSString stringWithFormat:@"%lld", whole];
    NSMutableString *out = [NSMutableString string];
    if (digits.length <= 3) {
        [out appendString:digits];
    } else {
        NSString *head = [digits substringToIndex:digits.length - 3];
        NSMutableArray<NSString *> *groups = [NSMutableArray array];
        while (head.length > 2) {
            [groups insertObject:[head substringFromIndex:head.length - 2] atIndex:0];
            head = [head substringToIndex:head.length - 2];
        }
        [groups insertObject:head atIndex:0];
        [out appendFormat:@"%@,%@", [groups componentsJoinedByString:@","], [digits substringFromIndex:digits.length - 3]];
    }
    return [NSString stringWithFormat:@"%@%@.%02lld", negative ? @"-" : @"", out, paise % 100];
}

#pragma mark - one index line

@interface AtelierIndexLine : UIView
@property (nonatomic, strong) UILabel *name, *price, *change, *note;
@property (nonatomic, copy) NSString *said;             // what it shows, for the tests
@end

@implementation AtelierIndexLine

- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 200, 14)])) return nil;
    self.userInteractionEnabled = NO;
    _name = [UILabel new];
    _price = [UILabel new];
    _change = [UILabel new];
    _note = [UILabel new];
    _note.textAlignment = NSTextAlignmentCenter;
    _note.layer.cornerRadius = 4;
    _note.clipsToBounds = YES;
    for (UILabel *l in @[ _name, _price, _change, _note ]) [self addSubview:l];
    return self;
}

- (void)show:(AtelierQuote *)quote label:(NSString *)label failing:(BOOL)failing sessionOpen:(BOOL)open compact:(BOOL)compact {
    CGFloat big = compact ? 12 : 13.5, small = compact ? 10.5 : 11;
    _name.attributedText = [[NSAttributedString alloc] initWithString:label attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:compact ? 9 : 9.5 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55], NSKernAttributeName: @0.5 }];
    _price.font = [UIFont monospacedDigitSystemFontOfSize:big weight:UIFontWeightSemibold];
    _price.textColor = UIColor.whiteColor;
    _change.font = [UIFont monospacedDigitSystemFontOfSize:small weight:UIFontWeightMedium];
    _note.font = [UIFont systemFontOfSize:8.5 weight:UIFontWeightSemibold];
    if (!quote) {
        _price.text = @"—";
        _change.text = nil;
        _note.text = failing ? @"No data" : nil;
        _note.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        _note.backgroundColor = UIColor.clearColor;
        self.alpha = 0.6;
        self.said = [NSString stringWithFormat:@"%@ —%@", label, failing ? @" (no data)" : @""];
        [self setNeedsLayout];
        return;
    }
    _price.text = AtelierIndianNumber(quote.price);
    double move = quote.previousClose > 0 ? quote.price - quote.previousClose : 0;
    double percent = quote.previousClose > 0 ? move / quote.previousClose * 100.0 : 0;
    UIColor *colour = move > 0.004 ? [UIColor colorWithRed:0.19 green:0.84 blue:0.42 alpha:1]
                    : (move < -0.004 ? [UIColor colorWithRed:1.0 green:0.36 blue:0.33 alpha:1] : [UIColor colorWithWhite:1 alpha:0.6]);
    NSString *mark = move > 0.004 ? @"▲" : (move < -0.004 ? @"▼" : @"•");
    _change.textColor = colour;
    _change.text = quote.previousClose <= 0 ? nil
        : (compact ? [NSString stringWithFormat:@"%@%.2f%%", mark, fabs(percent)]
                   : [NSString stringWithFormat:@"%@ %@ (%.2f%%)", mark, AtelierIndianNumber(fabs(move)), fabs(percent)]);
    // the tag: closed, or how old the number is when that is worth saying
    NSTimeInterval age = quote.marketTime ? [AtelierNow() timeIntervalSinceDate:quote.marketTime] : 0;
    NSString *tag = nil;
    BOOL boxed = NO;
    if (!open) { tag = @"Closed"; boxed = YES; }
    else if (age > 60) tag = age >= 3600 ? [NSString stringWithFormat:@"%ldh ago", (long)(age / 3600)] : [NSString stringWithFormat:@"%ldm ago", (long)(age / 60)];
    _note.text = tag;
    _note.textColor = [UIColor colorWithWhite:1 alpha:boxed ? 0.7 : 0.5];
    _note.backgroundColor = boxed ? [UIColor colorWithWhite:1 alpha:0.12] : UIColor.clearColor;
    self.alpha = failing ? 0.45 : 1.0;                   // the feed is failing: these are old numbers
    self.said = [NSString stringWithFormat:@"%@ %@ %@%@%@", label, _price.text, _change.text ?: @"", tag ? [NSString stringWithFormat:@" [%@]", tag] : @"",
                 failing ? @" (dimmed)" : @""];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    BOOL wide = W > 300;                                 // a line of its own: the names line up in a column
    CGFloat nameW = wide ? 47 : ceil([_name sizeThatFits:CGSizeMake(80, H)].width) + 4;
    _name.frame = CGRectMake(0, 0.5, nameW, H);
    CGFloat x = nameW;
    CGFloat pw = ceil([_price sizeThatFits:CGSizeMake(160, H)].width);
    _price.frame = CGRectMake(x, 0, pw, H);
    x += pw + (wide ? 8 : 5);
    CGFloat cw = _change.text.length ? ceil([_change sizeThatFits:CGSizeMake(200, H)].width) : 0;
    _change.frame = CGRectMake(x, 0.5, cw, H);
    x += cw + (cw ? 7 : 0);
    CGFloat tw = _note.text.length ? ceil([_note sizeThatFits:CGSizeMake(80, H)].width) + 8 : 0;
    _note.frame = CGRectMake(x, (H - 12) / 2.0 + 0.5, tw, 12);
    _note.hidden = tw == 0 || x + tw > W + 0.5;           // no room: the tag goes (the dimming still says "old")
}

@end

#pragma mark - a market flag

@interface AtelierFlagChip : UIView
@property (nonatomic, strong) UIView *ring;
@property (nonatomic, strong) UILabel *flag;
@property (nonatomic, strong) UILabel *caption;
@property (nonatomic) BOOL open;
@property (nonatomic, copy) NSString *shortCaption;     // what the caption says when the long one has no room
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
    _caption.textColor = [UIColor colorWithWhite:1 alpha:open ? 0.82 : 0.5];
    _ring.layer.borderWidth = open ? 1.2 : 0;
    _ring.layer.borderColor = AtelierAccent().CGColor;
    _ring.backgroundColor = open ? [AtelierAccent() colorWithAlphaComponent:0.16] : [UIColor colorWithWhite:1 alpha:0.05];
}

@end

#pragma mark - a shortcut app

@interface AtelierShortcutIcon : UIControl
@property (nonatomic, copy) NSString *bundleID;          // nil for the "+"
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *badge;
@end

@implementation AtelierShortcutIcon

- (instancetype)initWithBundleID:(NSString *)bid {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 28, 28)])) return nil;
    _bundleID = [bid copy];
    if (bid) {
        _icon = [[UIImageView alloc] initWithImage:[AtelierHost iconForBundleID:bid]];
        _icon.clipsToBounds = YES;
        self.accessibilityLabel = [AtelierHost displayNameForBundleID:bid];
    } else {                                             // the "+" at the end of the row
        UIImage *plus = [UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]];
        _icon = [[UIImageView alloc] initWithImage:[plus imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        _icon.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
        _icon.contentMode = UIViewContentModeCenter;
        _icon.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        _icon.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        _icon.layer.borderWidth = 1;
        _icon.clipsToBounds = YES;
        self.accessibilityLabel = @"Add a shortcut app";
    }
    _icon.frame = self.bounds;
    _icon.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _icon.layer.cornerCurve = kCACornerCurveContinuous;
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
- (void)refreshBadge {
    if (!_bundleID) return;
    id value = AtelierMsg([AtelierHost applicationForBundleID:_bundleID], @"badgeValue");
    NSString *text = nil;
    if ([value isKindOfClass:NSNumber.class]) {
        NSInteger n = [value integerValue];
        if (n > 0) text = n > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)n];
    } else if ([value isKindOfClass:NSString.class] && [value length]) {
        text = [value length] > 3 ? [[value substringToIndex:3] stringByAppendingString:@"…"] : value;
    }
    if (![(text ?: @"") isEqualToString:(_badge.text ?: @"")]) {
        _badge.text = text;
        [self setNeedsLayout];
    }
    _badge.hidden = text.length == 0;
}

@end

#pragma mark - the band

@implementation AtelierBand {
    UILabel *_hm, *_sec, *_ampm, *_date;
    NSMutableArray<AtelierIndexLine *> *_lines;
    NSMutableArray<AtelierFlagChip *> *_chips;
    NSMutableArray<AtelierShortcutIcon *> *_icons;       // the apps, then the "+" if there is one
    NSArray<NSString *> *_marketCodes;
    NSArray<NSString *> *_longCaptions;      // each flag's caption in full
    NSDictionary<NSString *, NSString *> *_indiaHolidays;
    NSTimer *_timer;
    NSDateFormatter *_hmFormat, *_ampmFormat, *_dateFormat;
    NSCalendar *_calendar;
    BOOL _compact, _running, _showClock, _showMarkets, _showIndices;
    CGFloat _flagsWidth;
    NSInteger _lastMinute;
}

+ (void)setDebugNow:(NSDate *)date {
    gNowOffset = date ? [date timeIntervalSinceNow] : 0;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _lines = [NSMutableArray array];
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
    for (int i = 0; i < 2; i++) {
        AtelierIndexLine *line = [AtelierIndexLine new];
        line.hidden = YES;
        [self addSubview:line];
        [_lines addObject:line];
    }
    return self;
}

// Only the shortcut icons take touches; anywhere else a finger goes through to the backdrop.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.05) return nil;
    for (AtelierShortcutIcon *icon in _icons) {
        if (CGRectContainsPoint(CGRectInset(icon.frame, -3, -6), point)) return icon;
    }
    return nil;
}

#pragma mark contents

- (void)reload {
    AtelierSettings *s = [AtelierSettings shared];
    _showClock = s.showClock;
    _showMarkets = s.showMarkets;
    _showIndices = s.showIndices;
    for (UILabel *l in @[ _hm, _sec, _ampm, _date ]) l.hidden = !_showClock;
    for (AtelierIndexLine *line in _lines) line.hidden = !_showIndices;

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
    _indiaHolidays = AtelierIndiaHolidays([s extraHolidays]);
    for (NSString *code in _marketCodes) {
        AtelierFlagChip *chip = [AtelierFlagChip new];
        chip.flag.text = AtelierFlag(AtelierMarketFor(code)->code);
        [self addSubview:chip];
        [_chips addObject:chip];
    }

    for (AtelierShortcutIcon *icon in _icons) [icon removeFromSuperview];
    [_icons removeAllObjects];
    for (NSString *bid in [AtelierBand shownShortcuts]) {
        AtelierShortcutIcon *icon = [[AtelierShortcutIcon alloc] initWithBundleID:bid];
        [icon addTarget:self action:@selector(_shortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_shortcutHeld:)];
        hold.minimumPressDuration = 0.4;
        [icon addGestureRecognizer:hold];
        [self addSubview:icon];
        [_icons addObject:icon];
    }
    if (_icons.count < ATELIER_SHORTCUTS) {
        AtelierShortcutIcon *plus = [[AtelierShortcutIcon alloc] initWithBundleID:nil];
        [plus addTarget:self action:@selector(_plusTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:plus];
        [_icons addObject:plus];
    }
    _lastMinute = -1;
    [self _tick];
    [self quotesChanged];
    if (_running) [self _schedule];
}

// The shortcut apps as the row shows them: installed, not hidden by SporeX, six at most.
+ (NSArray<NSString *> *)shownShortcuts {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *bid in [[AtelierSettings shared] shortcutApps]) {
        if (out.count >= ATELIER_SHORTCUTS) break;
        if (![AtelierHost applicationForBundleID:bid] || [AtelierHost isHiddenApp:bid]) continue;
        [out addObject:bid];
    }
    return out;
}

- (void)_shortcutTapped:(AtelierShortcutIcon *)icon {
    AtelierHapticPlay(AtelierHapticTick);
    if (self.onShortcut) self.onShortcut(icon.bundleID);
}

- (void)_shortcutHeld:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    AtelierShortcutIcon *icon = (AtelierShortcutIcon *)g.view;
    AtelierHapticPlay(AtelierHapticSwap);
    if (self.onShortcutHeld && icon.bundleID) self.onShortcutHeld(icon.bundleID, icon.frame);
}

- (void)_plusTapped {
    AtelierHapticPlay(AtelierHapticTick);
    if (self.onAddShortcut) self.onAddShortcut();
}

- (void)quotesChanged {
    if (!_showIndices) return;
    AtelierQuotes *source = [AtelierQuotes shared];
    NSArray<AtelierQuote *> *quotes = [source quotes];
    BOOL open = AtelierIndiaSessionOpen(AtelierNow());
    NSArray<NSString *> *labels = @[ @"NIFTY", @"SENSEX" ];
    for (NSUInteger i = 0; i < _lines.count; i++)
        [_lines[i] show:(i < quotes.count ? quotes[i] : nil) label:labels[i] failing:[source failing] sessionOpen:open compact:_compact];
    [self setNeedsLayout];
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
    NSTimeInterval period = _showClock ? 1.0 : 60.0;                     // without a clock only the minute matters
    NSTimeInterval shown = [AtelierNow() timeIntervalSinceReferenceDate];
    NSTimeInterval wait = period - fmod(shown, period);                  // to the next whole second (or minute)
    __weak typeof(self) weak = self;
    _timer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:wait] interval:period repeats:YES block:^(NSTimer *t) {
        @try { [weak _tick]; } @catch (NSException *e) { AtelierLog(@"band clock threw %@", e.reason); }
    }];
    _timer.tolerance = _showClock ? 0.02 : 2.0;
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)_tick {
    NSDate *now = [AtelierNow() dateByAddingTimeInterval:0.02];          // the timer may fire a hair early
    NSDateComponents *c = [(_calendar ?: NSCalendar.currentCalendar) components:NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:now];
    if (_showClock) _sec.text = [NSString stringWithFormat:@"%02ld", (long)c.second];
    if (c.minute == _lastMinute) return;
    _lastMinute = c.minute;
    if (_showClock) {
        _hm.text = [_hmFormat stringFromDate:now];
        _ampm.text = _ampmFormat ? [[_ampmFormat stringFromDate:now] uppercaseString] : nil;
        _date.text = [_dateFormat stringFromDate:now];
    }
    NSMutableArray<NSString *> *captions = [NSMutableArray array];
    for (NSUInteger i = 0; i < _chips.count && i < _marketCodes.count; i++) {
        const AtelierMarket *market = AtelierMarketFor(_marketCodes[i]);
        NSString *holiday = nil;
        NSInteger left = AtelierMarketMinutesLeft(market, now, strcmp(market->code, "IN") == 0 ? _indiaHolidays : nil, &holiday);
        AtelierFlagChip *chip = _chips[i];
        chip.open = left >= 0;
        NSString *caption = @"";
        chip.shortCaption = nil;
        if (left >= 0) {
            caption = left >= 60 ? [NSString stringWithFormat:@"%ldh %02ldm", (long)(left / 60), (long)(left % 60)]
                                 : [NSString stringWithFormat:@"%ldm", (long)left];
        } else if (holiday) {                             // closed for a trading holiday: say so, and which if there is room
            caption = holiday.length ? [NSString stringWithFormat:@"Holiday · %@", holiday] : @"Holiday";
            chip.shortCaption = @"Holiday";
        }
        [captions addObject:caption];
    }
    _longCaptions = captions;
    for (AtelierShortcutIcon *icon in _icons) [icon refreshBadge];
    [self quotesChanged];                                 // the "Closed" tag and a number's age move with the minute
    [self setNeedsLayout];
}

#pragma mark layout

- (void)setCompact:(BOOL)compact flagsWidth:(CGFloat)width {
    BOOL changed = compact != _compact;
    _compact = compact;
    _flagsWidth = width;
    if (changed) [self quotesChanged];
    [self setNeedsLayout];
}

- (void)_styleClock {
    CGFloat big = _compact ? 20 : 26, small = _compact ? 12 : 13;
    _hm.font = [UIFont monospacedDigitSystemFontOfSize:big weight:UIFontWeightSemibold];
    // a little tighter than the font's own spacing
    if (_hm.text.length) {
        _hm.attributedText = [[NSAttributedString alloc] initWithString:_hm.text attributes:@{
            NSFontAttributeName: _hm.font, NSKernAttributeName: @(_compact ? -0.4 : -0.7), NSForegroundColorAttributeName: UIColor.whiteColor }];
    }
    _sec.font = [UIFont monospacedDigitSystemFontOfSize:small weight:UIFontWeightSemibold];
    _ampm.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    _date.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat y0 = 0;                                       // the top of the clock's line

    // the index numbers: two lines of their own (Side), or side by side on one (Top, Split)
    if (_showIndices) {
        if (_compact) {
            CGFloat half = floor(W / 2.0);
            _lines[0].frame = CGRectMake(0, 0, half - 4, 16);
            _lines[1].frame = CGRectMake(half, 0, W - half, 16);
            y0 = 16;
        } else {
            _lines[0].frame = CGRectMake(0, 0, W, 14);
            _lines[1].frame = CGRectMake(0, 14, W, 14);
            y0 = 28;
        }
    }

    // shortcut icons (and the "+"), right-aligned on the clock's line
    CGFloat side = _compact ? 24 : 27, pitch = side + (_compact ? 6 : 7), top = y0 + (_compact ? 3 : 0.5);
    NSUInteger n = _icons.count;
    for (NSUInteger i = 0; i < n; i++) _icons[i].frame = CGRectMake(W - side - (n - 1 - i) * pitch, top, side, side);
    CGFloat iconsLeft = n ? W - side - (n - 1) * pitch - 10 : W;

    CGFloat x = 0;
    if (_showClock) {
        [self _styleClock];
        CGSize hm = [_hm sizeThatFits:CGSizeMake(300, 60)];
        CGSize sec = [_sec sizeThatFits:CGSizeMake(100, 40)];
        CGSize ap = [_ampm sizeThatFits:CGSizeMake(60, 20)];
        if (_compact) {
            _hm.frame = CGRectMake(0, y0 + 2, ceil(hm.width), 26);
            _sec.frame = CGRectMake(CGRectGetMaxX(_hm.frame) + 3, y0 + 9, ceil(sec.width), 16);
            _ampm.frame = CGRectMake(CGRectGetMaxX(_sec.frame) + 3, y0 + 11, ceil(ap.width), 13);
            _date.hidden = YES;
            x = (_ampm.text.length ? CGRectGetMaxX(_ampm.frame) : CGRectGetMaxX(_sec.frame)) + 12;
        } else {
            _hm.frame = CGRectMake(0, y0 - 2, ceil(hm.width), 32);
            CGFloat sx = CGRectGetMaxX(_hm.frame) + 5;
            _sec.frame = CGRectMake(sx, y0 + 1, ceil(sec.width), 15);
            _ampm.frame = CGRectMake(CGRectGetMaxX(_sec.frame) + 3, y0 + 3, ceil(ap.width), 12);
            CGSize d = [_date sizeThatFits:CGSizeMake(200, 20)];
            _date.frame = CGRectMake(sx, y0 + 15, ceil(d.width), 13);
            _date.hidden = CGRectGetMaxX(_date.frame) > iconsLeft;          // no room beside the icons: the date goes
        }
    }

    // flags: after the clock on the compact line, or on a row of their own left of the pill
    CGFloat fx = _compact ? x : 0, fy = _compact ? y0 + 4 : y0 + 28;
    CGFloat room = _compact ? iconsLeft - fx : (_flagsWidth > 0 ? _flagsWidth : W);
    // captions in full if the row has room for them, else the short ones ("Holiday" without
    // the holiday's name), else none; the compact line has none
    BOOL captions = NO;
    for (int attempt = 0; attempt < 2 && !_compact && !captions; attempt++) {
        CGFloat total = 0;
        for (NSUInteger i = 0; i < _chips.count; i++) {
            AtelierFlagChip *chip = _chips[i];
            NSString *full = i < _longCaptions.count ? _longCaptions[i] : @"";
            chip.caption.text = (attempt == 1 && chip.shortCaption) ? chip.shortCaption : full;
            CGFloat cw = chip.caption.text.length ? ceil([chip.caption sizeThatFits:CGSizeMake(240, 20)].width) + 5 : 0;
            total += 28 + cw + 8;
        }
        captions = total - 8 <= room;
    }
    for (AtelierFlagChip *chip in _chips) {
        CGFloat cw = (captions && chip.caption.text.length) ? ceil([chip.caption sizeThatFits:CGSizeMake(240, 20)].width) : 0;
        chip.caption.hidden = cw == 0;
        chip.caption.frame = CGRectMake(28 + 5, 0, cw, 22);
        chip.frame = CGRectMake(fx, fy, 28 + (cw ? cw + 5 : 0), 22);
        chip.hidden = CGRectGetMaxX(chip.frame) > (_compact ? iconsLeft : room) + 0.5;      // no room: this flag goes
        fx = CGRectGetMaxX(chip.frame) + 8;
    }
}

#pragma mark tests

- (void)debugTapShortcut:(NSUInteger)index {
    if (index < _icons.count && _icons[index].bundleID) [self _shortcutTapped:_icons[index]];
    else AtelierLog(@"shortcut %lu: there are %lu", (unsigned long)index, (unsigned long)[AtelierBand shownShortcuts].count);
}

- (void)debugHoldShortcut:(NSUInteger)index {
    if (index < _icons.count && _icons[index].bundleID) {
        if (self.onShortcutHeld) self.onShortcutHeld(_icons[index].bundleID, _icons[index].frame);
    } else {
        AtelierLog(@"shortcut %lu: there are %lu", (unsigned long)index, (unsigned long)[AtelierBand shownShortcuts].count);
    }
}

- (void)debugTapPlus {
    if (_icons.count && !_icons.lastObject.bundleID) [self _plusTapped];
    else AtelierLog(@"shortcuts: the row is full, there is no +");
}

- (NSArray<NSDictionary *> *)debugFrames {
    [self layoutIfNeeded];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (_showIndices) for (NSUInteger i = 0; i < _lines.count; i++)
        [out addObject:@{ @"name": [NSString stringWithFormat:@"index%lu", (unsigned long)i], @"frame": [NSValue valueWithCGRect:_lines[i].frame] }];
    if (_showClock) [out addObject:@{ @"name": @"clock", @"frame": [NSValue valueWithCGRect:CGRectUnion(_hm.frame, _sec.frame)] }];
    for (NSUInteger i = 0; i < _chips.count; i++)
        [out addObject:@{ @"name": [NSString stringWithFormat:@"flag%lu", (unsigned long)i], @"frame": [NSValue valueWithCGRect:_chips[i].frame] }];
    NSUInteger k = 0;
    for (AtelierShortcutIcon *icon in _icons)
        [out addObject:@{ @"name": icon.bundleID ? [NSString stringWithFormat:@"shortcut%lu", (unsigned long)k++] : @"shortcut-plus",
                          @"frame": [NSValue valueWithCGRect:icon.frame] }];
    return out;
}

- (NSString *)debugState {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (_showIndices) for (AtelierIndexLine *line in _lines) [parts addObject:[NSString stringWithFormat:@"«%@»", line.said ?: @"?"]];
    if (_showClock) [parts addObject:[NSString stringWithFormat:@"clock %@:%@%@%@ %@", _hm.text ?: @"?", _sec.text ?: @"?",
                                      _ampm.text.length ? @" " : @"", _ampm.text ?: @"", _date.hidden ? @"(no date)" : (_date.text ?: @"")]];
    for (NSUInteger i = 0; i < _chips.count && i < _marketCodes.count; i++) {
        AtelierFlagChip *chip = _chips[i];
        NSString *full = i < _longCaptions.count ? _longCaptions[i] : @"";
        [parts addObject:[NSString stringWithFormat:@"%@ %@%@%@", _marketCodes[i], chip.open ? @"open " : @"closed",
                          chip.open ? full : (full.length ? [NSString stringWithFormat:@" (%@)", full] : @""),
                          chip.caption.hidden ? @"" : [NSString stringWithFormat:@" shows \"%@\"", chip.caption.text ?: @""]]];
    }
    NSMutableArray<NSString *> *icons = [NSMutableArray array];
    for (AtelierShortcutIcon *icon in _icons)
        [icons addObject:icon.bundleID ? [NSString stringWithFormat:@"%@%@", icon.bundleID, icon.badge.hidden ? @"" : [NSString stringWithFormat:@"(%@)", icon.badge.text]] : @"+"];
    [parts addObject:[NSString stringWithFormat:@"shortcuts [%@]", [icons componentsJoinedByString:@" "]]];
    return [NSString stringWithFormat:@"band %@%@ timer %@ · %@", _compact ? @"compact" : @"tall", self.hidden ? @" hidden" : @"",
            _timer ? @"on" : @"off", [parts componentsJoinedByString:@" · "]];
}

@end
