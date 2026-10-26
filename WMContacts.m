/*  WMContacts.m — a small on-phone memory of who you chat with.

    Keyed by the chat's contact name (per app, in the app's own storage). It
    remembers a guessed gender and your own free-text notes (likes, dislikes,
    anything worth keeping), so a dating reply can use them without you
    scrolling the whole history. Nothing here leaves the phone except one
    keyless first-name lookup to api.genderize.io; message text is never stored
    and never sent.                                                           */

#import "Wingman.h"

static NSString *const kWMContactsKey = @"com.adarsh.wingman.contacts";

@implementation WMContacts

#pragma mark - storage (this app's own defaults)

+ (NSDictionary *)_all {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kWMContactsKey];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

+ (NSString *)_normalise:(NSString *)name {
    return [[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
}

+ (NSDictionary *)_recordForName:(NSString *)name {
    NSString *k = [self _normalise:name];
    if (k.length == 0) return nil;
    id r = [self _all][k];
    return [r isKindOfClass:[NSDictionary class]] ? r : nil;
}

+ (void)_write:(NSString *)bundle name:(NSString *)name gender:(NSString *)gender notes:(NSString *)notes {
    NSString *k = [self _normalise:name];
    if (k.length == 0) return;
    NSMutableDictionary *all = [[self _all] mutableCopy];
    all[k] = @{ @"name":   name ?: @"",
                @"app":    bundle ?: @"",
                @"gender": gender ?: @"",
                @"notes":  notes ?: @"",
                @"at":     @([[NSDate date] timeIntervalSince1970]) };
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:kWMContactsKey];
}

#pragma mark - public

+ (NSString *)noteForApp:(NSString *)bundle name:(NSString *)name {
    return [self _recordForName:name][@"notes"] ?: @"";
}

+ (void)setNote:(NSString *)note forApp:(NSString *)bundle name:(NSString *)name {
    NSDictionary *r = [self _recordForName:name];
    [self _write:bundle name:name gender:r[@"gender"] ?: @""
           notes:[note stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
}

+ (NSString *)ensureGenderForApp:(NSString *)bundle name:(NSString *)name {
    NSDictionary *r = [self _recordForName:name];
    NSString *have = r[@"gender"];
    if ([have isKindOfClass:[NSString class]] && have.length) return have;

    NSString *first = [self _firstName:name];
    if (first.length == 0) return @"";
    NSString *guessed = [self _lookupGender:first];
    if (guessed.length) [self _write:bundle name:name gender:guessed notes:r[@"notes"] ?: @""];
    return guessed;
}

+ (NSString *)promptContextForApp:(NSString *)bundle name:(NSString *)name
                           gender:(NSString *)gender typed:(NSString *)typed {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *n = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (n.length) [parts addObject:[NSString stringWithFormat:@"I'm chatting with %@.", n]];
    if ([gender isEqualToString:@"male"])
        [parts addObject:@"From their name they are most likely a man, so address them that way."];
    else if ([gender isEqualToString:@"female"])
        [parts addObject:@"From their name they are most likely a woman, so address them that way."];
    NSString *notes = [self noteForApp:bundle name:name];
    if (notes.length)
        [parts addObject:[NSString stringWithFormat:
            @"What I already know about them (use it naturally, don't read it back to them): %@", notes]];
    NSString *t = [typed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length) [parts addObject:t];
    return [parts componentsJoinedByString:@"\n"];
}

#pragma mark - internals

+ (NSString *)_firstName:(NSString *)name {
    NSString *raw = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0) return @"";
    // a name shouldn't contain digits (phone numbers, "Mom (2)", etc. are skipped)
    if ([raw rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) return @"";
    NSString *tok = [[raw componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@" ,\t\n"]] firstObject] ?: @"";
    NSMutableString *letters = [NSMutableString string];
    NSCharacterSet *lc = [NSCharacterSet letterCharacterSet];
    for (NSUInteger i = 0; i < tok.length; i++) {
        unichar c = [tok characterAtIndex:i];
        if ([lc characterIsMember:c]) [letters appendFormat:@"%C", c];
    }
    return letters.length >= 2 ? [letters copy] : @"";
}

// keyless name→gender guess. Synchronous (call off the main thread); short timeout; never throws.
+ (NSString *)_lookupGender:(NSString *)first {
    NSString *enc = [first stringByAddingPercentEncodingWithAllowedCharacters:
                     [NSCharacterSet URLQueryAllowedCharacterSet]];
    if (enc.length == 0) return @"";
    NSURL *url = [NSURL URLWithString:[@"https://api.genderize.io/?name=" stringByAppendingString:enc]];
    if (!url) return @"";

    __block NSString *result = @"";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 2.5;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && data) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) {
                NSString *g = j[@"gender"];
                double prob = [j[@"probability"] doubleValue];
                if (([g isEqualToString:@"male"] || [g isEqualToString:@"female"]) && prob >= 0.6) result = g;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));
    return result;
}

@end
