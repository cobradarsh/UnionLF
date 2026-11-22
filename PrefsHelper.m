/*  PrefsHelper.m — ShaniPrefs.dylib, Shani's code in the Settings app.

    Settings → Shani is a page made from a plist (tools/make_prefs.py); switches and choices
    need no code. Three screens do, and they are here:

      ShaniAppsController     "Apps & Log": the apps on Shani's list, each with what is held
                              and when it comes up. Swipe an app off the list, add one, show
                              what is held now. Tap an app for its log.
      ShaniAppLogController   one app's notification log, newest first.
      ShaniPickerController   every app on the phone with a search field; tap to put it on
                              or take it off the list.

    The plist's row names ShaniAppsController as its `detail`, the way a compiled settings
    bundle's plist names its classes; the class is in Settings because this library is loaded
    into it. (A Settings that was already open when the package was installed has no such class,
    so the package's postinst closes Settings.) The row is a PSLinkListCell: in a plist-only page
    PreferenceLoader takes over every PSLinkCell row for itself.

    Nothing is hooked. SpringBoard owns the data: this side reads state.plist and the logs,
    changes the list by writing the `apps` setting, and may delete a log file.

    Self-test: when <log dir>/shani_prefs_test exists, Settings writes <log dir>/ShaniSettings.log
    a moment after it starts (tools/phone.sh settings): are the classes there, can the files be
    read, does Settings find a controller for every row that opens a screen, does the Apps & Log
    screen build. Names of apps and notification text are never written there.                */

#import "Shani.h"
#import <dlfcn.h>
#import <notify.h>
#import <unistd.h>

@interface PSViewController : UIViewController
@end

static char gAnchor;                         // an address in this library: dyld says where it was loaded from

#pragma mark - apps

static id ShaniPrefsProxy(NSString *bid) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL s = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (bid.length == 0 || ![cls respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(cls, s, bid); } @catch (__unused id e) {}
    return nil;
}

static NSString *ShaniPrefsName(NSString *bid) {
    static NSCache<NSString *, NSString *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *known = [cache objectForKey:bid];
    if (known) return known;
    NSString *name = ShaniStr(ShaniPrefsProxy(bid), @"localizedName");
    if (name.length == 0) name = bid;
    [cache setObject:name forKey:bid];
    return name;
}

static UIImage *ShaniPrefsIcon(NSString *bid) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *known = [cache objectForKey:bid];
    if (known) return known;
    UIImage *icon = nil;
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    Class cls = UIImage.class;
    if ([cls respondsToSelector:s]) {
        @try {
            NSMethodSignature *sig = [cls methodSignatureForSelector:s];
            const char *t = sig.numberOfArguments == 5 ? [sig getArgumentTypeAtIndex:3] : "";
            CGFloat scale = UIScreen.mainScreen.scale;
            if (t[0] == 'i' || t[0] == 'I') icon = ((id (*)(id, SEL, id, int, double))objc_msgSend)(cls, s, bid, 0, scale);            // 0: the 29 pt icon of a Settings row
            else if (t[0] == 'q' || t[0] == 'Q') icon = ((id (*)(id, SEL, id, long long, double))objc_msgSend)(cls, s, bid, 0LL, scale);
        } @catch (__unused id e) {}
    }
    if (![icon isKindOfClass:UIImage.class]) icon = [UIImage systemImageNamed:@"app.dashed"];
    if (icon) [cache setObject:icon forKey:bid];
    return icon;
}

// Apps the user's SporeX tweak hides are left out of the picker, as everywhere else.
static NSSet<NSString *> *ShaniPrefsHiddenApps(void) {
    NSMutableSet<NSString *> *hidden = [NSMutableSet set];
    @try {
        CFStringRef dom = CFSTR("com.adarsh.sporex");
        CFPreferencesAppSynchronize(dom);
        id on = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Enabled"), dom));
        if ([on respondsToSelector:@selector(boolValue)] && ![on boolValue]) return hidden;
        id list = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("HiddenApps"), dom));
        if ([list isKindOfClass:NSArray.class]) {
            for (id bid in (NSArray *)list) if ([bid isKindOfClass:NSString.class]) [hidden addObject:bid];
        } else if ([list isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)list enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                if (![key isKindOfClass:NSString.class]) return;
                if (![value respondsToSelector:@selector(boolValue)] || [value boolValue]) [hidden addObject:key];
            }];
        }
    } @catch (__unused id e) {}
    return hidden;
}

// Every app with an icon on the Home Screen: [{ bid, name }], by name.
static NSArray<NSDictionary *> *ShaniPrefsAllApps(void) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    id workspace = ShaniMsg(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    id proxies = ShaniMsg(workspace, @"allInstalledApplications");
    if (![proxies isKindOfClass:NSArray.class]) return out;
    NSSet<NSString *> *hidden = ShaniPrefsHiddenApps();
    for (id proxy in (NSArray *)proxies) {
        NSString *bid = ShaniStr(proxy, @"applicationIdentifier");
        NSString *type = ShaniStr(proxy, @"applicationType");
        if (bid.length == 0 || [hidden containsObject:bid]) continue;
        if (![type isEqualToString:@"User"] && ![type isEqualToString:@"System"]) continue;
        id tags = ShaniMsg(proxy, @"appTags");
        if ([tags isKindOfClass:NSArray.class] && [(NSArray *)tags containsObject:@"hidden"]) continue;
        if (ShaniBoolMsg(proxy, @"isLaunchProhibited", NO)) continue;
        NSString *name = ShaniStr(proxy, @"localizedName");
        if (name.length == 0) continue;
        [out addObject:@{ @"bid": bid, @"name": name }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return out;
}

static void ShaniPrefsSaveApps(NSArray<NSString *> *apps) {
    [[ShaniSettings shared] setApps:apps];
    notify_post(SHANI_NOTE_PREFS);
}

static void ShaniPrefsReleaseNow(NSString *bid) {
    CFStringRef dom = (__bridge CFStringRef)SHANI_DOMAIN;
    CFPreferencesSetAppValue(CFSTR("releaseApp"), (__bridge CFStringRef)(bid ?: @""), dom);
    CFPreferencesAppSynchronize(dom);
    notify_post(SHANI_NOTE_RELEASE);
}

static NSDictionary *ShaniPrefsAppState(NSDictionary *state, NSString *bid) {
    NSDictionary *apps = state[@"apps"];
    NSDictionary *st = [apps isKindOfClass:NSDictionary.class] ? apps[bid] : nil;
    return [st isKindOfClass:NSDictionary.class] ? st : @{};
}

// "2 held · come up 4:32 PM"
static NSString *ShaniPrefsStatus(NSDictionary *st, NSUInteger logged) {
    NSInteger held = [st[@"held"] respondsToSelector:@selector(integerValue)] ? [st[@"held"] integerValue] : 0;
    double until = [st[@"until"] respondsToSelector:@selector(doubleValue)] ? [st[@"until"] doubleValue] : 0;
    if (held > 0 && until > 0) return [NSString stringWithFormat:@"%ld held · %@ %@", (long)held, held == 1 ? @"comes up" : @"come up", ShaniClockText(until)];
    if (held > 0) return [NSString stringWithFormat:@"%ld held", (long)held];
    if (until > [[NSDate date] timeIntervalSince1970]) return [NSString stringWithFormat:@"Silent until %@", ShaniClockText(until)];
    if (logged > 0) return [NSString stringWithFormat:@"%lu in the log", (unsigned long)logged];
    return @"Nothing logged yet";
}

#pragma mark - one app's log

@interface ShaniAppLogController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *bundleID;
@end

@implementation ShaniAppLogController {
    UITableView *_table;
    NSArray<NSDictionary *> *_entries;        // newest first
    NSArray<NSString *> *_top;                // the rows above the log
    NSDictionary *_st;
    BOOL _listed;
    int _token;
    BOOL _listening;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = ShaniPrefsName(self.bundleID ?: @"");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 72;
    [self.view addSubview:_table];
    __weak typeof(self) weak = self;
    _listening = notify_register_dispatch(SHANI_NOTE_CHANGED, &_token, dispatch_get_main_queue(), ^(__unused int t) { [weak _reload]; }) == NOTIFY_STATUS_OK;
}

- (void)dealloc {
    if (_listening) notify_cancel(_token);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self _reload];
}

- (void)_reload {
    NSString *bid = self.bundleID ?: @"";
    [[ShaniSettings shared] reload];
    _listed = [[ShaniSettings shared].apps containsObject:bid];
    _st = ShaniPrefsAppState(ShaniReadState(), bid);
    _entries = [[ShaniReadNoteLog(bid) reverseObjectEnumerator] allObjects];
    NSMutableArray<NSString *> *top = [NSMutableArray arrayWithObject:@"status"];
    if ([_st[@"held"] integerValue] > 0) [top addObject:@"release"];
    [top addObject:_listed ? @"off" : @"on"];
    if (_entries.count) [top addObject:@"clear"];
    _top = top;
    [_table reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)_top.count : (NSInteger)MAX((NSUInteger)1, _entries.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? @"Notifications" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1 && _entries.count) return @"Newest first. Kept on this iPhone only.";
    return nil;
}

static UIColor *ShaniFateColour(NSInteger fate) {
    switch (fate) {
        case ShaniFateHeld:      return UIColor.systemOrangeColor;
        case ShaniFateReleased:  return UIColor.systemGreenColor;
        case ShaniFateTapped:    return UIColor.systemIndigoColor;
        case ShaniFateCritical:  return UIColor.systemRedColor;
        default:                 return UIColor.secondaryLabelColor;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.section == 0) {
        NSString *kind = _top[(NSUInteger)indexPath.row];
        UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if ([kind isEqualToString:@"status"]) {
            c = [UIListContentConfiguration subtitleCellConfiguration];
            c.image = ShaniPrefsIcon(self.bundleID ?: @"");
            c.text = _listed ? @"On Shani" : @"Not on Shani";
            c.secondaryText = _listed ? ShaniPrefsStatus(_st, _entries.count) : @"Notifies as usual. The log below is from when it was on Shani.";
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if ([kind isEqualToString:@"release"]) {
            c.text = @"Show Held Notifications Now";
            c.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        } else if ([kind isEqualToString:@"off"]) {
            c.text = @"Take Off Shani";
            c.textProperties.color = UIColor.systemRedColor;
        } else if ([kind isEqualToString:@"on"]) {
            c.text = @"Put on Shani";
            c.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        } else {
            c.text = @"Clear This Log";
            c.textProperties.color = UIColor.systemRedColor;
        }
        cell.contentConfiguration = c;
        return cell;
    }
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (_entries.count == 0) {
        c.text = @"Nothing logged yet";
        c.textProperties.color = UIColor.secondaryLabelColor;
        cell.contentConfiguration = c;
        return cell;
    }
    NSDictionary *e = _entries[(NSUInteger)indexPath.row];
    NSString *title = [e[@"title"] isKindOfClass:NSString.class] ? e[@"title"] : @"";
    NSString *sub = [e[@"sub"] isKindOfClass:NSString.class] ? e[@"sub"] : @"";
    NSString *msg = [e[@"msg"] isKindOfClass:NSString.class] ? e[@"msg"] : @"";
    if (title.length == 0) { title = sub; sub = @""; }
    if (title.length == 0) { title = msg.length ? msg : @"(no text)"; msg = @""; }
    c.text = title;
    c.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    c.textProperties.numberOfLines = 2;
    NSMutableAttributedString *body = [NSMutableAttributedString new];
    UIFont *plain = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    NSDictionary *text = @{ NSFontAttributeName: plain, NSForegroundColorAttributeName: UIColor.labelColor };
    if (sub.length) [body appendAttributedString:[[NSAttributedString alloc] initWithString:[sub stringByAppendingString:@"\n"] attributes:text]];
    if (msg.length) [body appendAttributedString:[[NSAttributedString alloc] initWithString:[msg stringByAppendingString:@"\n"] attributes:text]];
    NSInteger fate = [e[@"st"] respondsToSelector:@selector(integerValue)] ? [e[@"st"] integerValue] : 0;
    double when = [e[@"t"] respondsToSelector:@selector(doubleValue)] ? [e[@"t"] doubleValue] : 0;
    NSString *foot = [NSString stringWithFormat:@"%@ · %@", ShaniClockText(when), ShaniFateText(e)];
    [body appendAttributedString:[[NSAttributedString alloc] initWithString:foot attributes:@{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSForegroundColorAttributeName: ShaniFateColour(fate) }]];
    c.secondaryAttributedText = body;
    c.secondaryTextProperties.numberOfLines = 8;
    c.textToSecondaryTextVerticalPadding = 3;
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    NSString *bid = self.bundleID ?: @"";
    NSString *kind = _top[(NSUInteger)indexPath.row];
    if ([kind isEqualToString:@"release"]) {
        ShaniPrefsReleaseNow(bid);
    } else if ([kind isEqualToString:@"off"] || [kind isEqualToString:@"on"]) {
        NSMutableArray<NSString *> *apps = [[ShaniSettings shared].apps mutableCopy];
        if ([kind isEqualToString:@"off"]) [apps removeObject:bid]; else if (![apps containsObject:bid]) [apps addObject:bid];
        ShaniPrefsSaveApps(apps);
        [self _reload];
    } else if ([kind isEqualToString:@"clear"]) {
        UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"Clear this log?" message:@"The lines are deleted. Notifications themselves are not touched."
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
        __weak typeof(self) weak = self;
        [ask addAction:[UIAlertAction actionWithTitle:@"Clear Log" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:ShaniNoteLogPath(bid) error:nil];
            [weak _reload];
        }]];
        [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ask animated:YES completion:nil];
    }
}

@end

#pragma mark - the picker

@interface ShaniPickerController : PSViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@end

@implementation ShaniPickerController {
    UITableView *_table;
    UISearchController *_search;
    NSArray<NSDictionary *> *_all, *_shown;
    NSMutableArray<NSString *> *_chosen;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Add Apps";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = @"Search";
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [[ShaniSettings shared] reload];
    _chosen = [[ShaniSettings shared].apps mutableCopy];
    _all = ShaniPrefsAllApps();
    _shown = _all;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (q.length == 0) {
        _shown = _all;
    } else {
        NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
        for (NSDictionary *app in _all) {
            if ([app[@"name"] rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) [hits addObject:app];
        }
        _shown = hits;
    }
    [_table reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_shown.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"A ticked app is on Shani's list: its notifications are held back for the time you chose, and logged.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"app"];
    NSDictionary *app = _shown[(NSUInteger)indexPath.row];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.text = app[@"name"];
    c.image = ShaniPrefsIcon(app[@"bid"]);
    cell.contentConfiguration = c;
    cell.accessoryType = [_chosen containsObject:app[@"bid"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *bid = _shown[(NSUInteger)indexPath.row][@"bid"];
    if ([_chosen containsObject:bid]) [_chosen removeObject:bid]; else [_chosen addObject:bid];
    ShaniPrefsSaveApps(_chosen);
    [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - Apps & Log

@interface ShaniAppsController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation ShaniAppsController {
    UITableView *_table;
    NSArray<NSString *> *_sections;           // "apps", "held", "others"
    NSArray<NSString *> *_listed, *_others;
    NSDictionary *_state;
    NSMutableDictionary<NSString *, NSNumber *> *_counts;
    int _token;
    BOOL _listening;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apps & Log";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(_add)];
    __weak typeof(self) weak = self;
    _listening = notify_register_dispatch(SHANI_NOTE_CHANGED, &_token, dispatch_get_main_queue(), ^(__unused int t) { [weak _reload]; }) == NOTIFY_STATUS_OK;
    [self _reload];
}

- (void)dealloc {
    if (_listening) notify_cancel(_token);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self _reload];
}

- (void)_reload {
    [[ShaniSettings shared] reload];
    _state = ShaniReadState();
    NSArray<NSString *> *listed = [[ShaniSettings shared].apps sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [ShaniPrefsName(a) localizedCaseInsensitiveCompare:ShaniPrefsName(b)];
    }];
    NSMutableArray<NSString *> *others = [NSMutableArray array];
    for (NSString *bid in ShaniAppsWithNoteLogs()) if (![listed containsObject:bid]) [others addObject:bid];
    _counts = [NSMutableDictionary dictionary];
    NSInteger held = 0;
    for (NSString *bid in [listed arrayByAddingObjectsFromArray:others]) {
        _counts[bid] = @(ShaniReadNoteLog(bid).count);
        held += [ShaniPrefsAppState(_state, bid)[@"held"] integerValue];
    }
    _listed = listed;
    _others = others;
    NSMutableArray<NSString *> *sections = [NSMutableArray arrayWithObject:@"apps"];
    if (held > 0) [sections addObject:@"held"];
    if (others.count) [sections addObject:@"others"];
    _sections = sections;
    [_table reloadData];
}

- (void)_add {
    [self.navigationController pushViewController:[ShaniPickerController new] animated:YES];
}

- (NSString *)_kind:(NSInteger)section { return _sections[(NSUInteger)section]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSString *kind = [self _kind:section];
    if ([kind isEqualToString:@"apps"]) return (NSInteger)_listed.count + 1;
    if ([kind isEqualToString:@"held"]) return 1;
    return (NSInteger)_others.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *kind = [self _kind:section];
    if ([kind isEqualToString:@"apps"]) return @"On Shani";
    if ([kind isEqualToString:@"others"]) return @"Earlier Logs";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *kind = [self _kind:section];
    if ([kind isEqualToString:@"apps"]) {
        return @"Apps get here when you tap Shani on one of their notifications, or with Add App. Tap an app for its log. Swipe it to the left to take it off; what was held for it then comes up.";
    }
    if ([kind isEqualToString:@"others"]) return @"Logs of apps that are no longer on Shani. Swipe to delete.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSString *kind = [self _kind:indexPath.section];
    if ([kind isEqualToString:@"held"]) {
        UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
        c.text = @"Show Held Notifications Now";
        c.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        cell.contentConfiguration = c;
        return cell;
    }
    BOOL apps = [kind isEqualToString:@"apps"];
    if (apps && indexPath.row == (NSInteger)_listed.count) {
        UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
        c.text = @"Add App…";
        c.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        c.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        cell.contentConfiguration = c;
        return cell;
    }
    NSString *bid = (apps ? _listed : _others)[(NSUInteger)indexPath.row];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.text = ShaniPrefsName(bid);
    c.image = ShaniPrefsIcon(bid);
    NSUInteger logged = _counts[bid].unsignedIntegerValue;
    c.secondaryText = apps ? ShaniPrefsStatus(ShaniPrefsAppState(_state, bid), logged) : [NSString stringWithFormat:@"%lu in the log", (unsigned long)logged];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *kind = [self _kind:indexPath.section];
    if ([kind isEqualToString:@"held"]) { ShaniPrefsReleaseNow(nil); return; }
    BOOL apps = [kind isEqualToString:@"apps"];
    if (apps && indexPath.row == (NSInteger)_listed.count) { [self _add]; return; }
    ShaniAppLogController *log = [ShaniAppLogController new];
    log.bundleID = (apps ? _listed : _others)[(NSUInteger)indexPath.row];
    [self.navigationController pushViewController:log animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *kind = [self _kind:indexPath.section];
    BOOL apps = [kind isEqualToString:@"apps"];
    if ([kind isEqualToString:@"held"] || (apps && indexPath.row == (NSInteger)_listed.count)) return nil;
    NSString *bid = (apps ? _listed : _others)[(NSUInteger)indexPath.row];
    __weak typeof(self) weak = self;
    UIContextualAction *act = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:apps ? @"Take Off" : @"Delete Log"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        if (apps) {
            NSMutableArray<NSString *> *list = [[ShaniSettings shared].apps mutableCopy];
            [list removeObject:bid];
            ShaniPrefsSaveApps(list);
        } else {
            [[NSFileManager defaultManager] removeItemAtPath:ShaniNoteLogPath(bid) error:nil];
        }
        done(YES);
        [weak _reload];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ act ]];
}

@end

#pragma mark - the self-test

static NSMutableString *gReport;

static void ShaniPrefsSay(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ShaniPrefsSay(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!gReport) gReport = [NSMutableString string];
    [gReport appendFormat:@"%@\n", line];
    [gReport writeToFile:[ShaniLogDir() stringByAppendingPathComponent:@"ShaniSettings.log"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSString *ShaniPrefsFind(NSString *tail) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(&gAnchor, &info) && info.dli_fname) {
        NSString *dir = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
        if (dir.length) [roots addObject:[dir stringByAppendingPathComponent:@".jbroot"]];
        for (int i = 0; i < 6 && dir.length > 1; i++) {
            dir = [dir stringByDeletingLastPathComponent];
            if (dir.length) [roots addObject:dir];
        }
    }
    [roots addObject:@"/"];
    for (NSString *root in roots) {
        NSString *path = [root stringByAppendingPathComponent:tail];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}

static id ShaniPrefsValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused id e) {}
    return nil;
}

static NSString *ShaniPrefsClassLine(Class cls) {            // "A : B : C"
    if (!cls) return @"MISSING";
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (Class c = cls; c && chain.count < 5; c = class_getSuperclass(c)) [chain addObject:NSStringFromClass(c)];
    return [chain componentsJoinedByString:@" : "];
}

// Settings' own reader for a page: the function PreferenceLoader calls for every entry.
typedef NSArray *(*ShaniPrefsReader)(NSDictionary *plist, id previous, id target, NSString *name, NSBundle *bundle,
                                     NSString *__autoreleasing *title, NSString *__autoreleasing *identifier,
                                     id caller, NSMutableArray *__autoreleasing *bundleControllers);

static void ShaniPrefsReport(void) {
    ShaniPrefsSay(@"Shani %@ in Settings, pid %d, %@", SHANI_VERSION, (int)getpid(), [NSDate date]);

    ShaniPrefsSay(@"1. classes");
    for (NSString *name in @[ @"ShaniAppsController", @"ShaniAppLogController", @"ShaniPickerController" ]) {
        ShaniPrefsSay(@"   %@", ShaniPrefsClassLine(NSClassFromString(name)));
    }
    ShaniPrefsSay(@"   PreferenceLoader's page class: %@", NSClassFromString(@"PLCustomListController") ? @"here" : @"not in Settings");

    ShaniPrefsSay(@"2. files");
    NSFileManager *fm = [NSFileManager defaultManager];
    ShaniPrefsSay(@"   %@: %@, state.plist %@, %lu log file(s)", ShaniDataDir(), [fm isReadableFileAtPath:ShaniDataDir()] ? @"readable" : @"NOT readable",
                  [fm isReadableFileAtPath:ShaniStatePath()] ? @"readable" : @"not there", (unsigned long)ShaniAppsWithNoteLogs().count);
    [[ShaniSettings shared] reload];
    ShaniPrefsSay(@"   settings: %lu app(s) on the list, %ld minutes, mode %ld", (unsigned long)[ShaniSettings shared].apps.count,
                  (long)[ShaniSettings shared].minutes, (long)[ShaniSettings shared].mode);

    ShaniPrefsSay(@"3. the page, read with Settings' own reader");
    NSString *page = ShaniPrefsFind(@"Library/PreferenceLoader/Preferences/Shani.plist");
    NSDictionary *plist = page ? [NSDictionary dictionaryWithContentsOfFile:page] : nil;
    NSArray *items = [plist[@"items"] isKindOfClass:NSArray.class] ? plist[@"items"] : nil;
    ShaniPrefsReader reader = (ShaniPrefsReader)dlsym(RTLD_DEFAULT, "SpecifiersFromPlist");
    ShaniPrefsSay(@"   page file: %@ (%lu items)", page ?: @"NOT FOUND", (unsigned long)items.count);
    if (!reader || !items) {
        ShaniPrefsSay(@"   cannot be read here (reader %@)", reader ? @"found" : @"missing");
    } else {
        @try {
            NSString *title = nil, *identifier = nil;
            NSMutableArray *controllers = nil;
            NSBundle *bundle = [NSBundle bundleWithPath:page.stringByDeletingLastPathComponent];
            NSArray *specs = reader(@{ @"items": items }, nil, nil, @"Shani", bundle, &title, &identifier, nil, &controllers);
            NSInteger links = 0, broken = 0;
            for (id spec in specs) {
                NSNumber *cell = ShaniPrefsValue(spec, @"cellType");
                Class detail = (Class)ShaniPrefsValue(spec, @"detailControllerClass");
                if (cell.integerValue != 1 && cell.integerValue != 2 && !detail) continue;      // PSLinkCell, PSLinkListCell
                links++;
                if (!detail) broken++;
                ShaniPrefsSay(@"   row \"%@\" (cell type %@) -> %@", ShaniPrefsValue(spec, @"name") ?: @"?", cell ?: @"?",
                              detail ? NSStringFromClass(detail) : @"NOTHING (the row cannot open)");
            }
            ShaniPrefsSay(@"   %lu rows, %ld open another screen, %ld of those have no controller", (unsigned long)specs.count, (long)links, (long)broken);
        } @catch (NSException *e) {
            ShaniPrefsSay(@"   SpecifiersFromPlist threw %@", e.reason);
        }
    }

    ShaniPrefsSay(@"4. the screens, built by hand");
    @try {
        ShaniAppsController *apps = [ShaniAppsController new];
        [apps loadViewIfNeeded];
        UITableView *table = nil;
        for (UIView *v in apps.view.subviews) if ([v isKindOfClass:UITableView.class]) table = (UITableView *)v;
        NSInteger rows = 0;
        for (NSInteger s = 0; s < table.numberOfSections; s++) rows += [table numberOfRowsInSection:s];
        ShaniPrefsSay(@"   Apps & Log: %ld section(s), %ld row(s)", (long)table.numberOfSections, (long)rows);
        ShaniPrefsSay(@"   picker: %lu app(s) to choose from, %lu hidden by SporeX left out", (unsigned long)ShaniPrefsAllApps().count, (unsigned long)ShaniPrefsHiddenApps().count);
        UIImage *icon = ShaniPrefsIcon(@"com.apple.Preferences");
        ShaniPrefsSay(@"   an app icon: %@", icon ? NSStringFromCGSize(icon.size) : @"none");
    } @catch (NSException *e) {
        ShaniPrefsSay(@"   threw %@: %@", e.name, e.reason);
    }
    ShaniPrefsSay(@"done");
}

__attribute__((constructor)) static void ShaniPrefsInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) return;
        [[ShaniSettings shared] reload];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[ShaniLogDir() stringByAppendingPathComponent:@"shani_prefs_test"]]) return;
        // the report waits until Settings is up: building a screen makes cells' images and the like
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { ShaniPrefsReport(); } @catch (NSException *e) { ShaniPrefsSay(@"the self-test threw %@", e.reason); }
        });
    }
}
