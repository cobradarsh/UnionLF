/*  PrefsHelper.m — AtelierPrefs.dylib, the only code of HyperTrade's that runs in the Settings app.

    Settings → HyperTrade is a page made from a plist; it has no code of its own. Its "Shortcut
    Apps" row opens AltList's list of apps, and Settings can open such a row only if the list's
    class is already in the process when it reads the page. A plist cannot bring it in (Chakra
    1.0.1 and 1.0.2 tried "bundle = AltList" on the row; that works for a top-level
    PreferenceLoader entry only). So this loads AltList when Settings starts, and the row names
    the class and nothing else. Nothing is hooked; nothing else happens here.

    What went wrong in 1.1.0 ("There appears to be an error with these preferences!" where the
    list should be): the row was a PSLinkCell. In a plist-only page, PreferenceLoader's page
    controller (libprefs, -[PLCustomListController specifiers]) gives every PSLinkCell row that
    has no `bundle` its own class as the row's controller, whatever the row's `detail` says: it
    takes the row for a sub-page made from another plist. Opened, that page finds no plist and
    shows the text above, which is PreferenceLoader's own. (Read in the libprefs.dylib of the
    phone's PreferenceLoader 2.3.3, 22 Nov 2026.) The row is a PSLinkListCell now, which that
    code leaves alone; see tools/make_prefs.py.

    The helper still has to be there first: a Settings that was already running when the
    package was installed has no AtelierPrefs in it, and no AltList class to open. The
    package's postinst closes Settings for that reason.

    AltList is looked for under the jailbreak's root, which is found from where this library was
    loaded from: RootHide keeps a ".jbroot" link beside every binary it installs.

    The self-test. When the marker <log dir>/atelier_prefs_test exists, Settings writes
    <log dir>/AtelierSettings.log a moment after it starts (tools/phone.sh settings):

      1. whether AltList is in, and from where
      2. what is saved under shortcutApps, and as what type
      3. the page read with Settings' own reader (SpecifiersFromPlist): every row that opens
         another screen, with the controller class Settings found for it
      4. the page opened the way PreferenceLoader opens it (its entry row, its page controller):
         the same rows again, as that page has them
      5. the Shortcut Apps row opened the way a tap opens it (-controllerForSpecifier:): the
         controller's class and how many rows it has

    The report is written after every step, so if a step takes Settings down the steps before
    it are in the file. Names of apps are never written.                                       */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <unistd.h>

static char gAnchor;                         // an address in this library: dyld says where it was loaded from
static NSString *gNote = nil;                // what happened to AltList

static NSString *const kLogDir = @"/var/mobile/Library/Logs";
static NSString *const kAltList = @"Library/Frameworks/AltList.framework/AltList";
static NSString *const kPage = @"Library/PreferenceLoader/Preferences/Atelier.plist";
static NSString *const kListClass = @"ATLApplicationListMultiSelectionController";

static NSString *AtelierPrefsFind(NSString *tail) {
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

static BOOL AtelierPrefsHasAltList(void) {
    return NSClassFromString(kListClass) != Nil;
}

static NSString *AtelierPrefsLoadAltList(void) {
    if (AtelierPrefsHasAltList()) return @"AltList was in Settings already";
    NSString *path = AtelierPrefsFind(kAltList);
    if (!path) return @"AltList is not installed where HyperTrade looks: the Shortcut Apps list cannot open";
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    if (handle && AtelierPrefsHasAltList()) return [NSString stringWithFormat:@"AltList loaded from %@", path];
    const char *why = dlerror();
    return [NSString stringWithFormat:@"AltList at %@ did not load: %s", path, why ? why : "no reason given"];
}

#pragma mark - the self-test

static NSMutableString *gReport;

static void AtelierPrefsSay(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void AtelierPrefsSay(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!gReport) gReport = [NSMutableString string];
    [gReport appendFormat:@"%@\n", line];
    [gReport writeToFile:[kLogDir stringByAppendingPathComponent:@"AtelierSettings.log"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static id AtelierPrefsProperty(id spec, NSString *key) {
    SEL s = NSSelectorFromString(@"propertyForKey:");
    if (![spec respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(spec, s, key); } @catch (__unused id e) {}
    return nil;
}

static id AtelierPrefsValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused id e) {}
    return nil;
}

static NSString *AtelierPrefsClassLine(Class cls) {            // "A : B : C" up to NSObject
    if (!cls) return @"NOTHING";
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (Class c = cls; c && chain.count < 6; c = class_getSuperclass(c)) {
        [chain addObject:NSStringFromClass(c)];
        if (c == NSClassFromString(@"PSListController")) break;
    }
    return [chain componentsJoinedByString:@" : "];
}

// One line per row that opens another screen; returns the Shortcut Apps row.
static id AtelierPrefsListRows(NSArray *specs, NSString *how) {
    id shortcut = nil;
    NSInteger links = 0, broken = 0;
    for (id spec in specs) {
        NSNumber *cell = AtelierPrefsValue(spec, @"cellType");
        Class detail = (Class)AtelierPrefsValue(spec, @"detailControllerClass");
        id wanted = AtelierPrefsProperty(spec, @"detail");
        NSString *key = AtelierPrefsProperty(spec, @"key");
        BOOL link = cell.integerValue == 1 || cell.integerValue == 2 || detail || [wanted isKindOfClass:NSString.class];     // PSLinkCell, PSLinkListCell
        if ([key isKindOfClass:NSString.class] && [key isEqualToString:@"shortcutApps"]) shortcut = spec;
        if (!link) continue;
        links++;
        if (!detail) broken++;
        AtelierPrefsSay(@"    row \"%@\" (key %@, cell type %@): asked for %@ -> %@", AtelierPrefsValue(spec, @"name") ?: @"?", key ?: @"-", cell ?: @"?",
                        [wanted isKindOfClass:NSString.class] ? wanted : @"(nothing named)", detail ? NSStringFromClass(detail) : @"NOTHING (the row cannot open)");
    }
    AtelierPrefsSay(@"  %@: %lu rows, %ld open another screen, %ld of those have no controller; Shortcut Apps row %@", how, (unsigned long)specs.count,
                    (long)links, (long)broken, shortcut ? @"found" : @"NOT FOUND");
    return shortcut;
}

// Settings' own reader for a page: the function PreferenceLoader calls for every entry.
typedef NSArray *(*AtelierPrefsReader)(NSDictionary *plist, id previous, id target, NSString *name, NSBundle *bundle,
                                       NSString *__autoreleasing *title, NSString *__autoreleasing *identifier,
                                       id caller, NSMutableArray *__autoreleasing *bundleControllers);

static void AtelierPrefsReport(void) {
    AtelierPrefsSay(@"HyperTrade (Atelier) in Settings, pid %d, %@", (int)getpid(), [NSDate date]);

    // 1. AltList
    Class listClass = NSClassFromString(kListClass);
    AtelierPrefsSay(@"1. %@", gNote ?: @"AltList: nothing was tried");
    AtelierPrefsSay(@"   list class: %@", listClass ? AtelierPrefsClassLine(listClass) : @"MISSING");
    AtelierPrefsSay(@"   PreferenceLoader's page class: %@", NSClassFromString(@"PLCustomListController") ? @"PLCustomListController is here" : @"not in Settings");

    // 2. what is saved
    @try {
        id stored = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("shortcutApps"), CFSTR("com.adarsh.atelier")));
        if (!stored) {
            AtelierPrefsSay(@"2. shortcutApps: nothing is saved");
        } else if ([stored isKindOfClass:NSArray.class]) {
            NSCountedSet *kinds = [NSCountedSet set];
            for (id item in (NSArray *)stored) [kinds addObject:[item isKindOfClass:NSString.class] ? @"string" : NSStringFromClass([item class])];
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (NSString *kind in kinds) [parts addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)[kinds countForObject:kind], kind]];
            AtelierPrefsSay(@"2. shortcutApps: an array (%@) of %lu item(s)%@", NSStringFromClass([stored class]), (unsigned long)[(NSArray *)stored count],
                            parts.count ? [NSString stringWithFormat:@": %@", [parts componentsJoinedByString:@", "]] : @"");
        } else if ([stored isKindOfClass:NSDictionary.class]) {
            AtelierPrefsSay(@"2. shortcutApps: a DICTIONARY (%@) of %lu item(s). The list expects an array.", NSStringFromClass([stored class]),
                            (unsigned long)[(NSDictionary *)stored count]);
        } else {
            AtelierPrefsSay(@"2. shortcutApps: a %@. The list expects an array.", NSStringFromClass([stored class]));
        }
    } @catch (NSException *e) {
        AtelierPrefsSay(@"2. shortcutApps: reading it threw %@", e.reason);
    }

    // 3. the page, read with Settings' own reader
    NSString *page = AtelierPrefsFind(kPage);
    NSDictionary *plist = page ? [NSDictionary dictionaryWithContentsOfFile:page] : nil;
    NSArray *items = [plist[@"items"] isKindOfClass:NSArray.class] ? plist[@"items"] : nil;
    NSString *folder = page.stringByDeletingLastPathComponent;
    NSBundle *bundle = folder ? [NSBundle bundleWithPath:folder] : nil;
    AtelierPrefsReader reader = (AtelierPrefsReader)dlsym(RTLD_DEFAULT, "SpecifiersFromPlist");
    id shortcutRow = nil;
    AtelierPrefsSay(@"3. page file: %@ (entry label \"%@\", title \"%@\", %lu items)", page ?: @"NOT FOUND", plist[@"entry"][@"label"] ?: @"?",
                    plist[@"title"] ?: @"?", (unsigned long)items.count);
    if (!reader || !items) {
        AtelierPrefsSay(@"  cannot be read here (reader %@)", reader ? @"found" : @"missing");
    } else {
        @try {
            NSString *title = nil, *identifier = nil;
            NSMutableArray *controllers = nil;
            NSArray *specs = reader(@{ @"items": items }, nil, nil, @"Atelier", bundle, &title, &identifier, nil, &controllers);
            shortcutRow = AtelierPrefsListRows(specs, @"read with SpecifiersFromPlist");
        } @catch (NSException *e) {
            AtelierPrefsSay(@"  SpecifiersFromPlist threw %@", e.reason);
        }
    }

    // 4. the page the way PreferenceLoader opens it
    id pageController = nil;
    AtelierPrefsSay(@"4. the page as PreferenceLoader opens it");
    @try {
        Class listController = NSClassFromString(@"PSListController");
        SEL fromEntry = NSSelectorFromString(@"specifiersFromEntry:sourcePreferenceLoaderBundlePath:title:");
        id anyList = [listController new];
        NSArray *entries = nil;
        if ([anyList respondsToSelector:fromEntry] && [plist[@"entry"] isKindOfClass:NSDictionary.class] && folder) {
            entries = ((id (*)(id, SEL, id, id, id))objc_msgSend)(anyList, fromEntry, plist[@"entry"], folder, @"Atelier");
        } else {
            AtelierPrefsSay(@"  PreferenceLoader's -specifiersFromEntry:… is not in Settings: step skipped");
        }
        id entry = entries.firstObject;
        if (entry) {
            Class pageClass = (Class)AtelierPrefsValue(entry, @"detailControllerClass");
            AtelierPrefsSay(@"  entry row \"%@\": controller %@, pl_alt_plist_name %@, pl_bundle %@", AtelierPrefsValue(entry, @"name") ?: @"?",
                            pageClass ? NSStringFromClass(pageClass) : @"NOTHING", AtelierPrefsProperty(entry, @"pl_alt_plist_name") ?: @"(none)",
                            [AtelierPrefsProperty(entry, @"pl_bundle") bundlePath] ?: @"(none)");
            if (pageClass) {
                pageController = [pageClass new];
                SEL setSpecifier = NSSelectorFromString(@"setSpecifier:");
                if ([pageController respondsToSelector:setSpecifier]) ((void (*)(id, SEL, id))objc_msgSend)(pageController, setSpecifier, entry);
                NSArray *rows = ((id (*)(id, SEL))objc_msgSend)(pageController, NSSelectorFromString(@"specifiers"));
                id row = AtelierPrefsListRows(rows, [NSString stringWithFormat:@"-[%@ specifiers]", NSStringFromClass(pageClass)]);
                if (rows.count <= 2) for (id spec in rows) AtelierPrefsSay(@"    the page says: \"%@\"", AtelierPrefsValue(spec, @"name") ?: @"?");
                if (row) shortcutRow = row;
            }
        } else if (entries) {
            AtelierPrefsSay(@"  PreferenceLoader made no entry row from the plist");
        }
    } @catch (NSException *e) {
        AtelierPrefsSay(@"  threw %@", e.reason);
    }

    // 5. the Shortcut Apps list, opened the way a tap opens it
    AtelierPrefsSay(@"5. the Shortcut Apps row, opened");
    @try {
        if (!shortcutRow) {
            AtelierPrefsSay(@"  there is no such row to open");
        } else {
            id list = nil;
            SEL open = NSSelectorFromString(@"controllerForSpecifier:");
            if (pageController && [pageController respondsToSelector:open]) {
                list = ((id (*)(id, SEL, id))objc_msgSend)(pageController, open, shortcutRow);
                AtelierPrefsSay(@"  -controllerForSpecifier: gave %@", list ? AtelierPrefsClassLine([list class]) : @"NOTHING");
            }
            if (!list) {
                Class detail = (Class)AtelierPrefsValue(shortcutRow, @"detailControllerClass");
                list = [detail new];
                SEL setSpecifier = NSSelectorFromString(@"setSpecifier:");
                if ([list respondsToSelector:setSpecifier]) ((void (*)(id, SEL, id))objc_msgSend)(list, setSpecifier, shortcutRow);
                AtelierPrefsSay(@"  made by hand from the row's class: %@", list ? AtelierPrefsClassLine([list class]) : @"NOTHING (the row has no class)");
            }
            if (list) {
                SEL specifiers = NSSelectorFromString(@"specifiers");
                NSArray *rows = [list respondsToSelector:specifiers] ? ((id (*)(id, SEL))objc_msgSend)(list, specifiers) : nil;
                NSInteger groups = 0;
                for (id spec in rows) if ([AtelierPrefsValue(spec, @"cellType") integerValue] == 0) groups++;
                AtelierPrefsSay(@"  its specifiers: %@ with %lu row(s), %ld of them group headers", rows ? NSStringFromClass([rows class]) : @"NOTHING",
                                (unsigned long)rows.count, (long)groups);
                // an error page has one or two rows of text: say what it says (an app list has many, and its names stay out of this file)
                if (rows.count && rows.count <= 2) for (id spec in rows) AtelierPrefsSay(@"    it says: \"%@\"", AtelierPrefsValue(spec, @"name") ?: @"?");
                SEL read = NSSelectorFromString(@"readPreferenceValue:");
                if ([list respondsToSelector:read]) {
                    id value = ((id (*)(id, SEL, id))objc_msgSend)(list, read, shortcutRow);
                    AtelierPrefsSay(@"  the list reads the saved value as: %@", value ? NSStringFromClass([value class]) : @"nothing");
                }
            }
        }
    } @catch (NSException *e) {
        AtelierPrefsSay(@"  threw %@: %@", e.name, e.reason);
    }
    AtelierPrefsSay(@"done");
}

__attribute__((constructor)) static void AtelierPrefsInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) return;
        @try { gNote = AtelierPrefsLoadAltList(); } @catch (NSException *e) { gNote = [NSString stringWithFormat:@"AltList: %@", e.reason]; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:[kLogDir stringByAppendingPathComponent:@"atelier_prefs_test"]]) return;
        // the report waits until Settings is up: reading a page makes cells' images and the like
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { AtelierPrefsReport(); } @catch (NSException *e) { AtelierPrefsSay(@"the self-test threw %@", e.reason); }
        });
    }
}
