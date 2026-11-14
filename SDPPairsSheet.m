/*  SDPPairsSheet.m — "App Pairs…" from the icon long-press menu.

    A bottom sheet in its own SpringBoard window (main scene, above apps):
      • your saved pairs: tap to open, swipe left to flip top/bottom or delete
      • "New pair with <app>": pick the second app (recent apps first, then A–Z)
    No text fields, so SpringBoard never has to take keyboard focus.            */

#import "SDPlus.h"

static UIWindow *gSheetWindow;

static void SDPCloseSheet(void (^then)(void)) {
    UIWindow *w = gSheetWindow;
    if (!w) { if (then) then(); return; }
    UIViewController *root = w.rootViewController;
    UIView *card = root.view.subviews.lastObject;
    [UIView animateWithDuration:0.22 animations:^{
        root.view.backgroundColor = UIColor.clearColor;
        card.transform = CGAffineTransformMakeTranslation(0, card.bounds.size.height);
    } completion:^(BOOL d) {
        w.hidden = YES;
        if (gSheetWindow == w) gSheetWindow = nil;
        if (then) then();
    }];
}

#pragma mark - app picker

@interface SDPAppPicker : UITableViewController
@property (nonatomic, copy) NSString *exclude;
@property (nonatomic, copy) void (^onPick)(NSString *bid);
@end

@implementation SDPAppPicker {
    NSArray<NSString *> *_titles;                      // section titles ("Recent", "A", "B", …)
    NSArray<NSArray<NSDictionary *> *> *_rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choose the bottom app";
    self.tableView.rowHeight = 52;
    NSMutableArray *titles = [NSMutableArray array], *rows = [NSMutableArray array];
    NSArray *all = [SDPHost installedApps];
    NSMutableSet *known = [NSMutableSet set];
    for (NSDictionary *a in all) [known addObject:a[@"id"]];

    NSMutableArray *recent = [NSMutableArray array];
    for (NSString *bid in [SDPHost recentApps]) {
        if ([bid isEqualToString:self.exclude] || ![known containsObject:bid]) continue;
        [recent addObject:@{ @"id": bid, @"name": [SDPHost displayNameForBundleID:bid] }];
    }
    if (recent.count) { [titles addObject:@"Recent"]; [rows addObject:recent]; }

    NSMutableDictionary<NSString *, NSMutableArray *> *byLetter = [NSMutableDictionary dictionary];
    for (NSDictionary *a in all) {
        if ([a[@"id"] isEqualToString:self.exclude]) continue;
        NSString *n = a[@"name"];
        NSString *L = n.length ? [[n substringToIndex:1] uppercaseString] : @"#";
        unichar c = [L characterAtIndex:0];
        if (c < 'A' || c > 'Z') L = @"#";
        if (!byLetter[L]) byLetter[L] = [NSMutableArray array];
        [byLetter[L] addObject:a];
    }
    for (NSString *L in [byLetter.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [titles addObject:L];
        [rows addObject:byLetter[L]];
    }
    _titles = titles; _rows = rows;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _titles.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows[s].count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _titles[s]; }

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tv {
    NSMutableArray *t = [NSMutableArray array];
    for (NSString *s in _titles) [t addObject:[s isEqualToString:@"Recent"] ? @"★" : s];
    return t;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"app"]
                      ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"app"];
    NSDictionary *a = _rows[ip.section][ip.row];
    c.textLabel.text = a[@"name"];
    c.imageView.image = [SDPHost iconForBundleID:a[@"id"]];
    c.imageView.layer.cornerRadius = 8;
    c.imageView.clipsToBounds = YES;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.onPick) self.onPick(_rows[ip.section][ip.row][@"id"]);
}

@end

#pragma mark - pairs list

@interface SDPPairsSheet () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *bundleID;      // the icon that was long-pressed
@property (nonatomic, strong) UITableView *table;
@end

@implementation SDPPairsSheet

+ (void)presentForBundleID:(NSString *)bid {
    if (gSheetWindow) return;
    SDPPairsSheet *vc = [SDPPairsSheet new];
    vc.bundleID = bid;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];

    CGRect screen = UIScreen.mainScreen.bounds;
    UIWindowScene *scene = [SDPHost mainScene];
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:screen];
    w.frame = screen;
    w.windowLevel = 100002;
    w.backgroundColor = UIColor.clearColor;

    UIViewController *host = [UIViewController new];
    host.view.backgroundColor = UIColor.clearColor;
    UIButton *dim = [UIButton buttonWithType:UIButtonTypeCustom];
    dim.frame = screen;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addTarget:vc action:@selector(_close) forControlEvents:UIControlEventTouchUpInside];
    [host.view addSubview:dim];

    CGFloat h = MIN(screen.size.height * 0.72, 640);
    [host addChildViewController:nav];
    nav.view.frame = CGRectMake(0, screen.size.height - h, screen.size.width, h);
    nav.view.layer.cornerRadius = 18;
    nav.view.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    nav.view.clipsToBounds = YES;
    [host.view addSubview:nav.view];
    [nav didMoveToParentViewController:host];

    w.rootViewController = host;
    gSheetWindow = w;
    w.hidden = NO;
    nav.view.transform = CGAffineTransformMakeTranslation(0, h);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4 options:0 animations:^{
        host.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        nav.view.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"App Pairs";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                         target:self action:@selector(_close)];
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 60;
    [self.view addSubview:_table];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_table reloadData];
}

- (void)_close { SDPCloseSheet(nil); }

- (NSArray<NSDictionary *> *)_pairs { return [[SDPSettings shared] pairs]; }

- (NSString *)_name:(NSString *)bid { return [SDPHost displayNameForBundleID:bid]; }

// sections: 0 = new pair, 1 = saved pairs
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    return MAX((NSInteger)[self _pairs].count, 1);
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"New pair" : @"Your pairs";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return [NSString stringWithFormat:@"%@ opens on top, the app you pick opens in the Dynamic Stage window below it.",
                        [self _name:self.bundleID]];
    return [self _pairs].count ? @"Tap a pair to open it. Swipe left to flip top and bottom, or delete. "
                                  "Long-press either app's icon to open its pairs."
                               : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.imageView.layer.cornerRadius = 8;
    c.imageView.clipsToBounds = YES;
    if (ip.section == 0) {
        c.textLabel.text = [NSString stringWithFormat:@"%@ + …", [self _name:self.bundleID]];
        c.detailTextLabel.text = @"Choose the bottom app";
        c.imageView.image = [SDPHost iconForBundleID:self.bundleID];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    NSArray *pairs = [self _pairs];
    if (pairs.count == 0) {
        c.textLabel.text = @"No pairs yet";
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *p = pairs[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@ + %@", [self _name:p[@"top"]], [self _name:p[@"bottom"]]];
    c.detailTextLabel.text = [NSString stringWithFormat:@"⬆ %@   ⬇ %@", [self _name:p[@"top"]], [self _name:p[@"bottom"]]];
    c.imageView.image = [self _pairIconTop:p[@"top"] bottom:p[@"bottom"]];
    return c;
}

// Two icons stacked diagonally, like a Samsung app-pair icon.
- (UIImage *)_pairIconTop:(NSString *)top bottom:(NSString *)bottom {
    UIImage *a = [SDPHost iconForBundleID:top], *b = [SDPHost iconForBundleID:bottom];
    CGSize sz = CGSizeMake(44, 44);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect ra = CGRectMake(0, 0, 30, 30), rb = CGRectMake(14, 14, 30, 30);
        CGContextSaveGState(ctx.CGContext);
        [[UIBezierPath bezierPathWithRoundedRect:ra cornerRadius:7] addClip];
        [a drawInRect:ra];
        CGContextRestoreGState(ctx.CGContext);
        CGContextSaveGState(ctx.CGContext);
        [[UIBezierPath bezierPathWithRoundedRect:rb cornerRadius:7] addClip];
        [b drawInRect:rb];
        CGContextRestoreGState(ctx.CGContext);
    }];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        SDPAppPicker *picker = [[SDPAppPicker alloc] initWithStyle:UITableViewStylePlain];
        picker.exclude = self.bundleID;
        __weak typeof(self) ws = self;
        picker.onPick = ^(NSString *bid) { [ws _savePairTop:ws.bundleID bottom:bid]; };
        [self.navigationController pushViewController:picker animated:YES];
        return;
    }
    NSArray *pairs = [self _pairs];
    if (ip.row >= (NSInteger)pairs.count) return;
    NSDictionary *p = pairs[ip.row];
    SDPCloseSheet(^{ [SDPStage launchPairTop:p[@"top"] bottom:p[@"bottom"]]; });
}

- (void)_savePairTop:(NSString *)top bottom:(NSString *)bottom {
    if (top.length == 0 || bottom.length == 0 || [top isEqualToString:bottom]) return;
    NSMutableArray *pairs = [[self _pairs] mutableCopy];
    for (NSDictionary *p in [pairs copy]) {   // one pair per two apps, newest order wins
        BOOL same = ([p[@"top"] isEqualToString:top] && [p[@"bottom"] isEqualToString:bottom]) ||
                    ([p[@"top"] isEqualToString:bottom] && [p[@"bottom"] isEqualToString:top]);
        if (same) [pairs removeObject:p];
    }
    [pairs insertObject:@{ @"top": top, @"bottom": bottom } atIndex:0];
    [[SDPSettings shared] setPairs:pairs];
    SDPLog(@"pair saved: %@ + %@ (%lu pairs)", top, bottom, (unsigned long)pairs.count);
    [self.navigationController popToRootViewControllerAnimated:YES];
    [_table reloadData];
    [SDPHost toast:[NSString stringWithFormat:@"Saved %@ + %@. Tap it to open.", [self _name:top], [self _name:bottom]]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 1 || [self _pairs].count == 0) return nil;
    __weak typeof(self) ws = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            NSMutableArray *pairs = [[ws _pairs] mutableCopy];
            if (ip.row < (NSInteger)pairs.count) [pairs removeObjectAtIndex:ip.row];
            [[SDPSettings shared] setPairs:pairs];
            [ws.table reloadData];
            done(YES);
        }];
    UIContextualAction *flip = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Flip"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            NSMutableArray *pairs = [[ws _pairs] mutableCopy];
            if (ip.row < (NSInteger)pairs.count) {
                NSDictionary *p = pairs[ip.row];
                pairs[ip.row] = @{ @"top": p[@"bottom"], @"bottom": p[@"top"] };
            }
            [[SDPSettings shared] setPairs:pairs];
            [ws.table reloadData];
            done(YES);
        }];
    flip.backgroundColor = [UIColor colorWithRed:0x7C/255.0 green:0x5C/255.0 blue:0xFF/255.0 alpha:1];
    return [UISwipeActionsConfiguration configurationWithActions:@[ del, flip ]];
}

@end
