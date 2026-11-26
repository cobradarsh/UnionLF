// HLS playlists: what a master offers, what a media playlist is made of.
#import "VidGrab.h"

@implementation VGVariant

- (NSInteger)lines {
    if (self.width > 0 && self.height > 0) return MIN(self.width, self.height);
    return MAX(self.width, self.height);
}

- (BOOL)decodable {
    NSString *c = self.codecs.lowercaseString;
    if (!c.length) return YES;
    return !([c containsString:@"av01"] || [c containsString:@"vp09"] || [c containsString:@"vp9"] || [c containsString:@"vp8"]);
}

- (BOOL)playableEverywhere {
    NSString *c = self.codecs.lowercaseString;
    if (!c.length) return YES;
    return [c containsString:@"avc1"] || [c containsString:@"avc3"];
}

- (NSString *)codecName {
    NSString *c = self.codecs.lowercaseString ?: @"";
    if ([c containsString:@"avc"]) return @"H.264";
    if ([c containsString:@"hvc1"] || [c containsString:@"hev1"]) return @"HEVC";
    if ([c containsString:@"dvh"]) return @"Dolby Vision";
    if ([c containsString:@"av01"]) return @"AV1";
    if ([c containsString:@"vp09"] || [c containsString:@"vp9"]) return @"VP9";
    if ([c hasPrefix:@"mp4a"]) return @"audio only";
    return nil;
}

- (NSString *)title {
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if (self.lines > 0) [parts addObject:[NSString stringWithFormat:@"%ldp", (long)self.lines]];
    NSString *codec = [self codecName];
    if (codec) [parts addObject:codec];
    if (self.bandwidth > 0) {
        double mbps = self.bandwidth / 1000000.0;
        [parts addObject:mbps >= 1 ? [NSString stringWithFormat:@"%.1f Mbps", mbps]
                                   : [NSString stringWithFormat:@"%.0f kbps", self.bandwidth / 1000.0]];
    }
    return parts.count ? [parts componentsJoinedByString:@" · "] : @"Standard";
}

@end

@implementation VGRendition
@end

@implementation VGMaster
@end

@implementation VGPiece
@end

@implementation VGMedia
@end

BOOL VGTextIsPlaylist(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [trimmed hasPrefix:@"#EXTM3U"];
}

BOOL VGTextIsMaster(NSString *text) {
    return [text containsString:@"#EXT-X-STREAM-INF"];
}

// KEY=value,KEY="quoted, with commas",… → dictionary (quotes removed).
NSDictionary<NSString *, NSString *> *VGParseAttributes(NSString *list) {
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary new];
    NSUInteger n = list.length, i = 0;
    while (i < n) {
        while (i < n && ([list characterAtIndex:i] == ',' || [list characterAtIndex:i] == ' ')) i++;
        NSUInteger keyStart = i;
        while (i < n && [list characterAtIndex:i] != '=' && [list characterAtIndex:i] != ',') i++;
        if (i >= n || [list characterAtIndex:i] != '=') continue;      // a word without a value
        NSString *key = [[list substringWithRange:NSMakeRange(keyStart, i - keyStart)]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        i++;
        NSString *value;
        if (i < n && [list characterAtIndex:i] == '"') {
            NSUInteger start = ++i;
            while (i < n && [list characterAtIndex:i] != '"') i++;
            value = [list substringWithRange:NSMakeRange(start, i - start)];
            if (i < n) i++;
        } else {
            NSUInteger start = i;
            while (i < n && [list characterAtIndex:i] != ',') i++;
            value = [[list substringWithRange:NSMakeRange(start, i - start)]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        if (key.length) out[key.uppercaseString] = value;
    }
    return out;
}

static NSArray<NSString *> *VGLines(NSString *text) {
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length) [lines addObject:line];
    }
    return lines;
}

static NSString *VGAfterColon(NSString *line) {
    NSRange colon = [line rangeOfString:@":"];
    return colon.location == NSNotFound ? @"" : [line substringFromIndex:colon.location + 1];
}

static NSURL *VGResolve(NSString *reference, NSURL *base) {
    NSURL *url = [NSURL URLWithString:reference relativeToURL:base];
    if (!url) {
        NSString *escaped = [reference stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
        url = escaped ? [NSURL URLWithString:escaped relativeToURL:base] : nil;
    }
    return url.absoluteURL;
}

VGMaster *VGParseMaster(NSString *text, NSURL *base) {
    NSMutableArray<VGVariant *> *variants = [NSMutableArray new];
    NSMutableArray<VGRendition *> *audio = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    VGVariant *pending = nil;
    for (NSString *line in VGLines(text)) {
        if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            NSDictionary<NSString *, NSString *> *a = VGParseAttributes(VGAfterColon(line));
            pending = [VGVariant new];
            pending.bandwidth = [a[@"AVERAGE-BANDWIDTH"] ?: a[@"BANDWIDTH"] longLongValue];
            NSArray<NSString *> *size = [[a[@"RESOLUTION"] lowercaseString] componentsSeparatedByString:@"x"];
            if (size.count == 2) {
                pending.width = size[0].integerValue;
                pending.height = size[1].integerValue;
            }
            pending.codecs = a[@"CODECS"];
            pending.audioGroup = a[@"AUDIO"];
        } else if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
            NSDictionary<NSString *, NSString *> *a = VGParseAttributes(VGAfterColon(line));
            if (![[a[@"TYPE"] uppercaseString] isEqualToString:@"AUDIO"] || !a[@"GROUP-ID"]) continue;
            VGRendition *r = [VGRendition new];
            r.groupID = a[@"GROUP-ID"];
            r.name = a[@"NAME"];
            r.isDefault = [[a[@"DEFAULT"] uppercaseString] isEqualToString:@"YES"];
            r.url = a[@"URI"].length ? VGResolve(a[@"URI"], base) : nil;
            [audio addObject:r];
        } else if (pending && ![line hasPrefix:@"#"]) {
            pending.url = VGResolve(line, base);
            if (pending.url && ![seen containsObject:pending.url.absoluteString]) {
                [seen addObject:pending.url.absoluteString];
                [variants addObject:pending];
            }
            pending = nil;
        }
    }
    [variants sortUsingComparator:^NSComparisonResult(VGVariant *a, VGVariant *b) {
        if (a.lines != b.lines) return a.lines > b.lines ? NSOrderedAscending : NSOrderedDescending;
        if (a.playableEverywhere != b.playableEverywhere) return a.playableEverywhere ? NSOrderedAscending : NSOrderedDescending;
        if (a.bandwidth != b.bandwidth) return a.bandwidth > b.bandwidth ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    VGMaster *master = [VGMaster new];
    master.variants = variants;
    master.audio = audio;
    return master;
}

// "n" or "n@o": length and, when given, where it starts.
static void VGParseRange(NSString *text, long long *length, long long *offset) {
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"@"];
    *length = parts.count ? [parts[0] longLongValue] : 0;
    *offset = parts.count > 1 ? [parts[1] longLongValue] : -1;
}

VGMedia *VGParseMedia(NSString *text, NSURL *base) {
    VGMedia *media = [VGMedia new];
    NSMutableArray<VGPiece *> *segments = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSNumber *> *nextOffset = [NSMutableDictionary new];   // per file, for ranges without "@"
    long long rangeLength = -1, rangeOffset = -1;
    NSString *firstMap = nil;
    double total = 0;
    for (NSString *line in VGLines(text)) {
        if ([line hasPrefix:@"#EXTINF:"]) {
            total += VGAfterColon(line).doubleValue;
        } else if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            VGParseRange(VGAfterColon(line), &rangeLength, &rangeOffset);
        } else if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            NSDictionary<NSString *, NSString *> *a = VGParseAttributes(VGAfterColon(line));
            NSString *uri = a[@"URI"];
            if (!uri.length) continue;
            NSString *identity = [NSString stringWithFormat:@"%@|%@", uri, a[@"BYTERANGE"] ?: @""];
            if (firstMap && ![firstMap isEqualToString:identity]) { media.severalMaps = YES; continue; }
            if (firstMap) continue;
            firstMap = identity;
            VGPiece *map = [VGPiece new];
            map.url = VGResolve(uri, base);
            map.offset = -1;
            if (a[@"BYTERANGE"]) {
                long long length = 0, offset = -1;
                VGParseRange(a[@"BYTERANGE"], &length, &offset);
                map.length = length;
                map.offset = offset < 0 ? 0 : offset;
            }
            if (map.url) media.map = map;
        } else if ([line hasPrefix:@"#EXT-X-KEY:"]) {
            NSString *method = [VGParseAttributes(VGAfterColon(line))[@"METHOD"] uppercaseString];
            if (method.length && ![method isEqualToString:@"NONE"]) media.encrypted = YES;
        } else if ([line hasPrefix:@"#EXT-X-ENDLIST"]) {
            media.ended = YES;
        } else if ([line hasPrefix:@"#EXT-X-PLAYLIST-TYPE:"]) {
            if ([[VGAfterColon(line) uppercaseString] isEqualToString:@"VOD"]) media.ended = YES;
        } else if (![line hasPrefix:@"#"]) {
            VGPiece *piece = [VGPiece new];
            piece.url = VGResolve(line, base);
            piece.offset = -1;
            if (piece.url && rangeLength >= 0) {
                NSString *key = piece.url.absoluteString;
                long long start = rangeOffset >= 0 ? rangeOffset : nextOffset[key].longLongValue;
                piece.offset = start;
                piece.length = rangeLength;
                nextOffset[key] = @(start + rangeLength);
            }
            rangeLength = rangeOffset = -1;
            if (piece.url) [segments addObject:piece];
        }
    }
    media.segments = segments;
    media.duration = total;
    return media;
}

VGVariant *VGPickVariant(NSArray<VGVariant *> *variants, NSInteger maxLines) {
    if (!variants.count) return nil;
    // what this iPhone can decode and Photos can keep; if nothing is, take what there is
    NSArray<VGVariant *> *usable = [variants filteredArrayUsingPredicate:
                                    [NSPredicate predicateWithBlock:^BOOL(VGVariant *v, id bindings) { return v.decodable; }]];
    if (!usable.count) usable = variants;
    // audio-only variants are a last resort
    NSArray<VGVariant *> *pictures = [usable filteredArrayUsingPredicate:
                                      [NSPredicate predicateWithBlock:^BOOL(VGVariant *v, id bindings) {
        return !(v.codecs.length && [v.codecs.lowercaseString hasPrefix:@"mp4a"] && ![v.codecs containsString:@","] && v.lines == 0);
    }]];
    if (pictures.count) usable = pictures;
    if (maxLines <= 0) return usable.firstObject;                       // sorted best first
    for (VGVariant *v in usable) {
        if (v.lines > 0 && v.lines <= maxLines) return v;               // the best one under the limit
    }
    // nothing small enough (or no sizes given): the smallest by size, then by bit rate
    VGVariant *smallest = usable.lastObject;
    for (VGVariant *v in usable) {
        if (v.lines == 0 && smallest.lines == 0 && v.bandwidth > 0 && v.bandwidth < smallest.bandwidth) smallest = v;
    }
    return smallest;
}

VGRendition *VGPickAudio(VGMaster *master, VGVariant *variant) {
    if (!variant.audioGroup.length) return nil;
    VGRendition *first = nil;
    for (VGRendition *r in master.audio) {
        if (![r.groupID isEqualToString:variant.audioGroup]) continue;
        if (r.isDefault) return r;
        if (!first) first = r;
    }
    return first;
}
