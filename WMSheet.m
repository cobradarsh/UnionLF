/*  WMSheet.m — bottom sheet
    Page 1  Quick replies: this app's 5 saved replies (tap Use, ✎ to edit).
    Page 2  Write with AI: provider (Claude/DeepSeek) -> context -> Short/Long
            -> pick ONE style -> 3 replies (Use / Save to a quick slot).
    The chat is read on-device (OCR) in the background as soon as the
    sheet opens, so AI calls send cheap text instead of images.         */

#import "WMSheet.h"

static UIColor *WMRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];
}
#define WM_BLUE   WMRGB(77, 140, 255)
#define WM_FIELD  WMRGB(46, 46, 52)
#define WM_CARD   WMRGB(41, 41, 47)
#define WM_GREEN  WMRGB(52, 199, 89)

// Debug breadcrumb: records the last AI-page step reached so a crash is pinpointable
// from the "Where are my settings coming from?" diagnostics, even without a crash log.
static void WMCrumb(NSString *step) {
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:step forKey:@"com.adarsh.wingman.lastAIStep"];
        [d synchronize];
    } @catch (__unused NSException *e) {}
    NSLog(@"[Wingman] AI step: %@", step);
}

typedef NS_ENUM(NSInteger, WMPage) { WMPageQuick, WMPageAI, WMPageKeys };

@interface WMSheet () <UITextFieldDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView        *card;
@property (nonatomic, strong) UILabel       *titleLabel;
@property (nonatomic, strong) UIButton      *backButton;
@property (nonatomic, strong) UIScrollView  *scroll;
@property (nonatomic)         WMPage         page;

// AI page state (kept when switching pages)
@property (nonatomic, copy)   NSString      *contextText;
@property (nonatomic)         WMReplyLength  length;
@property (nonatomic)         WMAPIProvider  provider;
@property (nonatomic)         WMReplyMode    currentMode;
@property (nonatomic, strong) NSArray<NSString *> *replies;
@property (nonatomic, copy)   NSString      *statusText;
@property (nonatomic)         BOOL           busy;
@property (nonatomic)         NSInteger      generation;

// who this chat is with (read from the header) + how many screens we've captured
@property (nonatomic, copy)   NSString      *contactName;
@property (nonatomic)         NSInteger      screensWanted;

// on-device reading
@property (nonatomic)         BOOL           ocrDone;
@property (nonatomic, copy)   NSString      *transcript;
@property (nonatomic)         NSInteger      ocrCount;
@property (nonatomic)         BOOL           generateWhenReady;

// AI page widgets
@property (nonatomic, weak)   UITextField   *contextField;
@property (nonatomic, weak)   UILabel       *readLabel;
@property (nonatomic, weak)   UIButton      *modelButton;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray *> *models;   // provider -> list
@property (nonatomic, strong) NSMutableSet<NSNumber *> *autoPickerShown;
// keys page
@property (nonatomic)         WMPage         backPage;
@property (nonatomic, weak)   UITextField   *keyField;
@property (nonatomic, weak)   UILabel       *keyStatus;
@property (nonatomic, weak)   UIButton      *verifyButton;
@property (nonatomic, weak)   UIButton      *keysModelButton;
@property (nonatomic, copy)   NSString      *keyStatusText;
@property (nonatomic)         BOOL           keyStatusGood;
@property (nonatomic, strong) NSMutableArray<UIButton *> *chips;
@property (nonatomic, weak)   UIView        *resultsView;
@property (nonatomic)         CGFloat        resultsTop;
@end

@implementation WMSheet

- (instancetype)initWithImages:(NSArray<UIImage *> *)frames {
    self = [super init];
    if (self) {
        _frames = frames ?: @[];
        _chips = [NSMutableArray array];
        _currentMode = -1;
        _page = WMPageQuick;
        _screensWanted = MAX(1, (NSInteger)_frames.count);
        [[WMSettings shared] reload];
        _provider = [WMSettings shared].provider;
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    }
    return self;
}

#pragma mark - chrome

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_dismiss)];
    dismissTap.delegate = self;
    [self.view addGestureRecognizer:dismissTap];

    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    CGFloat cardH = H * 0.88;

    _card = [[UIView alloc] initWithFrame:CGRectMake(0, H - cardH, W, cardH)];
    _card.backgroundColor = WMRGB(28, 28, 33);
    _card.layer.cornerRadius = 20;
    _card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];

    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake((W-36)/2, 8, 36, 5)];
    handle.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1];
    handle.layer.cornerRadius = 2.5;
    [_card addSubview:handle];

    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _backButton.frame = CGRectMake(8, 18, 44, 36);
    [_backButton setTitle:@"‹" forState:UIControlStateNormal];
    _backButton.titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightLight];
    [_backButton setTitleColor:WM_BLUE forState:UIControlStateNormal];
    [_backButton addTarget:self action:@selector(_goBack) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_backButton];

    _titleLabel = [self _label:@"" size:19 bold:YES color:UIColor.whiteColor];
    [_card addSubview:_titleLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(W - 52, 18, 36, 36);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:20];
    [close setTitleColor:[UIColor colorWithWhite:0.6 alpha:1] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(_dismiss) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:close];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 58, W, cardH - 58)];
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _scroll.alwaysBounceVertical = YES;
    [_card addSubview:_scroll];

    [self _rebuild];

    // read the chat on-device right away (free, local)
    [WMOCR transcriptFromFrames:_frames completion:^(NSString *t, NSInteger n) {
        self.ocrDone = YES;
        self.transcript = t;
        self.ocrCount = n;
        [self _updateReadLabel];
        if (self.generateWhenReady) { self.generateWhenReady = NO; [self _generate]; }
    }];

    [self _detectContactName];
}

// Read the chat's name from the newest frame's header, then pre-warm the gender guess.
- (void)_detectContactName {
    UIImage *frame = _frames.lastObject;       // frames are oldest-first; the newest has the header
    if (!frame) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *nm = [WMOCR contactNameFromFrame:frame];
        if (nm.length == 0) return;
        NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
        dispatch_async(dispatch_get_main_queue(), ^{ self.contactName = nm; });
        [WMContacts ensureGenderForApp:bundle name:nm];   // cached for when a reply is generated
    });
}

- (void)_rebuild {
    for (UIView *v in _scroll.subviews) [v removeFromSuperview];
    [_chips removeAllObjects];
    BOOL sub = (_page != WMPageQuick);
    _backButton.hidden = !sub;
    CGFloat W = self.view.bounds.size.width;
    CGFloat tx = sub ? 50 : 16;
    _titleLabel.frame = CGRectMake(tx, 22, W - tx - 60, 28);
    _titleLabel.text = _page == WMPageAI   ? @"✨ Write with AI"
                     : _page == WMPageKeys ? @"\U0001F511 API keys & model"
                     : [NSString stringWithFormat:@"\U0001FABD Wingman · %@", [WMApps currentAppName]];
    CGFloat y = _page == WMPageAI   ? [self _buildAIPage]
              : _page == WMPageKeys ? [self _buildKeysPage]
              : [self _buildQuickPage];
    _scroll.contentSize = CGSizeMake(W, y + 40);
    [_scroll setContentOffset:CGPointZero animated:NO];
}

- (UILabel *)_label:(NSString *)t size:(CGFloat)s bold:(BOOL)b color:(UIColor *)c {
    UILabel *l = [UILabel new];
    l.text = t; l.textColor = c;
    l.font = b ? [UIFont boldSystemFontOfSize:s] : [UIFont systemFontOfSize:s];
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.8;
    return l;
}

- (UIButton *)_pill:(NSString *)title color:(UIColor *)bg action:(SEL)sel frame:(CGRect)f {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = bg;
    b.layer.cornerRadius = 9;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (CGFloat)_addFramesStripAtY:(CGFloat)y height:(CGFloat)h {
    CGFloat pad = 16, inner = self.view.bounds.size.width - 2*pad;
    UIScrollView *strip = [[UIScrollView alloc] initWithFrame:CGRectMake(pad, y, inner, h)];
    strip.showsHorizontalScrollIndicator = NO;
    CGFloat sx = 0;
    for (UIImage *img in _frames) {
        CGFloat w = h * (img.size.width / MAX(img.size.height, 1));
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(sx, 0, w, h)];
        iv.image = img; iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES; iv.layer.cornerRadius = 7;
        [strip addSubview:iv];
        sx += w + 8;
    }
    strip.contentSize = CGSizeMake(sx, h);
    [_scroll addSubview:strip];
    return y + h;
}

#pragma mark - page 1: quick replies

- (CGFloat)_buildQuickPage {
    CGFloat W = self.view.bounds.size.width, pad = 16, w = W - 2*pad, y = 4;

    UILabel *hdr = [self _label:@"Quick replies" size:13 bold:YES color:[UIColor colorWithWhite:0.75 alpha:1]];
    hdr.frame = CGRectMake(pad, y, w - 80, 20);
    [_scroll addSubview:hdr];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(W - pad - 70, y - 4, 70, 28);
    [reset setTitle:@"Reset" forState:UIControlStateNormal];
    reset.titleLabel.font = [UIFont systemFontOfSize:13];
    [reset setTitleColor:[UIColor colorWithWhite:0.55 alpha:1] forState:UIControlStateNormal];
    reset.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [reset addTarget:self action:@selector(_resetQuick) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:reset];
    y += 26;

    NSArray *qr = [WMQuickReplies repliesForCurrentApp];
    for (NSInteger i = 0; i < (NSInteger)qr.count; i++) {
        UIView *card = [UIView new];
        card.backgroundColor = WM_CARD;
        card.layer.cornerRadius = 13;

        UILabel *body = [UILabel new];
        body.text = qr[i];
        body.textColor = [UIColor colorWithWhite:0.93 alpha:1];
        body.font = [UIFont systemFontOfSize:15];
        body.numberOfLines = 0;
        CGFloat bw = w - 28 - 120;
        CGSize fit = [body sizeThatFits:CGSizeMake(bw, CGFLOAT_MAX)];
        CGFloat ch = MAX(fit.height + 24, 52);
        body.frame = CGRectMake(14, (ch - fit.height)/2, bw, fit.height);
        [card addSubview:body];

        UIButton *edit = [self _pill:@"✎" color:WM_FIELD action:@selector(_editQuick:)
                               frame:CGRectMake(w - 124, (ch-32)/2, 44, 32)];
        edit.tag = i;
        [card addSubview:edit];
        UIButton *use = [self _pill:@"Use" color:WM_GREEN action:@selector(_useQuick:)
                              frame:CGRectMake(w - 72, (ch-32)/2, 60, 32)];
        use.tag = i;
        [card addSubview:use];

        card.frame = CGRectMake(pad, y, w, ch);
        [_scroll addSubview:card];
        y += ch + 8;
    }

    y += 8;
    UIButton *ai = [self _pill:@"✨  Write a custom reply with AI  ›" color:WM_BLUE
                        action:@selector(_goAI) frame:CGRectMake(pad, y, w, 50)];
    ai.layer.cornerRadius = 13;
    ai.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [_scroll addSubview:ai];
    y += 62;

    UILabel *note = [self _label:@"Quick replies are saved separately for each app. Tap ✎ to change one, or Save an AI reply into a slot."
                            size:12 bold:NO color:[UIColor colorWithWhite:0.45 alpha:1]];
    note.numberOfLines = 0; note.adjustsFontSizeToFitWidth = NO;
    CGSize nf = [note sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    note.frame = CGRectMake(pad, y, w, nf.height);
    [_scroll addSubview:note];
    y += nf.height + 14;

    UIButton *keys = [self _pill:@"\U0001F511  API keys & model" color:WM_FIELD
                           action:@selector(_goKeys) frame:CGRectMake(pad, y, w, 42)];
    keys.layer.cornerRadius = 11;
    [_scroll addSubview:keys];
    y += 52;

    UIButton *hide = [UIButton buttonWithType:UIButtonTypeSystem];
    hide.frame = CGRectMake(pad, y, w, 36);
    [hide setTitle:@"Hide bubble (comes back when you reopen the app)" forState:UIControlStateNormal];
    hide.titleLabel.font = [UIFont systemFontOfSize:13];
    hide.titleLabel.adjustsFontSizeToFitWidth = YES;
    [hide setTitleColor:[UIColor colorWithWhite:0.55 alpha:1] forState:UIControlStateNormal];
    [hide addTarget:self action:@selector(_hideBubble) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:hide];
    return y + 36;
}

- (void)_hideBubble {
    [[WMBubble shared] hideUntilReopen];
    [self _dismiss];
}

- (void)_useQuick:(UIButton *)b {
    NSArray *qr = [WMQuickReplies repliesForCurrentApp];
    if (b.tag < (NSInteger)qr.count) [self _send:qr[b.tag]];
}

- (void)_editQuick:(UIButton *)b {
    NSInteger idx = b.tag;
    NSString *cur = [WMQuickReplies repliesForCurrentApp][idx];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Quick reply %ld", (long)idx + 1]
        message:[NSString stringWithFormat:@"Saved for %@ only", [WMApps currentAppName]]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [WMQuickReplies setReply:a.textFields.firstObject.text atIndex:idx];
        [self _rebuild];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)_resetQuick {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset quick replies?"
        message:[NSString stringWithFormat:@"Restores the 5 default replies for %@.", [WMApps currentAppName]]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [WMQuickReplies resetCurrentApp];
        [self _rebuild];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)_goAI {
    WMCrumb(@"goAI");
    @try {
        _page = WMPageAI;
        [self _rebuild];
    } @catch (NSException *e) {
        // Turn an Objective-C exception into a readable message instead of a force-close,
        // and recover to the quick-replies page. (EXC_BAD_ACCESS can't be caught here.)
        NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:@"com.adarsh.wingman.lastAIStep"];
        _page = WMPageQuick;
        [self _rebuild];
        [self _alert:@"Wingman hit an error opening the AI page"
             message:[NSString stringWithFormat:@"%@: %@\n(last step: %@)",
                      e.name ?: @"error", e.reason ?: @"?", last ?: @"(none)"]];
    }
}
- (void)_goQuick { [self.view endEditing:YES]; _page = WMPageQuick; [self _rebuild]; }

- (void)_goKeys {
    [self.view endEditing:YES];
    _backPage = _page;
    _keyStatusText = nil;
    _page = WMPageKeys;
    [self _rebuild];
}

- (void)_goBack {
    [self.view endEditing:YES];
    _page = (_page == WMPageKeys) ? _backPage : WMPageQuick;
    [self _rebuild];
}

#pragma mark - page 3: API keys & model

- (CGFloat)_buildKeysPage {
    CGFloat W = self.view.bounds.size.width, pad = 16, inner = W - 2*pad, y = 4;
    WMSettings *s = [WMSettings shared];
    [s reload];
    NSString *name = [self _providerName];

    // provider switch
    UISegmentedControl *prov = [[UISegmentedControl alloc] initWithItems:@[@"Claude", @"DeepSeek"]];
    prov.frame = CGRectMake(pad, y, inner, 36);
    prov.selectedSegmentIndex = (_provider == WMAPIProviderDeepSeek) ? 1 : 0;
    [self _styleSegment:prov];
    [prov addTarget:self action:@selector(_keysProviderChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:prov];
    y += 48;

    // current state
    NSString *saved = [s keyForProvider:_provider];
    UILabel *hdr = [self _label:[NSString stringWithFormat:@"%@ API key", name]
                           size:13 bold:YES color:[UIColor colorWithWhite:0.75 alpha:1]];
    hdr.frame = CGRectMake(pad, y, inner, 18);
    [_scroll addSubview:hdr];
    y += 24;

    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, inner, 44)];
    tf.backgroundColor = WM_FIELD;
    tf.textColor = UIColor.whiteColor;
    tf.font = [UIFont systemFontOfSize:14];
    tf.layer.cornerRadius = 10;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.spellCheckingType = UITextSpellCheckingTypeNo;
    tf.keyboardType = UIKeyboardTypeASCIICapable;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    tf.text = saved;
    tf.secureTextEntry = NO;          // you need to see what you pasted
    tf.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:(_provider == WMAPIProviderDeepSeek ? @"sk-..." : @"sk-ant-...")
            attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.4 alpha:1]}];
    [_scroll addSubview:tf];
    _keyField = tf;
    y += 52;

    // paste + verify
    UIButton *paste = [self _pill:@"Paste" color:WM_FIELD action:@selector(_pasteKey)
                            frame:CGRectMake(pad, y, 88, 42)];
    [_scroll addSubview:paste];
    UIButton *verify = [self _pill:@"Verify & load models" color:WM_BLUE action:@selector(_verifyKey)
                             frame:CGRectMake(pad + 96, y, inner - 96, 42)];
    verify.layer.cornerRadius = 11;
    [_scroll addSubview:verify];
    _verifyButton = verify;
    y += 52;

    UILabel *st = [self _label:@"" size:13 bold:NO color:[UIColor colorWithWhite:0.6 alpha:1]];
    st.numberOfLines = 0; st.adjustsFontSizeToFitWidth = NO;
    st.frame = CGRectMake(pad, y, inner, 0);
    [_scroll addSubview:st];
    _keyStatus = st;
    if (!_keyStatusText)
        _keyStatusText = saved.length ? @"A key is saved. Tap Verify to check it and load the model list."
                                      : [NSString stringWithFormat:
                                         @"Paste your %@ key, then tap Verify.", name];
    y += [self _layoutStatus] + 14;

    // model
    UILabel *ml = [self _label:@"Model" size:13 bold:YES color:[UIColor colorWithWhite:0.75 alpha:1]];
    ml.frame = CGRectMake(pad, y, inner, 18);
    [_scroll addSubview:ml];
    y += 24;
    UIButton *mb = [UIButton buttonWithType:UIButtonTypeSystem];
    mb.frame = CGRectMake(pad, y, inner, 44);
    mb.backgroundColor = WM_FIELD;
    mb.layer.cornerRadius = 10;
    mb.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    mb.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    mb.titleLabel.font = [UIFont systemFontOfSize:14];
    mb.titleLabel.adjustsFontSizeToFitWidth = YES;
    mb.titleLabel.minimumScaleFactor = 0.7;
    [mb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [mb addTarget:self action:@selector(_modelTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:mb];
    _keysModelButton = mb;
    [self _updateModelButton];
    y += 54;

    UILabel *note = [self _label:
        @"The key is saved to a shared file every app can read, so it works in Instagram, Reddit, "
         "X and the rest, not just the app you typed it in. Verify confirms it."
                            size:12 bold:NO color:[UIColor colorWithWhite:0.45 alpha:1]];
    note.numberOfLines = 0; note.adjustsFontSizeToFitWidth = NO;
    CGSize nf = [note sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)];
    note.frame = CGRectMake(pad, y, inner, nf.height);
    [_scroll addSubview:note];
    y += nf.height + 16;

    UIButton *diag = [self _pill:@"Where are my settings coming from?" color:WM_FIELD
                          action:@selector(_showDiagnostics) frame:CGRectMake(pad, y, inner, 40)];
    diag.titleLabel.font = [UIFont systemFontOfSize:13];
    [_scroll addSubview:diag];
    return y + 40;
}

- (CGFloat)_layoutStatus {
    if (!_keyStatus) return 0;
    _keyStatus.text = _keyStatusText ?: @"";
    _keyStatus.textColor = _keyStatusGood ? WM_GREEN : [UIColor colorWithWhite:0.6 alpha:1];
    CGFloat w = self.view.bounds.size.width - 32;
    CGSize fit = [_keyStatus sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    CGRect f = _keyStatus.frame; f.size = CGSizeMake(w, fit.height); _keyStatus.frame = f;
    return fit.height;
}

- (void)_setStatus:(NSString *)text good:(BOOL)good {
    _keyStatusText = text; _keyStatusGood = good;
    if (_page == WMPageKeys) [self _rebuild];
}

- (void)_keysProviderChanged:(UISegmentedControl *)sc {
    _provider = sc.selectedSegmentIndex == 1 ? WMAPIProviderDeepSeek : WMAPIProviderClaude;
    [[WMSettings shared] saveProvider:_provider];
    _keyStatusText = nil;
    [self _rebuild];
}

- (void)_pasteKey {
    NSString *s = [UIPasteboard generalPasteboard].string;
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) { [self _setStatus:@"Clipboard is empty." good:NO]; return; }
    _keyField.text = s;
    [self _setStatus:@"Pasted. Now tap Verify." good:NO];
}

- (void)_verifyKey {
    [self.view endEditing:YES];
    NSString *typed = [_keyField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    WMAPIProvider p = _provider;
    NSString *name = [self _providerName];
    if (typed.length == 0) { [self _setStatus:@"Enter the key first." good:NO]; return; }

    [self _setStatus:[NSString stringWithFormat:@"Checking the key with %@...", name] good:NO];
    [WMModels fetchForProvider:p key:typed force:YES completion:^(NSArray *models, NSError *err) {
        if (!models.count) {
            [self _setStatus:[NSString stringWithFormat:@"❌ %@",
                              err.localizedDescription ?: @"That key didn't work."] good:NO];
            return;
        }
        self.models[@(p)] = models;
        BOOL everywhere = [[WMSettings shared] saveKey:typed forProvider:p];
        // if the saved model isn't on this key, switch to the newest one
        WMSettings *s = [WMSettings shared];
        if (![self _nameForModel:[s modelForProvider:p]])
            [s saveModel:models.firstObject[@"id"] forProvider:p];
        [self _setStatus:[NSString stringWithFormat:
            @"✅ Key works. %lu models available.\nSaved %@.\nPick one below.",
            (unsigned long)models.count,
            everywhere ? @"for all apps" : [NSString stringWithFormat:@"for %@ only", [WMApps currentAppName]]]
                     good:YES];
        [self _presentModelPicker:models];
    }];
}

- (void)_showDiagnostics {
    [self _alert:@"Settings diagnostics" message:[[WMSettings shared] diagnostics]];
}

#pragma mark - page 2: AI

- (CGFloat)_buildAIPage {
    WMCrumb(@"build:start");
    CGFloat W = self.view.bounds.size.width, pad = 16, inner = W - 2*pad, y = 4;

    y = [self _addFramesStripAtY:y height:72] + 4;
    WMCrumb(@"build:afterFrames");
    UILabel *read = [self _label:@"" size:11 bold:NO color:[UIColor colorWithWhite:0.5 alpha:1]];
    read.frame = CGRectMake(pad, y, inner, 16);
    [_scroll addSubview:read];
    _readLabel = read;
    [self _updateReadLabel];
    y += 26;

    // scroll older + per-contact notes
    CGFloat halfW = (inner - 8) / 2;
    UIButton *older = [self _pill:@"⟲  Scroll Older" color:WM_FIELD action:@selector(_scrollOlder)
                            frame:CGRectMake(pad, y, halfW, 36)];
    older.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_scroll addSubview:older];
    UIButton *notes = [self _pill:@"\U0001F4DD  Notes" color:WM_FIELD action:@selector(_editNotes)
                            frame:CGRectMake(pad + halfW + 8, y, halfW, 36)];
    notes.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_scroll addSubview:notes];
    y += 46;
    WMCrumb(@"build:afterButtons");

    // provider switch
    UILabel *pl = [self _label:@"AI" size:13 bold:YES color:[UIColor colorWithWhite:0.75 alpha:1]];
    pl.frame = CGRectMake(pad, y, inner, 18);
    [_scroll addSubview:pl];
    y += 22;
    UISegmentedControl *prov = [[UISegmentedControl alloc] initWithItems:@[@"Claude", @"DeepSeek"]];
    prov.frame = CGRectMake(pad, y, inner, 36);
    prov.selectedSegmentIndex = (_provider == WMAPIProviderDeepSeek) ? 1 : 0;
    [self _styleSegment:prov];
    [prov addTarget:self action:@selector(_providerChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:prov];
    y += 44;

    // model row: tap to pick from the models your key can use
    UIButton *kb = [self _pill:@"\U0001F511" color:WM_FIELD action:@selector(_goKeys)
                         frame:CGRectMake(pad + inner - 44, y, 44, 40)];
    kb.titleLabel.font = [UIFont systemFontOfSize:15];
    [_scroll addSubview:kb];

    UIButton *mb = [UIButton buttonWithType:UIButtonTypeSystem];
    mb.frame = CGRectMake(pad, y, inner - 50, 40);
    mb.backgroundColor = WM_FIELD;
    mb.layer.cornerRadius = 10;
    mb.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    mb.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    mb.titleLabel.font = [UIFont systemFontOfSize:14];
    mb.titleLabel.adjustsFontSizeToFitWidth = YES;
    mb.titleLabel.minimumScaleFactor = 0.7;
    [mb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [mb addTarget:self action:@selector(_modelTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:mb];
    _modelButton = mb;
    WMCrumb(@"build:beforeModelUpdate");
    [self _updateModelButton];
    WMCrumb(@"build:beforePrefetch");
    [self _prefetchModels];
    y += 52;
    WMCrumb(@"build:afterModel");

    // context
    UILabel *ctxL = [self _label:@"What's the context? (optional)" size:13 bold:NO color:[UIColor colorWithWhite:0.6 alpha:1]];
    ctxL.frame = CGRectMake(pad, y, inner, 18);
    [_scroll addSubview:ctxL];
    y += 22;
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, inner, 42)];
    tf.backgroundColor = WM_FIELD;
    tf.textColor = UIColor.whiteColor;
    tf.font = [UIFont systemFontOfSize:15];
    tf.layer.cornerRadius = 10;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.text = _contextText;
    tf.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"e.g. I was sick today, she's asking about money"
            attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.4 alpha:1]}];
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    [tf addTarget:self action:@selector(_contextChanged:) forControlEvents:UIControlEventEditingChanged];
    [_scroll addSubview:tf];
    _contextField = tf;
    y += 56;

    // length
    UILabel *lenL = [self _label:@"Length" size:13 bold:YES color:[UIColor colorWithWhite:0.75 alpha:1]];
    lenL.frame = CGRectMake(pad, y, inner, 18);
    [_scroll addSubview:lenL];
    y += 22;
    UISegmentedControl *len = [[UISegmentedControl alloc] initWithItems:@[@"Short", @"Long"]];
    len.frame = CGRectMake(pad, y, inner, 36);
    len.selectedSegmentIndex = (_length == WMReplyLengthLong) ? 1 : 0;
    [self _styleSegment:len];
    [len addTarget:self action:@selector(_lengthChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:len];
    y += 50;

    // styles
    UILabel *styL = [self _label:@"Pick a style (3 replies)" size:13 bold:YES color:[UIColor colorWithWhite:0.75 alpha:1]];
    styL.frame = CGRectMake(pad, y, inner, 18);
    [_scroll addSubview:styL];
    y += 24;
    NSInteger cols = 3; CGFloat gap = 8, chipH = 42;
    CGFloat chipW = (inner - gap * (cols - 1)) / cols;
    WMCrumb(@"build:beforeStyles");
    for (NSInteger i = 0; i < WMReplyModeCount; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(pad + (i % cols) * (chipW + gap), y + (i / cols) * (chipH + gap), chipW, chipH);
        b.tag = i;
        b.backgroundColor = (i == _currentMode) ? WM_BLUE : WM_FIELD;
        b.layer.cornerRadius = 11;
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.titleLabel.minimumScaleFactor = 0.75;
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);
        [b setTitle:[NSString stringWithFormat:@"%@ %@", [WMPrompts emojiForMode:i], [WMPrompts labelForMode:i]]
           forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [b addTarget:self action:@selector(_styleTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:b];
        [_chips addObject:b];
    }
    y += ((WMReplyModeCount + cols - 1) / cols) * (chipH + gap) + 10;
    WMCrumb(@"build:afterStyles");

    _resultsTop = y;
    UIView *rv = [[UIView alloc] initWithFrame:CGRectMake(0, y, W, 0)];
    [_scroll addSubview:rv];
    _resultsView = rv;
    if (_replies.count)      [self _showReplies];
    else if (_statusText)    [self _showStatus:_statusText spinner:_busy];
    WMCrumb(@"build:done");
    return y + _resultsView.frame.size.height;
}

- (void)_styleSegment:(UISegmentedControl *)sc {
    sc.selectedSegmentTintColor = WM_BLUE;
    [sc setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                 NSFontAttributeName: [UIFont boldSystemFontOfSize:14]}
                      forState:UIControlStateNormal];
    sc.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
}

- (void)_updateReadLabel {
    if (!_readLabel) return;
    NSString *t;
    if (!_ocrDone) t = @"Reading the chat on your phone...";
    else if (_ocrCount > 0)
        t = [NSString stringWithFormat:@"Read %ld messages on-device ✓  (right = you, left = them, notices ignored)",
             (long)_ocrCount];
    else t = @"Couldn't read text here. Claude will look at the screenshot instead.";
    _readLabel.text = t;
}

- (void)_providerChanged:(UISegmentedControl *)sc {
    _provider = sc.selectedSegmentIndex == 1 ? WMAPIProviderDeepSeek : WMAPIProviderClaude;
    [[WMSettings shared] saveProvider:_provider];   // stays chosen next time
    [self _updateModelButton];
    [self _prefetchModels];
}

#pragma mark - model picker

- (NSString *)_providerName { return _provider == WMAPIProviderDeepSeek ? @"DeepSeek" : @"Claude"; }

- (NSString *)_nameForModel:(NSString *)mid {
    for (NSDictionary *m in _models[@(_provider)])
        if ([m[@"id"] isEqual:mid]) return m[@"name"];
    return nil;
}

- (void)_updateModelButton {
    UIButton *btn = (_page == WMPageKeys) ? _keysModelButton : _modelButton;
    if (!btn) return;
    WMSettings *s = [WMSettings shared];
    NSString *mid = [s modelForProvider:_provider];
    NSArray *list = _models[@(_provider)];
    NSString *nm = [self _nameForModel:mid];
    NSString *title;
    if (list.count && !nm)
        title = [NSString stringWithFormat:@"\u26A0\uFE0F  %@ isn't on your key, tap to choose", mid];
    else if (nm && ![nm isEqualToString:mid])
        title = [NSString stringWithFormat:@"Model:  %@  (%@)  \u203A", nm, mid];
    else
        title = [NSString stringWithFormat:@"Model:  %@  \u203A", mid];
    [btn setTitle:title forState:UIControlStateNormal];
}

// fetch quietly when the AI page opens; the first time a key is in use and no
// model has been chosen yet, show the list straight away
- (void)_prefetchModels {
    WMAPIProvider p = _provider;
    if (!_models) _models = [NSMutableDictionary dictionary];
    if (!_autoPickerShown) _autoPickerShown = [NSMutableSet set];
    [WMModels fetchForProvider:p force:NO completion:^(NSArray *models, NSError *err) {
        if (!models.count) return;                  // no key / offline: stay quiet
        self.models[@(p)] = models;
        if (p != self.provider) return;
        [self _updateModelButton];
        WMSettings *s = [WMSettings shared];
        BOOL missing = ![self _nameForModel:[s modelForProvider:p]];
        if ((![s hasChosenModelForProvider:p] || missing) && ![self.autoPickerShown containsObject:@(p)]
            && self.page == WMPageAI && !self.presentedViewController) {
            [self.autoPickerShown addObject:@(p)];
            [self _presentModelPicker:models];
        }
    }];
}

- (void)_modelTapped {
    NSArray *have = _models[@(_provider)];
    if (have.count) { [self _presentModelPicker:have]; return; }
    UIButton *btn = (_page == WMPageKeys) ? _keysModelButton : _modelButton;
    [btn setTitle:[NSString stringWithFormat:@"Fetching %@ models...", [self _providerName]]
         forState:UIControlStateNormal];
    WMAPIProvider p = _provider;
    [WMModels fetchForProvider:p force:YES completion:^(NSArray *models, NSError *err) {
        if (models.count) self.models[@(p)] = models;
        [self _updateModelButton];
        if (p != self.provider) return;
        if (models.count) { [self _presentModelPicker:models]; return; }
        [self _offerKeysPage:@"Couldn't load models"
                     message:err.localizedDescription ?: @"Try again."];
    }];
}

// every failure should lead somewhere useful: the key page
- (void)_offerKeysPage:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Enter API key" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [self _goKeys]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)_presentModelPicker:(NSArray<NSDictionary *> *)models {
    WMAPIProvider p = _provider;
    NSString *cur = [[WMSettings shared] modelForProvider:p];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Choose a %@ model", [self _providerName]]
                         message:[NSString stringWithFormat:@"%lu models available on your API key",
                                  (unsigned long)models.count]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *m in models) {
        NSString *mid = m[@"id"], *nm = m[@"name"];
        NSString *label = [nm isEqualToString:mid] ? mid : [NSString stringWithFormat:@"%@  \u00B7  %@", nm, mid];
        if ([m[@"lifecycle"] isEqualToString:@"deprecated"])
            label = [label stringByAppendingString:@"  (older)"];
        if ([mid isEqualToString:cur]) label = [@"\u2713  " stringByAppendingString:label];
        [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            BOOL global = [[WMSettings shared] saveModel:mid forProvider:p];
            [self _updateModelButton];
            [WMSheet _toast:global ? [NSString stringWithFormat:@"Model set: %@ \u2713", nm]
                                   : [NSString stringWithFormat:@"Model set for %@ only: %@", [WMApps currentAppName], nm]
                         in:self.view];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"\u21BB  Refresh list" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        [self.models removeObjectForKey:@(p)];
        [self _modelTapped];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = _modelButton ?: self.view;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)_alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)_lengthChanged:(UISegmentedControl *)sc {
    _length = sc.selectedSegmentIndex == 1 ? WMReplyLengthLong : WMReplyLengthShort;
}
- (void)_contextChanged:(UITextField *)tf { _contextText = tf.text; }

- (void)_styleTapped:(UIButton *)b {
    [self.view endEditing:YES];
    _currentMode = (WMReplyMode)b.tag;
    for (UIButton *c in _chips) c.backgroundColor = (c == b) ? WM_BLUE : WM_FIELD;
    [self _generate];
}

- (void)_generate {
    if (_currentMode < 0) return;
    if (!_ocrDone) {                       // wait for on-device reading (usually < 1 s)
        _generateWhenReady = YES;
        [self _showStatus:@"Reading the chat..." spinner:YES];
        return;
    }
    NSInteger gen = ++_generation;
    WMReplyMode mode = _currentMode;
    NSString *who = (_provider == WMAPIProviderDeepSeek) ? @"DeepSeek" : @"Claude";
    NSString *msg = (mode == WMReplyModeInMyFavor && _provider == WMAPIProviderClaude)
        ? [NSString stringWithFormat:@"%@ is searching the web + writing 3 replies...", who]
        : [NSString stringWithFormat:@"%@ is writing 3 replies...", who];
    _replies = nil;
    [self _showStatus:msg spinner:YES];

    NSString *name = _contactName;
    NSString *typed = _contextText ?: @"";
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
    WMAPIProvider provider = _provider;
    NSArray *frames = _frames;
    NSString *transcript = _transcript;
    WMReplyLength length = _length;

    void (^onDone)(NSArray<NSString *> *, NSError *) = ^(NSArray<NSString *> *replies, NSError *err) {
        if (gen != self.generation) return;
        if (err || replies.count == 0) {
            [self _showStatus:[NSString stringWithFormat:@"⚠️ %@",
                               err.localizedDescription ?: @"No replies"] spinner:NO];
            return;
        }
        self.replies = replies;
        self.statusText = nil; self.busy = NO;
        if (self.page == WMPageAI) [self _showReplies];
    };

    // Build the context (who they are, likely gender, saved notes, then my own text) off the
    // main thread, since the gender guess may hit the network the first time for a new contact.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *gender = name.length ? [WMContacts ensureGenderForApp:bundle name:name] : @"";
        NSString *ctx = [WMContacts promptContextForApp:bundle name:name gender:gender typed:typed];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self.generation) return;
            [[WMAPIClient shared] generateRepliesWithProvider:provider
                                                       frames:frames
                                                   transcript:transcript
                                                      context:ctx
                                                         mode:mode
                                                       length:length
                                                   completion:onDone];
        });
    });
}

#pragma mark - scroll older + notes

- (void)_scrollOlder {
    [self.view endEditing:YES];
    if (_page != WMPageAI) { _page = WMPageAI; [self _rebuild]; }
    _screensWanted = MIN(_screensWanted + 2, 8);
    _replies = nil;
    [self _showStatus:[NSString stringWithFormat:@"Grabbing %ld screens of older messages...",
                       (long)_screensWanted] spinner:YES];
    [WMCapture dismissKeyboardInChat];
    [WMCapture scrollCaptureHidingView:[WMBubble shared].overlayWindow
                               screens:_screensWanted
                            completion:^(NSArray<UIImage *> *frames) {
        if (frames.count) { self.frames = frames; [self _reloadAfterRecapture]; }
        else [self _showStatus:@"Couldn't grab more from this screen." spinner:NO];
    }];
}

// re-OCR the new frames and refresh the AI page (frame strip, read label, contact name)
- (void)_reloadAfterRecapture {
    _ocrDone = NO; _transcript = nil; _ocrCount = 0; _statusText = nil; _replies = nil;
    [self _rebuild];
    [WMOCR transcriptFromFrames:_frames completion:^(NSString *t, NSInteger n) {
        self.ocrDone = YES; self.transcript = t; self.ocrCount = n;
        [self _updateReadLabel];
    }];
    [self _detectContactName];
}

- (void)_editNotes {
    NSString *name = _contactName;
    if (name.length == 0) {
        [self _alert:@"Who is this chat with?"
             message:@"Wingman couldn't read the name from the top of the chat. Open the chat so the "
                     "name shows in the header, then tap the bubble again."];
        return;
    }
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Notes · %@", name]
                         message:@"Likes, dislikes, anything worth remembering. Saved on this phone and used in replies."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [WMContacts noteForApp:bundle name:name];
        tf.placeholder = @"e.g. loves hiking, hates smokers, from Pune";
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [WMContacts setNote:a.textFields.firstObject.text forApp:bundle name:name];
        [WMSheet _toast:@"Saved ✓" in:self.view];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)_clearResults {
    for (UIView *v in _resultsView.subviews) [v removeFromSuperview];
}

- (void)_showStatus:(NSString *)msg spinner:(BOOL)spin {
    _statusText = msg; _busy = spin;
    if (_page != WMPageAI || !_resultsView) return;
    [self _clearResults];
    CGFloat W = self.view.bounds.size.width, pad = 16, y = 0;
    if (spin) {
        UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        sp.color = UIColor.whiteColor;
        sp.center = CGPointMake(W/2, 16);
        [sp startAnimating];
        [_resultsView addSubview:sp];
        y = 36;
    }
    UILabel *l = [self _label:msg size:14 bold:NO color:[UIColor colorWithWhite:0.75 alpha:1]];
    l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; l.adjustsFontSizeToFitWidth = NO;
    CGSize fit = [l sizeThatFits:CGSizeMake(W - 2*pad, CGFLOAT_MAX)];
    l.frame = CGRectMake(pad, y, W - 2*pad, fit.height);
    [_resultsView addSubview:l];
    [self _finishResultsWithHeight:y + fit.height + 10 scroll:YES];
}

- (void)_showReplies {
    if (!_resultsView) return;
    [self _clearResults];
    CGFloat W = self.view.bounds.size.width, pad = 16, w = W - 2*pad, y = 0;

    UILabel *hdr = [self _label:[NSString stringWithFormat:@"%@ %@ · %@ · %@",
                                 [WMPrompts emojiForMode:_currentMode], [WMPrompts labelForMode:_currentMode],
                                 _length == WMReplyLengthLong ? @"Long" : @"Short",
                                 _provider == WMAPIProviderDeepSeek ? @"DeepSeek" : @"Claude"]
                           size:14 bold:YES color:WMRGB(115, 178, 255)];
    hdr.frame = CGRectMake(pad, y, w, 20);
    [_resultsView addSubview:hdr];
    y += 28;

    for (NSInteger i = 0; i < (NSInteger)_replies.count; i++) {
        UIView *card = [UIView new];
        card.backgroundColor = WM_CARD;
        card.layer.cornerRadius = 14;

        UILabel *body = [UILabel new];
        body.text = _replies[i];
        body.textColor = [UIColor colorWithWhite:0.93 alpha:1];
        body.font = [UIFont systemFontOfSize:15];
        body.numberOfLines = 0;
        CGSize fit = [body sizeThatFits:CGSizeMake(w - 28, CGFLOAT_MAX)];
        body.frame = CGRectMake(14, 12, w - 28, fit.height);
        [card addSubview:body];

        CGFloat by = 12 + fit.height + 10;
        UIButton *save = [self _pill:@"Save" color:WM_FIELD action:@selector(_saveReply:)
                               frame:CGRectMake(w - 162, by, 70, 32)];
        save.tag = i;
        [card addSubview:save];
        UIButton *use = [self _pill:@"Use" color:WM_GREEN action:@selector(_useReply:)
                              frame:CGRectMake(w - 84, by, 70, 32)];
        use.tag = i;
        [card addSubview:use];

        CGFloat cardH = by + 32 + 12;
        card.frame = CGRectMake(pad, y, w, cardH);
        [_resultsView addSubview:card];
        y += cardH + 10;
    }

    UIButton *regen = [self _pill:@"↻  Regenerate" color:WM_FIELD action:@selector(_generate)
                            frame:CGRectMake(pad, y, w, 42)];
    regen.layer.cornerRadius = 11;
    [_resultsView addSubview:regen];
    y += 52;

    [self _finishResultsWithHeight:y scroll:YES];
}

- (void)_finishResultsWithHeight:(CGFloat)h scroll:(BOOL)scroll {
    CGRect f = _resultsView.frame; f.size.height = h; _resultsView.frame = f;
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, _resultsTop + h + 40);
    if (scroll) {
        CGFloat target = MIN(_resultsTop - 12, MAX(0, _scroll.contentSize.height - _scroll.bounds.size.height));
        [_scroll setContentOffset:CGPointMake(0, MAX(0, target)) animated:YES];
    }
}

- (void)_useReply:(UIButton *)b {
    if (b.tag < (NSInteger)_replies.count) [self _send:_replies[b.tag]];
}

// save an AI reply into one of this app's 5 quick-reply slots
- (void)_saveReply:(UIButton *)b {
    if (b.tag >= (NSInteger)_replies.count) return;
    NSString *text = _replies[b.tag];
    NSArray *qr = [WMQuickReplies repliesForCurrentApp];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save as quick reply"
        message:@"Replace which slot?" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)qr.count; i++) {
        NSString *cur = qr[i];
        if (cur.length > 34) cur = [[cur substringToIndex:34] stringByAppendingString:@"…"];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%ld. %@", (long)i + 1, cur]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [WMQuickReplies setReply:text atIndex:i];
            [WMSheet _toast:[NSString stringWithFormat:@"Saved to quick reply %ld ✓", (long)i + 1] in:self.view];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = b;
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - send into the chat

- (void)_send:(NSString *)text {
    [UIPasteboard generalPasteboard].string = text;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];

    UIWindow *mine = self.sheetWindow;
    _generation++;
    [UIView animateWithDuration:0.2 animations:^{ self.view.alpha = 0; } completion:^(BOOL f) {
        mine.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL ok = [WMSheet _insertIntoChat:text excluding:mine];
            UIWindow *app = [WMSheet _appWindowExcluding:mine];
            [WMSheet _toast:ok ? @"Inserted ✓  (also copied)"
                               : @"Copied ✓  Long-press the message box to paste" in:app];
            self.sheetWindow = nil;
        });
    }];
}

+ (UIWindow *)_appWindowExcluding:(UIWindow *)ex {
    UIWindow *best = nil;
    for (UIWindow *w in WMActiveScene().windows) {
        if (w == ex || w.hidden || w == [WMBubble shared].overlayWindow) continue;
        if (w.windowLevel == UIWindowLevelNormal && (!best || w.isKeyWindow)) best = w;
    }
    return best;
}

+ (BOOL)_insertIntoChat:(NSString *)text excluding:(UIWindow *)ex {
    UIWindow *win = [self _appWindowExcluding:ex];
    if (!win) return NO;
    [win makeKeyWindow];

    // the lowest visible editable text input = the message bar
    __block UIView<UITextInput> *target = nil;
    __block CGFloat bestY = -1;
    __block void (^walk)(UIView *);
    __weak __block void (^weakWalk)(UIView *);
    walk = ^(UIView *v) {
        if (v.hidden || v.alpha < 0.01) return;
        BOOL editable =
            ([v isKindOfClass:[UITextView class]] && ((UITextView *)v).isEditable) ||
            ([v isKindOfClass:[UITextField class]] && ((UITextField *)v).isEnabled);
        if (editable) {
            CGRect r = [v convertRect:v.bounds toView:win];
            if (CGRectIntersectsRect(r, win.bounds) && CGRectGetMaxY(r) > bestY) {
                bestY = CGRectGetMaxY(r);
                target = (UIView<UITextInput> *)v;
            }
        }
        for (UIView *s in v.subviews) weakWalk(s);
    };
    weakWalk = walk;
    walk(win);
    if (!target) return NO;

    [target becomeFirstResponder];
    UITextRange *all = [target textRangeFromPosition:target.beginningOfDocument toPosition:target.endOfDocument];
    if (all && !all.isEmpty) [target replaceRange:all withText:@""];
    [target insertText:text];   // normal typing path -> app shows its Send button
    return YES;
}

+ (void)_toast:(NSString *)msg in:(UIView *)host {
    if (!host) return;
    UILabel *l = [UILabel new];
    l.text = msg;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont boldSystemFontOfSize:14];
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [WMRGB(30, 160, 80) colorWithAlphaComponent:0.95];
    l.layer.cornerRadius = 12;
    l.clipsToBounds = YES;
    CGSize s = [l sizeThatFits:CGSizeMake(host.bounds.size.width - 40, 40)];
    l.frame = CGRectMake(0, 0, MIN(s.width + 32, host.bounds.size.width - 24), 40);
    l.center = CGPointMake(host.bounds.size.width / 2, host.safeAreaInsets.top + 40);
    [host addSubview:l];
    [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ l.alpha = 0; }
                     completion:^(BOOL f) { [l removeFromSuperview]; }];
}

#pragma mark - misc

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return ![t.view isDescendantOfView:_card];   // only the dimmed area dismisses
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)_dismiss {
    _generation++;
    [UIView animateWithDuration:0.25 animations:^{ self.view.alpha = 0; } completion:^(BOOL f) {
        self.sheetWindow.hidden = YES;
        self.sheetWindow = nil;
    }];
}

- (void)presentGlobally {
    UIWindowScene *scene = WMActiveScene();
    if (!scene) return;
    _sheetWindow = [[UIWindow alloc] initWithWindowScene:scene];
    _sheetWindow.frame = scene.coordinateSpace.bounds;
    _sheetWindow.windowLevel = UIWindowLevelAlert + 60;   // above the bubble
    _sheetWindow.rootViewController = self;
    [_sheetWindow makeKeyAndVisible];
}

@end
