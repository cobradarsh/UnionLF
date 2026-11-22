/*  AtelierSheets.m — the app picker and the Sets list.

    Bottom sheets in a SpringBoard window of their own, above the bench. Lists only: no text
    fields, so SpringBoard never has to take keyboard focus (a set is named by picking from a
    short list of names).                                                                     */

#import "Atelier.h"

static AtelierWindow *gSheetWindow;
static UINavigationController *gSheetNav;

@interface AtelierSheetList : UITableViewController
- (void)debugPick:(NSUInteger)row;
@end

@implementation AtelierSheetList

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                             target:self action:@selector(_close)];
    }
}

- (void)_close { [AtelierSheets dismiss]; }

// what a list has unless it says otherwise
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 0; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {}

// Row n counted through the sections, top to bottom.
- (void)debugPick:(NSUInteger)row {
    NSUInteger seen = 0;
    for (NSInteger s = 0; s < [self numberOfSectionsInTableView:self.tableView]; s++) {
        NSInteger rows = [self tableView:self.tableView numberOfRowsInSection:s];
        if (row < seen + (NSUInteger)rows) {
            [self tableView:self.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)(row - seen) inSection:s]];
            return;
        }
        seen += (NSUInteger)rows;
    }
    AtelierLog(@"pick %lu: the list has %lu rows", (unsigned long)row, (unsigned long)seen);
}

@end

#pragma mark - app picker

@interface AtelierAppPicker : AtelierSheetList
@property (nonatomic, copy) NSArray<NSString *> *exclude;
@property (nonatomic, copy) void (^onPick)(NSString *bid);
@end

@implementation AtelierAppPicker {
    NSArray<NSString *> *_titles;                      // section titles ("Recent", "A", "B", …)
    NSArray<NSArray<NSDictionary *> *> *_rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52;
    NSMutableArray *titles = [NSMutableArray array], *rows = [NSMutableArray array];
    NSArray<NSDictionary *> *all = [AtelierHost installedApps];
    NSMutableSet *known = [NSMutableSet set];
    for (NSDictionary *a in all) [known addObject:a[@"id"]];
    NSArray<NSString *> *skip = self.exclude ?: @[];

    NSMutableArray *recent = [NSMutableArray array];
    for (NSString *bid in [AtelierHost recentApps]) {
        if ([skip containsObject:bid] || ![known containsObject:bid]) continue;
        [recent addObject:@{ @"id": bid, @"name": [AtelierHost displayNameForBundleID:bid] }];
        if (recent.count >= 8) break;
    }
    if (recent.count) { [titles addObject:@"Recent"]; [rows addObject:recent]; }

    NSMutableDictionary<NSString *, NSMutableArray *> *byLetter = [NSMutableDictionary dictionary];
    for (NSDictionary *a in all) {
        if ([skip containsObject:a[@"id"]]) continue;
        NSString *n = a[@"name"];
        NSString *letter = n.length ? [[n substringToIndex:1] uppercaseString] : @"#";
        unichar c = [letter characterAtIndex:0];
        if (c < 'A' || c > 'Z') letter = @"#";
        if (!byLetter[letter]) byLetter[letter] = [NSMutableArray array];
        [byLetter[letter] addObject:a];
    }
    for (NSString *letter in [byLetter.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [titles addObject:letter];
        [rows addObject:byLetter[letter]];
    }
    _titles = titles;
    _rows = rows;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_titles.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_rows[(NSUInteger)s].count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _titles[(NSUInteger)s]; }

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tv {
    NSMutableArray *t = [NSMutableArray array];
    for (NSString *s in _titles) [t addObject:[s isEqualToString:@"Recent"] ? @"★" : s];
    return t;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"app"]
                      ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"app"];
    NSDictionary *a = _rows[(NSUInteger)ip.section][(NSUInteger)ip.row];
    c.textLabel.text = a[@"name"];
    c.imageView.image = [AtelierHost iconForBundleID:a[@"id"]];
    c.imageView.layer.cornerRadius = 8;
    c.imageView.clipsToBounds = YES;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *bid = _rows[(NSUInteger)ip.section][(NSUInteger)ip.row][@"id"];
    void (^pick)(NSString *) = self.onPick;
    [AtelierSheets dismiss];
    if (pick) pick(bid);
}

@end

#pragma mark - names for a set

@interface AtelierNamePicker : AtelierSheetList
@property (nonatomic, copy) NSString *current;
@property (nonatomic, copy) NSString *plain;         // what the set is called without a name: its apps
@property (nonatomic, copy) void (^onPick)(NSString *name);
@end

@implementation AtelierNamePicker {
    NSArray<NSString *> *_names;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Name";
    _names = @[ @"", @"Work", @"Study", @"Markets", @"Research", @"Writing", @"Reading", @"Chat", @"Social",
                @"Media", @"Travel", @"Shopping", @"Money", @"Morning", @"Evening" ];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_names.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *name = _names[(NSUInteger)ip.row];
    c.textLabel.text = name.length ? name : self.plain;
    c.detailTextLabel.text = name.length ? nil : @"Its apps' names";
    c.accessoryType = [name isEqualToString:self.current ?: @""] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (self.onPick) self.onPick(_names[(NSUInteger)ip.row]);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - sets

@interface AtelierSetsList : AtelierSheetList
@end

@implementation AtelierSetsList

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sets";
    self.tableView.rowHeight = 62;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSArray<NSDictionary *> *)_sets { return [[AtelierSettings shared] sets]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)[self _sets].count, 1); }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return [self _sets].count
        ? @"Tap a set to open its apps on the bench. Swipe left to rename it, move it up or delete it. "
           "Hold the icon of any app in a set to open the set from the Home Screen."
        : @"Put two to five apps on the bench, then choose Save as Set from the ··· menu above the main app.";
}

// The first three icons, overlapping.
- (UIImage *)_iconFor:(NSArray<NSString *> *)apps {
    CGSize sz = CGSizeMake(62, 44);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:sz] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        NSUInteger n = MIN((NSUInteger)3, apps.count);
        for (NSUInteger i = 0; i < n; i++) {
            NSUInteger k = n - 1 - i;                    // the first app is drawn last, on top
            CGRect r = CGRectMake(k * 13.0, 6, 32, 32);
            CGContextSaveGState(ctx.CGContext);
            [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:7.5] addClip];
            [[AtelierHost iconForBundleID:apps[k]] drawInRect:r];
            CGContextRestoreGState(ctx.CGContext);
        }
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray<NSDictionary *> *sets = [self _sets];
    if (sets.count == 0) {
        c.textLabel.text = @"No sets yet";
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *set = sets[(NSUInteger)ip.row];
    NSArray<NSString *> *apps = set[@"apps"];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *bid in apps) [names addObject:[AtelierHost displayNameForBundleID:bid]];
    static NSArray<NSString *> *layouts;
    if (!layouts) layouts = @[ @"Side", @"Top", @"Split" ];
    c.textLabel.text = [AtelierSheets setTitle:set];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", layouts[(NSUInteger)[set[@"layout"] integerValue] % 3],
                              [names componentsJoinedByString:@", "]];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [self _iconFor:apps];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray<NSDictionary *> *sets = [self _sets];
    if ((NSUInteger)ip.row >= sets.count) return;
    NSDictionary *set = sets[(NSUInteger)ip.row];
    [AtelierSheets dismiss];
    [[AtelierBench shared] openSet:set];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSUInteger row = (NSUInteger)ip.row;
    if (row >= [self _sets].count) return nil;
    __weak typeof(self) weak = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            NSMutableArray *sets = [[weak _sets] mutableCopy];
            if (row < sets.count) [sets removeObjectAtIndex:row];
            [[AtelierSettings shared] setSets:sets];
            [weak.tableView reloadData];
            done(YES);
        }];
    UIContextualAction *up = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Up"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            NSMutableArray *sets = [[weak _sets] mutableCopy];
            if (row > 0 && row < sets.count) [sets exchangeObjectAtIndex:row withObjectAtIndex:row - 1];
            [[AtelierSettings shared] setSets:sets];
            [weak.tableView reloadData];
            done(YES);
        }];
    UIContextualAction *name = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Name"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [weak _renameRow:row];
            done(YES);
        }];
    name.backgroundColor = [UIColor colorWithRed:0x5E / 255.0 green:0x5C / 255.0 blue:0xE6 / 255.0 alpha:1];
    return [UISwipeActionsConfiguration configurationWithActions:(row > 0 ? @[ del, name, up ] : @[ del, name ])];
}

- (void)_renameRow:(NSUInteger)row {
    NSArray<NSDictionary *> *sets = [self _sets];
    if (row >= sets.count) return;
    NSDictionary *set = sets[row];
    AtelierNamePicker *picker = [[AtelierNamePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.current = set[@"name"];
    NSMutableDictionary *bare = [set mutableCopy];
    bare[@"name"] = @"";
    picker.plain = [AtelierSheets setTitle:bare];
    picker.onPick = ^(NSString *name) {
        NSMutableArray *all = [[[AtelierSettings shared] sets] mutableCopy];
        if (row >= all.count) return;
        NSMutableDictionary *changed = [all[row] mutableCopy];
        changed[@"name"] = name ?: @"";
        all[row] = changed;
        [[AtelierSettings shared] setSets:all];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

@end

#pragma mark - the sheet

@implementation AtelierSheets

+ (BOOL)isOpen { return gSheetWindow != nil; }

+ (void)dismiss {
    AtelierWindow *w = gSheetWindow;
    if (!w) return;
    gSheetWindow = nil;
    gSheetNav = nil;
    UIViewController *root = w.rootViewController;
    UIView *card = root.view.subviews.lastObject;
    [UIView animateWithDuration:0.2 animations:^{
        root.view.backgroundColor = UIColor.clearColor;
        card.transform = CGAffineTransformMakeTranslation(0, card.bounds.size.height);
    } completion:^(BOOL done) { w.hidden = YES; }];
}

+ (void)_present:(AtelierSheetList *)list {
    if (gSheetWindow) [self dismiss];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    CGSize screen = [AtelierHost screenSize];
    UIWindowLevel level = MAX(1005, (UIWindowLevel)[[AtelierSettings shared] tune:@"windowLevel" fallback:999] + 6);
    AtelierWindow *w = [AtelierHost windowAtLevel:level];
    UIViewController *host = w.rootViewController;

    UIButton *dim = [UIButton buttonWithType:UIButtonTypeCustom];
    dim.frame = host.view.bounds;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [host.view addSubview:dim];

    CGFloat h = MIN(screen.height * 0.72, 660);
    [host addChildViewController:nav];
    nav.view.frame = CGRectMake(0, screen.height - h, screen.width, h);
    nav.view.layer.cornerRadius = 18;
    nav.view.layer.cornerCurve = kCACornerCurveContinuous;
    nav.view.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    nav.view.clipsToBounds = YES;
    [host.view addSubview:nav.view];
    [nav didMoveToParentViewController:host];

    gSheetWindow = w;
    gSheetNav = nav;
    w.hidden = NO;
    nav.view.transform = CGAffineTransformMakeTranslation(0, h);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4 options:0 animations:^{
        host.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        nav.view.transform = CGAffineTransformIdentity;
    } completion:nil];
}

+ (void)pickAppWithTitle:(NSString *)title excluding:(NSArray<NSString *> *)exclude then:(void (^)(NSString *))then {
    AtelierAppPicker *picker = [[AtelierAppPicker alloc] initWithStyle:UITableViewStylePlain];
    picker.title = title;
    picker.exclude = exclude;
    picker.onPick = then;
    [self _present:picker];
}

+ (void)showSets {
    [self _present:[[AtelierSetsList alloc] initWithStyle:UITableViewStyleInsetGrouped]];
}

+ (void)debugPick:(NSUInteger)row {
    UIViewController *top = gSheetNav.topViewController;
    if ([top isKindOfClass:AtelierSheetList.class]) [(AtelierSheetList *)top debugPick:row];
    else AtelierLog(@"pick: no list on screen");
}

+ (NSString *)setTitle:(NSDictionary *)set {
    NSString *name = set[@"name"];
    if ([name isKindOfClass:NSString.class] && name.length) return name;
    NSArray<NSString *> *apps = [set[@"apps"] isKindOfClass:NSArray.class] ? set[@"apps"] : @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *bid in apps) {
        if (names.count == 3) break;
        [names addObject:[AtelierHost displayNameForBundleID:bid]];
    }
    NSString *title = [names componentsJoinedByString:@" + "];
    if (apps.count > names.count) title = [title stringByAppendingFormat:@" +%lu", (unsigned long)(apps.count - names.count)];
    return title.length ? title : @"Set";
}

@end
