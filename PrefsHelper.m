/*  PrefsHelper.m — AtelierPrefs.dylib, the only Atelier code that runs in the Settings app.

    Settings → Atelier is a page made from a plist; it has no code of its own. Its "Shortcut
    Apps" row opens AltList's list of apps, and Settings can open such a row only if the list's
    class is already in the process when it reads the page. A plist cannot bring it in (Chakra
    1.0.1 and 1.0.2 tried "bundle = AltList" on the row; that works for a top-level
    PreferenceLoader entry only). So this loads AltList when Settings starts, and the row names
    the class and nothing else. Nothing is hooked; nothing else happens here.

    AltList is looked for under the jailbreak's root, which is found from where this library was
    loaded from: RootHide keeps a ".jbroot" link beside every binary it installs.

    When the debug marker <log dir>/atelier_prefs_test exists, what happened is written to
    <log dir>/AtelierSettings.log (tools/phone.sh settings).                                  */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>

static char gAnchor;                         // an address in this library: dyld says where it was loaded from

static NSString *const kLogDir = @"/var/mobile/Library/Logs";
static NSString *const kAltList = @"Library/Frameworks/AltList.framework/AltList";

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
    return NSClassFromString(@"ATLApplicationListMultiSelectionController") != Nil;
}

static NSString *AtelierPrefsLoadAltList(void) {
    if (AtelierPrefsHasAltList()) return @"AltList was in Settings already";
    NSString *path = AtelierPrefsFind(kAltList);
    if (!path) return @"AltList is not installed where Atelier looks: the Shortcut Apps list cannot open";
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
    if (handle && AtelierPrefsHasAltList()) return [NSString stringWithFormat:@"AltList loaded from %@", path];
    const char *why = dlerror();
    return [NSString stringWithFormat:@"AltList at %@ did not load: %s", path, why ? why : "no reason given"];
}

__attribute__((constructor)) static void AtelierPrefsInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) return;
        NSString *note = nil;
        @try { note = AtelierPrefsLoadAltList(); } @catch (NSException *e) { note = [NSString stringWithFormat:@"AltList: %@", e.reason]; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:[kLogDir stringByAppendingPathComponent:@"atelier_prefs_test"]]) return;
        NSString *report = [NSString stringWithFormat:@"Atelier in Settings (pid %d), %@\n%@\nlist class: %@\n", (int)getpid(), [NSDate date],
                            note ?: @"nothing was tried", AtelierPrefsHasAltList() ? @"ATLApplicationListMultiSelectionController is here" : @"MISSING"];
        [report writeToFile:[kLogDir stringByAppendingPathComponent:@"AtelierSettings.log"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}
