/*  ChakraEditor.m — the sheet behind "hold the ball, then let go".

    A bottom sheet in its own SpringBoard window, above the ball:
      • what is on the wheel, in order: drag ≡ to reorder, the red button to remove
      • "Add": every action this iOS supports, your shortcuts, and the apps you can open (A–Z)
    Changes are saved as they are made. There are no text fields here, so SpringBoard never has
    to take keyboard focus away from the app in front; the shortcuts' names and links are typed
    under Settings → Chakra, where a keyboard is no trouble.                                  */

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

#pragma mark - what is on the wheel

@interface ChakraItemsController : UITableViewController
- (BOOL)hasItem:(ChakraItem *)item;
- (BOOL)toggleItem:(ChakraItem *)item;          // YES if it is on the wheel afterwards
@end

@interface ChakraAddController : UITableViewController
@property (nonatomic, weak) ChakraItemsController *owner;
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
        [ChakraHost toast:[NSString stringWithFormat:@"The wheel holds %d entries. Remove one first.", CHAKRA_MAX_ITEMS]];
        return NO;
    }
    [_items addObject:item];
    [self _save];
    return YES;
}

// sections: 0 = the entries, 1 = add
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? MAX((NSInteger)_items.count, 1) : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"On the wheel" : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Drag ≡ to change the order. The first entries sit nearest the ball. "
                              "An entry that can't be shown right now stays here, greyed.";
    return @"Tap the ball to open the wheel, or slide from it and lift over an icon. "
            "Hold the ball, then drag, to move it.\n\n"
            "Look, haptics and your own shortcuts: Settings → Chakra.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section == 1) {
        c.textLabel.text = @"Add Apps, Actions and Shortcuts";
        c.textLabel.textColor = [ChakraSettings shared].accentColor;
        c.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        c.imageView.tintColor = [ChakraSettings shared].accentColor;
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

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 0 && _items.count > 0; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return (ip.section == 0 && _items.count > 0) ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 && _items.count > 0;
}

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 0 && _items.count > 1; }

- (NSIndexPath *)tableView:(UITableView *)tv targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from
       toProposedIndexPath:(NSIndexPath *)to {
    if (to.section != 0) return [NSIndexPath indexPathForRow:MAX((NSInteger)_items.count - 1, 0) inSection:0];
    return to;
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.section != 0 || (NSUInteger)from.row >= _items.count) return;
    ChakraItem *item = _items[(NSUInteger)from.row];
    [_items removeObjectAtIndex:(NSUInteger)from.row];
    [_items insertObject:item atIndex:MIN((NSUInteger)MAX(to.row, 0), _items.count)];
    [self _save];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.section != 0 || (NSUInteger)ip.row >= _items.count) return;
    [_items removeObjectAtIndex:(NSUInteger)ip.row];
    [self _save];
    if (_items.count == 0) [tv reloadData];                  // the last row turns into the "nothing yet" row
    else [tv deleteRowsAtIndexPaths:@[ ip ] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;
    ChakraAddController *add = [[ChakraAddController alloc] initWithStyle:UITableViewStylePlain];
    add.owner = self;
    [self.navigationController pushViewController:add animated:YES];
}

@end

#pragma mark - add

@implementation ChakraAddController {
    NSArray<NSString *> *_titles;                  // section titles
    NSArray<NSString *> *_strip;                   // what the index strip on the right shows
    NSArray<NSArray<ChakraItem *> *> *_rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Add to the Wheel";
    self.tableView.rowHeight = 52;

    NSMutableArray *titles = [NSMutableArray array], *strip = [NSMutableArray array], *rows = [NSMutableArray array];

    NSMutableArray<ChakraItem *> *actions = [NSMutableArray array];
    for (ChakraAction *a in [ChakraActions all]) {
        if (![ChakraActions available:a.ident]) continue;        // nothing that would do nothing on this iOS
        ChakraItem *item = [ChakraItem itemWithKind:ChakraKindAction ident:a.ident];
        if (item) [actions addObject:item];
    }
    if (actions.count) { [titles addObject:@"Actions"]; [strip addObject:@"●"]; [rows addObject:actions]; }

    NSMutableArray<ChakraItem *> *shortcuts = [NSMutableArray array];
    for (NSInteger slot = 1; slot <= CHAKRA_SLOTS; slot++) {
        ChakraItem *item = [ChakraItem itemWithKind:ChakraKindShortcut ident:[NSString stringWithFormat:@"%ld", (long)slot]];
        if (item) [shortcuts addObject:item];
    }
    [titles addObject:@"Shortcuts"]; [strip addObject:@"◆"]; [rows addObject:shortcuts];

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
        [titles addObject:letter]; [strip addObject:letter]; [rows addObject:byLetter[letter]];
    }
    _titles = titles; _strip = strip; _rows = rows;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_titles.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return (NSInteger)_rows[(NSUInteger)section].count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section { return _titles[(NSUInteger)section]; }
- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tv { return _strip; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (![_titles[(NSUInteger)section] isEqualToString:@"Shortcuts"]) return nil;
    return @"A shortcut is a link, an app's URL scheme, or the name of a shortcut in the Shortcuts app. "
            "Type them in under Settings → Chakra; an empty one can't be added.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"entry"]
                      ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"entry"];
    ChakraItem *item = _rows[(NSUInteger)ip.section][(NSUInteger)ip.row];
    BOOL ok = [item available];
    c.textLabel.text = item.title;
    c.textLabel.textColor = ok ? UIColor.labelColor : UIColor.secondaryLabelColor;
    c.detailTextLabel.text = (item.kind == ChakraKindApp) ? nil : item.subtitle;
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
    CGFloat h = MIN(sz.height * 0.78, 700);
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
        ChakraLog(@"editor closed: %lu entries on the wheel", (unsigned long)[ChakraItems all].count);
    }];
}

+ (void)debugPushAdd {
    if (!gSheetWindow) [self present];
    UINavigationController *nav = gSheetNav;
    ChakraItemsController *list = (ChakraItemsController *)nav.viewControllers.firstObject;
    if (![list isKindOfClass:ChakraItemsController.class]) return;
    ChakraAddController *add = [[ChakraAddController alloc] initWithStyle:UITableViewStylePlain];
    add.owner = list;
    [nav pushViewController:add animated:NO];
}

@end
