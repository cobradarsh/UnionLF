/*  WMSettings.m — settings storage that survives the app sandbox.

    The problem this solves: the Settings page writes into the preference
    domain "com.adarsh.wingman". A tweak inside a sandboxed App Store app
    (WhatsApp, Tinder, Hopr...) is often refused both the cfprefsd query for
    a foreign domain and a direct read of the prefs file. RootHide keeps app
    sandboxes intact on purpose, so that refusal is normal, not a bug.

    So we read from every place the value could be, in order, and we let you
    type the key inside Wingman as well. Writes go everywhere we are allowed
    to write; if only the app-local store works, the value still applies, just
    in that one app, and Wingman says so.

    Rule: a value stored globally always wins. App-local is only used for keys
    the global store doesn't have, so editing in Settings still takes over.   */

#import "Wingman.h"
#import <dlfcn.h>

static CFStringRef const kWMDomain    = CFSTR("com.adarsh.wingman");
static NSString  *const kWMPlistName  = @"com.adarsh.wingman.plist";
static NSString  *const kWMLocalKey   = @"com.adarsh.wingman.localSettings";

static void WMAnchor(void) {}

// "<jbroot>/Library/MobileSubstrate/DynamicLibraries/Wingman.dylib" -> "<jbroot>"
static NSString *WMJBRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((const void *)&WMAnchor, &info) && info.dli_fname) {
            NSString *p = @(info.dli_fname);
            NSRange r = [p rangeOfString:@"/Library/MobileSubstrate/"];
            if (r.location != NSNotFound && r.location > 0)
                root = [p substringToIndex:r.location];
        }
    });
    return root;
}

// every file that could hold the global settings
static NSArray<NSString *> *WMGlobalPaths(void) {
    NSMutableArray *p = [NSMutableArray array];
    NSString *jb = WMJBRoot();
    if (jb) {
        [p addObject:[jb stringByAppendingFormat:@"/var/mobile/Library/Preferences/%@", kWMPlistName]];
        [p addObject:[jb stringByAppendingFormat:@"/var/mobile/Library/Preferences/ByHost/%@", kWMPlistName]];
    }
    [p addObject:[@"/var/mobile/Library/Preferences/" stringByAppendingString:kWMPlistName]];
    [p addObject:[@"/var/jb/var/mobile/Library/Preferences/" stringByAppendingString:kWMPlistName]];
    return p;
}

// The one file we actively CREATE and keep world-readable, so every sandboxed app
// (not just the one a key was typed in) can read the settings. Prefer the jbroot copy,
// which an injected tweak can reach from any app; fall back to the plain path.
static NSString *WMSharedGlobalPath(void) {
    NSString *jb = WMJBRoot();
    NSString *dir = jb ? [jb stringByAppendingString:@"/var/mobile/Library/Preferences"]
                       : @"/var/mobile/Library/Preferences";
    return [dir stringByAppendingPathComponent:kWMPlistName];
}

@implementation WMSettings {
    NSDictionary *_prefs;        // merged view
    NSDictionary *_global;       // what the global store gave us
    NSString     *_diag;
}

+ (instancetype)shared {
    static WMSettings *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [WMSettings new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) [self reload];
    return self;
}

#pragma mark - read

- (void)reload {
    NSMutableArray *log = [NSMutableArray array];
    NSMutableDictionary *global = [NSMutableDictionary dictionary];

    // 1. cfprefsd (works when the sandbox allows the foreign domain)
    CFPreferencesAppSynchronize(kWMDomain);
    CFArrayRef keys = CFPreferencesCopyKeyList(kWMDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        CFDictionaryRef d = CFPreferencesCopyMultiple(keys, kWMDomain,
                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (d) {
            NSDictionary *nd = (__bridge_transfer NSDictionary *)d;
            [global addEntriesFromDictionary:nd];
            [log addObject:[NSString stringWithFormat:@"cfprefs: %lu keys", (unsigned long)nd.count]];
        }
        CFRelease(keys);
    }
    if (global.count == 0) [log addObject:@"cfprefs: blocked/empty"];

    // 2. the prefs file, wherever it lives
    for (NSString *p in WMGlobalPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (!d.count) continue;
        NSInteger added = 0;
        for (id k in d) if (!global[k]) { global[k] = d[k]; added++; }
        [log addObject:[NSString stringWithFormat:@"file %@: %lu keys (+%ld new)",
                        [p stringByDeletingLastPathComponent].lastPathComponent,
                        (unsigned long)d.count, (long)added]];
    }
    if (global.count == 0) [log addObject:@"no global settings readable from this app"];

    // 3. values you chose inside Wingman. Your latest choice wins: a value saved
    //    here stays in force until the global value changes after it (you then
    //    edited it in Settings on purpose, so that newer edit wins instead).
    NSDictionary *local = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kWMLocalKey];
    NSMutableDictionary *merged = [global mutableCopy];
    NSInteger used = 0;
    for (id k in local) {
        id entry = local[k], v, seen;
        if ([entry isKindOfClass:[NSDictionary class]] && entry[@"v"]) {
            v = entry[@"v"];
            seen = entry[@"g"];                   // absent = Settings had no value
        } else {                                   // older format: plain value
            v = entry; seen = global[k];
        }
        id now = global[k];
        BOOL settingsUnchanged = (now == nil && seen == nil) || [now isEqual:seen];
        if (settingsUnchanged || now == nil) { merged[k] = v; used++; }
    }
    if (local.count) [log addObject:[NSString stringWithFormat:@"this app: %lu keys (%ld used)",
                                     (unsigned long)local.count, (long)used]];

    _global = [global copy];
    _prefs  = [merged copy];
    _diag   = [log componentsJoinedByString:@"\n"];
}

- (NSString *)diagnostics {
    NSMutableString *s = [NSMutableString stringWithString:_diag ?: @""];
    [s appendFormat:@"\n\nClaude key: %@", _prefs[@"claudeAPIKey"] ? @"found" : @"MISSING"];
    [s appendFormat:@"\nDeepSeek key: %@", _prefs[@"deepseekAPIKey"] ? @"found" : @"MISSING"];
    [s appendFormat:@"\njbroot: %@", WMJBRoot() ?: @"not detected"];
    NSString *shared = WMSharedGlobalPath();
    [s appendFormat:@"\nshared file: %@",
        [[NSFileManager defaultManager] fileExistsAtPath:shared] ? @"present (readable here)" : @"not created yet"];
    return s;
}

#pragma mark - write

// Writes everywhere allowed. Returns YES if it landed somewhere global.
- (BOOL)setValue:(id)value forSettingKey:(NSString *)key {
    BOOL global = NO;

    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                          kWMDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (CFPreferencesSynchronize(kWMDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        global = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in WMGlobalPaths()) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p];
        if (!d) continue;                      // only update a file that already exists
        d[key] = value;
        if ([d writeToFile:p atomically:YES]) {
            global = YES;
            // keep it readable from every app's sandbox, not just the one that wrote it
            [fm setAttributes:@{ NSFilePosixPermissions: @(0644) } ofItemAtPath:p error:nil];
        }
    }

    // The real cross-app fix: CREATE a shared, world-readable copy if one doesn't
    // exist yet. Before this, a key entered inside Wingman only ever reached this
    // app's own NSUserDefaults, so it showed as "no API key" in every OTHER app.
    NSString *shared = WMSharedGlobalPath();
    if (shared) {
        [fm createDirectoryAtPath:[shared stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:shared] ?: [NSMutableDictionary dictionary];
        for (id k in _global) if (!d[k]) d[k] = _global[k];   // don't lose keys we already knew
        d[key] = value;
        if ([d writeToFile:shared atomically:YES]) {
            [fm setAttributes:@{ NSFilePosixPermissions: @(0644) } ofItemAtPath:shared error:nil];
            global = YES;
        }
    }

    // see what the global store holds now (our write may or may not have stuck)
    [self reload];
    id back = _global[key];
    BOOL landed = global && back && [back isEqual:value];

    // always keep a copy in this app, with a note of what Settings held at this
    // moment, so this choice wins until Settings itself changes later
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *local = [[ud dictionaryForKey:kWMLocalKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    // (NSNull can't be stored in defaults: leave "g" out when Settings had nothing)
    local[key] = back ? @{ @"v": value, @"g": back } : @{ @"v": value };
    [ud setObject:local forKey:kWMLocalKey];

    [self reload];
    return landed;
}

- (void)clearLocalOverrides {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kWMLocalKey];
    [self reload];
}

#pragma mark - values

static NSString *WMStr(id v, NSString *fallback) {
    if ([v isKindOfClass:[NSString class]]) {
        NSString *t = [(NSString *)v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) return t;
    }
    return fallback;
}

- (WMAPIProvider)provider { return [_prefs[@"apiProvider"] integerValue] == 1 ? WMAPIProviderDeepSeek : WMAPIProviderClaude; }
- (NSString *)claudeKey   { return WMStr(_prefs[@"claudeAPIKey"], @""); }
- (NSString *)deepseekKey { return WMStr(_prefs[@"deepseekAPIKey"], @""); }
- (NSString *)soundLikeMe { return WMStr(_prefs[@"soundLikeMe"], @""); }
- (BOOL)claudeSendsScreenshot { return [_prefs[@"claudeReads"] integerValue] == 1; }

- (NSString *)keyForProvider:(WMAPIProvider)p {
    return p == WMAPIProviderDeepSeek ? self.deepseekKey : self.claudeKey;
}
- (NSString *)keyPrefKeyForProvider:(WMAPIProvider)p {
    return p == WMAPIProviderDeepSeek ? @"deepseekAPIKey" : @"claudeAPIKey";
}

// base URL with no path
- (NSString *)deepseekBaseURL {
    NSString *b = WMStr(_prefs[@"deepseekBaseURL"], @"https://api.deepseek.com");
    if (![b hasPrefix:@"http://"] && ![b hasPrefix:@"https://"]) b = [@"https://" stringByAppendingString:b];
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    if ([b hasSuffix:@"/chat/completions"]) b = [b substringToIndex:b.length - @"/chat/completions".length];
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    return b;
}
- (NSString *)deepseekEndpoint { return [self.deepseekBaseURL stringByAppendingString:@"/chat/completions"]; }

#pragma mark - models

static NSString *WMModelKey(WMAPIProvider p) {
    return p == WMAPIProviderDeepSeek ? @"deepseekModel" : @"claudeModel";
}

- (NSString *)modelForProvider:(WMAPIProvider)p {
    NSString *def = p == WMAPIProviderDeepSeek ? @"deepseek-chat" : @"claude-sonnet-4-5-20250929";
    return WMStr(_prefs[WMModelKey(p)], def);
}
- (BOOL)hasChosenModelForProvider:(WMAPIProvider)p {
    return WMStr(_prefs[WMModelKey(p)], @"").length > 0;
}
- (BOOL)saveModel:(NSString *)modelID forProvider:(WMAPIProvider)p {
    if (modelID.length == 0) return NO;
    return [self setValue:modelID forSettingKey:WMModelKey(p)];
}
- (BOOL)saveProvider:(WMAPIProvider)p {
    return [self setValue:@(p == WMAPIProviderDeepSeek ? 1 : 0) forSettingKey:@"apiProvider"];
}

- (BOOL)saveKey:(NSString *)key forProvider:(WMAPIProvider)p {
    NSString *t = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [self setValue:t forSettingKey:[self keyPrefKeyForProvider:p]];
}

- (NSString *)claudeModel   { return [self modelForProvider:WMAPIProviderClaude]; }
- (NSString *)deepseekModel { return [self modelForProvider:WMAPIProviderDeepSeek]; }

#pragma mark - apps

- (BOOL)autoDetectApps { id v = _prefs[@"autoDetectApps"]; return v ? [v boolValue] : YES; }

- (NSArray<NSString *> *)manualApps {
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    id v = _prefs[@"manualApps"];
    if ([v isKindOfClass:[NSArray class]])
        for (id x in v) if ([x isKindOfClass:[NSString class]] && [x length]) [out addObject:x];
    id typed = _prefs[@"otherAppIDs"];
    if ([typed isKindOfClass:[NSString class]]) {
        NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@", \n\t;"];
        for (NSString *t in [typed componentsSeparatedByCharactersInSet:sep])
            if (t.length) [out addObject:t];
    }
    return out.array;
}

- (BOOL)bubbleOnRight { id v = _prefs[@"bubbleOnRight"]; return v ? [v boolValue] : YES; }
- (CGFloat)bubbleAlpha {
    id v = _prefs[@"bubbleAlpha"];
    CGFloat a = v ? [v floatValue] : 0.85;
    return MAX(0.3, MIN(1.0, a));
}

@end
