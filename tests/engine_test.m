// Runs VidGrab's download engine outside any app: the playlist reader on fixed texts, then whole
// downloads of public test streams, each read back and decoded to prove the saved file plays.
//
//   engine_test <output folder> [only <name>]
//
// Built for the Mac and for the iOS simulator by tools/engine_test.sh. A stream that cannot be
// reached counts as SKIP, not as a failure of the code.
#import "../VidGrab.h"
#import <CoreVideo/CoreVideo.h>

static int gPassed, gFailed, gSkipped;

static void Check(BOOL ok, NSString *what) {
    if (ok) gPassed++; else gFailed++;
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    fflush(stdout);
}

#pragma mark - playlists

static void PlaylistTests(void) {
    printf("== playlists\n");
    NSDictionary *a = VGParseAttributes(@"BANDWIDTH=2177116,CODECS=\"avc1.640020,mp4a.40.2\",RESOLUTION=960x540,AUDIO=\"aud1\", NAME=\"a, b\"");
    Check([a[@"CODECS"] isEqualToString:@"avc1.640020,mp4a.40.2"] && [a[@"RESOLUTION"] isEqualToString:@"960x540"]
          && [a[@"AUDIO"] isEqualToString:@"aud1"] && [a[@"NAME"] isEqualToString:@"a, b"] && [a[@"BANDWIDTH"] isEqualToString:@"2177116"],
          @"attribute list with quoted commas");

    NSURL *base = [NSURL URLWithString:@"https://video.example.com/ext/123/pl/master.m3u8?tag=12"];
    NSString *masterText =
        @"#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        @"#EXT-X-MEDIA:NAME=\"Audio\",TYPE=AUDIO,GROUP-ID=\"audio-64000\",AUTOSELECT=YES,URI=\"/ext/123/pl/mp4a/64000/a.m3u8\"\n"
        @"#EXT-X-MEDIA:NAME=\"Audio\",TYPE=AUDIO,GROUP-ID=\"audio-128000\",AUTOSELECT=YES,DEFAULT=YES,URI=\"/ext/123/pl/mp4a/128000/b.m3u8\"\n"
        @"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\",URI=\"subs.m3u8\"\n"
        @"#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=288000,BANDWIDTH=421000,RESOLUTION=320x568,CODECS=\"mp4a.40.2,avc1.4d0015\",AUDIO=\"audio-64000\"\n"
        @"/ext/123/pl/avc1/320x568/low.m3u8\n"
        @"#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2176000,BANDWIDTH=2900000,RESOLUTION=720x1280,CODECS=\"mp4a.40.2,avc1.640020\",AUDIO=\"audio-128000\"\n"
        @"/ext/123/pl/avc1/720x1280/high.m3u8\n"
        @"#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1500000,BANDWIDTH=1900000,RESOLUTION=720x1280,CODECS=\"mp4a.40.2,hvc1.1.6.L93.90\",AUDIO=\"audio-128000\"\n"
        @"/ext/123/pl/hvc1/720x1280/hevc.m3u8\n"
        @"#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=3000000,BANDWIDTH=3500000,RESOLUTION=1080x1920,CODECS=\"mp4a.40.2,av01.0.08M.08\",AUDIO=\"audio-128000\"\n"
        @"/ext/123/pl/av01/1080x1920/av1.m3u8\n"
        @"#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=832000,BANDWIDTH=1100000,RESOLUTION=480x852,CODECS=\"mp4a.40.2,avc1.4d001f\",AUDIO=\"audio-64000\"\n"
        @"/ext/123/pl/avc1/480x852/mid.m3u8\n"
        @"#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,URI=\"iframes.m3u8\"\n";
    Check(VGTextIsPlaylist(masterText) && VGTextIsMaster(masterText), @"a master playlist is told from a media playlist");
    VGMaster *master = VGParseMaster(masterText, base);
    Check(master.variants.count == 5 && master.audio.count == 2, @"master: five qualities, two sound renditions (subtitles left out)");
    VGVariant *best = VGPickVariant(master.variants, 0);
    Check([best.url.absoluteString isEqualToString:@"https://video.example.com/ext/123/pl/avc1/720x1280/high.m3u8"] && best.lines == 720,
          [NSString stringWithFormat:@"best quality skips AV1 and prefers H.264 over HEVC at the same size (got %@)", best.title]);
    VGVariant *capped = VGPickVariant(master.variants, 480);
    Check(capped.lines == 480, [NSString stringWithFormat:@"a 480p limit picks the 480p quality (got %@)", capped.title]);
    VGVariant *tiny = VGPickVariant(master.variants, 144);
    Check(tiny.lines == 320, [NSString stringWithFormat:@"a limit below everything picks the smallest (got %@)", tiny.title]);
    VGRendition *sound = VGPickAudio(master, best);
    Check([sound.url.absoluteString isEqualToString:@"https://video.example.com/ext/123/pl/mp4a/128000/b.m3u8"], @"the sound rendition of the picked quality's group");

    NSString *mediaText =
        @"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        @"#EXT-X-MAP:URI=\"main.mp4\",BYTERANGE=\"719@0\"\n"
        @"#EXTINF:6.00000,\t\n#EXT-X-BYTERANGE:1508000@719\nmain.mp4\n"
        @"#EXTINF:6.00000,\t\n#EXT-X-BYTERANGE:1510244\nmain.mp4\n"
        @"#EXTINF:4.5,\n#EXT-X-BYTERANGE:100@5000000\nmain.mp4\n#EXT-X-ENDLIST\n";
    VGMedia *media = VGParseMedia(mediaText, base);
    Check(media.ended && !media.encrypted && media.segments.count == 3 && media.map.offset == 0 && media.map.length == 719
          && media.segments[0].offset == 719 && media.segments[1].offset == 1508719 && media.segments[1].length == 1510244
          && media.segments[2].offset == 5000000 && fabs(media.duration - 16.5) < 0.01,
          @"media playlist: byte ranges, also the ones that continue where the last ended");

    VGMedia *locked = VGParseMedia(@"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n", base);
    VGMedia *open = VGParseMedia(@"#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\na.ts\n#EXTINF:4,\nhttps://other.example.com/b.ts?x=1\n", base);
    Check(locked.encrypted && !open.encrypted && !open.ended && open.segments.count == 2
          && [open.segments[0].url.absoluteString isEqualToString:@"https://video.example.com/ext/123/pl/a.ts"]
          && [open.segments[1].url.host isEqualToString:@"other.example.com"],
          @"media playlist: protected and live streams are recognised, addresses resolved");
}

#pragma mark - downloads

/// Decodes the start of the file: the proof that a player can show and play it.
static NSDictionary *DecodeCheck(NSURL *file) {
    NSMutableDictionary *out = [NSMutableDictionary new];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (video) {
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:NULL];
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:video outputSettings:
                                            @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [reader addOutput:output];
        NSInteger frames = 0;
        double last = -1;
        BOOL ordered = YES;
        if ([reader startReading]) {
            CMSampleBufferRef sample;
            while (frames < 400 && (sample = [output copyNextSampleBuffer])) {
                if (CMSampleBufferGetImageBuffer(sample)) {
                    double t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                    if (t < last) ordered = NO;
                    last = t;
                    frames++;
                }
                CFRelease(sample);
            }
        }
        out[@"frames"] = @(frames);
        out[@"lastFrameAt"] = @(last);
        out[@"ordered"] = @(ordered);
        if (reader.status == AVAssetReaderStatusFailed) out[@"videoError"] = reader.error.localizedDescription ?: @"failed";
        [reader cancelReading];
    }
    if (audio) {
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:NULL];
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:audio outputSettings:
                                            @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @16,
                                              AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO}];
        [reader addOutput:output];
        long long samples = 0, loud = 0;
        if ([reader startReading]) {
            CMSampleBufferRef sample;
            while ((sample = [output copyNextSampleBuffer])) {
                samples += CMSampleBufferGetNumSamples(sample);
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
                size_t length = 0;
                char *bytes = NULL;
                if (block && CMBlockBufferGetDataPointer(block, 0, NULL, &length, &bytes) == noErr) {
                    const int16_t *pcm = (const int16_t *)bytes;
                    for (size_t i = 0; i < length / 2; i += 16) if (pcm[i] > 200 || pcm[i] < -200) loud++;
                }
                CFRelease(sample);
            }
        }
        out[@"pcm"] = @(samples);
        out[@"loud"] = @(loud);
        if (reader.status == AVAssetReaderStatusFailed) out[@"audioError"] = reader.error.localizedDescription ?: @"failed";
    }
    return out;
}

static void StreamTest(NSString *name, NSString *address, NSInteger maxLines, NSInteger limit, BOOL wantSound,
                       double minSeconds, double maxSeconds, NSString *folder) {
    printf("== %s\n   %s\n", name.UTF8String, address.UTF8String);
    VGSource *source = [VGSource new];
    source.url = [NSURL URLWithString:address];
    VGJob *job = [[VGJob alloc] initWithSource:source];
    job.maxLines = maxLines;
    job.segmentLimit = limit;
    __block NSString *lastStage = nil;
    __block double lastFraction = -1;
    __block BOOL backwards = NO;
    __block NSString *lastWord = nil;
    job.onProgress = ^(double fraction, NSString *stage) {
        if (fraction + 0.001 < lastFraction) backwards = YES;
        lastFraction = fraction;
        lastStage = stage;
        NSString *word = [stage componentsSeparatedByString:@" "].firstObject;
        if (![word isEqualToString:lastWord]) {
            lastWord = word;
            printf("   … %s (%.2f)
", stage.UTF8String, fraction);
        }
    };
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSURL *result = nil;
    __block NSError *problem = nil;
    NSDate *began = NSDate.date;
    [job start:^(NSURL *file, NSError *error) {
        result = file;
        problem = error;
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_SEC)) != 0) {
        printf("   stalled at \"%s\" (%.2f); so far: %s
", lastStage.UTF8String, lastFraction, job.report.UTF8String);
        [job cancel];
        Check(NO, [name stringByAppendingString:@": finished within 100 seconds"]);
        return;
    }
    printf("   %.1f s; %s\n", -began.timeIntervalSinceNow, job.report.UTF8String);
    if (!result) {
        if (problem.code == VGErrorNetwork) {
            gSkipped++;
            printf("SKIP  %s: %s\n", name.UTF8String, problem.localizedDescription.UTF8String);
            return;
        }
        Check(NO, [NSString stringWithFormat:@"%@: produced a file (%@)", name, problem.localizedDescription]);
        return;
    }
    NSDictionary *about = VGDescribeFile(result);
    NSDictionary *decoded = DecodeCheck(result);
    printf("   file: %s\n   %s\n   decoded: %s\n", result.lastPathComponent.UTF8String,
           [[about description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String,
           [[decoded description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
    double seconds = [about[@"seconds"] doubleValue];
    Check(about[@"video"] != nil, [name stringByAppendingString:@": the file has a picture track"]);
    Check(seconds >= minSeconds && seconds <= maxSeconds,
          [NSString stringWithFormat:@"%@: length %.2f s is within %.1f…%.1f s", name, seconds, minSeconds, maxSeconds]);
    Check([decoded[@"frames"] integerValue] >= 100 && [decoded[@"ordered"] boolValue] && !decoded[@"videoError"],
          [NSString stringWithFormat:@"%@: %ld frames decode, in order", name, (long)[decoded[@"frames"] integerValue]]);
    if (wantSound) {
        Check(about[@"audio"] != nil, [name stringByAppendingString:@": the file has a sound track"]);
        double rate = 0;
        NSScanner *scanner = [NSScanner scannerWithString:about[@"audio"] ?: @""];
        [scanner scanUpToCharactersFromSet:NSCharacterSet.whitespaceCharacterSet intoString:NULL];
        [scanner scanDouble:&rate];
        double heard = rate > 0 ? [decoded[@"pcm"] doubleValue] / rate : 0;
        Check(heard >= minSeconds - 1.0 && !decoded[@"audioError"],
              [NSString stringWithFormat:@"%@: %.2f s of sound decode", name, heard]);
        Check([decoded[@"loud"] longLongValue] > 50, [name stringByAppendingString:@": the sound is not silence"]);
        double apart = fabs([about[@"videoStart"] doubleValue] - [about[@"audioStart"] doubleValue]);
        double lengths = fabs([about[@"videoSeconds"] doubleValue] - [about[@"audioSeconds"] doubleValue]);
        Check(apart < 0.25 && lengths < 1.0,
              [NSString stringWithFormat:@"%@: picture and sound start %.3f s apart and differ %.2f s in length", name, apart, lengths]);
    }
    Check(!backwards && lastFraction > 0.85, [NSString stringWithFormat:@"%@: progress only moves forward (ended at %.2f, \"%@\")", name, lastFraction, lastStage]);
    NSString *kept = [folder stringByAppendingPathComponent:[name stringByAppendingPathExtension:result.pathExtension]];
    [NSFileManager.defaultManager removeItemAtPath:kept error:NULL];
    [NSFileManager.defaultManager copyItemAtURL:result toURL:[NSURL fileURLWithPath:kept] error:NULL];
    [job cleanUp];
    Check(![NSFileManager.defaultManager fileExistsAtPath:job.workFolder], [name stringByAppendingString:@": the work folder is gone after cleaning up"]);
}

static void RefusalTest(void) {
    printf("== refusals\n");
    // a live stream must be turned down with a sentence, not saved as a fragment
    VGSource *source = [VGSource new];
    source.url = [NSURL URLWithString:@"https://devstreaming-cdn.apple.com/videos/streaming/examples/no-such-stream/master.m3u8"];
    VGJob *job = [[VGJob alloc] initWithSource:source];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *problem = nil;
    __block NSURL *result = nil;
    [job start:^(NSURL *file, NSError *error) { result = file; problem = error; dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
    printf("   missing stream: %s\n", problem.localizedDescription.UTF8String);
    Check(!result && problem.localizedDescription.length > 0, @"a stream that is not there fails with a sentence");

    VGSource *cancelSource = [VGSource new];
    cancelSource.url = [NSURL URLWithString:@"https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"];
    VGJob *cancelJob = [[VGJob alloc] initWithSource:cancelSource];
    cancelJob.segmentLimit = 40;
    dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);
    __block NSError *cancelProblem = nil;
    __block NSURL *cancelResult = nil;
    [cancelJob start:^(NSURL *file, NSError *error) { cancelResult = file; cancelProblem = error; dispatch_semaphore_signal(cancelled); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ [cancelJob cancel]; });
    BOOL returned = dispatch_semaphore_wait(cancelled, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0;
    Check(returned && !cancelResult && cancelProblem.code == VGErrorCancelled && ![NSFileManager.defaultManager fileExistsAtPath:cancelJob.workFolder ?: @"/nonexistent"],
          [NSString stringWithFormat:@"cancelling stops a download and leaves nothing behind (%@)", cancelProblem.localizedDescription]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);                   // every line at once: a run that stalls shows where
        NSString *folder = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
        NSString *only = argc > 3 && strcmp(argv[2], "only") == 0 ? [NSString stringWithUTF8String:argv[3]] : nil;
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        PlaylistTests();

        NSString *apple = @"https://devstreaming-cdn.apple.com/videos/streaming/examples";
        NSArray *streams = @[
            // name, address, quality limit, parts, sound expected, shortest and longest length
            @[@"fmp4-ranges-own-sound", [apple stringByAppendingString:@"/img_bipbop_adv_example_fmp4/master.m3u8"], @540, @3, @YES, @17.0, @19.0],
            @[@"ts-picture-packed-sound", [apple stringByAppendingString:@"/img_bipbop_adv_example_ts/master.m3u8"], @540, @3, @YES, @17.0, @19.0],
            @[@"ts-with-sound-inside", [apple stringByAppendingString:@"/bipbop_4x3/bipbop_4x3_variant.m3u8"], @0, @3, @YES, @28.5, @31.0],
            @[@"ts-ranges", [apple stringByAppendingString:@"/bipbop_16x9/bipbop_16x9_variant.m3u8"], @0, @2, @YES, @19.0, @21.0],
            @[@"ts-other-packager", @"https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", @480, @2, @YES, @19.0, @21.5],
            @[@"ts-he-aac", @"https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", @200, @2, @YES, @19.0, @21.5],
            @[@"ts-single-quality-list", @"https://test-streams.mux.dev/x36xhzz/url_0/193039199_mp4_h264_aac_hd_7.m3u8", @0, @1, @YES, @9.0, @11.5],
            @[@"plain-mp4", @"https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4", @0, @0, @NO, @9.0, @11.0],
        ];
        for (NSArray *s in streams) {
            if (only && ![s[0] isEqualToString:only]) continue;
            @autoreleasepool {
                StreamTest(s[0], s[1], [s[2] integerValue], [s[3] integerValue], [s[4] boolValue], [s[5] doubleValue], [s[6] doubleValue], folder);
            }
        }
        if (!only) RefusalTest();
        printf("== %d passed, %d failed, %d skipped (no network)\n", gPassed, gFailed, gSkipped);
        return gFailed ? 1 : 0;
    }
}
