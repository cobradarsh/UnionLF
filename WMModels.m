/*  WMModels.m — fetches the models your API key can use.

    Claude:   GET https://api.anthropic.com/v1/models?limit=100&lifecycle=active
              headers x-api-key + anthropic-version; paged with after_id/last_id
    DeepSeek: GET <base URL>/models   (Authorization: Bearer <key>)

    Listing models is free on both. Results are cached for 10 minutes.   */

#import "Wingman.h"

@implementation WMModels

static NSMutableDictionary *gCache;       // "provider|key" -> @{ "at": date, "models": array }

+ (NSString *)_cacheKey:(WMAPIProvider)p key:(NSString *)k {
    return [NSString stringWithFormat:@"%ld|%@", (long)p, k];
}

+ (NSError *)_err:(NSString *)m {
    return [NSError errorWithDomain:@"Wingman" code:2 userInfo:@{NSLocalizedDescriptionKey: m}];
}

+ (NSError *)_errorFor:(NSHTTPURLResponse *)r json:(id)json name:(NSString *)name {
    NSString *api = nil;
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"error"] isKindOfClass:[NSDictionary class]])
        api = json[@"error"][@"message"];
    switch (r.statusCode) {
        case 401: return [self _err:[NSString stringWithFormat:@"%@ rejected this API key. Check it in Settings > Wingman.", name]];
        case 403: return [self _err:[NSString stringWithFormat:@"%@: this key isn't allowed to list models.", name]];
        case 404: return [self _err:[NSString stringWithFormat:@"%@: no model list at this URL. Check the Base URL.", name]];
        case 429: return [self _err:[NSString stringWithFormat:@"%@ rate limit. Try again in a few seconds.", name]];
        default:  return [self _err:api ?: [NSString stringWithFormat:@"%@ couldn't list models (HTTP %ld).", name, (long)r.statusCode]];
    }
}

+ (void)fetchForProvider:(WMAPIProvider)p
                   force:(BOOL)force
              completion:(void(^)(NSArray<NSDictionary *> *models, NSError *err))done {
    [self fetchForProvider:p key:nil force:force completion:done];
}

// key == nil uses the saved key; pass one to test it before saving
+ (void)fetchForProvider:(WMAPIProvider)p
                     key:(NSString *)explicitKey
                   force:(BOOL)force
              completion:(void(^)(NSArray<NSDictionary *> *models, NSError *err))done {
    WMSettings *s = [WMSettings shared];
    NSString *name = (p == WMAPIProviderDeepSeek) ? @"DeepSeek" : @"Claude";
    NSString *key = explicitKey.length
        ? [explicitKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : ([s reload], [s keyForProvider:p]);
    if (key.length == 0) {
        done(nil, [self _err:[NSString stringWithFormat:
            @"No %@ API key yet. Tap \"API keys\" in Wingman and paste it there.", name]]);
        return;
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{ gCache = [NSMutableDictionary dictionary]; });
    NSString *ck = [self _cacheKey:p key:key];
    NSDictionary *hit = gCache[ck];
    if (!force && hit && -[hit[@"at"] timeIntervalSinceNow] < 600) { done(hit[@"models"], nil); return; }

    NSMutableArray *all = [NSMutableArray array];
    void (^finish)(NSError *) = ^(NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (e && all.count == 0) { done(nil, e); return; }
            // current models first, deprecated ones after, order kept otherwise
            NSMutableArray *active = [NSMutableArray array], *old = [NSMutableArray array];
            for (NSDictionary *m in all)
                [[m[@"lifecycle"] isEqualToString:@"deprecated"] ? old : active addObject:m];
            [active addObjectsFromArray:old];
            gCache[ck] = @{ @"at": [NSDate date], @"models": [active copy] };
            done([active copy], nil);
        });
    };

    if (p == WMAPIProviderDeepSeek) {
        NSString *base = s.deepseekBaseURL;
        NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/models"]];
        if (!url) { done(nil, [self _err:@"DeepSeek Base URL looks invalid."]); return; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
        req.timeoutInterval = 20;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) { finish(err); return; }
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
            if (h.statusCode != 200) { finish([self _errorFor:h json:json name:name]); return; }
            NSArray *arr = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            if ([arr isKindOfClass:[NSArray class]])
                for (NSDictionary *m in arr) {
                    if (![m isKindOfClass:[NSDictionary class]] || ![m[@"id"] isKindOfClass:[NSString class]]) continue;
                    NSString *nm = [m[@"name"] isKindOfClass:[NSString class]] && [m[@"name"] length] ? m[@"name"] : m[@"id"];
                    [all addObject:@{ @"id": m[@"id"], @"name": nm }];
                }
            finish(all.count ? nil : [self _err:@"DeepSeek returned no models for this key."]);
        }] resume];
        return;
    }

    // Claude: follow pages (newest first), at most 5 pages of 100
    __block void (^page)(NSString *, NSInteger);
    __weak __block void (^weakPage)(NSString *, NSInteger);
    page = ^(NSString *afterID, NSInteger n) {
        // Only plain scalar params here. The lifecycle filter is an array param
        // ("lifecycle[]"), and getting that spelling wrong makes the whole call
        // fail, so we skip it and filter on each model's own lifecycle below.
        NSString *u = @"https://api.anthropic.com/v1/models?limit=100";
        if (afterID.length)
            u = [u stringByAppendingFormat:@"&after_id=%@",
                 [afterID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
        [req setValue:key           forHTTPHeaderField:@"x-api-key"];
        [req setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
        req.timeoutInterval = 20;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) { finish(err); return; }
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
            if (h.statusCode != 200) { finish([self _errorFor:h json:json name:name]); return; }
            NSArray *arr = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            if ([arr isKindOfClass:[NSArray class]])
                for (NSDictionary *m in arr) {
                    if (![m isKindOfClass:[NSDictionary class]] || ![m[@"id"] isKindOfClass:[NSString class]]) continue;
                    NSString *nm = [m[@"display_name"] isKindOfClass:[NSString class]] && [m[@"display_name"] length]
                                   ? m[@"display_name"] : m[@"id"];
                    NSString *life = [m[@"lifecycle"] isKindOfClass:[NSString class]] ? m[@"lifecycle"] : @"active";
                    if ([life isEqualToString:@"retired"]) continue;      // can't be called
                    [all addObject:@{ @"id": m[@"id"], @"name": nm, @"lifecycle": life }];
                }
            BOOL isDict = [json isKindOfClass:[NSDictionary class]];
            BOOL more = isDict && [json[@"has_more"] boolValue];
            NSString *last = (isDict && [json[@"last_id"] isKindOfClass:[NSString class]]) ? json[@"last_id"] : nil;
            void (^next)(NSString *, NSInteger) = weakPage;
            if (more && last.length && n < 5 && next) next(last, n + 1);
            else finish(all.count ? nil : [self _err:@"Claude returned no models for this key."]);
        }] resume];
    };
    weakPage = page;
    page(nil, 1);
    // keep the recursive block alive until the chain finishes
    static NSMutableSet *live;
    static dispatch_once_t o2;
    dispatch_once(&o2, ^{ live = [NSMutableSet set]; });
    void (^holder)(NSString *, NSInteger) = page;
    [live addObject:holder];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [live removeObject:holder]; });
}

@end
