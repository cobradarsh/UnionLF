/*  WPSheet.m — Wingman Plus reply sheet, shown as a SpringBoard overlay.

    Flow: the bubble captured the screen -> we OCR it on-device -> you pick a
    style -> Claude/DeepSeek writes 3 replies -> tap one to copy it, then paste
    it in the dating app. Settings (API key, "sound like me", which apps show the
    bubble) live behind the gear. Everything runs in SpringBoard; nothing is ever
    injected into the dating app.                                                */

#import "WPlus.h"

NSString *const kWPVersion = @"1.0.4-DIAG";

// dating-first style order for the chips
static WMReplyMode const kWPModes[] = {
    WMReplyModeIcebreaker,
    WMReplyModePlanDate, WMReplyModeRomance, WMReplyModeSeduce,
    WMReplyModeSensual,  WMReplyModeLustful, WMReplyModeDirty,
    WMReplyModeFlirty,   WMReplyModeFunny,   WMReplyModeChill
};
static NSInteger const kWPModeCount = sizeof(kWPModes)/sizeof(kWPModes[0]);

static UIWindow *gWPWindow;   // strong ref so the overlay isn't deallocated while up

#pragma mark - app picker

@interface WPAppPickerVC : UITableViewController
@end
@implementation WPAppPickerVC {
    NSArray<NSDictionary *> *_apps;
    NSMutableSet<NSString *> *_chosen;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Show bubble over…";
    _apps = [WPHost installedApps];
    _chosen = [NSMutableSet setWithArray:[WMSettings shared].manualApps];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(_done)];
}
- (void)_done {
    [[WMSettings shared] setValue:_chosen.allObjects forSettingKey:@"manualApps"];
    [[WMSettings shared] setValue:@NO forSettingKey:@"autoDetectApps"]; // explicit list only
    [self.navigationController popViewControllerAnimated:YES];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _apps.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *a = _apps[ip.row];
    c.textLabel.text = a[@"name"];
    c.detailTextLabel.text = a[@"id"];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = [_chosen containsObject:a[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *bid = _apps[ip.row][@"id"];
    if ([_chosen containsObject:bid]) [_chosen removeObject:bid]; else [_chosen addObject:bid];
    [t reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [t deselectRowAtIndexPath:ip animated:YES];
}
@end

#pragma mark - settings

@interface WPSettingsVC : UIViewController <UITextFieldDelegate, UITextViewDelegate>
@end
@implementation WPSettingsVC {
    UISegmentedControl *_provider;
    UITextField *_key;
    UITextView  *_style;
    UILabel     *_status, *_model;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    WMSettings *s = [WMSettings shared]; [s reload];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sc.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sc.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    sc.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:sc];
    CGFloat W = self.view.bounds.size.width, m = 16, y = 16;

    _provider = [[UISegmentedControl alloc] initWithItems:@[@"Claude", @"DeepSeek"]];
    _provider.frame = CGRectMake(m, y, W-2*m, 34);
    _provider.selectedSegmentIndex = (s.provider == WMAPIProviderDeepSeek) ? 1 : 0;
    [_provider addTarget:self action:@selector(_providerChanged) forControlEvents:UIControlEventValueChanged];
    [sc addSubview:_provider]; y += 48;

    _key = [[UITextField alloc] initWithFrame:CGRectMake(m, y, W-2*m, 40)];
    _key.borderStyle = UITextBorderStyleRoundedRect;
    _key.placeholder = @"Paste API key";
    _key.secureTextEntry = YES; _key.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _key.autocorrectionType = UITextAutocorrectionTypeNo; _key.delegate = self;
    _key.text = [s keyForProvider:s.provider];
    [sc addSubview:_key]; y += 48;

    UIButton *verify = [UIButton buttonWithType:UIButtonTypeSystem];
    verify.frame = CGRectMake(m, y, W-2*m, 40);
    verify.backgroundColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1];
    [verify setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    verify.layer.cornerRadius = 8;
    [verify setTitle:@"Save & verify key" forState:UIControlStateNormal];
    [verify addTarget:self action:@selector(_verify) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:verify]; y += 48;

    _model = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 20)];
    _model.font = [UIFont systemFontOfSize:13]; _model.textColor = UIColor.secondaryLabelColor;
    _model.text = [NSString stringWithFormat:@"Model: %@", [s modelForProvider:s.provider]];
    [sc addSubview:_model]; y += 28;

    _status = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 20)];
    _status.font = [UIFont systemFontOfSize:13]; _status.textColor = UIColor.secondaryLabelColor;
    [sc addSubview:_status]; y += 28;

    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 20)];
    sl.text = @"Sound like me (optional)"; sl.font = [UIFont boldSystemFontOfSize:14];
    [sc addSubview:sl]; y += 26;
    _style = [[UITextView alloc] initWithFrame:CGRectMake(m, y, W-2*m, 80)];
    _style.layer.borderColor = UIColor.separatorColor.CGColor; _style.layer.borderWidth = 1;
    _style.layer.cornerRadius = 8; _style.font = [UIFont systemFontOfSize:15];
    _style.text = s.soundLikeMe;
    [sc addSubview:_style]; y += 92;

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
- (void)_providerChanged {
    WMSettings *s = [WMSettings shared];
    WMAPIProvider p = _provider.selectedSegmentIndex == 1 ? WMAPIProviderDeepSeek : WMAPIProviderClaude;
    _key.text = [s keyForProvider:p];
    _model.text = [NSString stringWithFormat:@"Model: %@", [s modelForProvider:p]];
}
- (WMAPIProvider)_p { return _provider.selectedSegmentIndex == 1 ? WMAPIProviderDeepSeek : WMAPIProviderClaude; }
- (void)_verify {
    [_key resignFirstResponder];
    WMAPIProvider p = [self _p];
    WMSettings *s = [WMSettings shared];
    [s saveProvider:p];
    [s saveKey:_key.text forProvider:p];
    _status.textColor = UIColor.secondaryLabelColor;
    _status.text = @"Verifying…";
    [WMModels fetchForProvider:p force:YES completion:^(NSArray<NSDictionary *> *models, NSError *err) {
        if (err || models.count == 0) {
            self->_status.textColor = UIColor.systemRedColor;
            self->_status.text = err ? err.localizedDescription : @"No models returned.";
            return;
        }
        // auto-pick the first model if none chosen yet
        if (![s hasChosenModelForProvider:p]) [s saveModel:models.firstObject[@"id"] forProvider:p];
        self->_status.textColor = UIColor.systemGreenColor;
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
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - main sheet

@interface WPSheet ()
@property (nonatomic, strong) NSMutableArray<UIImage *> *frames;
@property (nonatomic) WMReplyMode mode;
@property (nonatomic) WMReplyLength length;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *results;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *genBtn;
@property (nonatomic, strong) NSArray<UIButton *> *chips;
@end

@implementation WPSheet

- (instancetype)initWithImage:(UIImage *)shot {
    if ((self = [super init])) {
        _frames = shot ? [NSMutableArray arrayWithObject:shot] : [NSMutableArray array];
        _mode = WMReplyModeIcebreaker;
        _length = WMReplyLengthShort;
    }
    return self;
}
- (void)appendImage:(UIImage *)shot { if (shot) [_frames addObject:shot]; }

- (void)presentGlobally {
    // Classic window (no scene) so it works reliably inside SpringBoard.
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self];
    gWPWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gWPWindow.windowLevel = 100001;                 // just above the bubble
    gWPWindow.rootViewController = nav;
    [gWPWindow makeKeyAndVisible];
}
- (void)_close {
    gWPWindow.hidden = YES;
    gWPWindow = nil;                                 // let it deallocate
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = [NSString stringWithFormat:@"Wingman Plus %@", kWPVersion];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(_close)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                         style:UIBarButtonItemStylePlain target:self action:@selector(_settings)];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:_scroll];
    [self _rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // returning from settings: refresh the "add key" hint / button state
    [[WMSettings shared] reload];
    [self _rebuild];
}

- (void)_settings { [self.navigationController pushViewController:[WPSettingsVC new] animated:YES]; }

- (NSString *)_genTitle { return _mode == WMReplyModeIcebreaker ? @"Write icebreaker" : @"Write 3 replies"; }

- (void)_addScreen { [[WPBubble shared] beginAppendTo:self]; }

- (void)dismissForAppend { gWPWindow.hidden = YES; }
- (void)reshowAfterAppend {
    gWPWindow.hidden = NO;
    [gWPWindow makeKeyAndVisible];
    [self _rebuild];                 // refresh the captured-screen count
}

- (void)_rebuild {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    CGFloat W = self.view.bounds.size.width, m = 16, y = 12;
    WMSettings *s = [WMSettings shared];
    BOOL hasKey = [s keyForProvider:s.provider].length > 0;

    if (!hasKey) {
        UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 44)];
        note.numberOfLines = 0; note.font = [UIFont systemFontOfSize:14];
        note.textColor = UIColor.systemRedColor;
        note.text = @"Tap the gear to add your API key first.";
        [_scroll addSubview:note]; y += 52;
    }

    // style chips
    UIScrollView *chipRow = [[UIScrollView alloc] initWithFrame:CGRectMake(0, y, W, 44)];
    chipRow.showsHorizontalScrollIndicator = NO;
    CGFloat cx = m;
    NSMutableArray *chips = [NSMutableArray array];
    for (NSInteger i = 0; i < kWPModeCount; i++) {
        WMReplyMode md = kWPModes[i];
        NSString *title = [NSString stringWithFormat:@"%@ %@", [WMPrompts emojiForMode:md], [WMPrompts labelForMode:md]];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        b.tag = i;
        [b addTarget:self action:@selector(_chip:) forControlEvents:UIControlEventTouchUpInside];
        [b sizeToFit];
        CGFloat w = b.bounds.size.width + 24;
        b.frame = CGRectMake(cx, 4, w, 36);
        b.layer.cornerRadius = 18;
        [self _styleChip:b selected:(md == _mode)];
        [chipRow addSubview:b]; [chips addObject:b];
        cx += w + 8;
    }
    chipRow.contentSize = CGSizeMake(cx, 44);
    _chips = chips;
    [_scroll addSubview:chipRow]; y += 52;

    // length
    UISegmentedControl *len = [[UISegmentedControl alloc] initWithItems:@[@"Short", @"Longer"]];
    len.frame = CGRectMake(m, y, W-2*m, 32);
    len.selectedSegmentIndex = (_length == WMReplyLengthLong) ? 1 : 0;
    [len addTarget:self action:@selector(_len:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:len]; y += 44;

    // add another screen (scroll the profile, then tap the bubble again)
    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(m, y, W-2*m, 40);
    add.layer.borderColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1].CGColor;
    add.layer.borderWidth = 1.5; add.layer.cornerRadius = 10;
    [add setTitleColor:[UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1] forState:UIControlStateNormal];
    add.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [add setTitle:@"➕  Add another screen (scroll first)" forState:UIControlStateNormal];
    [add addTarget:self action:@selector(_addScreen) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:add]; y += 48;

    // generate
    _genBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _genBtn.frame = CGRectMake(m, y, W-2*m, 48);
    _genBtn.backgroundColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1];
    [_genBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _genBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    _genBtn.layer.cornerRadius = 10;
    [_genBtn setTitle:[self _genTitle] forState:UIControlStateNormal];
    [_genBtn addTarget:self action:@selector(_generate) forControlEvents:UIControlEventTouchUpInside];
    _genBtn.enabled = hasKey;
    _genBtn.alpha = hasKey ? 1 : 0.5;
    [_scroll addSubview:_genBtn]; y += 58;

    _status = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 36)];
    _status.font = [UIFont systemFontOfSize:13]; _status.textColor = UIColor.secondaryLabelColor;
    _status.numberOfLines = 2;
    _status.text = [NSString stringWithFormat:@"%lu screen%@ captured. For a full profile, add screens top to bottom.",
                    (unsigned long)_frames.count, _frames.count==1?@"":@"s"];
    [_scroll addSubview:_status]; y += 44;

    _results = [[UIView alloc] initWithFrame:CGRectMake(0, y, W, 0)];
    [_scroll addSubview:_results];
    _scroll.contentSize = CGSizeMake(W, y + 20);
}

- (void)_styleChip:(UIButton *)b selected:(BOOL)sel {
    b.backgroundColor = sel ? [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1] : UIColor.secondarySystemBackgroundColor;
    [b setTitleColor:(sel ? UIColor.whiteColor : UIColor.labelColor) forState:UIControlStateNormal];
}
- (void)_chip:(UIButton *)b {
    _mode = kWPModes[b.tag];
    for (UIButton *c in _chips) [self _styleChip:c selected:(kWPModes[c.tag] == _mode)];
    [_genBtn setTitle:[self _genTitle] forState:UIControlStateNormal];
}
- (void)_len:(UISegmentedControl *)s { _length = s.selectedSegmentIndex == 1 ? WMReplyLengthLong : WMReplyLengthShort; }

#pragma mark - generate

- (void)_generate {
    WMSettings *s = [WMSettings shared];
    if ([s keyForProvider:s.provider].length == 0) { [self _settings]; return; }
    _genBtn.enabled = NO; _genBtn.alpha = 0.5;
    _status.textColor = UIColor.secondaryLabelColor;
    _status.text = @"Reading the screen…";
    for (UIView *v in _results.subviews) [v removeFromSuperview];

    NSArray<UIImage *> *frames = [_frames copy];
    [WMOCR transcriptFromFrames:frames completion:^(NSString *transcript, NSInteger count) {
        self->_status.text = @"Writing replies…";
        @try {
            [[WMAPIClient shared] generateRepliesWithProvider:s.provider
                                                       frames:frames
                                                   transcript:transcript ?: @""
                                                      context:@""
                                                         mode:self->_mode
                                                       length:self->_length
                                                   completion:^(NSArray<NSString *> *replies, NSError *err) {
                self->_genBtn.enabled = YES; self->_genBtn.alpha = 1;
                if (err || replies.count == 0) {
                    self->_status.textColor = UIColor.systemRedColor;
                    self->_status.text = err ? err.localizedDescription : @"No replies — try again.";
                    return;
                }
                self->_status.textColor = UIColor.secondaryLabelColor;
                self->_status.text = @"Tap a reply to copy it.";
                [self _showReplies:replies];
            }];
        } @catch (id e) {
            self->_genBtn.enabled = YES; self->_genBtn.alpha = 1;
            self->_status.textColor = UIColor.systemRedColor;
            self->_status.text = @"Something went wrong generating. Try again.";
        }
    }];
}

- (void)_showReplies:(NSArray<NSString *> *)replies {
    for (UIView *v in _results.subviews) [v removeFromSuperview];
    CGFloat W = self.view.bounds.size.width, m = 16, y = 0;
    for (NSString *r in replies) {
        CGFloat tw = W - 2*m - 24;
        CGRect box = [r boundingRectWithSize:CGSizeMake(tw, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:16]} context:nil];
        CGFloat h = ceil(box.size.height) + 44;
        UIButton *card = [UIButton buttonWithType:UIButtonTypeSystem];
        card.frame = CGRectMake(m, y, W-2*m, h);
        card.backgroundColor = UIColor.secondarySystemBackgroundColor;
        card.layer.cornerRadius = 12;
        [card addTarget:self action:@selector(_copyCard:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *txt = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, tw, ceil(box.size.height))];
        txt.numberOfLines = 0; txt.font = [UIFont systemFontOfSize:16]; txt.textColor = UIColor.labelColor;
        txt.text = r; txt.userInteractionEnabled = NO;
        [card addSubview:txt];

        UILabel *copy = [[UILabel alloc] initWithFrame:CGRectMake(12, h-26, tw, 18)];
        copy.text = @"Tap to copy"; copy.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        copy.textColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.45 alpha:1];
        copy.userInteractionEnabled = NO;
        [card addSubview:copy];

        [_results addSubview:card];
        y += h + 10;
    }
    _results.frame = CGRectMake(0, _results.frame.origin.y, W, y);
    _scroll.contentSize = CGSizeMake(W, _results.frame.origin.y + y + 20);
}

- (void)_copyCard:(UIButton *)card {
    UILabel *txt = nil;
    for (UIView *v in card.subviews) if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).numberOfLines == 0) { txt = (UILabel *)v; break; }
    if (!txt.text.length) return;
    [WPHost copyToClipboard:txt.text];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    _status.textColor = UIColor.systemGreenColor;
    _status.text = @"Copied — switch to the app and paste.";
}

@end
