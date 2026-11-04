/*  WPSheet.m — Wingman Plus reply sheet, shown as a SpringBoard overlay.

    Flow: the bubble captured the screen -> we OCR it on-device -> you pick a
    style -> Claude/DeepSeek writes 3 replies -> tap one to copy it, then paste
    it in the dating app. Settings (API key, "sound like me", which apps show the
    bubble) live behind the gear. Everything runs in SpringBoard; nothing is ever
    injected into the dating app.                                                */

#import "WPlus.h"

NSString *const kWPVersion = @"1.0.16-DIAG";

// dating-first style order for the chips
static WMReplyMode const kWPModes[] = {
    WMReplyModeIcebreaker, WMReplyModePhotoOpener, WMReplyModeReviver,
    WMReplyModePlanDate,   WMReplyModeRomance,     WMReplyModeSeduce,   WMReplyModeAlphaPower,
    WMReplyModeSensual,    WMReplyModeLustful,     WMReplyModeDirty,
    WMReplyModeFlirty,     WMReplyModeFunny,       WMReplyModeChill
};
static NSInteger const kWPModeCount = sizeof(kWPModes)/sizeof(kWPModes[0]);

static UIWindow *gWPWindow;   // strong ref so the overlay isn't deallocated while up

// Same iOS 13+ rule as the bubble: a UIWindow only renders when it belongs to a
// foreground UIWindowScene. The reply sheet needs this too, or it stays invisible.
static UIWindowScene *WPActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

// A key-capable window: a plain overlay UIWindow in SpringBoard often won't bring up
// the keyboard. canBecomeKeyWindow + makeKeyAndVisible lets text fields edit where
// possible. (Key entry also has a clipboard "Paste" button that needs no keyboard.)
@interface WPSheetWindow : UIWindow
@end
@implementation WPSheetWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

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
        _status.textColor = UIColor.secondaryLabelColor;
        _status.text = @"Pasted. Now tap Save & verify key.";
    } else {
        _status.textColor = UIColor.systemRedColor;
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
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self];
    UIWindowScene *scene = WPActiveScene();
    gWPWindow = scene ? [[WPSheetWindow alloc] initWithWindowScene:scene]
                      : [[WPSheetWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gWPWindow.frame = [UIScreen mainScreen].bounds;
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

    // vibe chips — wrapping grid so every vibe is visible at once (no scrolling)
    CGFloat cx = m, cy = y, rowH = 36, gap = 8;
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
        if (cx + w > W - m) { cx = m; cy += rowH + gap; }   // wrap to the next row
        b.frame = CGRectMake(cx, cy, w, rowH);
        b.layer.cornerRadius = rowH / 2;
        [self _styleChip:b selected:(md == _mode)];
        [_scroll addSubview:b]; [chips addObject:b];
        cx += w + gap;
    }
    _chips = chips;
    y = cy + rowH + 12;

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

    // preview of what was captured, so you can see which part of the profile is in frame
    if (_frames.count) {
        UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(m, y, W-2*m, 18)];
        cap.text = @"Captured (what Wingman is reading):";
        cap.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        cap.textColor = UIColor.secondaryLabelColor;
        [_scroll addSubview:cap]; y += 22;
        CGFloat th = 170, tx = m, ty = y, rowBottom = ty;
        for (UIImage *f in _frames) {
            CGFloat ratio = (f.size.width > 0 && f.size.height > 0) ? (f.size.width / f.size.height) : 0.46;
            CGFloat tw2 = th * ratio;
            if (tx + tw2 > W - m && tx > m) { tx = m; ty = rowBottom + 8; }   // wrap
            UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(tx, ty, tw2, th)];
            iv.image = f; iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.backgroundColor = UIColor.secondarySystemBackgroundColor;
            iv.clipsToBounds = YES; iv.layer.cornerRadius = 8;
            iv.layer.borderColor = UIColor.separatorColor.CGColor; iv.layer.borderWidth = 1;
            [_scroll addSubview:iv];
            tx += tw2 + 8; rowBottom = MAX(rowBottom, ty + th);
        }
        y = rowBottom + 12;
    }

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
    _status.text = @"Copied — paste it in the app.";
    // auto-close so the user lands straight back on the dating app to paste
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self _close]; });
}

@end
