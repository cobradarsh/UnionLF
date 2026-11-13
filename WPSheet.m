/*  WPSheet.m — Wingman Plus reply sheet, shown as a SpringBoard overlay.

    Flow: the bubble captured the screen -> we OCR it on-device -> you pick a
    style -> Claude/DeepSeek writes 3 replies -> tap one to copy it, then paste
    it in the dating app. Settings (API key, "sound like me", which apps show the
    bubble) live behind the gear. Everything runs in SpringBoard; nothing is ever
    injected into the dating app.                                                */

#import "WPlus.h"

NSString *const kWPVersion = @"1.0.25";

// ── palette: the Android Wingman look (purple accent, deep-night sheet / clean light sheet)
static UIColor *WPHex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0 alpha:1];
}
static UIColor *WPDyn(uint32_t dark, uint32_t light) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return WPHex(tc.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light);
    }];
}
#define WP_ACCENT  WPHex(0x7C5CFF)
#define WP_SHEET   WPDyn(0x17171F, 0xFFFFFF)
#define WP_CARD    WPDyn(0x242432, 0xF3F1FA)
#define WP_FIELD   WPDyn(0x1F1F2A, 0xF4F4F8)
#define WP_TEXT    WPDyn(0xF2F2F7, 0x15151C)
#define WP_SUBTEXT WPDyn(0xA3A3B5, 0x6A6A7A)
#define WP_ERROR   WPDyn(0xFF8A80, 0xC62828)
#define WP_OK      WPDyn(0x7BE495, 0x2E7D32)
#define WP_STROKE  [UIColor colorWithRed:0x80/255.0 green:0x80/255.0 blue:0x98/255.0 alpha:0x33/255.0]
static CGFloat const kWPSheetTopPad = 14;

// Two chip sections, like the Android sheet: dating & flirt first (this is a dating tool), then every
// general vibe. A chip's tag is the WMReplyMode value itself.
static WMReplyMode const kWPDatingModes[] = {
    WMReplyModeIcebreaker, WMReplyModePhotoOpener, WMReplyModeReviver,  WMReplyModePhoneConvo,
    WMReplyModePlanDate,   WMReplyModeRomance,     WMReplyModeSeduce,   WMReplyModeStupidLove,
    WMReplyModeHilarify,   WMReplyModeAlphaPower,  WMReplyModeFlirty,   WMReplyModeSensual,
    WMReplyModeLustful,    WMReplyModeDirty
};
static WMReplyMode const kWPGeneralModes[] = {
    WMReplyModeAggressive, WMReplyModeDecentRoast, WMReplyModeRoastedToHell,
    WMReplyModeInMyFavor,  WMReplyModeDefendMe,    WMReplyModeExcuse,   WMReplyModeFunny,
    WMReplyModeGenZ,       WMReplyModeLyrical,     WMReplyModeExcited,  WMReplyModeThankful,
    WMReplyModeWishing,    WMReplyModeFormal,      WMReplyModeChill,    WMReplyModeEmojify,
    WMReplyModeRemix,      WMReplyModeFacts,       WMReplyModeBackhand
};
static NSInteger const kWPDatingCount  = sizeof(kWPDatingModes)/sizeof(kWPDatingModes[0]);
static NSInteger const kWPGeneralCount = sizeof(kWPGeneralModes)/sizeof(kWPGeneralModes[0]);

// Photo Opener sub-styles — a little sub-menu under the vibe when Photo Opener is picked.
// The brief is appended to the Photo Opener prompt via WMSettings.photoStyleExtra.
static NSString *const kWPPhotoStyleLabels[] = {
    @"Combination", @"Classy", @"Bold", @"Flirty", @"Cheeky", @"Story", @"Witty"
};
static NSInteger const kWPPhotoStyleCount = sizeof(kWPPhotoStyleLabels)/sizeof(kWPPhotoStyleLabels[0]);
static NSString *WPPhotoStyleBrief(NSInteger i) {
    switch (i) {
        case 1: return @"FLAVOUR — refined and eloquent: a rare, considered line with real finesse, the "
                        "kind a well-read man with taste would say. Appreciate her beauty with elegance "
                        "and a touch of poetry, never cliche.";
        case 2: return @"FLAVOUR — bold and alpha: confidently admire her figure and the way she carries "
                        "herself in that shot, a little daring, owning the compliment with magnetic "
                        "self-assurance. Tasteful and adult, never crude, creepy or objectifying.";
        case 3: return @"FLAVOUR — flirty and teasing: playful flirtation with a little tease that makes "
                        "her grin, charged and fun, with an easy hook for her to reply to.";
        case 4: return @"FLAVOUR — cheeky: a playful accusation, a mock complaint or a confident cold "
                        "read about her from the photo ('you're definitely the one who...'), push-pull "
                        "that teases her a little while making it obvious I'm into her.";
        case 5: return @"FLAVOUR — story spin: turn the photo into a tiny scene or a playful 'what "
                        "happens next' that puts me in the picture with her, a mini adventure she'll "
                        "want to add to.";
        case 6: return @"FLAVOUR — witty: clever wordplay, a sharp one-liner or the perfect caption for "
                        "her photo, smart and funny, with the flirt riding on the wit.";
        default: return @"FLAVOUR — the full blend: a sharp observation of the scene, genuine "
                        "appreciation of HER and how she carries herself in it, and a flirty twist or "
                        "tease to finish. Well beyond what an average guy sends ('you look "
                        "beautiful'); make it the line she can't leave on read.";
    }
}

static UIWindow *gWPWindow;   // strong ref so the overlay isn't deallocated while up

// The sheet belongs to the app it was opened over. Once that app leaves the front (home screen, app switcher,
// another app, the lock screen) the sheet closes itself; up to 1.0.24 it stayed up over whatever came next.
// Two misses in a row are needed, so one odd answer from SpringBoard can't close it.
static NSTimeInterval const kWPHostCheckSeconds = 0.3;

// A key-capable window: a plain overlay UIWindow in SpringBoard won't bring up the
// keyboard. canBecomeKeyWindow + makeKeyAndVisible makes it key, and WPFocus asks
// SpringBoard for keyboard focus while the sheet is up (without that the app in front
// keeps the keyboard). The clipboard "Paste" buttons stay as a fallback.
@interface WPSheetWindow : UIWindow
@end
@implementation WPSheetWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

// Ask SpringBoard for keyboard focus on the next run-loop turn, once the sheet window is
// really on screen; skipped if the sheet was closed or hidden again in the meantime.
static void WPTakeKeyboardSoon(void) {
    UIWindow *w = gWPWindow;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (w && gWPWindow == w && !w.hidden) [WPFocus takeKeyboardForWindow:w];
    });
}

#pragma mark - app picker

@interface WPAppPickerVC : UITableViewController
@end
@implementation WPAppPickerVC {
    NSArray<NSDictionary *> *_apps;
    NSArray<NSString *> *_recent;          // exact bundle ids SpringBoard recently reported in front
    NSMutableSet<NSString *> *_chosen;
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Show bubble over…";
    _apps = [WPHost installedApps];
    _recent = [WPHost recentFrontmostApps];
    _chosen = [NSMutableSet setWithArray:[WMSettings shared].manualApps];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(_done)];
}
- (void)_done {
    [[WMSettings shared] setValue:_chosen.allObjects forSettingKey:@"manualApps"];
    // Your picks ADD to the built-in chat/dating list. (This used to switch auto-detection OFF, so picking
    // one extra app silently hid the bubble everywhere else.)
    [[WMSettings shared] setValue:@YES forSettingKey:@"autoDetectApps"];
    [self.navigationController popViewControllerAnimated:YES];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Recently in front" : @"All apps";
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s != 0) return @"A grey tick means the bubble already shows there by itself.";
    return _recent.count
        ? @"Exactly as SpringBoard reports them. If an app doesn't get the bubble, open it, come back here and tick it in this list: that works whatever its bundle ID is (TrollStore and dual builds often have unusual ones)."
        : @"Nothing yet. Open the app once, then come back here and tick it.";
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return s == 0 ? _recent.count : _apps.count; }
- (NSString *)_bidAt:(NSIndexPath *)ip { return ip.section == 0 ? _recent[ip.row] : _apps[ip.row][@"id"]; }
- (NSString *)_nameFor:(NSString *)bid {
    for (NSDictionary *a in _apps) if ([a[@"id"] isEqualToString:bid]) return a[@"name"];
    return bid;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *bid = [self _bidAt:ip];
    BOOL picked = [_chosen containsObject:bid];
    WMAppKind kind = [WMApps kindForBundleID:bid];
    BOOL builtIn = !picked && (kind == WMAppKindChat || kind == WMAppKindDating);
    c.textLabel.text = [self _nameFor:bid];
    c.detailTextLabel.text = builtIn ? [bid stringByAppendingString:@"   ·  built-in"] : bid;
    c.detailTextLabel.textColor = WP_SUBTEXT;
    c.accessoryType = (picked || builtIn) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.tintColor = builtIn ? WP_SUBTEXT : WP_ACCENT;      // grey tick = on by itself, purple = your pick
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *bid = [self _bidAt:ip];
    if ([_chosen containsObject:bid]) [_chosen removeObject:bid]; else [_chosen addObject:bid];
    [t reloadData];                       // the same app can appear in both sections
    [t deselectRowAtIndexPath:ip animated:YES];
}
@end

#pragma mark - settings

@interface WPSettingsVC : UIViewController <UITextFieldDelegate, UITextViewDelegate>
@end
@implementation WPSettingsVC {
    UISegmentedControl *_provider;
    UITextField *_key, *_city;
    UITextView  *_style;
    UILabel     *_status, *_model;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = WP_SHEET;
    WMSettings *s = [WMSettings shared]; [s reload];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sc.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sc.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    sc.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:sc];
    CGFloat W = self.view.bounds.size.width, m = 16, y = 16;

    _provider = [[UISegmentedControl alloc] initWithItems:@[@"Claude", @"DeepSeek", @"Kimi"]];
    _provider.frame = CGRectMake(m, y, W-2*m, 34);
    _provider.selectedSegmentIndex = (NSInteger)s.provider;
    [_provider addTarget:self action:@selector(_providerChanged) forControlEvents:UIControlEventValueChanged];
    [sc addSubview:_provider]; y += 48;

    _key = [[UITextField alloc] initWithFrame:CGRectMake(m, y, W-2*m, 40)];
    _key.borderStyle = UITextBorderStyleRoundedRect;
    _key.placeholder = @"Paste API key";
    _key.secureTextEntry = YES; _key.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _key.autocorrectionType = UITextAutocorrectionTypeNo; _key.delegate = self;
    _key.text = [s keyForProvider:s.provider];
    [sc addSubview:_key]; y += 48;

    // The keyboard is unreliable in a SpringBoard overlay, so offer a no-keyboard
    // path: copy the key anywhere (e.g. Notes), then tap this to paste it in.
    UIButton *paste = [UIButton buttonWithType:UIButtonTypeSystem];
    paste.frame = CGRectMake(m, y, W-2*m, 36);
    paste.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [paste setTitle:@"📋  Paste key from clipboard" forState:UIControlStateNormal];
    [paste addTarget:self action:@selector(_pasteKey) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:paste]; y += 44;

    UIButton *verify = [UIButton buttonWithType:UIButtonTypeSystem];
    verify.frame = CGRectMake(m, y, W-2*m, 40);
    verify.backgroundColor = WP_ACCENT;
    [verify setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    verify.layer.cornerRadius = 8;
    [verify setTitle:@"Save & verify key" forState:UIControlStateNormal];
    [verify addTarget:self action:@selector(_verify) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:verify]; y += 48;

    _model = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 20)];
    _model.font = [UIFont systemFontOfSize:13]; _model.textColor = WP_SUBTEXT;
    _model.text = [NSString stringWithFormat:@"Model: %@", [s modelForProvider:s.provider]];
    [sc addSubview:_model]; y += 28;

    _status = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 20)];
    _status.font = [UIFont systemFontOfSize:13]; _status.textColor = WP_SUBTEXT;
    [sc addSubview:_status]; y += 28;

    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 20)];
    sl.text = @"Sound like me (optional)"; sl.font = [UIFont boldSystemFontOfSize:14];
    [sc addSubview:sl]; y += 26;
    _style = [[UITextView alloc] initWithFrame:CGRectMake(m, y, W-2*m, 80)];
    _style.layer.borderColor = WP_STROKE.CGColor; _style.layer.borderWidth = 1;
    _style.layer.cornerRadius = 8; _style.font = [UIFont systemFontOfSize:15];
    _style.text = s.soundLikeMe;
    [sc addSubview:_style]; y += 92;

    UILabel *cl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 20)];
    cl.text = @"My city (optional, for Phone Convo's local news)"; cl.font = [UIFont boldSystemFontOfSize:14];
    [sc addSubview:cl]; y += 26;
    _city = [[UITextField alloc] initWithFrame:CGRectMake(m, y, W-2*m, 40)];
    _city.borderStyle = UITextBorderStyleRoundedRect;
    _city.placeholder = @"The city you live in";
    _city.autocorrectionType = UITextAutocorrectionTypeNo; _city.delegate = self;
    _city.text = s.myCity;
    [sc addSubview:_city]; y += 52;

    UIButton *apps = [UIButton buttonWithType:UIButtonTypeSystem];
    apps.frame = CGRectMake(m, y, W-2*m, 40);
    [apps setTitle:@"Choose apps that show the bubble…" forState:UIControlStateNormal];
    apps.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [apps addTarget:self action:@selector(_pickApps) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:apps]; y += 48;

    sc.contentSize = CGSizeMake(W, y + 20);

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(_save)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];   // the sheet hides it
}
- (void)_providerChanged {
    WMSettings *s = [WMSettings shared];
    WMAPIProvider p = [self _p];
    [s saveProvider:p];                 // the segmented control IS the active-provider picker
    _key.text = [s keyForProvider:p];
    _model.text = [NSString stringWithFormat:@"Model: %@", [s modelForProvider:p]];
    _status.text = @"";
}
- (void)_pasteKey {
    NSString *c = [[UIPasteboard generalPasteboard].string
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (c.length) {
        _key.text = c;
        _status.textColor = WP_SUBTEXT;
        _status.text = @"Pasted. Now tap Save & verify key.";
    } else {
        _status.textColor = WP_ERROR;
        _status.text = @"Clipboard empty — copy your key (e.g. in Notes) first.";
    }
}
- (WMAPIProvider)_p { return (WMAPIProvider)_provider.selectedSegmentIndex; }
- (void)_verify {
    [_key resignFirstResponder];
    WMAPIProvider p = [self _p];
    WMSettings *s = [WMSettings shared];
    [s saveProvider:p];
    [s saveKey:_key.text forProvider:p];
    _status.textColor = WP_SUBTEXT;
    _status.text = @"Verifying…";
    [WMModels fetchForProvider:p force:YES completion:^(NSArray<NSDictionary *> *models, NSError *err) {
        if (err || models.count == 0) {
            self->_status.textColor = WP_ERROR;
            self->_status.text = err ? err.localizedDescription : @"No models returned.";
            return;
        }
        // auto-pick the first model if none chosen yet
        if (![s hasChosenModelForProvider:p]) [s saveModel:models.firstObject[@"id"] forProvider:p];
        self->_status.textColor = WP_OK;
        self->_status.text = [NSString stringWithFormat:@"Key OK — %lu models.", (unsigned long)models.count];
        self->_model.text = [NSString stringWithFormat:@"Model: %@", [s modelForProvider:p]];
        [self _pickModel:models provider:p];
    }];
}
- (void)_pickModel:(NSArray<NSDictionary *> *)models provider:(WMAPIProvider)p {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Choose model" message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger n = 0;
    for (NSDictionary *mdl in models) {
        if (n++ > 12) break;
        [ac addAction:[UIAlertAction actionWithTitle:mdl[@"name"] style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [[WMSettings shared] saveModel:mdl[@"id"] forProvider:p];
            self->_model.text = [NSString stringWithFormat:@"Model: %@", mdl[@"id"]];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Keep current" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = _model;
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)_pickApps { [self.navigationController pushViewController:[WPAppPickerVC new] animated:YES]; }
- (void)_save {
    WMSettings *s = [WMSettings shared];
    [s saveProvider:[self _p]];
    [s saveKey:_key.text forProvider:[self _p]];
    [s setValue:(_style.text ?: @"") forSettingKey:@"soundLikeMe"];
    [s setValue:(_city.text ?: @"") forSettingKey:@"myCity"];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - main sheet

@interface WPSheet () <UIGestureRecognizerDelegate, UITextViewDelegate>
@property (nonatomic, strong) NSMutableArray<UIImage *> *frames;
@property (nonatomic) WMReplyMode mode;
@property (nonatomic) WMReplyLength length;
@property (nonatomic) NSInteger photoStyle;                       // Photo Opener sub-style
@property (nonatomic, strong) NSMutableArray<NSString *> *allReplies;  // accumulated, newest first
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *results;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *genBtn;
@property (nonatomic, strong) NSArray<UIButton *> *chips;
@property (nonatomic, strong) NSArray<UIButton *> *photoChips;
@property (nonatomic, strong) UIView *sheet;                           // the bottom sheet itself
@property (nonatomic, strong) UIButton *shortChip, *longChip;
@property (nonatomic) BOOL appeared, animatingIn;
@property (nonatomic) CGFloat builtWidth;
@property (nonatomic) CGRect lastBounds;
@property (nonatomic, strong) UITextView *contextBox;                  // optional situation / what I want to say
@property (nonatomic, strong) UILabel *contextHint;
@property (nonatomic, copy)   NSString *contextText;                   // survives _rebuild (chip taps rebuild)
@property (nonatomic) CGFloat kbHeight;                                // keyboard overlap while typing context
@property (nonatomic, copy)   NSString *hostApp;                       // bundle id of the app the sheet opened over
@property (nonatomic, strong) NSTimer *hostTimer;                      // watches that app stays in front
@property (nonatomic) NSInteger hostMisses;
@property (nonatomic, strong) NSMutableSet<NSString *> *noteReplies;   // Phone Convo cards: copy without closing
@end

@implementation WPSheet

- (instancetype)initWithImage:(UIImage *)shot {
    if ((self = [super init])) {
        _frames = shot ? [NSMutableArray arrayWithObject:shot] : [NSMutableArray array];
        _allReplies = [NSMutableArray array];
        _noteReplies = [NSMutableSet set];
        _mode = WMReplyModeIcebreaker;
        _length = WMReplyLengthShort;
        _photoStyle = 0;   // Combination
    }
    return self;
}
- (void)appendImage:(UIImage *)shot { if (shot) [_frames addObject:shot]; }

- (void)presentGlobally {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self];
    // Same iOS 13+ rule as the bubble: a UIWindow only renders when it belongs to a foreground
    // UIWindowScene. It has to be SpringBoard's main scene, the only one keyboard focus can lock to.
    UIWindowScene *scene = [WPHost mainScene];
    gWPWindow = scene ? [[WPSheetWindow alloc] initWithWindowScene:scene]
                      : [[WPSheetWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gWPWindow.frame = [UIScreen mainScreen].bounds;
    gWPWindow.windowLevel = 100001;                 // just above the bubble
    gWPWindow.rootViewController = nav;
    [gWPWindow makeKeyAndVisible];
    WPTakeKeyboardSoon();                            // so the context and key boxes get a keyboard
    [self _watchHostApp];
}

- (void)_watchHostApp {
    [_hostTimer invalidate];
    _hostTimer = nil;
    _hostMisses = 0;
    _hostApp = [WPHost frontmostBundleID];
    if (_hostApp.length == 0) return;                // opened over nothing we can name: the user closes it
    __weak typeof(self) ws = self;
    _hostTimer = [NSTimer scheduledTimerWithTimeInterval:kWPHostCheckSeconds repeats:YES block:^(NSTimer *t) {
        WPSheet *sheet = ws;
        if (sheet) [sheet _checkHostApp]; else [t invalidate];
    }];
}

// Also runs while the sheet is hidden for "Add another screen": leaving the app ends that capture too.
- (void)_checkHostApp {
    if (!gWPWindow || gWPWindow.rootViewController != self.navigationController) {   // a newer sheet took over
        [_hostTimer invalidate];
        _hostTimer = nil;
        return;
    }
    if ([[WPHost frontmostBundleID] isEqualToString:_hostApp]) { _hostMisses = 0; return; }
    if (++_hostMisses >= 2) [self _close];
}

- (void)_close {
    [_hostTimer invalidate];
    _hostTimer = nil;
    [gWPWindow endEditing:YES];
    [WPFocus giveKeyboardBack];                      // the app in front gets its keyboard back
    gWPWindow.hidden = YES;
    gWPWindow = nil;                                 // let it deallocate
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // A bottom sheet over a dimmed view of the app, like the Android version: the dating app stays
    // visible behind it, and a tap outside the sheet closes it.
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.navigationController.view.backgroundColor = UIColor.clearColor;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_close)];
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];

    _sheet = [[UIView alloc] initWithFrame:CGRectZero];
    _sheet.backgroundColor = WP_SHEET;
    _sheet.layer.cornerRadius = 26;
    _sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _sheet.clipsToBounds = YES;
    [self.view addSubview:_sheet];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    [_sheet addSubview:_scroll];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_kbChange:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    [self _rebuild];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

// only taps on the dimmed backdrop close the sheet, never taps inside it
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isDescendantOfView:_sheet];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];   // the sheet draws its own header
    // returning from settings: refresh the "add key" hint / button state
    [[WMSettings shared] reload];
    [self _rebuild];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_appeared) return;
    _appeared = YES;
    // slide up from the bottom edge
    CGRect end = _sheet.frame;
    _sheet.frame = CGRectOffset(end, 0, end.size.height);
    _animatingIn = YES;
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self->_sheet.frame = end; }
                     completion:^(BOOL done) { self->_animatingIn = NO; }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (CGRectEqualToRect(self.view.bounds, _lastBounds)) return;
    _lastBounds = self.view.bounds;
    // first real layout (bounds were empty in viewDidLoad) or a rotation: chip wrapping depends on the width
    if (fabs(self.view.bounds.size.width - _builtWidth) > 0.5) [self _rebuild];
    else [self _layoutSheet:NO];
}

- (void)_settings { [self.navigationController pushViewController:[WPSettingsVC new] animated:YES]; }

- (NSString *)_genTitle {
    if (_mode == WMReplyModeIcebreaker) return @"Write icebreaker";
    if (_mode == WMReplyModePhoneConvo) return @"Plan my call";
    return @"Write 3 replies";
}

- (void)_addScreen { [[WPBubble shared] beginAppendTo:self]; }

- (void)dismissForAppend {
    [gWPWindow endEditing:YES];
    [WPFocus giveKeyboardBack];      // the app is used while the sheet is hidden
    gWPWindow.hidden = YES;
}
- (void)reshowAfterAppend {
    gWPWindow.hidden = NO;
    [gWPWindow makeKeyAndVisible];
    WPTakeKeyboardSoon();
    [self _rebuild];                 // refresh the captured-screen count
}

- (void)_rebuild {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    CGFloat W = self.view.bounds.size.width, m = 20, y = 2;
    _builtWidth = W;
    if (W < 1) return;
    WMSettings *s = [WMSettings shared];
    BOOL hasKey = [s keyForProvider:s.provider].length > 0;
    NSString *providerName = @[@"Claude", @"DeepSeek", @"Kimi"][MIN((NSUInteger)s.provider, (NSUInteger)2)];

    // ── header: 🪽 Wingman · provider chip (opens settings) · ✕
    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
    [x setTitle:@"✕" forState:UIControlStateNormal];
    [x setTitleColor:WP_SUBTEXT forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:20];
    x.frame = CGRectMake(W - m - 24, y, 32, 36);
    [x addTarget:self action:@selector(_close) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:x];

    UIButton *prov = [self _makeChip:providerName size:14];
    [self _styleChip:prov selected:NO];
    [prov addTarget:self action:@selector(_settings) forControlEvents:UIControlEventTouchUpInside];
    prov.frame = CGRectMake(CGRectGetMinX(x.frame) - 6 - prov.bounds.size.width, y, prov.bounds.size.width, 36);
    [_scroll addSubview:prov];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(m, y, CGRectGetMinX(prov.frame) - m - 8, 36)];
    title.text = @"🪽  Wingman";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textColor = WP_TEXT;
    [_scroll addSubview:title];
    y += 44;

    // ── what was captured
    UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 18)];
    cap.font = [UIFont systemFontOfSize:13];
    cap.textColor = hasKey ? WP_SUBTEXT : WP_ERROR;
    cap.numberOfLines = 2;
    cap.text = hasKey
        ? [NSString stringWithFormat:@"%lu screen%@ captured. For a whole profile, add screens top to bottom.",
           (unsigned long)_frames.count, _frames.count == 1 ? @"" : @"s"]
        : [NSString stringWithFormat:@"Tap %@ above to add your API key first.", providerName];
    CGSize cs = [cap sizeThatFits:CGSizeMake(W-2*m, 60)];
    cap.frame = CGRectMake(m, y, W-2*m, MAX(18, cs.height));
    [_scroll addSubview:cap];
    y += cap.frame.size.height + 10;

    // thumbnails of every captured screen, so you can see what Wingman is reading
    if (_frames.count) {
        CGFloat th = 100, tx = 0;
        UIScrollView *strip = [[UIScrollView alloc] initWithFrame:CGRectMake(m, y, W-2*m, th)];
        strip.showsHorizontalScrollIndicator = NO;
        for (UIImage *f in _frames) {
            CGFloat ratio = (f.size.width > 0 && f.size.height > 0) ? (f.size.width / f.size.height) : 0.46;
            UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(tx, 0, th * ratio, th)];
            iv.image = f; iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.backgroundColor = WP_FIELD; iv.clipsToBounds = YES; iv.layer.cornerRadius = 10;
            [strip addSubview:iv];
            tx += th * ratio + 8;
        }
        strip.contentSize = CGSizeMake(tx, th);
        [_scroll addSubview:strip];
        y += th + 12;
    }

    // ── actions
    UIButton *add = [self _makeChip:@"➕  Add another screen" size:14];
    [self _styleChip:add selected:NO];
    [add addTarget:self action:@selector(_addScreen) forControlEvents:UIControlEventTouchUpInside];
    add.frame = CGRectMake(m, y, add.bounds.size.width, 36);
    [_scroll addSubview:add];
    y += 36 + 14;

    // ── context (optional): the situation for Defend Me / In My Favor / Wishing, or anything I want said.
    // The keyboard can be flaky in a SpringBoard overlay, so there's a Paste button too.
    CGFloat pasteW = 92;
    _contextBox = [[UITextView alloc] initWithFrame:CGRectMake(m, y, W - 2*m - 8 - pasteW, 44)];
    _contextBox.backgroundColor = WP_FIELD;
    _contextBox.layer.cornerRadius = 12;
    _contextBox.font = [UIFont systemFontOfSize:14];
    _contextBox.textColor = WP_TEXT;
    _contextBox.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    _contextBox.delegate = self;
    _contextBox.text = _contextText ?: @"";
    [_scroll addSubview:_contextBox];
    _contextHint = [[UILabel alloc] initWithFrame:CGRectMake(m + 15, y, W - 2*m - 8 - pasteW - 30, 44)];
    _contextHint.text = @"Context (optional): the situation, what I want to say…";
    _contextHint.font = [UIFont systemFontOfSize:14];
    _contextHint.textColor = WP_SUBTEXT;
    _contextHint.userInteractionEnabled = NO;
    _contextHint.hidden = _contextBox.text.length > 0;
    [_scroll addSubview:_contextHint];
    UIButton *paste = [self _makeChip:@"📋 Paste" size:13];
    [self _styleChip:paste selected:NO];
    [paste addTarget:self action:@selector(_pasteContext) forControlEvents:UIControlEventTouchUpInside];
    paste.frame = CGRectMake(W - m - pasteW, y + 4, pasteW, 36);
    [_scroll addSubview:paste];
    y += 44 + 14;

    // ── length
    y = [self _sectionLabel:@"How long?" at:y width:W];
    _shortChip = [self _makeChip:@"Short" size:14];
    _longChip  = [self _makeChip:@"Longer" size:14];
    [_shortChip addTarget:self action:@selector(_pickShort) forControlEvents:UIControlEventTouchUpInside];
    [_longChip  addTarget:self action:@selector(_pickLong)  forControlEvents:UIControlEventTouchUpInside];
    _shortChip.frame = CGRectMake(m, y, _shortChip.bounds.size.width, 36);
    _longChip.frame  = CGRectMake(CGRectGetMaxX(_shortChip.frame) + 8, y, _longChip.bounds.size.width, 36);
    [self _styleLength];
    [_scroll addSubview:_shortChip];
    [_scroll addSubview:_longChip];
    y += 36 + 14;

    // ── vibes: two wrapping grids so every vibe is visible at once (no horizontal scrolling)
    NSMutableArray *chips = [NSMutableArray array];
    y = [self _chipSection:@"Dating & flirt" modes:kWPDatingModes count:kWPDatingCount at:y width:W into:chips];
    y = [self _chipSection:@"Pick a vibe"    modes:kWPGeneralModes count:kWPGeneralCount at:y width:W into:chips];
    _chips = chips;
    CGFloat gap = 8;

    // ── Photo Opener sub-style, only when Photo Opener is picked
    _photoChips = nil;
    if (_mode == WMReplyModePhotoOpener) {
        y = [self _sectionLabel:@"Photo style" at:y width:W];
        CGFloat px = m, py = y, rowH2 = 32;
        NSMutableArray *pchips = [NSMutableArray array];
        for (NSInteger i = 0; i < kWPPhotoStyleCount; i++) {
            UIButton *b = [self _makeChip:kWPPhotoStyleLabels[i] size:13];
            b.tag = i;
            [b addTarget:self action:@selector(_photoChip:) forControlEvents:UIControlEventTouchUpInside];
            CGFloat w = b.bounds.size.width;
            if (px + w > W - m && px > m) { px = m; py += rowH2 + gap; }
            b.frame = CGRectMake(px, py, w, rowH2);
            b.layer.cornerRadius = rowH2 / 2;
            [self _styleChip:b selected:(i == _photoStyle)];
            [_scroll addSubview:b];
            [pchips addObject:b];
            px += w + gap;
        }
        _photoChips = pchips;
        y = py + rowH2 + 14;
    }

    // ── generate
    _genBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _genBtn.frame = CGRectMake(m, y, W-2*m, 48);
    _genBtn.backgroundColor = WP_ACCENT;
    [_genBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _genBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    _genBtn.layer.cornerRadius = 24;
    [_genBtn setTitle:[self _genTitle] forState:UIControlStateNormal];
    [_genBtn addTarget:self action:@selector(_generate) forControlEvents:UIControlEventTouchUpInside];
    _genBtn.enabled = hasKey;
    _genBtn.alpha = hasKey ? 1 : 0.5;
    [_scroll addSubview:_genBtn];
    y += 56;

    _status = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 34)];
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = WP_SUBTEXT;
    _status.numberOfLines = 2;
    _status.text = [NSString stringWithFormat:@"%@ · Wingman Plus %@", providerName, kWPVersion];
    [_scroll addSubview:_status];
    y += 38;

    _results = [[UIView alloc] initWithFrame:CGRectMake(0, y, W, 0)];
    [_scroll addSubview:_results];
    _scroll.contentSize = CGSizeMake(W, y + 8);
    if (_allReplies.count) [self _showReplies:_allReplies];   // keep accumulated replies on screen
    else [self _layoutSheet:NO];
}

// pill chip sized to its title (Android: 14sp, 14x9 padding, radius 20)
- (UIButton *)_makeChip:(NSString *)t size:(CGFloat)size {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    [b sizeToFit];
    b.bounds = CGRectMake(0, 0, ceil(b.bounds.size.width) + 28, 36);
    b.layer.cornerRadius = 18;
    return b;
}

- (CGFloat)_sectionLabel:(NSString *)t at:(CGFloat)y width:(CGFloat)W {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, y, W - 40, 16)];
    l.text = t;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    l.textColor = WP_SUBTEXT;
    [_scroll addSubview:l];
    return y + 22;
}

- (void)_styleChip:(UIButton *)b selected:(BOOL)sel {
    b.backgroundColor = sel ? WP_ACCENT : WP_CARD;
    [b setTitleColor:(sel ? UIColor.whiteColor : WP_TEXT) forState:UIControlStateNormal];
    b.layer.borderWidth = sel ? 0 : 1;
    b.layer.borderColor = WP_STROKE.CGColor;
}
- (void)_styleLength {
    [self _styleChip:_shortChip selected:(_length == WMReplyLengthShort)];
    [self _styleChip:_longChip  selected:(_length == WMReplyLengthLong)];
}
- (void)_pickShort { _length = WMReplyLengthShort; [self _styleLength]; }
- (void)_pickLong  { _length = WMReplyLengthLong;  [self _styleLength]; }

// One labelled, wrapping grid of vibe chips. Returns the y below it.
- (CGFloat)_chipSection:(NSString *)title modes:(const WMReplyMode *)modes count:(NSInteger)n
                     at:(CGFloat)y width:(CGFloat)W into:(NSMutableArray *)chips {
    CGFloat m = 20, rowH = 36, gap = 8;
    y = [self _sectionLabel:title at:y width:W];
    CGFloat cx = m, cy = y;
    for (NSInteger i = 0; i < n; i++) {
        WMReplyMode md = modes[i];
        NSString *t = [NSString stringWithFormat:@"%@ %@", [WMPrompts emojiForMode:md], [WMPrompts labelForMode:md]];
        UIButton *b = [self _makeChip:t size:14];
        b.tag = md;
        [b addTarget:self action:@selector(_chip:) forControlEvents:UIControlEventTouchUpInside];
        CGFloat w = b.bounds.size.width;
        if (cx + w > W - m && cx > m) { cx = m; cy += rowH + gap; }   // wrap to the next row
        b.frame = CGRectMake(cx, cy, w, rowH);
        [self _styleChip:b selected:(md == _mode)];
        [_scroll addSubview:b];
        [chips addObject:b];
        cx += w + gap;
    }
    return cy + rowH + 14;
}

- (void)textViewDidChange:(UITextView *)tv {
    _contextText = tv.text;
    _contextHint.hidden = tv.text.length > 0;
}

- (void)_pasteContext {
    NSString *c = [[UIPasteboard generalPasteboard].string
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!c.length) {
        _status.textColor = WP_ERROR;
        _status.text = @"Clipboard is empty — copy the context first.";
        return;
    }
    _contextText = c;
    _contextBox.text = c;
    _contextHint.hidden = YES;
    _status.textColor = WP_SUBTEXT;
    _status.text = @"Context pasted.";
}

// Keep the context box reachable above the keyboard: the overlap becomes extra scroll inset.
- (void)_kbChange:(NSNotification *)n {
    CGRect end = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self.view convertRect:end fromView:nil];
    BOOL hidden = CGRectGetMinY(inView) >= CGRectGetMaxY(self.view.bounds) - 1;
    _kbHeight = hidden ? 0 : MAX(0, CGRectGetMaxY(_sheet.frame) - CGRectGetMinY(inView));
    [self _layoutSheet:NO];
    if (_kbHeight > 0 && _contextBox)
        [_scroll scrollRectToVisible:CGRectInset(_contextBox.frame, 0, -40) animated:YES];
}

// Size the sheet to its content: grows as replies arrive, capped at 88% of the screen (then scrolls).
- (void)_layoutSheet:(BOOL)animated {
    if (_animatingIn) return;
    CGRect b = self.view.bounds;
    if (b.size.width < 1) return;
    CGFloat bottomSafe = self.view.safeAreaInsets.bottom;
    CGFloat maxH = floor(b.size.height * 0.88);
    CGFloat want = kWPSheetTopPad + _scroll.contentSize.height + bottomSafe + 8;
    CGFloat h = MIN(maxH, MAX(want, 240));
    CGRect f = CGRectMake(0, b.size.height - h, b.size.width, h);
    _scroll.contentInset = UIEdgeInsetsMake(0, 0, bottomSafe + 8 + _kbHeight, 0);
    void (^apply)(void) = ^{
        self->_sheet.frame = f;
        self->_scroll.frame = CGRectMake(0, kWPSheetTopPad, f.size.width, f.size.height - kWPSheetTopPad);
    };
    if (animated && !CGRectEqualToRect(_sheet.frame, f))
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:apply completion:nil];
    else apply();
}

// New replies may start below the fold of a capped sheet: scroll them into view once it has resized.
- (void)_revealResults {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGFloat maxOff = MAX(0, self->_scroll.contentSize.height + self->_scroll.contentInset.bottom
                                - self->_scroll.bounds.size.height);
        CGFloat target = MIN(maxOff, MAX(0, self->_results.frame.origin.y - 56));
        [self->_scroll setContentOffset:CGPointMake(0, target) animated:YES];
    });
}

- (void)_chip:(UIButton *)b {
    _mode = (WMReplyMode)b.tag;
    [self _rebuild];                 // re-render so the Photo Opener sub-menu shows/hides
}
- (void)_photoChip:(UIButton *)b {
    _photoStyle = b.tag;
    for (UIButton *c in _photoChips) [self _styleChip:c selected:(c.tag == _photoStyle)];
}
- (void)_len:(UISegmentedControl *)s { _length = s.selectedSegmentIndex == 1 ? WMReplyLengthLong : WMReplyLengthShort; }

#pragma mark - generate

- (void)_generate {
    WMSettings *s = [WMSettings shared];
    if ([s keyForProvider:s.provider].length == 0) { [self _settings]; return; }
    [self.view endEditing:YES];
    _genBtn.enabled = NO; _genBtn.alpha = 0.5;
    _status.textColor = WP_SUBTEXT;
    _status.text = @"Reading the screen…";

    // the photo sub-style only applies to Photo Opener (cleared otherwise)
    [WMSettings shared].photoStyleExtra =
        (_mode == WMReplyModePhotoOpener) ? WPPhotoStyleBrief(_photoStyle) : nil;

    NSArray<UIImage *> *frames = [_frames copy];
    WMReplyMode mode = _mode;                        // chips stay tappable while this batch is written
    BOOL notes = [WMPrompts isTalkingPointsMode:mode];
    // Claude / Kimi see the frames themselves, so the OCR text is only a ME/THEM hint there: use Vision's
    // fast recognizer (several times quicker on a multi-screen capture). DeepSeek is text-only: accurate.
    BOOL fastOCR = (s.provider != WMAPIProviderDeepSeek) && frames.count > 0;
    [WMOCR transcriptFromFrames:frames fast:fastOCR completion:^(NSString *transcript, NSInteger count) {
        NSString *busy = @"Writing replies…";
        if (s.provider == WMAPIProviderClaude && notes) busy = @"Checking what's on near you…";
        else if (s.provider == WMAPIProviderClaude && mode == WMReplyModeHilarify) busy = @"Finding fresh local material…";
        self->_status.text = busy;
        @try {
            [[WMAPIClient shared] generateRepliesWithProvider:s.provider
                                                       frames:frames
                                                   transcript:transcript ?: @""
                                                      context:(self->_contextText ?: @"")
                                                         mode:mode
                                                       length:self->_length
                                                   completion:^(NSArray<NSString *> *replies, NSError *err) {
                self->_genBtn.enabled = YES; self->_genBtn.alpha = 1;
                if (err || replies.count == 0) {
                    self->_status.textColor = WP_ERROR;
                    self->_status.text = err ? err.localizedDescription : @"No replies — try again.";
                    return;
                }
                if (notes) [self->_noteReplies addObjectsFromArray:replies];
                self->_status.textColor = WP_SUBTEXT;
                self->_status.text = notes ? @"Tap a card to copy it for the call." : @"Tap a reply to copy it.";
                if (!self->_allReplies) self->_allReplies = [NSMutableArray array];
                // newest batch on top, older replies kept below
                [self->_allReplies insertObjects:replies
                    atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, replies.count)]];
                while (self->_allReplies.count > 30) [self->_allReplies removeLastObject];
                [self _showReplies:self->_allReplies];
                [self _revealResults];
            }];
        } @catch (id e) {
            self->_genBtn.enabled = YES; self->_genBtn.alpha = 1;
            self->_status.textColor = WP_ERROR;
            self->_status.text = @"Something went wrong generating. Try again.";
        }
    }];
}

- (void)_showReplies:(NSArray<NSString *> *)replies {
    for (UIView *v in _results.subviews) [v removeFromSuperview];
    CGFloat W = self.view.bounds.size.width, m = 20, y = 0;
    for (NSString *r in replies) {
        CGFloat tw = W - 2*m - 28;
        CGRect box = [r boundingRectWithSize:CGSizeMake(tw, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:15]} context:nil];
        CGFloat textH = ceil(box.size.height), h = 12 + textH + 8 + 16 + 14;   // pad, text, gap, hint, pad
        UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
        card.frame = CGRectMake(m, y, W-2*m, h);
        card.backgroundColor = WP_CARD;
        card.layer.cornerRadius = 16;
        [card addTarget:self action:@selector(_copyCard:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *txt = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, tw, textH)];
        txt.numberOfLines = 0; txt.font = [UIFont systemFontOfSize:15]; txt.textColor = WP_TEXT;
        txt.text = r; txt.userInteractionEnabled = NO;
        [card addSubview:txt];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(14, h - 14 - 16, tw, 16)];
        hint.text = @"Tap to copy";
        hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        hint.textColor = WP_ACCENT; hint.userInteractionEnabled = NO;
        [card addSubview:hint];

        [_results addSubview:card];
        y += h + 10;
    }
    _results.frame = CGRectMake(0, _results.frame.origin.y, W, y);
    _scroll.contentSize = CGSizeMake(W, _results.frame.origin.y + y + 8);
    [self _layoutSheet:YES];
}

- (void)_copyCard:(UIButton *)card {
    UILabel *txt = nil;
    for (UIView *v in card.subviews) if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).numberOfLines == 0) { txt = (UILabel *)v; break; }
    if (!txt.text.length) return;
    [WPHost copyToClipboard:txt.text];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    if ([_noteReplies containsObject:txt.text]) {   // call notes, not a text: stay open so every card can be copied
        _status.textColor = WP_OK;
        _status.text = @"Copied. Paste it into Notes before the call.";
        return;
    }
    _status.textColor = WP_OK;
    _status.text = @"Copied — paste it in the app.";
    // auto-close so the user lands straight back on the dating app to paste
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self _close]; });
}

@end
