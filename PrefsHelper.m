/*  PrefsHelper.m — ChakraPrefs.dylib, the only Chakra code that runs in the Settings app.

    Settings → Chakra is a page made from a plist; it has no code of its own. Its lists of apps
    are AltList's controllers, and Settings can open such a row only if the controller's class
    is already in the process when it reads the page. Tweaks with a compiled settings bundle get
    that for free, because the bundle links AltList. A plist cannot: "bundle = AltList" is
    honoured for a top-level PreferenceLoader entry (the loader itself points Settings at the
    jailbreak's PreferenceBundles folder), but nothing does that for a row inside a page, and
    the loader then shows "There was an error loading the preference bundle". Chakra 1.0.1 and
    1.0.2 shipped their four app rows that way.

    So this loads AltList when Settings starts, and the rows name the class and nothing else.
    Nothing is hooked; nothing else happens here.

    With the test marker present (<log dir>/chakra_test, see ChakraDebug.m) it also writes
    <log dir>/ChakraSettings.log: where AltList came from, and which controller Settings gives
    each row of the page that opens another screen.  */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <unistd.h>

static char gAnchor;                         // an address in this library: dyld says where it was loaded from
static NSString *gNote = nil;                // what happened to AltList, for the log

static NSString *const kLogDir = @"/var/mobile/Library/Logs";
static NSString *const kAltList = @"Library/Frameworks/AltList.framework/AltList";
static NSString *const kPage = @"Library/PreferenceLoader/Preferences/Chakra.plist";

// Folders that may be the jailbreak's root, most likely first. RootHide keeps a ".jbroot" link
// beside every binary it installs; elsewhere the root is a few folders above this library.
static NSArray<NSString *> *ChakraPrefsRoots(void) {
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
    [roots addObject:@"/var/jb"];
    [roots addObject:@"/"];
    return roots;
}

static NSString *ChakraPrefsFind(NSString *tail) {
    for (NSString *root in ChakraPrefsRoots()) {
        NSString *path = [root stringByAppendingPathComponent:tail];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}

static BOOL ChakraPrefsHasAltList(void) {
    return NSClassFromString(@"ATLApplicationListMultiSelectionController") != Nil;
}

static void ChakraPrefsLoadAltList(void) {
    if (ChakraPrefsHasAltList()) { gNote = @"AltList was in Settings already"; return; }
    NSString *path = ChakraPrefsFind(kAltList);
    if (!path) { gNote = @"AltList is not installed where Chakra looks: the app lists cannot open"; return; }
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    if (handle && ChakraPrefsHasAltList()) {
        gNote = [NSString stringWithFormat:@"AltList loaded from %@", path];
    } else {
        const char *why = dlerror();
        gNote = [NSString stringWithFormat:@"AltList at %@ did not load: %s", path, why ? why : "no reason given"];
    }
}

#pragma mark - the test report

static id ChakraPrefsProperty(id spec, NSString *key) {
    SEL s = NSSelectorFromString(@"propertyForKey:");
    if (![spec respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(spec, s, key); } @catch (__unused id e) {}
    return nil;
}

static NSString *ChakraPrefsDetail(id spec) {
    id cls = nil;
    @try { cls = [spec valueForKey:@"detailControllerClass"]; } @catch (__unused id e) {}
    return cls ? NSStringFromClass(cls) : nil;
}

// Settings' own reader for a page: the function PreferenceLoader calls for every entry.
typedef NSArray *(*ChakraPrefsReader)(NSDictionary *plist, id previous, id target, NSString *name, NSBundle *bundle,
                                      NSString *__autoreleasing *title, NSString *__autoreleasing *identifier,
                                      id caller, NSMutableArray *__autoreleasing *bundleControllers);

static NSArray *ChakraPrefsRead(ChakraPrefsReader reader, NSArray *items, NSBundle *bundle) {
    NSString *title = nil, *identifier = nil;
    NSMutableArray *controllers = nil;
    @try {
        return reader(@{ @"items": items }, nil, nil, @"Chakra", bundle, &title, &identifier, nil, &controllers);
    } @catch (__unused id e) {
        return nil;
    }
}

static void ChakraPrefsReport(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"Chakra in Settings (pid %d), %@\n", (int)getpid(), [NSDate date]];
    [out appendFormat:@"%@\n", gNote ?: @"AltList: nothing was tried"];

    ChakraPrefsReader reader = (ChakraPrefsReader)dlsym(RTLD_DEFAULT, "SpecifiersFromPlist");
    NSString *page = ChakraPrefsFind(kPage);
    NSDictionary *plist = page ? [NSDictionary dictionaryWithContentsOfFile:page] : nil;
    NSArray *items = [plist[@"items"] isKindOfClass:NSArray.class] ? plist[@"items"] : nil;
    if (!reader || !items) {
        [out appendFormat:@"page: cannot be read here (reader %@, file %@)\n", reader ? @"found" : @"missing", page ?: @"not found"];
    } else {
        NSBundle *bundle = [NSBundle bundleWithPath:page.stringByDeletingLastPathComponent];
        NSArray *specs = ChakraPrefsRead(reader, items, bundle);
        NSInteger links = 0, broken = 0;
        BOOL paired = specs.count == items.count;      // one row per entry, so the entry says what was asked for
        for (NSUInteger i = 0; i < specs.count; i++) {
            id spec = specs[i];
            NSDictionary *item = (paired && [items[i] isKindOfClass:NSDictionary.class]) ? items[i] : nil;
            id wanted = item ? item[@"detail"] : ChakraPrefsProperty(spec, @"detail");
            if (![wanted isKindOfClass:NSString.class]) continue;
            NSString *got = ChakraPrefsDetail(spec);
            links++;
            if (!got) broken++;
            NSString *name = item[@"label"];
            if (!name) { @try { name = [spec valueForKey:@"name"]; } @catch (__unused id e) {} }
            NSString *cell = @"";
            if (item[@"cellClass"]) {
                id made = ChakraPrefsProperty(spec, @"cellClass");
                cell = [NSString stringWithFormat:@", cell %@ -> %@", item[@"cellClass"],
                        (made && object_isClass(made)) ? NSStringFromClass(made) : @"NOTHING"];
            }
            [out appendFormat:@"row \"%@\": %@ -> %@%@\n", name ?: @"?", wanted, got ?: @"NOTHING (the row will not open)", cell];
        }
        [out appendFormat:@"page: %lu rows read from %@, %ld open another screen, %ld of those would not open\n",
                          (unsigned long)specs.count, page, (long)links, (long)broken];

        // For the record: where Settings would look for a row written the 1.0.1 way.
        NSDictionary *old = @{ @"cell": @"PSLinkCell", @"label": @"probe", @"bundle": @"AltList", @"isController": @YES,
                               @"overridePrincipalClass": @YES, @"detail": @"ATLApplicationListMultiSelectionController" };
        id probe = [ChakraPrefsRead(reader, @[old], bundle) firstObject];
        [out appendFormat:@"a row with bundle = AltList: Settings would load %@\n", ChakraPrefsProperty(probe, @"lazy-bundle") ?: @"(no path given)"];
    }
    [out writeToFile:[kLogDir stringByAppendingPathComponent:@"ChakraSettings.log"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

__attribute__((constructor)) static void ChakraPrefsInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) return;
        @try { ChakraPrefsLoadAltList(); } @catch (NSException *e) { gNote = [NSString stringWithFormat:@"AltList: %@", e.reason]; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:[kLogDir stringByAppendingPathComponent:@"chakra_test"]]) return;
        // the report waits until Settings is up: reading a page makes cells' images and the like
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { ChakraPrefsReport(); } @catch (__unused id e) {}
        });
    }
}
