/*  WMOCR.m — reads Wingman's captures on the phone (Apple Vision) and turns
    them into a short "THEM: / ME:" transcript. Sending text instead of the
    image is far cheaper and makes who-said-what exact.

    RULESET (applied to every line, always):
      - right-side bubbles = ME, left-side bubbles = THEM
      - WhatsApp/Signal/Instagram encryption + system notices are dropped
      - timestamps, ticks, date separators, header and input bar dropped */

#import "Wingman.h"
#import <Vision/Vision.h>

typedef NS_ENUM(NSInteger, WMSpeaker) { WMSpeakerThem, WMSpeakerMe, WMSpeakerNotice };

@implementation WMOCR

#pragma mark - ignore ruleset

+ (BOOL)isSystemNotice:(NSString *)line {
    NSString *l = [[line lowercaseString] stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (l.length == 0) return YES;

    static NSArray *phrases;
    static NSRegularExpression *dateRx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        phrases = @[
            // end-to-end encryption banners / placeholders
            @"end-to-end encrypted", @"end to end encrypted", @"end-to-end encryption",
            @"end-to-end-encrypted", @"messages and calls are", @"no one outside of this chat",
            @"not even whatsapp", @"can read or listen to them", @"tap to learn more",
            @"waiting for this message", @"this may take a while", @"check your phone",
            @"secured with end", @"encrypted messages",
            @"are now end-to-end", @"only people in this chat", @"listen to, or share",
            @"or share them", @"can read, listen", @"learn more.",
            // security / key changes
            @"security code", @"your security code with", @"tap to verify",
            // deleted / disappearing / timer
            @"this message was deleted", @"you deleted this message", @"message was deleted",
            @"disappearing messages", @"turned on disappearing", @"turned off disappearing",
            @"message timer", @"view once",
            // business / meta notices
            @"uses a secure service from meta", @"this chat is with a business",
            @"this business uses", @"official business account",
            // misc system rows
            @"unread message", @"pinned a message", @"you blocked this contact",
            @"you unblocked this contact", @"changed their phone number",
            @"joined using this group", @"created group", @"tap to view",
        ];
        NSString *mon = @"(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)";
        NSString *pat = [NSString stringWithFormat:
            @"^(today|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday"
             "|(mon|tue|wed|thu|fri|sat|sun)[a-z]*,? \\d{1,2} %1$@( \\d{4})?"
             "|\\d{1,2} %1$@( \\d{4})?|%1$@ \\d{1,2},?( \\d{4})?"
             "|\\d{1,2}/\\d{1,2}/\\d{2,4}"
             "|\\d{1,2}:\\d{2}( ?(am|pm))?)$", mon];
        dateRx = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    });
    for (NSString *p in phrases) if ([l containsString:p]) return YES;
    if ([dateRx firstMatchInString:l options:0 range:NSMakeRange(0, l.length)]) return YES;
    // lone lock / tick / dot glyphs
    if (l.length <= 2 && ![l rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]].length) return YES;
    return NO;
}

+ (NSString *)_clean:(NSString *)s {
    static NSRegularExpression *trailTime, *media;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trailTime = [NSRegularExpression regularExpressionWithPattern:
            @"\\s*(edited\\s*)?\\d{1,2}:\\d{2}\\s*(am|pm)?\\s*[\\u2713\\u2714vV/]*\\s*$"
                                                              options:NSRegularExpressionCaseInsensitive error:nil];
        media = [NSRegularExpression regularExpressionWithPattern:
            @"\\(\\s*\\d+(\\.\\d+)?\\s*(kb|mb|gb)\\s*\\)"
                                                          options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSString *t = [trailTime stringByReplacingMatchesInString:s options:0
                                                        range:NSMakeRange(0, s.length) withTemplate:@""];
    if ([media firstMatchInString:t options:0 range:NSMakeRange(0, t.length)]) return @"[photo/video]";
    return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - per frame

typedef struct { CGFloat minX, maxX, top, bottom; } WMBox;

+ (NSArray<NSDictionary *> *)_messagesInImage:(UIImage *)img {
    CGImageRef cg = img.CGImage;
    if (!cg) return @[];

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;            // keep Hinglish as typed
    req.recognitionLanguages = @[@"en-US"];
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    if (![h performRequests:@[req] error:nil]) return @[];

    // collect lines (Vision boxes are normalized, origin bottom-left)
    NSMutableArray *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *o in req.results) {
        NSString *txt = [o topCandidates:1].firstObject.string;
        if (txt.length == 0) continue;
        CGRect b = o.boundingBox;
        CGFloat top = 1.0 - CGRectGetMaxY(b), bottom = 1.0 - CGRectGetMinY(b);
        if (top < 0.115 || bottom > 0.915) continue;   // header / pinned bar / input bar
        [lines addObject:@{ @"t": txt,
                            @"minX": @(CGRectGetMinX(b)), @"maxX": @(CGRectGetMaxX(b)),
                            @"top": @(top), @"bottom": @(bottom) }];
    }
    [lines sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"top"] compare:b[@"top"]];
    }];

    // ── pass 1: classify every line ───────────────────────
    // A system banner is centred with equal margins both sides; chat bubbles
    // are anchored to one side, so even long messages are lopsided.
    NSInteger n = lines.count;
    NSMutableArray<NSNumber *> *who = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:n];
    BOOL symmetric[n > 0 ? n : 1];
    for (NSInteger i = 0; i < n; i++) {
        NSDictionary *ln = lines[i];
        NSString *raw = ln[@"t"];
        NSString *t = [self _clean:raw];
        [texts addObject:t];
        CGFloat minX = [ln[@"minX"] doubleValue], maxX = [ln[@"maxX"] doubleValue];
        CGFloat c = (minX + maxX) / 2;
        symmetric[i] = fabs(minX - (1.0 - maxX)) < 0.07 && minX > 0.06;
        NSString *lc = raw.lowercaseString;

        WMSpeaker w;
        if ([self isSystemNotice:raw] || t.length == 0 || [self isSystemNotice:t])
            w = WMSpeakerNotice;
        else if (symmetric[i] && ([lc containsString:@"encrypt"] || [lc containsString:@"learn more"]))
            w = WMSpeakerNotice;                                   // banner, any wording
        else if (fabs(c - 0.5) < 0.07 && maxX < 0.8)
            w = WMSpeakerNotice;                                   // centred row (dates)
        else if (minX < 0.15)
            w = WMSpeakerThem;                                     // left bubble
        else
            w = WMSpeakerMe;                                       // right bubble
        [who addObject:@(w)];
    }

    // ── pass 2: a banner is one block, drop all of it ─────
    // Any centred line touching a notice line (above or below) is part of the
    // same banner, e.g. "encrypted. Only people in this chat can read, listen"
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSInteger i = 0; i < n; i++) {
            if ([who[i] integerValue] == WMSpeakerNotice || !symmetric[i]) continue;
            CGFloat top = [lines[i][@"top"] doubleValue], bot = [lines[i][@"bottom"] doubleValue];
            for (NSInteger j = MAX(0, i - 1); j <= MIN(n - 1, i + 1); j++) {
                if (j == i || [who[j] integerValue] != WMSpeakerNotice) continue;
                CGFloat jt = [lines[j][@"top"] doubleValue], jb = [lines[j][@"bottom"] doubleValue];
                CGFloat gap = (j < i) ? top - jb : jt - bot;
                if (gap < 0.012) { who[i] = @(WMSpeakerNotice); changed = YES; break; }
            }
        }
    }

    // ── pass 3: merge wrapped lines into bubbles ──────────
    NSMutableArray *msgs = [NSMutableArray array];
    NSMutableDictionary *cur = nil;
    for (NSInteger i = 0; i < n; i++) {
        WMSpeaker w = (WMSpeaker)[who[i] integerValue];
        if (w == WMSpeakerNotice) { cur = nil; continue; }
        NSDictionary *ln = lines[i];
        CGFloat top = [ln[@"top"] doubleValue];
        BOOL sameBubble = cur && [cur[@"who"] integerValue] == w &&
                          top - [cur[@"bottom"] doubleValue] < 0.011;
        if (sameBubble) {
            cur[@"t"] = [cur[@"t"] stringByAppendingFormat:@" %@", texts[i]];
            cur[@"bottom"] = ln[@"bottom"];
        } else {
            cur = [@{ @"who": @(w), @"t": texts[i], @"bottom": ln[@"bottom"] } mutableCopy];
            [msgs addObject:cur];
        }
    }
    return msgs;
}

#pragma mark - public

+ (void)transcriptFromFrames:(NSArray<UIImage *> *)frames
                  completion:(void(^)(NSString *, NSInteger))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *out = [NSMutableArray array];
        for (UIImage *f in frames) {                       // oldest first
            for (NSDictionary *m in [self _messagesInImage:f]) {
                NSString *line = [NSString stringWithFormat:@"%@: %@",
                                  [m[@"who"] integerValue] == WMSpeakerMe ? @"ME" : @"THEM", m[@"t"]];
                // frames overlap a little when scrolling: skip recent duplicates
                NSRange recent = NSMakeRange(MAX(0, (NSInteger)out.count - 8),
                                             MIN((NSInteger)out.count, 8));
                if ([[out subarrayWithRange:recent] containsObject:line]) continue;
                [out addObject:line];
            }
        }
        // keep the latest 40 messages to bound cost
        NSArray *tail = out.count > 40 ? [out subarrayWithRange:NSMakeRange(out.count - 40, 40)] : out;
        NSString *t = tail.count ? [tail componentsJoinedByString:@"\n"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(t, tail.count); });
    });
}

@end
