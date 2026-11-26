// One download from start to finished file: find out what the link is, fetch the parts, put
// picture and sound into one MP4.
#import "VidGrab.h"
#include <stdatomic.h>

@implementation VGSource

- (BOOL)looksLikeHLS {
    NSString *extension = self.url.pathExtension.lowercaseString;
    return [extension isEqualToString:@"m3u8"] || [extension isEqualToString:@"m3u"];
}

- (NSString *)shortName {
    if (self.isPicture) {
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:@"picture"];
        if (self.url.host.length && !self.url.isFileURL) [parts addObject:self.url.host];
        if (self.pictureWidth > 0 && self.pictureHeight > 0) [parts addObject:[NSString stringWithFormat:@"%ld×%ld", (long)self.pictureWidth, (long)self.pictureHeight]];
        return [parts componentsJoinedByString:@" · "];
    }
    if (!self.url) return self.asset ? @"video on this iPhone" : @"video";
    if (self.url.isFileURL) return @"video on this iPhone";
    NSString *extension = self.url.pathExtension.lowercaseString;
    NSString *kind = self.looksLikeHLS ? @"stream" : (extension.length && extension.length <= 4 ? extension : @"video");
    return self.url.host.length ? [NSString stringWithFormat:@"%@ · %@", self.url.host, kind] : kind;
}

@end

#pragma mark - where a picture's original is

static NSURL *VGWithPath(NSURL *url, NSString *path, BOOL keepQuery) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    if (!parts) return nil;
    parts.percentEncodedPath = path;
    if (!keepQuery) parts.query = nil;
    return parts.URL;
}

NSArray<NSURL *> *VGPictureCandidateURLs(NSURL *url) {
    if (!url) return @[];
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return url.isFileURL ? @[url] : @[];
    NSMutableArray<NSURL *> *list = [NSMutableArray new];
    void (^add)(NSURL *) = ^(NSURL *candidate) {
        if (candidate && ![list containsObject:candidate]) [list addObject:candidate];
    };
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.percentEncodedPath ?: @"";
    NSArray<NSString *> *pieces = [path componentsSeparatedByString:@"/"];        // "", size, …

    if ([host hasSuffix:@"pinimg.com"] && pieces.count > 2 && pieces[1].length) {
        // i.pinimg.com/236x/ab/cd/ef/<hash>.jpg: the first folder is the size, "originals" the upload
        NSString *rest = [[pieces subarrayWithRange:NSMakeRange(2, pieces.count - 2)] componentsJoinedByString:@"/"];
        for (NSString *size in @[@"originals", @"1200x", @"736x"]) {
            if ([pieces[1] isEqualToString:size]) break;           // already this size: nothing larger after it
            add(VGWithPath(url, [NSString stringWithFormat:@"/%@/%@", size, rest], NO));
        }
    } else if ([host isEqualToString:@"pbs.twimg.com"] && [path hasPrefix:@"/media/"]) {
        // pbs.twimg.com/media/<id>?format=jpg&name=small, or the older /media/<id>.jpg:small
        NSString *name = path.lastPathComponent;
        NSString *format = nil;
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES].queryItems) {
            if ([item.name isEqualToString:@"format"]) format = item.value;
        }
        NSRange colon = [name rangeOfString:@":"];
        if (colon.location != NSNotFound) name = [name substringToIndex:colon.location];
        if (name.pathExtension.length) {
            format = format ?: name.pathExtension;
            name = name.stringByDeletingPathExtension;
        }
        for (NSString *size in @[@"orig", @"4096x4096", @"large"]) {
            NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
            parts.percentEncodedPath = [@"/media/" stringByAppendingString:name];
            parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"format" value:format ?: @"jpg"], [NSURLQueryItem queryItemWithName:@"name" value:size]];
            add(parts.URL);
        }
    } else if ([host isEqualToString:@"pbs.twimg.com"] && [path hasPrefix:@"/profile_images/"]) {
        // …/<name>_normal.jpg, _bigger, _200x200, _400x400: without the ending, the upload itself
        NSString *file = path.lastPathComponent;
        for (NSString *ending in @[@"_normal", @"_bigger", @"_mini", @"_200x200", @"_400x400"]) {
            NSRange found = [file rangeOfString:[ending stringByAppendingString:@"."]];
            if (found.location == NSNotFound) continue;
            NSString *plain = [file stringByReplacingCharactersInRange:NSMakeRange(found.location, ending.length) withString:@""];
            add(VGWithPath(url, [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:plain], NO));
            break;
        }
    } else if ([host isEqualToString:@"preview.redd.it"] && path.length > 1) {
        // preview.redd.it/<name>.jpg?width=640&…&s=<signature> is a scaled copy of i.redd.it/<name>.jpg
        // (newer names carry the post's title first: <title>-v0-<name>.jpeg)
        NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
        parts.host = @"i.redd.it";
        parts.query = nil;
        NSString *file = path.lastPathComponent;
        NSRange marker = [file rangeOfString:@"-v0-" options:NSBackwardsSearch];
        if (marker.location != NSNotFound) file = [file substringFromIndex:NSMaxRange(marker)];
        parts.percentEncodedPath = [@"/" stringByAppendingString:file];
        add(parts.URL);
    }
    add(url);
    return list;
}

@interface VGJob ()
- (void)note:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
@end

@implementation VGJob {
    VGSource *_source;
    VGFetcher *_fetcher;
    dispatch_queue_t _queue;
    NSMutableArray<NSString *> *_notes;
    NSString *_work;
    atomic_bool _cancelled;
    AVAssetExportSession *_export;
    // what loadVariants read, so that start does not fetch it again
    NSString *_playlistText;
    NSURL *_playlistURL;
}

- (instancetype)initWithSource:(VGSource *)source {
    if ((self = [super init])) {
        _source = source;
        _fetcher = [[VGFetcher alloc] initWithHeaders:source.headers];
        _queue = dispatch_queue_create("com.adarsh.vidgrab.job", DISPATCH_QUEUE_SERIAL);
        _notes = [NSMutableArray new];
    }
    return self;
}

- (BOOL)cancelled { return atomic_load(&_cancelled); }
- (NSString *)workFolder { return _work; }

- (NSString *)report {
    @synchronized (_notes) { return [_notes componentsJoinedByString:@"; "]; }
}

- (void)note:(NSString *)format, ... {
    va_list arguments;
    va_start(arguments, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    @synchronized (_notes) { [_notes addObject:text]; }
}

- (void)cancel {
    atomic_store(&_cancelled, true);
    [_fetcher cancel];
    [_export cancelExport];
}

- (void)cleanUp {
    NSString *work = _work;
    if (work) [NSFileManager.defaultManager removeItemAtPath:work error:NULL];
}

+ (NSString *)workRoot {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vidgrab-work"];
}

+ (void)removeStaleWorkFolders {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = [self workRoot];
    for (NSString *name in [files contentsOfDirectoryAtPath:root error:NULL] ?: @[]) {
        NSString *path = [root stringByAppendingPathComponent:name];
        NSDate *changed = [[files attributesOfItemAtPath:path error:NULL] fileModificationDate];
        if (!changed || -changed.timeIntervalSinceNow > 2 * 3600) [files removeItemAtPath:path error:NULL];
    }
}

- (void)stage:(NSString *)stage fraction:(double)fraction {
    void (^handler)(double, NSString *) = self.onProgress;
    if (handler) handler(MAX(0.0, MIN(1.0, fraction)), stage);
}

/// The link as a plain web address: apps that hand their player a made-up scheme, Reddit's DASH list.
- (NSURL *)webURL {
    NSURL *url = _source.url;
    if (!url || url.isFileURL) return url;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
        parts.scheme = [scheme hasSuffix:@"http"] ? @"http" : @"https";
        if (parts.URL) {
            [self note:@"scheme %@ read as %@", scheme, parts.scheme];
            url = parts.URL;
        }
    }
    if ([url.host.lowercaseString isEqualToString:@"v.redd.it"] && [url.pathExtension.lowercaseString isEqualToString:@"mpd"]
        && url.pathComponents.count > 1) {
        NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
        parts.path = [NSString stringWithFormat:@"/%@/HLSPlaylist.m3u8", url.pathComponents[1]];
        if (parts.URL) url = parts.URL;                     // the same video as an HLS stream; the query (its signature) stays
    }
    return url;
}

- (NSString *)textAtURL:(NSURL *)url error:(NSError **)error {
    NSData *data = [_fetcher dataAtURL:url error:error];
    if (!data) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!text || !VGTextIsPlaylist(text)) {
        if (error) *error = VGError(VGErrorPlaylist, @"The stream's list of parts could not be read.");
        return nil;
    }
    return text;
}

- (void)loadVariants:(void (^)(NSArray<VGVariant *> *, NSError *))completion {
    dispatch_async(_queue, ^{
        NSURL *url = [self webURL];
        VGSource *probe = [VGSource new];
        probe.url = url;
        if (!url || url.isFileURL || !probe.looksLikeHLS) {
            completion(@[], nil);
            return;
        }
        NSError *error = nil;
        NSString *text = [self textAtURL:url error:&error];
        if (!text) {
            completion(@[], error);
            return;
        }
        self->_playlistText = text;
        self->_playlistURL = url;
        completion(VGTextIsMaster(text) ? VGParseMaster(text, url).variants : @[], nil);
    });
}

- (void)start:(void (^)(NSURL *, NSError *))completion {
    dispatch_async(_queue, ^{
        NSError *error = nil;
        NSURL *file = nil;
        @try {
            file = [self run:&error];
        } @catch (NSException *exception) {
            error = VGError(VGErrorMedia, [NSString stringWithFormat:@"VidGrab stumbled: %@", exception.reason ?: exception.name]);
        }
        if (self.cancelled) {
            file = nil;
            error = VGError(VGErrorCancelled, @"Cancelled.");
        }
        if (!file && !error) error = VGError(VGErrorMedia, @"The video could not be saved.");
        if (!file) [self cleanUp];
        VGLog(@"job %@: %@ (%@)", file ? @"done" : @"failed", file ? file.lastPathComponent : error.localizedDescription, self.report);
        completion(file, file ? nil : error);
    });
}

- (NSString *)finalNameWithExtension:(NSString *)extension {
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = @"yyyyMMdd-HHmmss";
    return [NSString stringWithFormat:@"VidGrab-%@.%@", [format stringFromDate:NSDate.date], extension];
}

- (NSURL *)run:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    [VGJob removeStaleWorkFolders];
    _work = [[VGJob workRoot] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![files createDirectoryAtPath:_work withIntermediateDirectories:YES attributes:nil error:NULL]) {
        if (error) *error = VGError(VGErrorStorage, @"No room to work in: the temporary folder could not be made.");
        return nil;
    }
    [self stage:@"Getting ready" fraction:0.02];

    NSURL *url = [self webURL];
    if (!url) return _source.asset ? [self exportAsset:_source.asset error:error] : nil;

    if (url.isFileURL) {                                    // already on the iPhone: a status, a chat video
        NSString *extension = url.pathExtension.length ? url.pathExtension.lowercaseString : @"mp4";
        NSURL *copy = [NSURL fileURLWithPath:[_work stringByAppendingPathComponent:[self finalNameWithExtension:extension]]];
        NSError *problem = nil;
        if (![files copyItemAtURL:url toURL:copy error:&problem]) {
            if (_source.asset) return [self exportAsset:_source.asset error:error];
            if (error) *error = VGError(VGErrorStorage, @"The app's copy of the video could not be read.");
            return nil;
        }
        [self note:@"local file copied"];
        return copy;
    }

    NSString *text = nil;
    VGSource *probe = [VGSource new];
    probe.url = url;
    if (probe.looksLikeHLS) {
        text = (_playlistText && [_playlistURL isEqual:url]) ? _playlistText : [self textAtURL:url error:error];
        if (!text) return nil;
    } else {
        // a plain file, as far as the link tells: fetch it, then look at what came
        NSString *path = [_work stringByAppendingPathComponent:@"download.bin"];
        __weak VGJob *weakSelf = self;
        BOOL ok = [_fetcher downloadURLs:@[url] toPaths:@[path] ranges:nil starts:nil progress:^(double fraction, long long bytes) {
            [weakSelf stage:[NSString stringWithFormat:@"Downloading · %@", VGByteString(bytes)] fraction:0.03 + 0.9 * fraction];
        } error:error];
        if (!ok) return nil;
        VGFileKind kind = VGSniffFile(path);
        long long size = [[files attributesOfItemAtPath:path error:NULL] fileSize];
        [self note:@"direct file, %@", VGByteString(size)];
        if (kind == VGFilePlaylist) {
            text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            if (!text) {
                if (error) *error = VGError(VGErrorPlaylist, @"The stream's list of parts could not be read.");
                return nil;
            }
        } else if (kind == VGFileTS || kind == VGFileAAC) {
            NSString *named = [_work stringByAppendingPathComponent:kind == VGFileTS ? @"video.ts" : @"audio.aac"];
            [files moveItemAtPath:path toPath:named error:NULL];
            return [self muxVideo:named audio:nil seconds:0 error:error];
        } else if (kind == VGFileWebM) {
            if (error) *error = VGError(VGErrorUnsupported, @"This video is WebM, which iOS cannot keep in Photos.");
            return nil;
        } else if (kind == VGFileText) {
            BOOL dash = [url.pathExtension.lowercaseString isEqualToString:@"mpd"];
            if (error) *error = VGError(VGErrorUnsupported, dash ? @"This app plays the video as DASH, which VidGrab cannot put together yet."
                                        : @"The server sent a page instead of a video (the link may have expired).");
            return nil;
        } else {
            // MP4 family, or something with a video's name that Photos may still take
            NSString *extension = @"mp4";
            NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
            NSData *head = [handle readDataOfLength:12];
            [handle closeFile];
            if (head.length == 12 && memcmp((const char *)head.bytes + 4, "ftypqt  ", 8) == 0) extension = @"mov";
            if (kind == VGFileUnknown) {
                NSString *given = url.pathExtension.lowercaseString;
                if (![@[@"mp4", @"mov", @"m4v"] containsObject:given]) {
                    if (error) *error = VGError(VGErrorUnsupported, @"The download is not a video VidGrab can read.");
                    return nil;
                }
                extension = given;
            }
            NSURL *final = [NSURL fileURLWithPath:[_work stringByAppendingPathComponent:[self finalNameWithExtension:extension]]];
            if (![files moveItemAtPath:path toPath:final.path error:NULL]) return nil;
            return final;
        }
    }
    return [self runStream:text base:url error:error];
}

#pragma mark - HLS

- (NSURL *)runStream:(NSString *)text base:(NSURL *)base error:(NSError **)error {
    VGMedia *picture = nil, *sound = nil;
    if (VGTextIsMaster(text)) {
        VGMaster *master = VGParseMaster(text, base);
        VGVariant *variant = nil;
        for (VGVariant *v in master.variants) {             // a choice from the quality list is matched by address
            if (self.variant && [v.url isEqual:self.variant.url]) variant = v;
        }
        if (!variant) variant = VGPickVariant(master.variants, self.maxLines);
        if (!variant.url) {
            if (error) *error = VGError(VGErrorPlaylist, @"The stream lists no video.");
            return nil;
        }
        [self note:@"stream with %lu qualities, took %@", (unsigned long)master.variants.count, variant.title];
        NSString *pictureText = [self textAtURL:variant.url error:error];
        if (!pictureText) return nil;
        picture = VGParseMedia(pictureText, variant.url);
        VGRendition *rendition = VGPickAudio(master, variant);
        if (rendition.url && ![rendition.url isEqual:variant.url]) {
            NSString *soundText = [self textAtURL:rendition.url error:error];
            if (!soundText) return nil;
            sound = VGParseMedia(soundText, rendition.url);
            [self note:@"sound is a stream of its own"];
        }
    } else {
        picture = VGParseMedia(text, base);
        [self note:@"single-quality stream"];
    }

    for (VGMedia *media in sound ? @[picture, sound] : @[picture]) {
        if (media.encrypted) {
            if (error) *error = VGError(VGErrorProtected, @"This stream is protected and cannot be saved.");
            return nil;
        }
        if (!media.ended) {
            if (error) *error = VGError(VGErrorLive, @"This is a live stream; only finished videos can be saved.");
            return nil;
        }
        if (media.segments.count == 0) {
            if (error) *error = VGError(VGErrorPlaylist, @"The stream lists no parts.");
            return nil;
        }
        if (media.severalMaps) {
            if (error) *error = VGError(VGErrorUnsupported, @"This stream changes format part-way, which VidGrab cannot join.");
            return nil;
        }
        if (self.segmentLimit > 0 && media.segments.count > (NSUInteger)self.segmentLimit) {
            media.duration *= (double)self.segmentLimit / (double)media.segments.count;
            media.segments = [media.segments subarrayWithRange:NSMakeRange(0, (NSUInteger)self.segmentLimit)];
        }
    }

    // every file once, and of a file that is addressed by byte ranges only the stretch that is used
    NSMutableArray<NSURL *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSNumber *> *indexOf = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, NSNumber *> *low = [NSMutableDictionary new], *high = [NSMutableDictionary new];
    NSMutableSet<NSNumber *> *whole = [NSMutableSet new];
    void (^want)(VGPiece *) = ^(VGPiece *piece) {
        NSString *key = piece.url.absoluteString;
        NSNumber *index = indexOf[key];
        if (!index) {
            index = @(urls.count);
            indexOf[key] = index;
            [urls addObject:piece.url];
            [paths addObject:[self->_work stringByAppendingPathComponent:[NSString stringWithFormat:@"part-%05lu.bin", (unsigned long)urls.count]]];
        }
        if (piece.offset < 0) {
            [whole addObject:index];
        } else {
            long long end = piece.offset + piece.length - 1;
            if (!low[index] || piece.offset < low[index].longLongValue) low[index] = @(piece.offset);
            if (!high[index] || end > high[index].longLongValue) high[index] = @(end);
        }
    };
    for (VGMedia *media in sound ? @[picture, sound] : @[picture]) {
        if (media.map) want(media.map);
        for (VGPiece *piece in media.segments) want(piece);
    }
    NSMutableArray *ranges = [NSMutableArray new];
    for (NSUInteger i = 0; i < urls.count; i++) {
        if ([whole containsObject:@(i)] || !low[@(i)]) [ranges addObject:NSNull.null];
        else [ranges addObject:[NSString stringWithFormat:@"bytes=%lld-%lld", low[@(i)].longLongValue, high[@(i)].longLongValue]];
    }
    [self note:@"%lu picture parts%@, %lu files to fetch", (unsigned long)picture.segments.count,
     sound ? [NSString stringWithFormat:@", %lu sound parts", (unsigned long)sound.segments.count] : @"", (unsigned long)urls.count];

    NSMutableArray<NSNumber *> *starts = [NSMutableArray new];
    __weak VGJob *weakSelf = self;
    BOOL ok = [_fetcher downloadURLs:urls toPaths:paths ranges:ranges starts:starts progress:^(double fraction, long long bytes) {
        [weakSelf stage:[NSString stringWithFormat:@"Downloading · %@", VGByteString(bytes)] fraction:0.04 + 0.8 * fraction];
    } error:error];
    if (!ok) return nil;
    [self note:@"%@ fetched", VGByteString(_fetcher.bytesReceived)];

    [self stage:@"Putting it together" fraction:0.85];
    VGLog(@"job: parts fetched, joining");
    NSString *pictureFile = [self assemble:picture named:@"video" paths:paths indexOf:indexOf starts:starts error:error];
    if (!pictureFile) return nil;
    NSString *soundFile = nil;
    if (sound) {
        soundFile = [self assemble:sound named:@"audio" paths:paths indexOf:indexOf starts:starts error:error];
        if (!soundFile) return nil;
    }
    for (NSString *path in paths) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    return [self muxVideo:pictureFile audio:soundFile seconds:picture.duration error:error];
}

/// The parts of one playlist written one after the other into a single file.
- (NSString *)assemble:(VGMedia *)media
                 named:(NSString *)name
                 paths:(NSArray<NSString *> *)paths
               indexOf:(NSDictionary<NSString *, NSNumber *> *)indexOf
                starts:(NSArray<NSNumber *> *)starts
                 error:(NSError **)error {
    NSMutableArray<VGPiece *> *pieces = [NSMutableArray new];
    if (media.map) [pieces addObject:media.map];
    [pieces addObjectsFromArray:media.segments];
    NSString *firstPath = paths[indexOf[media.segments.firstObject.url.absoluteString].unsignedIntegerValue];
    VGFileKind kind = media.map ? VGFileMP4 : VGSniffFile(firstPath);
    NSString *extension = kind == VGFileTS ? @"ts" : kind == VGFileAAC ? @"aac" : @"mp4";
    NSString *path = [_work stringByAppendingPathComponent:[name stringByAppendingPathExtension:extension]];

    FILE *out = fopen(path.fileSystemRepresentation, "wb");
    if (!out) {
        if (error) *error = VGError(VGErrorStorage, @"The video file could not be created.");
        return nil;
    }
    size_t bufferSize = 512 * 1024;
    uint8_t *buffer = malloc(bufferSize);
    BOOL ok = YES;
    for (VGPiece *piece in pieces) {
        NSUInteger index = indexOf[piece.url.absoluteString].unsignedIntegerValue;
        FILE *in = fopen(paths[index].fileSystemRepresentation, "rb");
        if (!in) { ok = NO; break; }
        long long remaining = LLONG_MAX;
        if (piece.offset >= 0) {
            long long skip = piece.offset - starts[index].longLongValue;
            if (skip < 0 || fseeko(in, (off_t)skip, SEEK_SET) != 0) { fclose(in); ok = NO; break; }
            remaining = piece.length;
        }
        while (remaining > 0) {
            size_t wanted = (size_t)MIN((long long)bufferSize, remaining);
            size_t got = fread(buffer, 1, wanted, in);
            if (got == 0) break;
            if (fwrite(buffer, 1, got, out) != got) { ok = NO; break; }
            remaining -= (long long)got;
        }
        fclose(in);
        if (!ok) break;
        if (piece.offset >= 0 && remaining > 0) { ok = NO; break; }         // the server sent less than the list promised
    }
    free(buffer);
    fclose(out);
    if (!ok) {
        if (error) *error = VGError(VGErrorStorage, @"The downloaded parts could not be joined (storage full, or a part came short).");
        return nil;
    }
    if (!media.map) {
        // the list did not say what the parts are: name the joined file after what it holds
        VGFileKind real = VGSniffFile(path);
        NSString *right = real == VGFileTS ? @"ts" : real == VGFileAAC ? @"aac" : real == VGFileMP4 ? @"mp4" : nil;
        if (right && ![right isEqualToString:extension]) {
            NSString *renamed = [_work stringByAppendingPathComponent:[name stringByAppendingPathExtension:right]];
            if ([NSFileManager.defaultManager moveItemAtPath:path toPath:renamed error:NULL]) path = renamed;
        }
    }
    return path;
}

- (NSURL *)muxVideo:(NSString *)pictureFile audio:(NSString *)soundFile seconds:(double)seconds error:(NSError **)error {
    NSMutableArray<id<VGTrack>> *tracks = [NSMutableArray new];
    NSArray<id<VGTrack>> *fromPicture = VGOpenTracks(pictureFile, YES, soundFile == nil, error);
    if (!fromPicture) return nil;
    [tracks addObjectsFromArray:fromPicture];
    if (soundFile) {
        NSError *soundProblem = nil;
        NSArray<id<VGTrack>> *fromSound = VGOpenTracks(soundFile, NO, YES, &soundProblem);
        if (fromSound.count) [tracks addObjectsFromArray:fromSound];
        else [self note:@"sound left out: %@", soundProblem.localizedDescription ?: @"none found"];
    }
    BOOL hasPicture = NO, hasSound = NO;
    for (id<VGTrack> track in tracks) {
        if (track.isVideo) hasPicture = YES; else hasSound = YES;
    }
    if (!tracks.count) {
        if (error) *error = VGError(VGErrorMedia, @"No picture or sound was found in the download.");
        return nil;
    }
    [self note:@"%@%@", hasPicture ? @"picture" : @"no picture", hasSound ? @" + sound" : @", no sound"];
    VGLog(@"job: tracks open (%lu), writing", (unsigned long)tracks.count);
    [self stage:@"Finishing" fraction:0.87];
    NSURL *output = [NSURL fileURLWithPath:[_work stringByAppendingPathComponent:[self finalNameWithExtension:hasPicture ? @"mp4" : @"m4a"]]];
    __weak VGJob *weakSelf = self;
    BOOL ok = VGMuxTracks(tracks, output, seconds, ^(double fraction) {
        [weakSelf stage:@"Finishing" fraction:0.87 + 0.12 * fraction];
    }, ^BOOL{
        return weakSelf.cancelled;
    }, error);
    tracks = nil;
    if (!ok) return nil;
    [NSFileManager.defaultManager removeItemAtPath:pictureFile error:NULL];
    if (soundFile) [NSFileManager.defaultManager removeItemAtPath:soundFile error:NULL];
    return output;
}

#pragma mark - a player without a link

- (NSURL *)exportAsset:(AVAsset *)asset error:(NSError **)error {
    if (!asset || [asset tracksWithMediaType:AVMediaTypeVideo].count == 0) {
        if (error) *error = VGError(VGErrorUnsupported, @"This player gives VidGrab nothing it can save.");
        return nil;
    }
    for (NSString *preset in @[AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]) {
        if (self.cancelled) break;
        AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
        if (!session) continue;
        BOOL movie = ![session.supportedFileTypes containsObject:AVFileTypeMPEG4];
        NSURL *output = [NSURL fileURLWithPath:[_work stringByAppendingPathComponent:[self finalNameWithExtension:movie ? @"mov" : @"mp4"]]];
        [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        session.outputURL = output;
        session.outputFileType = movie ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4;
        session.shouldOptimizeForNetworkUse = YES;
        _export = session;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [session exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
        while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) != 0) {
            [self stage:@"Copying the video" fraction:0.05 + 0.9 * session.progress];
        }
        _export = nil;
        if (session.status == AVAssetExportSessionStatusCompleted) {
            [self note:@"player's own video copied (%@)", [preset isEqualToString:AVAssetExportPresetPassthrough] ? @"as it is" : @"re-encoded"];
            return output;
        }
        [self note:@"copy with %@ failed: %@", preset, session.error.localizedDescription ?: @"?"];
    }
    if (error) *error = VGError(VGErrorUnsupported, @"This player's video could not be copied.");
    return nil;
}

@end
