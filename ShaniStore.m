/*  ShaniStore.m — where Shani keeps its files, and how they are read. In both libraries.

    <Library>/Shani/state.plist         which apps are on the list, what is held, until when.
                                        Written by SpringBoard only; Settings reads it.
    <Library>/Shani/log/<app>.plist     the notification log of one app: an array, oldest first.
                                        Written by SpringBoard; Settings reads it and may delete it.
    <Library>/Logs/Shani.log            the debug log (what Shani did, no notification text)

    On the phone <Library> is /var/mobile/Library. In the simulator it is the folder named by
    SHANI_DIR, so a test can read everything.                                                  */

#import "Shani.h"

static NSString *ShaniBase(BOOL *fromEnv) {
#if TARGET_OS_SIMULATOR
    const char *env = getenv("SHANI_DIR");
    if (env && env[0]) { if (fromEnv) *fromEnv = YES; return @(env); }
    if (fromEnv) *fromEnv = NO;
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
#else
    if (fromEnv) *fromEnv = NO;
    return @"/var/mobile/Library";
#endif
}

NSString *ShaniDataDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [ShaniBase(NULL) stringByAppendingPathComponent:@"Shani"];
        [[NSFileManager defaultManager] createDirectoryAtPath:[dir stringByAppendingPathComponent:@"log"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

NSString *ShaniLogDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL fromEnv = NO;
        NSString *base = ShaniBase(&fromEnv);
        dir = fromEnv ? base : [base stringByAppendingPathComponent:@"Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

NSString *ShaniStatePath(void) {
    return [ShaniDataDir() stringByAppendingPathComponent:@"state.plist"];
}

static NSString *ShaniFileName(NSString *bundleID) {
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger i = 0; i < bundleID.length && i < 120; i++) {
        unichar c = [bundleID characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
        [name appendFormat:@"%C", (unichar)(ok ? c : '_')];
    }
    if (name.length == 0) [name appendString:@"_"];
    return name;
}

NSString *ShaniNoteLogPath(NSString *bundleID) {
    NSString *file = [ShaniFileName(bundleID ?: @"") stringByAppendingPathExtension:@"plist"];
    return [[ShaniDataDir() stringByAppendingPathComponent:@"log"] stringByAppendingPathComponent:file];
}

NSArray<NSDictionary *> *ShaniReadNoteLog(NSString *bundleID) {
    NSArray *raw = [NSArray arrayWithContentsOfFile:ShaniNoteLogPath(bundleID)];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:raw.count];
    for (id item in raw) if ([item isKindOfClass:NSDictionary.class]) [out addObject:item];
    return out;
}

NSArray<NSString *> *ShaniAppsWithNoteLogs(void) {
    NSString *dir = [ShaniDataDir() stringByAppendingPathComponent:@"log"];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        if ([file.pathExtension isEqualToString:@"plist"]) [out addObject:file.stringByDeletingPathExtension];
    }
    [out sortUsingSelector:@selector(caseInsensitiveCompare:)];
    return out;
}

NSDictionary *ShaniReadState(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:ShaniStatePath()];
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

NSString *ShaniClockText(double epoch) {
    if (epoch <= 0) return @"";
    static NSDateFormatter *today, *other;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        today = [NSDateFormatter new];
        today.dateStyle = NSDateFormatterNoStyle;
        today.timeStyle = NSDateFormatterShortStyle;
        other = [NSDateFormatter new];
        [other setLocalizedDateFormatFromTemplate:@"dMMMjmm"];
    });
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:epoch];
    return [([[NSCalendar currentCalendar] isDateInToday:date] ? today : other) stringFromDate:date] ?: @"";
}

NSString *ShaniPeriodText(NSInteger minutes) {
    if (minutes < 1) minutes = 1;
    if (minutes % 1440 == 0) return minutes == 1440 ? @"1 day" : [NSString stringWithFormat:@"%ld days", (long)(minutes / 1440)];
    if (minutes % 60 == 0) return minutes == 60 ? @"1 hour" : [NSString stringWithFormat:@"%ld hours", (long)(minutes / 60)];
    if (minutes < 60) return minutes == 1 ? @"1 minute" : [NSString stringWithFormat:@"%ld minutes", (long)minutes];
    return [NSString stringWithFormat:@"%ld h %ld min", (long)(minutes / 60), (long)(minutes % 60)];
}

NSString *ShaniFateText(NSDictionary *entry) {
    NSInteger fate = [entry[@"st"] respondsToSelector:@selector(integerValue)] ? [entry[@"st"] integerValue] : 0;
    double rel = [entry[@"rel"] respondsToSelector:@selector(doubleValue)] ? [entry[@"rel"] doubleValue] : 0;
    double due = [entry[@"due"] respondsToSelector:@selector(doubleValue)] ? [entry[@"due"] doubleValue] : 0;
    switch (fate) {
        case ShaniFateHeld:      return due > 0 ? [NSString stringWithFormat:@"Held · comes up %@", ShaniClockText(due)] : @"Held";
        case ShaniFateReleased:  return rel > 0 ? [NSString stringWithFormat:@"Held · shown %@", ShaniClockText(rel)] : @"Held · shown";
        case ShaniFateLogOnly:   return @"Held · kept in this log only";
        case ShaniFateWithdrawn: return @"Held · taken back by the app";
        case ShaniFateTapped:    return @"You tapped Shani on this one";
        case ShaniFateCritical:  return @"Critical alert · shown at once";
        default:                 return @"Shown at once";
    }
}

NSArray<NSString *> *ShaniCleanList(id raw) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:NSString.class] || [item length] == 0 || [out containsObject:item]) continue;
        [out addObject:item];
    }
    return out;
}
