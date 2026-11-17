/*  ChakraEditor.m — the sheet for changing what is on the wheel.

    Opened by the "Edit" entry on the wheel, or by holding the ball and letting go. A bottom
    sheet in its own SpringBoard window, above the ball:

      Add to the wheel   three lists to pick from: every app on the iPhone (A–Z, with the index
                         strip down the side), every action and switch this iOS supports, and
                         your four shortcuts. Tap to add, tap again to take off.
      On the wheel       what is there now, in order: drag ≡ to reorder, the red button to remove.

    Changes are saved as they are made. There are no text fields here, so SpringBoard never has
    to take keyboard focus away from the app in front; searching apps by name, and typing the
    shortcuts' names and links, is done under Settings → Chakra, where a keyboard is no trouble. */

#import "Chakra.h"

static UIWindow *gSheetWindow;
static __weak UINavigationController *gSheetNav;
static NSCache<NSString *, UIImage *> *gThumbs;

static UIImage *ChakraThumb(ChakraItem *item, CGFloat side) {
    if (!gThumbs) gThumbs = [NSCache new];
    NSString *key = [NSString stringWithFormat:@"%@|%.0f|%d", item.key, side, (int)item.isOn];
    UIImage *thumb = [gThumbs objectForKey:key];
    if (thumb) return thumb;
    UIImage *src = [item iconWithSize:side];
    if (!src) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    thumb = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format]
             imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [src drawInRect:CGRectMake(0, 0, side, side)]; }];
    if (thumb) [gThumbs setObject:thumb forKey:key];
    return thumb;
}

static UIImage *ChakraRowGlyph(NSString *symbol) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:symbol withConfiguration:cfg];
}

#pragma mark - what is on the wheel

@interface ChakraItemsController : UITableViewController
- (BOOL)hasItem:(ChakraItem *)item;
- (BOOL)toggleItem:(ChakraItem *)item;          // YES if it is on the wheel afterwards
- (void)pushAdd:(NSInteger)kind animated:(BOOL)animated;
@end

// One list to add from. kind: 0 apps, 1 actions and switches, 2 shortcuts.
@interface ChakraAddController : UITableViewController
@property (nonatomic, weak) ChakraItemsController *owner;
@property (nonatomic) NSInteger kind;
@end

@implementation ChakraItemsController {
    NSMutableArray<ChakraItem *> *_items;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chakra";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self action:@selector(_done)];
    self.tableView.rowHeight = 56;
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    _items = [[ChakraItems all] mutableCopy];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)_done { [ChakraEditor dismiss]; }
- (void)_save { [ChakraItems save:_items]; }

- (BOOL)hasItem:(ChakraItem *)item { return [_items containsObject:item]; }

- (BOOL)toggleItem:(ChakraItem *)item {
    if (!item) return NO;
    if ([_items containsObject:item]) {
        [_items removeObject:item];
        [self _save];
        return NO;
    }
    if (_items.count >= CHAKRA_MAX_ITEMS) {
        [ChakraHost toast:[NSString stringWithFormat:@"The wheel holds %d entries. Take one off first.", CHAKRA_MAX_ITEMS]];
        return NO;
    }
    [_items addObject:item];
    [self _save];
    return YES;
}

// sections: 0 = add, 1 = the entries
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : MAX((NSInteger)_items.count, 1);
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Add to the wheel";
    return [NSString stringWithFormat:@"On the wheel (%lu of %d)", (unsigned long)_items.count, CHAKRA_MAX_ITEMS];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0) return nil;
    return @"Drag ≡ to change the order: the first entries sit nearest the ball. An entry that can't be "
            "shown right now stays here, greyed.\n\n"
            "Look, gestures, the ball's position and your own shortcuts: Settings → Chakra.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIColor *accent = [ChakraSettings shared].accentColor;
    if (ip.section == 0) {
        NSArray<NSString *> *titles = @[ @"Apps", @"Actions and Switches", @"Shortcuts" ];
        NSArray<NSString *> *details = @[ @"Every app on this iPhone, A to Z", @"Home, Last App, Torch, Wi-Fi and the rest",
                                          @"Your own links and Shortcuts" ];
        NSArray<NSString *> *symbols = @[ @"square.grid.2x2.fill", @"bolt.circle.fill", @"star.circle.fill" ];
        c.textLabel.text = titles[(NSUInteger)ip.row];
        c.detailTextLabel.text = details[(NSUInteger)ip.row];
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.imageView.image = ChakraRowGlyph(symbols[(NSUInteger)ip.row]);
        c.imageView.tintColor = accent;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (_items.count == 0) {
        c.textLabel.text = @"Nothing on the wheel yet";
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        return c;
    }
    ChakraItem *item = _items[(NSUInteger)ip.row];
    BOOL ok = [item available];
    c.textLabel.text = item.title;
    c.textLabel.textColor = ok ? UIColor.labelColor : UIColor.secondaryLabelColor;
    c.detailTextLabel.text = item.subtitle;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = ChakraThumb(item, 36);
    c.imageView.alpha = ok ? 1.0 : 0.4;
    c.showsReorderControl = YES;
    return c;
}

- (BOOL)_isEntry:(NSIndexPath *)ip { return ip.section == 1 && _items.count > 0; }

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return [self _isEntry:ip]; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return [self _isEntry:ip] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip { return [self _isEntry:ip]; }

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1 && _items.count > 1; }

- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from
       toProposedIndexPath:(NSIndexPath *)to {
    if (to.section < 1) return [NSIndexPath indexPathForRow:0 inSection:1];
    return to;
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.section != 1 || (NSUInteger)from.row >= _items.count) return;
    ChakraItem *item = _items[(NSUInteger)from.row];
    [_items removeObjectAtIndex:(NSUInteger)from.row];
    [_items insertObject:item atIndex:MIN((NSUInteger)MAX(to.row, 0), _items.count)];
    [self _save];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.section != 1 || (NSUInteger)ip.row >= _items.count) return;
    [_items removeObjectAtIndex:(NSUInteger)ip.row];
    [self _save];
    [tv reloadData];                                         // the count in the heading, and the "nothing yet" row
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 0) return;
    [self pushAdd:ip.row animated:YES];
}

- (void)pushAdd:(NSInteger)kind animated:(BOOL)animated {
    kind = MAX(0, MIN(2, kind));
    // the app list is plain so it can have the A–Z strip; the two short lists are grouped, which lets their notes wrap
    ChakraAddController *add = [[ChakraAddController alloc] initWithStyle:(kind == 0 ? UITableViewStylePlain : UITableViewStyleInsetGrouped)];
    add.owner = self;
    add.kind = kind;
    [self.navigationController pushViewController:add animated:animated];
}

@end

#pragma mark - add

@implementation ChakraAddController {
    NSArray<NSString *> *_titles;                  // section titles
    NSArray<NSString *> *_strip;                   // the index strip (apps only)
    NSArray<NSArray<ChakraItem *> *> *_rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52;
    NSMutableArray *titles = [NSMutableArray array], *rows = [NSMutableArray array];

    if (self.kind == 1) {
        self.title = @"Actions and Switches";
        NSMutableArray<ChakraItem *> *plain = [NSMutableArray array], *switches = [NSMutableArray array];
        for (ChakraAction *a in [ChakraActions all]) {
            if (![ChakraActions available:a.ident]) continue;        // nothing that would do nothing on this iOS
            ChakraItem *item = [ChakraItem itemWithKind:ChakraKindAction ident:a.ident];
            if (item) [(a.toggle ? switches : plain) addObject:item];
        }
        if (plain.count) { [titles addObject:@"Actions"]; [rows addObject:plain]; }
        if (switches.count) { [titles addObject:@"Switches"]; [rows addObject:switches]; }
    } else if (self.kind == 2) {
        self.title = @"Shortcuts";
        NSMutableArray<ChakraItem *> *shortcuts = [NSMutableArray array];
        for (NSInteger slot = 1; slot <= CHAKRA_SLOTS; slot++) {
            ChakraItem *item = [ChakraItem itemWithKind:ChakraKindShortcut ident:[NSString stringWithFormat:@"%ld", (long)slot]];
            if (item) [shortcuts addObject:item];
        }
        [titles addObject:@"Your shortcuts"]; [rows addObject:shortcuts];
    } else {
        self.title = @"Apps";
        NSMutableDictionary<NSString *, NSMutableArray<ChakraItem *> *> *byLetter = [NSMutableDictionary dictionary];
        for (NSDictionary *app in [ChakraHost installedApps]) {
            NSString *name = app[@"name"];
            NSString *letter = name.length ? [[name substringToIndex:1] uppercaseString] : @"#";
            unichar ch = [letter characterAtIndex:0];
            if (ch < 'A' || ch > 'Z') letter = @"#";
            ChakraItem *item = [ChakraItem itemWithKind:ChakraKindApp ident:app[@"id"]];
            if (!item) continue;
            if (!byLetter[letter]) byLetter[letter] = [NSMutableArray array];
            [byLetter[letter] addObject:item];
        }
        for (NSString *letter in [byLetter.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [titles addObject:letter]; [rows addObject:byLetter[letter]];
        }
        _strip = [titles copy];
    }
    _titles = titles;
    _rows = rows;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_titles.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)_rows[(NSUInteger)section].count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section { return _titles[(NSUInteger)section]; }
- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tv { return _strip; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)_titles.count - 1) return nil;
    if (self.kind == 1) return @"A switch on the wheel shows whether it is on, and tapping it leaves the wheel open.";
    if (self.kind == 2) return @"A shortcut is a web link, an app's own link, or the name of a shortcut in the Shortcuts app. "
                               "Type them in under Settings → Chakra; an empty one can't be added.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"entry"]
                      ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"entry"];
    ChakraItem *item = _rows[(NSUInteger)ip.section][(NSUInteger)ip.row];
    BOOL ok = [item available];
    c.textLabel.text = item.title;
    c.textLabel.textColor = ok ? UIColor.labelColor : UIColor.secondaryLabelColor;
    c.detailTextLabel.text = (item.kind == ChakraKindShortcut) ? item.subtitle : nil;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = ChakraThumb(item, 34);
    c.imageView.alpha = ok ? 1.0 : 0.4;
    c.accessoryType = [self.owner hasItem:item] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.tintColor = [ChakraSettings shared].accentColor;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    ChakraItem *item = _rows[(NSUInteger)ip.section][(NSUInteger)ip.row];
    if (![item available] && ![self.owner hasItem:item]) {
        [ChakraHost toast:@"This shortcut is empty. Fill it in under Settings → Chakra first."];
        return;
    }
    BOOL on = [self.owner toggleItem:item];
    [tv cellForRowAtIndexPath:ip].accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

@end

#pragma mark - the sheet

@implementation ChakraEditor

+ (BOOL)isOpen { return gSheetWindow != nil; }

+ (void)present {
    if (gSheetWindow) return;
    if ([ChakraWheel shared].isOpen) [[ChakraWheel shared] closeAnimated:NO completion:nil];

    CGSize sz = [ChakraHost screenSize];
    UIWindow *w = [ChakraHost overlayWindowAtLevel:100020];
    w.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIViewController *host = w.rootViewController;

    UIButton *dim = [UIButton buttonWithType:UIButtonTypeCustom];
    dim.frame = host.view.bounds;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [host.view addSubview:dim];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:
                                   [[ChakraItemsController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    CGFloat h = MIN(sz.height * 0.8, 720);
    [host addChildViewController:nav];
    nav.view.frame = CGRectMake(0, sz.height - h, sz.width, h);
    nav.view.layer.cornerRadius = 20;
    nav.view.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    nav.view.clipsToBounds = YES;
    [host.view addSubview:nav.view];
    [nav didMoveToParentViewController:host];

    gSheetWindow = w;
    gSheetNav = nav;
    [[ChakraBall shared] refresh];                               // the ball steps aside while the sheet is up
    w.hidden = NO;
    nav.view.transform = CGAffineTransformMakeTranslation(0, h);
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4 options:0 animations:^{
        host.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        nav.view.transform = CGAffineTransformIdentity;
    } completion:nil];
    ChakraLog(@"editor opened");
}

+ (void)dismiss {
    UIWindow *w = gSheetWindow;
    if (!w) return;
    UIViewController *host = w.rootViewController;
    UIView *sheet = gSheetNav.view;
    [UIView animateWithDuration:0.22 animations:^{
        host.view.backgroundColor = UIColor.clearColor;
        sheet.transform = CGAffineTransformMakeTranslation(0, sheet.bounds.size.height);
    } completion:^(BOOL done) {
        w.hidden = YES;
        if (gSheetWindow == w) gSheetWindow = nil;
        [gThumbs removeAllObjects];
        [[ChakraBall shared] refresh];
        [ChakraItems warmIcons];
        ChakraLog(@"editor closed: %lu entries on the wheel", (unsigned long)[ChakraItems all].count);
    }];
}

+ (void)debugPushAdd:(NSInteger)kind {
    if (!gSheetWindow) [self present];
    UINavigationController *nav = gSheetNav;
    ChakraItemsController *list = (ChakraItemsController *)nav.viewControllers.firstObject;
    if (![list isKindOfClass:ChakraItemsController.class]) return;
    [nav popToRootViewControllerAnimated:NO];
    [list pushAdd:kind animated:NO];
}

@end
