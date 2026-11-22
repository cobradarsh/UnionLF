/*  AtelierSheets.m — the app picker and the Sets list.

    Bottom sheets in a SpringBoard window of their own, above the bench.

    The app picker has a search field at the top, in the keyboard's focus from the moment the
    sheet is up. That takes two things in SpringBoard: a window that may become the key window
    (every other window of Atelier's refuses to), and SpringBoard's keyboard focus, which
    otherwise stays with the app in front (AtelierHost +takeKeyboardForWindow:, the recipe
    Wingman Plus uses on this phone). Both are given back the moment the sheet closes, by
    whatever road. The Sets list has no text field and takes neither (a set is named by picking
    from a short list of names).

    Nothing here lists an app that SporeX hides: not in Recents, not in A to Z, not in a search,
    not in the names of a set.                                                                 */

#import "Atelier.h"

static AtelierWindow *gSheetWindow;
static UINavigationController *gSheetNav;

static NSString *AtelierFold(NSString *text) {
    return [(text ?: @"") stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                              locale:nil];
}

static NSArray<NSString *> *AtelierShownApps(id raw) {          // a set's apps without the hidden ones
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id bid in (NSArray *)raw) if ([bid isKindOfClass:NSString.class] && ![AtelierHost isHiddenApp:bid]) [out addObject:bid];
    return out;
}

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

@interface AtelierAppPicker : AtelierSheetList <UITextFieldDelegate>
@property (nonatomic, copy) NSArray<NSString *> *exclude;
@property (nonatomic, copy) void (^onPick)(NSString *bid);
@property (nonatomic, readonly) BOOL keyboardUp;
- (BOOL)focus;                                                  // the search field takes the keyboard
- (void)debugType:(NSString *)text;
- (void)debugReturn;
- (NSArray<NSString *> *)debugWhere;
- (NSString *)debugState;
@end

@implementation AtelierAppPicker {
    NSArray<NSString *> *_titles;                      // section titles ("Recent", "A", "B", …)
    NSArray<NSArray<NSDictionary *> *> *_rows;         // what is shown while the field is empty
    NSArray<NSDictionary *> *_all;                     // every app that may be listed: @{ id, name, fold }
    NSArray<NSDictionary *> *_found;                   // the matches, best first; nil while the field is empty
    NSString *_asked;                                  // what the list was last searched for
    UIView *_bar;
    UISearchTextField *_field;
    CGRect _keyboard;                                  // on the screen; empty while it is down
}

static const CGFloat kSearchBar = 52;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;       // scrolling the list makes room for it
    UIColor *paper = [UIColor colorWithWhite:0.07 alpha:1];
    self.tableView.backgroundColor = paper;

    // every app that may be listed, A to Z, with its name folded for searching
    NSArray<NSString *> *skip = self.exclude ?: @[];
    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *known = [NSMutableDictionary dictionary];
    for (NSDictionary *a in [AtelierHost listedApps]) {
        if ([skip containsObject:a[@"id"]]) continue;
        NSDictionary *entry = @{ @"id": a[@"id"], @"name": a[@"name"] ?: a[@"id"], @"fold": AtelierFold(a[@"name"]) };
        [all addObject:entry];
        known[a[@"id"]] = entry;
    }
    _all = all;

    NSMutableArray *titles = [NSMutableArray array], *rows = [NSMutableArray array];
    NSMutableArray *recent = [NSMutableArray array];
    for (NSString *bid in [AtelierHost recentApps]) {
        if (!known[bid]) continue;
        [recent addObject:known[bid]];
        if (recent.count >= 8) break;
    }
    if (recent.count) { [titles addObject:@"Recent"]; [rows addObject:recent]; }
    NSMutableDictionary<NSString *, NSMutableArray *> *byLetter = [NSMutableDictionary dictionary];
    for (NSDictionary *a in all) {
        NSString *n = a[@"fold"];
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

    // The search field: in a bar of its own under the title, so it stays put while the list
    // scrolls. The list starts below it (the bar's height is added to the safe area).
    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, kSearchBar)];
    _bar.backgroundColor = paper;
    _field = [[UISearchTextField alloc] initWithFrame:CGRectMake(14, 6, 320 - 28, 38)];
    _field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _field.placeholder = @"Search apps";
    _field.font = [UIFont systemFontOfSize:17];
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.spellCheckingType = UITextSpellCheckingTypeNo;
    _field.smartQuotesType = UITextSmartQuotesTypeNo;
    _field.smartDashesType = UITextSmartDashesTypeNo;
    _field.returnKeyType = UIReturnKeyGo;                       // Return picks the first match
    _field.enablesReturnKeyAutomatically = YES;
    _field.clearButtonMode = UITextFieldViewModeWhileEditing;
    _field.keyboardAppearance = UIKeyboardAppearanceDark;
    _field.delegate = self;
    _field.accessibilityLabel = @"Search apps";
    [_field addTarget:self action:@selector(_typed) forControlEvents:UIControlEventEditingChanged];
    [_bar addSubview:_field];
    self.additionalSafeAreaInsets = UIEdgeInsetsMake(kSearchBar, 0, 0, 0);

    UINavigationBarAppearance *look = [UINavigationBarAppearance new];
    [look configureWithOpaqueBackground];
    look.backgroundColor = paper;
    look.shadowColor = UIColor.clearColor;
    self.navigationItem.standardAppearance = look;
    self.navigationItem.scrollEdgeAppearance = look;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(_keyboardMoved:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [nc addObserver:self selector:@selector(_keyboardMoved:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    if (_bar.superview != nav.view) [nav.view addSubview:_bar];
    _bar.frame = CGRectMake(0, CGRectGetMaxY(nav.navigationBar.frame), nav.view.bounds.size.width, kSearchBar);
}

#pragma mark the keyboard

- (BOOL)focus {
    [self loadViewIfNeeded];
    UINavigationController *nav = self.navigationController;
    if (nav && _bar.superview != nav.view) {             // asked before the first layout: the field must be in the window
        [nav.view addSubview:_bar];
        [nav.view setNeedsLayout];
        [nav.view layoutIfNeeded];
        _bar.frame = CGRectMake(0, CGRectGetMaxY(nav.navigationBar.frame), nav.view.bounds.size.width, kSearchBar);
    }
    return _field.isFirstResponder || [_field becomeFirstResponder];
}

- (BOOL)keyboardUp { return !CGRectIsEmpty(_keyboard); }

// The keyboard covers the lower part of the sheet: the list gets that much room at its end.
- (void)_keyboardMoved:(NSNotification *)n {
    // Notices about other keyboards arrive here as well (an app's keyboard leaving as SpringBoard
    // takes the keyboard): while the field has the focus only "a keyboard is up, here" counts,
    // and a notice that one is hiding is somebody else's. Its own going is -textFieldDidEndEditing:.
    BOOL hiding = [n.name isEqualToString:UIKeyboardWillHideNotification];
    CGSize screen = [AtelierHost screenSize];
    CGRect end = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    BOOL up = !hiding && end.size.height > 60 && end.origin.y < screen.height - 60;
    if (_field.isFirstResponder ? !up : up) return;
    [self _keyboardIs:(up ? end : CGRectZero)];
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    [self _keyboardIs:CGRectZero];
}

- (void)_keyboardIs:(CGRect)end {
    CGSize screen = [AtelierHost screenSize];
    BOOL up = !CGRectIsEmpty(end);
    CGRect was = _keyboard;
    _keyboard = up ? end : CGRectZero;
    CGFloat cover = up ? MAX(0, screen.height - end.origin.y) : 0;
    UIEdgeInsets inset = self.tableView.contentInset;
    inset.bottom = cover;
    self.tableView.contentInset = inset;
    UIEdgeInsets bar = self.tableView.verticalScrollIndicatorInsets;
    bar.bottom = cover;
    self.tableView.verticalScrollIndicatorInsets = bar;
    if (up != !CGRectIsEmpty(was))
        AtelierLog(@"picker keyboard: %@", up ? [NSString stringWithFormat:@"up, %.0f,%.0f %.0fx%.0f", end.origin.x, end.origin.y, end.size.width, end.size.height] : @"down");
}

#pragma mark searching

// Names that begin with what was typed, then names with a word that begins with it, then names
// that have it anywhere; each group A to Z. Case, accents and width are not told apart.
- (void)_search:(NSString *)text {
    NSString *q = AtelierFold([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    if ([q isEqualToString:_asked ?: @""] && (_found != nil) == (q.length > 0)) return;      // told twice (the clear button says it two ways)
    _asked = q;
    if (q.length == 0) {
        _found = nil;
    } else {
        NSMutableArray<NSDictionary *> *starts = [NSMutableArray array], *words = [NSMutableArray array], *inside = [NSMutableArray array];
        NSString *word = [@" " stringByAppendingString:q];
        for (NSDictionary *a in _all) {
            NSString *name = a[@"fold"];
            NSRange r = [name rangeOfString:q];
            if (r.location == NSNotFound) continue;
            if (r.location == 0) [starts addObject:a];
            else if ([name rangeOfString:word].location != NSNotFound) [words addObject:a];
            else [inside addObject:a];
        }
        [starts addObjectsFromArray:words];
        [starts addObjectsFromArray:inside];
        _found = starts;
    }
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    [self.tableView setContentOffset:CGPointMake(0, -self.tableView.adjustedContentInset.top) animated:NO];
    if (_found) AtelierLog(@"picker search \"%@\": %lu match(es)%@", q, (unsigned long)_found.count,
                           _found.count ? [NSString stringWithFormat:@", first %@", _found[0][@"name"]] : @"");
    else AtelierLog(@"picker search cleared: Recent and A to Z again");
}

- (void)_typed {
    [self _search:_field.text];
}

- (BOOL)textFieldShouldClear:(UITextField *)field {
    AtelierAfter(0, ^{ [self _search:self->_field.text]; });        // once the field is empty
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (_found.count) [self _pick:_found[0] how:@"Return"];
    return NO;
}

- (void)_pick:(NSDictionary *)app how:(NSString *)how {
    NSString *bid = app[@"id"];
    void (^pick)(NSString *) = self.onPick;
    AtelierLog(@"picker: %@ chose %@%@", how, bid, _found ? [NSString stringWithFormat:@" (searching \"%@\")", _field.text ?: @""] : @"");
    [AtelierSheets dismiss];
    if (pick) pick(bid);
}

#pragma mark the list

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _found ? 1 : (NSInteger)_titles.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _found ? (NSInteger)_found.count : (NSInteger)_rows[(NSUInteger)s].count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _found ? nil : _titles[(NSUInteger)s]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return (_found && _found.count == 0) ? @"No app has that in its name." : nil;
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tv {
    if (_found) return nil;
    NSMutableArray *t = [NSMutableArray array];
    for (NSString *s in _titles) [t addObject:[s isEqualToString:@"Recent"] ? @"★" : s];
    return t;
}

- (NSDictionary *)_appAt:(NSIndexPath *)ip {
    if (_found) return (NSUInteger)ip.row < _found.count ? _found[(NSUInteger)ip.row] : nil;
    if ((NSUInteger)ip.section >= _rows.count || (NSUInteger)ip.row >= _rows[(NSUInteger)ip.section].count) return nil;
    return _rows[(NSUInteger)ip.section][(NSUInteger)ip.row];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"app"]
                      ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"app"];
    NSDictionary *a = [self _appAt:ip];
    c.backgroundColor = UIColor.clearColor;
    c.textLabel.text = a[@"name"];
    c.imageView.image = [AtelierHost iconForBundleID:a[@"id"]];
    c.imageView.layer.cornerRadius = 8;
    c.imageView.clipsToBounds = YES;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *a = [self _appAt:ip];
    if (a) [self _pick:a how:@"a tap"];
}

#pragma mark tests

- (void)debugType:(NSString *)text {
    _field.text = text;
    [self _search:text];
}

- (void)debugReturn {
    [self textFieldShouldReturn:_field];
}

// The field, the keyboard and the first rows, on the screen: name x y width height 0
- (NSArray<NSString *> *)debugWhere {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    void (^add)(NSString *, CGRect) = ^(NSString *name, CGRect r) {
        if (CGRectIsEmpty(r)) return;
        [lines addObject:[NSString stringWithFormat:@"%@ %.1f %.1f %.1f %.1f 0", name, r.origin.x, r.origin.y, r.size.width, r.size.height]];
    };
    add(@"sheet", [self.navigationController.view convertRect:self.navigationController.view.bounds toView:nil]);
    CGRect field = [_field convertRect:_field.bounds toView:nil];
    add(@"field", field);
    add(@"fieldclear", CGRectMake(CGRectGetMaxX(field) - 34, field.origin.y, 34, field.size.height));
    add(@"keyboard", _keyboard);
    NSArray<NSIndexPath *> *shown = [self.tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < shown.count && i < 4; i++)
        add([NSString stringWithFormat:@"row%lu", (unsigned long)i], [self.tableView convertRect:[self.tableView rectForRowAtIndexPath:shown[i]] toView:nil]);
    return lines;
}

- (NSString *)debugState {
    NSMutableArray<NSString *> *first = [NSMutableArray array];
    NSArray<NSIndexPath *> *shown = [self.tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < shown.count && i < 6; i++) [first addObject:[self _appAt:shown[i]][@"name"] ?: @"?"];
    return [NSString stringWithFormat:@"picker \"%@\": field %@, keyboard %@, text \"%@\", %@, %lu apps in all, rows on show: %@", self.title ?: @"",
            _field.isFirstResponder ? @"has the keyboard's focus" : @"NOT focused", self.keyboardUp ? @"up" : @"down", _field.text ?: @"",
            _found ? [NSString stringWithFormat:@"%lu match(es)", (unsigned long)_found.count] : [NSString stringWithFormat:@"sections [%@]", [_titles componentsJoinedByString:@" "]],
            (unsigned long)_all.count, [first componentsJoinedByString:@", "]];
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

// The saved sets as the list shows them: without the apps SporeX hides, and without a set that
// has no app left. @"at" is the set's place in the saved list.
- (NSArray<NSDictionary *> *)_sets {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSArray<NSDictionary *> *saved = [[AtelierSettings shared] sets];
    for (NSUInteger i = 0; i < saved.count; i++) {
        NSArray<NSString *> *apps = AtelierShownApps(saved[i][@"apps"]);
        if (apps.count == 0) continue;
        NSMutableDictionary *set = [saved[i] mutableCopy];
        set[@"apps"] = apps;
        set[@"at"] = @(i);
        [out addObject:set];
    }
    return out;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)[self _sets].count, 1); }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return [self _sets].count
        ? @"Tap a set to open its apps on the bench. Swipe left to rename it, move it up or delete it. "
           "Hold the icon of any app in a set to open the set from the Home Screen."
        : @"Put two to six apps on the bench, then choose Save as Set from the ··· menu above the main app.";
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
    NSArray<NSDictionary *> *shown = [self _sets];
    if (row >= shown.count) return nil;
    // what the row is in the saved list (the list on show may leave sets out)
    NSUInteger at = [shown[row][@"at"] unsignedIntegerValue];
    NSUInteger above = row > 0 ? [shown[row - 1][@"at"] unsignedIntegerValue] : NSNotFound;
    __weak typeof(self) weak = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            NSMutableArray *sets = [[[AtelierSettings shared] sets] mutableCopy];
            if (at < sets.count) [sets removeObjectAtIndex:at];
            [[AtelierSettings shared] setSets:sets];
            [weak.tableView reloadData];
            done(YES);
        }];
    UIContextualAction *up = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Up"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            NSMutableArray *sets = [[[AtelierSettings shared] sets] mutableCopy];
            if (above != NSNotFound && at < sets.count && above < sets.count) [sets exchangeObjectAtIndex:at withObjectAtIndex:above];
            [[AtelierSettings shared] setSets:sets];
            [weak.tableView reloadData];
            done(YES);
        }];
    UIContextualAction *name = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Name"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [weak _renameSetAt:at shownAs:shown[row]];
            done(YES);
        }];
    name.backgroundColor = [UIColor colorWithRed:0x5E / 255.0 green:0x5C / 255.0 blue:0xE6 / 255.0 alpha:1];
    return [UISwipeActionsConfiguration configurationWithActions:(row > 0 ? @[ del, name, up ] : @[ del, name ])];
}

- (void)_renameSetAt:(NSUInteger)at shownAs:(NSDictionary *)set {
    AtelierNamePicker *picker = [[AtelierNamePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];
    picker.current = set[@"name"];
    NSMutableDictionary *bare = [set mutableCopy];
    bare[@"name"] = @"";
    picker.plain = [AtelierSheets setTitle:bare];
    picker.onPick = ^(NSString *name) {
        NSMutableArray *all = [[[AtelierSettings shared] sets] mutableCopy];
        if (at >= all.count) return;
        NSMutableDictionary *changed = [all[at] mutableCopy];
        changed[@"name"] = name ?: @"";
        all[at] = changed;
        [[AtelierSettings shared] setSets:all];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

@end

#pragma mark - the sheet

@implementation AtelierSheets

+ (BOOL)isOpen { return gSheetWindow != nil; }

+ (AtelierAppPicker *)_picker {
    UIViewController *top = gSheetNav.topViewController;
    return [top isKindOfClass:AtelierAppPicker.class] ? (AtelierAppPicker *)top : nil;
}

+ (void)dismiss {
    AtelierWindow *w = gSheetWindow;
    if (!w) return;
    gSheetWindow = nil;
    gSheetNav = nil;
    // the keyboard first: the field lets go of it, and SpringBoard's keyboard focus goes back
    // to where it was (the app in front, the bench's main app)
    [w endEditing:YES];
    [AtelierHost giveKeyboardBack];
    UIViewController *root = w.rootViewController;
    UIView *card = root.view.subviews.lastObject;
    [UIView animateWithDuration:0.2 animations:^{
        root.view.backgroundColor = UIColor.clearColor;
        card.transform = CGAffineTransformMakeTranslation(0, card.bounds.size.height);
    } completion:^(BOOL done) { w.hidden = YES; }];
}

// `search`: the sheet is tall and its window may take the keyboard (the app picker).
+ (void)_present:(AtelierSheetList *)list search:(BOOL)search {
    if (gSheetWindow) [self dismiss];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    CGSize screen = [AtelierHost screenSize];
    UIWindowLevel level = MAX(1005, (UIWindowLevel)[[AtelierSettings shared] tune:@"windowLevel" fallback:999] + 6);
    AtelierWindow *w = [AtelierHost windowAtLevel:level key:search];
    UIViewController *host = w.rootViewController;

    UIButton *dim = [UIButton buttonWithType:UIButtonTypeCustom];
    dim.frame = host.view.bounds;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [host.view addSubview:dim];

    // the picker reaches nearly to the top: the keyboard takes the lower third of the screen
    CGFloat h = search ? screen.height - [AtelierHost safeInsets].top - 14 : MIN(screen.height * 0.72, 660);
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
    if (search) [w makeKeyAndVisible]; else w.hidden = NO;
    nav.view.transform = CGAffineTransformMakeTranslation(0, h);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4 options:0 animations:^{
        host.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        nav.view.transform = CGAffineTransformIdentity;
    } completion:nil];
    if (!search) return;

    // On the next turn of the run loop, with the window really on the screen: SpringBoard's
    // keyboard focus first, then the field. If no keyboard has come up half a second later the
    // field asks once more (the focus may have been granted a moment after the first try).
    AtelierAppPicker *picker = (AtelierAppPicker *)list;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSheetWindow != w) return;
        BOOL focus = [AtelierHost takeKeyboardForWindow:w];
        BOOL first = [picker focus];
        AtelierLog(@"picker: window key %d, keyboard focus %@, field first responder %d", (int)w.isKeyWindow, focus ? @"taken" : @"NOT taken", (int)first);
        AtelierAfter(0.6, ^{
            if (gSheetWindow != w || picker.keyboardUp) return;
            [w endEditing:YES];
            if (!w.isKeyWindow) [w makeKeyWindow];
            BOOL again = [picker focus];
            AtelierLog(@"picker: no keyboard yet, asked again (window key %d, first responder %d)", (int)w.isKeyWindow, (int)again);
        });
    });
}

+ (void)pickAppWithTitle:(NSString *)title excluding:(NSArray<NSString *> *)exclude then:(void (^)(NSString *))then {
    AtelierAppPicker *picker = [[AtelierAppPicker alloc] initWithStyle:UITableViewStylePlain];
    picker.title = title;
    picker.exclude = exclude;
    picker.onPick = then;
    [self _present:picker search:YES];
}

+ (void)showSets {
    [self _present:[[AtelierSetsList alloc] initWithStyle:UITableViewStyleInsetGrouped] search:NO];
}

#pragma mark tests

+ (void)debugPick:(NSUInteger)row {
    UIViewController *top = gSheetNav.topViewController;
    if ([top isKindOfClass:AtelierSheetList.class]) [(AtelierSheetList *)top debugPick:row];
    else AtelierLog(@"pick: no list on screen");
}

+ (void)debugType:(NSString *)text {
    AtelierAppPicker *picker = [self _picker];
    if (picker) [picker debugType:text ?: @""]; else AtelierLog(@"type: the app picker is not open");
}

+ (void)debugReturn {
    AtelierAppPicker *picker = [self _picker];
    if (picker) [picker debugReturn]; else AtelierLog(@"return: the app picker is not open");
}

+ (NSArray<NSString *> *)debugWhere {
    return [[self _picker] debugWhere] ?: @[];
}

+ (NSString *)debugState {
    if (!gSheetWindow) return @"no sheet";
    AtelierAppPicker *picker = [self _picker];
    return picker ? [picker debugState] : [NSString stringWithFormat:@"sheet: %@", NSStringFromClass([gSheetNav.topViewController class])];
}

// A set's name, or the names of its apps (never one that is hidden).
+ (NSString *)setTitle:(NSDictionary *)set {
    NSString *name = set[@"name"];
    if ([name isKindOfClass:NSString.class] && name.length) return name;
    NSArray<NSString *> *apps = AtelierShownApps(set[@"apps"]);
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
