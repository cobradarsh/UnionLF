/*  WMAPIClient.m — ONE request per generation, returns 3 replies.
    You choose Claude or DeepSeek per reply in the sheet.
    Both get the on-device transcript (cheap, exact ME/THEM labels).
    Claude additionally gets the screenshot only if you enable it in
    Settings, or if the phone couldn't read the chat.                 */

#import "Wingman.h"

// Private session, created once. Its delegate queue is a serial queue we own,
// so no Wingman network callback ever runs on the host app's shared session
// queue (which triggered the recursive-lock SIGTRAP inside WhatsApp).
NSURLSession *WMPrivateSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.waitsForConnectivity = NO;
        NSOperationQueue *q = [[NSOperationQueue alloc] init];
        q.name = @"com.adarsh.wingman.net";
        q.maxConcurrentOperationCount = 1;   // serial: our callbacks never overlap
        session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:q];
    });
    return session;
}

@implementation WMAPIClient

+ (instancetype)shared {
    static WMAPIClient *c;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ c = [WMAPIClient new]; });
    return c;
}

- (void)generateRepliesWithProvider:(WMAPIProvider)provider
                             frames:(NSArray<UIImage *> *)frames
                         transcript:(NSString *)transcript
                            context:(NSString *)context
                               mode:(WMReplyMode)mode
                             length:(WMReplyLength)length
                         completion:(void(^)(NSArray<NSString *> *, NSError *))done {
    WMSettings *s = [WMSettings shared];
    [s reload];
    if (provider == WMAPIProviderDeepSeek)
        [self _deepseekTranscript:transcript context:context mode:mode length:length settings:s completion:done];
    else
        [self _claudeFrames:frames transcript:transcript context:context mode:mode length:length settings:s completion:done];
}

- (NSInteger)_maxTokensForMode:(WMReplyMode)mode length:(WMReplyLength)length {
    NSInteger n = (length == WMReplyLengthShort) ? 400 : 900;
    if (mode == WMReplyModeInMyFavor) n += 600;
    return n;
}

// readable errors for the common failures
- (NSError *)_httpError:(NSURLResponse *)resp json:(id)json provider:(NSString *)name {
    NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
    NSString *apiMsg = nil;
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"error"] isKindOfClass:[NSDictionary class]])
        apiMsg = json[@"error"][@"message"];
    NSString *msg;
    switch (code) {
        case 401: msg = [NSString stringWithFormat:@"%@ rejected the API key. Check it in Settings > Wingman.", name]; break;
        case 402: msg = [NSString stringWithFormat:@"%@ account has no balance left. Top up, or switch provider.", name]; break;
        case 403: msg = [NSString stringWithFormat:@"%@ refused the request (permission).", name]; break;
        case 404: msg = [NSString stringWithFormat:@"%@: model or URL not found. Check the model name / URL in Settings.", name]; break;
        case 429: msg = [NSString stringWithFormat:@"%@ rate limit hit. Wait a few seconds and tap Regenerate.", name]; break;
        case 500: case 502: case 503: case 529:
                  msg = [NSString stringWithFormat:@"%@ is overloaded right now. Try again, or switch provider.", name]; break;
        default:  msg = apiMsg ?: [NSString stringWithFormat:@"%@ returned no replies. Try again.", name];
    }
    if (apiMsg && code >= 400 && code != 401) msg = [msg stringByAppendingFormat:@"\n(%@)", apiMsg];
    return [self _err:msg];
}

// ── Claude ────────────────────────────────────────────────
- (void)_claudeFrames:(NSArray<UIImage *> *)frames
           transcript:(NSString *)transcript
              context:(NSString *)context
                 mode:(WMReplyMode)mode
               length:(WMReplyLength)length
             settings:(WMSettings *)s
           completion:(void(^)(NSArray<NSString *> *, NSError *))done {

    if (s.claudeKey.length == 0) {
        done(nil, [self _err:@"No Claude API key yet. Tap the key button on this page to paste and verify it."]);
        return;
    }

    BOOL sendImages = s.claudeSendsScreenshot || transcript.length == 0;
    NSMutableArray *content = [NSMutableArray array];
    if (sendImages) {
        for (UIImage *img in frames) {
            NSData *jpeg = UIImageJPEGRepresentation(img, 0.7);
            if (!jpeg) continue;
            [content addObject:@{ @"type": @"image",
                                  @"source": @{ @"type": @"base64", @"media_type": @"image/jpeg",
                                                @"data": [jpeg base64EncodedStringWithOptions:0] } }];
        }
    }
    BOOL hasImages = content.count > 0;
    if (!hasImages && transcript.length == 0 && context.length == 0) {
        done(nil, [self _err:@"Couldn't read the chat. Type the context and try again."]);
        return;
    }
    [content addObject:@{ @"type": @"text",
                          @"text": [WMPrompts userPromptForMode:mode length:length context:context
                                                     transcript:transcript hasImages:hasImages] }];

    NSMutableDictionary *body = [@{
        @"model":      s.claudeModel,
        @"max_tokens": @([self _maxTokensForMode:mode length:length]),
        @"system":     [WMPrompts systemPromptWithSoundLikeMe:s.soundLikeMe],
        @"messages":   @[ @{ @"role": @"user", @"content": content } ]
    } mutableCopy];
    if (mode == WMReplyModeInMyFavor)
        body[@"tools"] = @[ @{ @"type": @"web_search_20250305", @"name": @"web_search", @"max_uses": @2 } ];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.anthropic.com/v1/messages"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:s.claudeKey         forHTTPHeaderField:@"x-api-key"];
    [req setValue:@"2023-06-01"       forHTTPHeaderField:@"anthropic-version"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.timeoutInterval = 90;

    [[WMPrivateSession() dataTaskWithRequest:req
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *replies = nil; NSError *e = err;
        if (!e) {
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSMutableString *text = [NSMutableString string];
            NSArray *blocks = [json isKindOfClass:[NSDictionary class]] ? json[@"content"] : nil;
            if ([blocks isKindOfClass:[NSArray class]])
                for (NSDictionary *b in blocks)
                    if ([b isKindOfClass:[NSDictionary class]] && [b[@"type"] isEqual:@"text"] &&
                        [b[@"text"] isKindOfClass:[NSString class]]) [text appendString:b[@"text"]];
            replies = [self _parseReplies:text];
            if (replies.count == 0) e = [self _httpError:resp json:json provider:@"Claude"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(e ? nil : replies, e); });
    }] resume];
}

// ── DeepSeek (OpenAI-compatible, text only) ───────────────
- (void)_deepseekTranscript:(NSString *)transcript
                    context:(NSString *)context
                       mode:(WMReplyMode)mode
                     length:(WMReplyLength)length
                   settings:(WMSettings *)s
                 completion:(void(^)(NSArray<NSString *> *, NSError *))done {

    if (s.deepseekKey.length == 0) {
        done(nil, [self _err:@"No DeepSeek API key yet. Tap the key button on this page to paste and verify it."]);
        return;
    }
    if (transcript.length == 0 && context.length == 0) {
        done(nil, [self _err:@"Couldn't read the chat on this screen. Type the context, or switch to Claude (it can read the screenshot)."]);
        return;
    }

    NSMutableDictionary *body = [@{
        @"model":      s.deepseekModel,
        @"max_tokens": @([self _maxTokensForMode:mode length:length]),
        @"messages": @[
            @{ @"role": @"system", @"content": [WMPrompts systemPromptWithSoundLikeMe:s.soundLikeMe] },
            @{ @"role": @"user",   @"content": [WMPrompts userPromptForMode:mode length:length context:context
                                                                transcript:transcript hasImages:NO] }
        ]
    } mutableCopy];
    // JSON mode on chat models; reasoning models don't accept it
    if (![s.deepseekModel.lowercaseString containsString:@"reasoner"])
        body[@"response_format"] = @{ @"type": @"json_object" };

    NSURL *url = [NSURL URLWithString:s.deepseekEndpoint];
    if (!url) { done(nil, [self _err:@"DeepSeek URL in Settings looks invalid."]); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:s.deepseekKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.timeoutInterval = 90;

    [[WMPrivateSession() dataTaskWithRequest:req
      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *replies = nil; NSError *e = err;
        if (!e) {
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *text = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSArray *ch = json[@"choices"];
                if ([ch isKindOfClass:[NSArray class]] && ch.count &&
                    [ch[0] isKindOfClass:[NSDictionary class]]) {
                    id c = ch[0][@"message"][@"content"];
                    if ([c isKindOfClass:[NSString class]]) text = c;
                }
            }
            replies = [self _parseReplies:text ?: @""];
            if (replies.count == 0) e = [self _httpError:resp json:json provider:@"DeepSeek"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(e ? nil : replies, e); });
    }] resume];
}

// ── parsing ───────────────────────────────────────────────
// Accepts {"replies":[...]}, a bare [...], or numbered lines as a fallback.
- (NSArray<NSString *> *)_parseReplies:(NSString *)raw {
    if (raw.length == 0) return @[];
    NSMutableArray *out = [NSMutableArray array];

    id obj = nil;
    NSRange a = [raw rangeOfString:@"{"], b = [raw rangeOfString:@"}" options:NSBackwardsSearch];
    if (a.location != NSNotFound && b.location != NSNotFound && b.location > a.location) {
        NSString *js = [raw substringWithRange:NSMakeRange(a.location, b.location - a.location + 1)];
        obj = [NSJSONSerialization JSONObjectWithData:[js dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) obj = obj[@"replies"];
    }
    if (![obj isKindOfClass:[NSArray class]]) {
        a = [raw rangeOfString:@"["]; b = [raw rangeOfString:@"]" options:NSBackwardsSearch];
        if (a.location != NSNotFound && b.location != NSNotFound && b.location > a.location) {
            NSString *js = [raw substringWithRange:NSMakeRange(a.location, b.location - a.location + 1)];
            obj = [NSJSONSerialization JSONObjectWithData:[js dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id r in obj) if ([r isKindOfClass:[NSString class]]) [out addObject:r];
    } else {
        NSCharacterSet *junk = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.)-*\"' \t"];
        for (NSString *line in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *t = [line stringByTrimmingCharactersInSet:junk];
            if (t.length > 1) [out addObject:t];
        }
    }

    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *r in out) {
        NSString *t = [self _humanize:r];
        if (t.length) [clean addObject:t];
        if (clean.count == kWMRepliesPerCall) break;
    }
    return clean;
}

// hard guarantee: no em/en dashes, no wrapping quotes
- (NSString *)_humanize:(NSString *)s {
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    t = [t stringByReplacingOccurrencesOfString:@" — " withString:@", "];
    t = [t stringByReplacingOccurrencesOfString:@"—" withString:@", "];
    t = [t stringByReplacingOccurrencesOfString:@" – " withString:@", "];
    t = [t stringByReplacingOccurrencesOfString:@"–" withString:@"-"];
    if (t.length >= 2 && [t hasPrefix:@"\""] && [t hasSuffix:@"\""])
        t = [t substringWithRange:NSMakeRange(1, t.length - 2)];
    return t;
}

- (NSError *)_err:(NSString *)msg {
    return [NSError errorWithDomain:@"Wingman" code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end
