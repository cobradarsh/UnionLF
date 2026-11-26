// Tracks out of assembled files, and the writer that puts picture and sound into one MP4.
// Samples are copied as they are: no decoding, no loss, and it takes about as long as a file copy.
#import "VidGrab.h"
#import <objc/runtime.h>
#include <unistd.h>

#pragma mark - a track of a file AVFoundation can open

@interface VGReaderTrack : NSObject <VGTrack>
- (nullable instancetype)initWithAsset:(AVAsset *)asset track:(AVAssetTrack *)track;
@end

@implementation VGReaderTrack {
    AVAsset *_asset;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    CMFormatDescriptionRef _format;
    CGAffineTransform _transform;
    BOOL _video;
    BOOL _done;
}

- (instancetype)initWithAsset:(AVAsset *)asset track:(AVAssetTrack *)track {
    if ((self = [super init])) {
        _asset = asset;
        _video = [track.mediaType isEqualToString:AVMediaTypeVideo];
        _transform = track.preferredTransform;
        id first = track.formatDescriptions.firstObject;
        if (!first) return nil;
        _format = (__bridge_retained CMFormatDescriptionRef)first;
        NSError *error = nil;
        _reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!_reader) return nil;
        _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
        _output.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_output]) return nil;
        [_reader addOutput:_output];
        if (![_reader startReading]) return nil;
    }
    return self;
}

- (void)dealloc {
    if (_format) CFRelease(_format);
    [_reader cancelReading];
}

- (BOOL)isVideo { return _video; }
- (CMFormatDescriptionRef)format { return _format; }
- (BOOL)timelineKnown { return YES; }
- (CGAffineTransform)transform { return _transform; }

- (NSError *)failure {
    return _reader.status == AVAssetReaderStatusFailed ? (_reader.error ?: VGError(VGErrorMedia, @"The download could not be read back.")) : nil;
}

- (CMSampleBufferRef)copyNextSample {
    if (_done) return NULL;
    CMSampleBufferRef sample = [_output copyNextSampleBuffer];
    if (!sample) _done = YES;
    return sample;
}

@end

NSArray<id<VGTrack>> *VGOpenTracks(NSString *path, BOOL wantVideo, BOOL wantAudio, NSError **error) {
    VGFileKind kind = VGSniffFile(path);
    NSMutableArray<id<VGTrack>> *tracks = [NSMutableArray new];
    if (kind == VGFileTS || kind == VGFileAAC) {
        VGTSReader *reader = [[VGTSReader alloc] initWithPath:path];
        if (![reader prepare:error]) return nil;
        if (wantVideo && reader.video) [tracks addObject:(id<VGTrack>)reader.video];
        if (wantAudio && reader.audio) [tracks addObject:(id<VGTrack>)reader.audio];
        // the tracks pull from the reader, which they hold weakly: keep it alive with them
        for (id track in tracks) objc_setAssociatedObject(track, "VGReaderOwner", reader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VGLog(@"%@: %@", path.lastPathComponent, reader.summary);
        return tracks;
    }
    if (kind != VGFileMP4) {
        if (error) *error = VGError(VGErrorUnsupported, kind == VGFileWebM ? @"This video is WebM, which iOS cannot keep in Photos."
                                    : @"The download is not a video VidGrab can read.");
        return nil;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    if (wantVideo) {
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        VGReaderTrack *reader = track ? [[VGReaderTrack alloc] initWithAsset:asset track:track] : nil;
        if (reader) [tracks addObject:reader];
    }
    if (wantAudio) {
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        VGReaderTrack *reader = track ? [[VGReaderTrack alloc] initWithAsset:asset track:track] : nil;
        if (reader) [tracks addObject:reader];
    }
    if (!tracks.count && [asset tracks].count == 0) {
        if (error) *error = VGError(VGErrorMedia, @"The download could not be read as a video.");
        return nil;
    }
    return tracks;
}

#pragma mark - writing

static CMTime VGOrderTime(CMSampleBufferRef sample) {
    CMTime time = CMSampleBufferGetDecodeTimeStamp(sample);
    if (!CMTIME_IS_VALID(time)) time = CMSampleBufferGetPresentationTimeStamp(sample);
    return time;
}

/// The same samples, moved along the timeline.
static CMSampleBufferRef VGShifted(CMSampleBufferRef sample, CMTime shift) CF_RETURNS_RETAINED {
    CMItemCount count = 0;
    if (CMSampleBufferGetSampleTimingInfoArray(sample, 0, NULL, &count) != noErr || count <= 0) return (CMSampleBufferRef)CFRetain(sample);
    CMSampleTimingInfo *timing = malloc(sizeof(CMSampleTimingInfo) * (size_t)count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, timing, &count);
    for (CMItemCount i = 0; i < count; i++) {
        if (CMTIME_IS_VALID(timing[i].presentationTimeStamp)) timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, shift);
        if (CMTIME_IS_VALID(timing[i].decodeTimeStamp)) timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, shift);
    }
    CMSampleBufferRef copy = NULL;
    OSStatus status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sample, count, timing, &copy);
    free(timing);
    if (status != noErr || !copy) return (CMSampleBufferRef)CFRetain(sample);
    return copy;
}

BOOL VGMuxTracks(NSArray<id<VGTrack>> *tracks, NSURL *output, double expectedSeconds,
                 void (^progress)(double), BOOL (^cancelled)(void), NSError **error) {
    NSUInteger n = tracks.count;
    if (n == 0 || n > 4) {
        if (error) *error = VGError(VGErrorMedia, @"There is no picture or sound to save.");
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
    NSError *problem = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:output fileType:AVFileTypeMPEG4 error:&problem];
    if (!writer) {
        if (error) *error = VGError(VGErrorStorage, problem.localizedDescription ?: @"The video file could not be created.");
        return NO;
    }
    writer.shouldOptimizeForNetworkUse = YES;               // the index first: plays and shares at once

    NSMutableArray<AVAssetWriterInput *> *inputs = [NSMutableArray new];
    for (id<VGTrack> track in tracks) {
        CMFormatDescriptionRef format = track.format;
        AVAssetWriterInput *input = nil;
        @try {
            if (format) {
                input = [[AVAssetWriterInput alloc] initWithMediaType:track.isVideo ? AVMediaTypeVideo : AVMediaTypeAudio
                                                       outputSettings:nil sourceFormatHint:format];
            }
        } @catch (NSException *exception) {
            input = nil;
        }
        if (!input || ![writer canAddInput:input]) {
            if (error) *error = VGError(VGErrorUnsupported, track.isVideo ? @"The picture is in a format an MP4 cannot hold."
                                        : @"The sound is in a format an MP4 cannot hold.");
            return NO;
        }
        input.expectsMediaDataInRealTime = NO;
        if (track.isVideo) input.transform = track.transform;
        [writer addInput:input];
        [inputs addObject:input];
    }

    CMSampleBufferRef next[4] = {NULL, NULL, NULL, NULL};
    CMTime shift[4];
    BOOL finished[4] = {NO, NO, NO, NO};
    CMTime start = kCMTimeInvalid, videoStart = kCMTimeInvalid;
    for (NSUInteger i = 0; i < n; i++) {
        shift[i] = kCMTimeZero;
        next[i] = [tracks[i] copyNextSample];
        // buffers without samples only carry notes for a player
        while (next[i] && CMSampleBufferGetNumSamples(next[i]) == 0) {
            CFRelease(next[i]);
            next[i] = [tracks[i] copyNextSample];
        }
        if (!next[i]) continue;
        CMTime first = CMSampleBufferGetPresentationTimeStamp(next[i]);
        if (tracks[i].isVideo && !CMTIME_IS_VALID(videoStart)) videoStart = first;
        if (tracks[i].timelineKnown && (!CMTIME_IS_VALID(start) || CMTimeCompare(first, start) < 0)) start = first;
    }
    for (NSUInteger i = 0; i < n; i++) {
        // a track whose first time stamp is a guess starts with the picture (or with whatever starts first)
        if (!next[i] || tracks[i].timelineKnown) continue;
        CMTime anchor = CMTIME_IS_VALID(videoStart) ? videoStart : start;
        CMTime first = CMSampleBufferGetPresentationTimeStamp(next[i]);
        if (CMTIME_IS_VALID(anchor)) shift[i] = CMTimeSubtract(anchor, first);
        else start = first;
    }
    if (!CMTIME_IS_VALID(start)) {
        for (NSUInteger i = 0; i < n; i++) if (next[i]) CFRelease(next[i]);
        NSError *reading = nil;
        for (id<VGTrack> track in tracks) if (track.failure) reading = track.failure;
        if (error) *error = VGError(VGErrorMedia, reading.localizedDescription ?: @"The download holds no picture or sound.");
        return NO;
    }

    BOOL ok = [writer startWriting];
    if (ok) [writer startSessionAtSourceTime:start];
    VGLog(@"mux: %lu tracks, session starts at %.3f s, writer %@", (unsigned long)n, CMTimeGetSeconds(start), ok ? @"started" : writer.error.localizedDescription);
    NSString *why = nil;
    NSUInteger appended = 0;
    while (ok) {
        NSInteger pick = -1;
        CMTime best = kCMTimeInvalid;
        for (NSUInteger i = 0; i < n; i++) {
            if (!next[i]) {
                if (!finished[i]) {                         // tell the writer at once: it stops waiting for this track
                    finished[i] = YES;
                    [inputs[i] markAsFinished];
                }
                continue;
            }
            CMTime time = CMTimeAdd(VGOrderTime(next[i]), shift[i]);
            if (pick < 0 || CMTimeCompare(time, best) < 0) {
                pick = (NSInteger)i;
                best = time;
            }
        }
        if (pick < 0) break;
        if (cancelled && cancelled()) {
            ok = NO;
            why = @"Cancelled.";
            break;
        }
        AVAssetWriterInput *input = inputs[(NSUInteger)pick];
        NSInteger waited = 0;
        while (!input.isReadyForMoreMediaData && writer.status == AVAssetWriterStatusWriting && waited < 30000) {
            usleep(2000);
            waited += 2;
        }
        if (writer.status != AVAssetWriterStatusWriting || !input.isReadyForMoreMediaData) {
            ok = NO;
            why = writer.error.localizedDescription ?: @"Writing the video stopped.";
            break;
        }
        CMSampleBufferRef sample = next[pick];
        if (CMTimeCompare(shift[pick], kCMTimeZero) != 0) {
            CMSampleBufferRef moved = VGShifted(sample, shift[pick]);
            CFRelease(sample);
            sample = moved;
        }
        if (CMSampleBufferGetNumSamples(sample) > 0 && ![input appendSampleBuffer:sample]) {
            ok = NO;
            why = writer.error.localizedDescription ?: @"A sample could not be written.";
        }
        CFRelease(sample);
        next[pick] = ok ? [tracks[(NSUInteger)pick] copyNextSample] : NULL;
        if (ok && progress && (++appended % 60) == 0 && expectedSeconds > 0) {
            double done = CMTimeGetSeconds(CMTimeSubtract(best, start)) / expectedSeconds;
            progress(MAX(0.0, MIN(1.0, done)));
        }
    }
    for (NSUInteger i = 0; i < n; i++) {
        if (next[i]) CFRelease(next[i]);
        next[i] = NULL;
    }
    if (ok) {
        for (id<VGTrack> track in tracks) {
            if (track.failure) {
                ok = NO;
                why = track.failure.localizedDescription;
            }
        }
    }
    if (!ok) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        BOOL stopped = cancelled && cancelled();
        if (error) *error = stopped ? VGError(VGErrorCancelled, @"Cancelled.") : VGError(VGErrorMedia, why ?: writer.error.localizedDescription ?: @"The video could not be written.");
        return NO;
    }
    for (NSUInteger i = 0; i < n; i++) if (!finished[i]) [inputs[i] markAsFinished];
    VGLog(@"mux: %lu buffers written, finishing the file", (unsigned long)appended);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:output error:NULL];
        if (error) *error = VGError(VGErrorMedia, writer.error.localizedDescription ?: @"The video could not be finished.");
        return NO;
    }
    if (progress) progress(1.0);
    return YES;
}

#pragma mark - what a file holds

static NSString *VGFourCC(FourCharCode code) {
    char text[5] = {(char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0};
    for (int i = 0; i < 4; i++) if (text[i] < 32 || text[i] > 126) text[i] = '?';
    return [NSString stringWithUTF8String:text];
}

NSDictionary *VGDescribeFile(NSURL *file) {
    NSMutableDictionary *out = [NSMutableDictionary new];
    out[@"bytes"] = @([[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL] fileSize]);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    out[@"seconds"] = @(CMTIME_IS_NUMERIC(asset.duration) ? CMTimeGetSeconds(asset.duration) : 0);
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (video) {
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)video.formatDescriptions.firstObject;
        CGSize size = video.naturalSize;
        out[@"video"] = [NSString stringWithFormat:@"%@ %.0fx%.0f", format ? VGFourCC(CMFormatDescriptionGetMediaSubType(format)) : @"?",
                         size.width, size.height];
        out[@"videoSeconds"] = @(CMTimeGetSeconds(video.timeRange.duration));
        out[@"videoStart"] = @(CMTimeGetSeconds(video.timeRange.start));
        out[@"fps"] = @(video.nominalFrameRate);
    }
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (audio) {
        CMAudioFormatDescriptionRef format = (__bridge CMAudioFormatDescriptionRef)audio.formatDescriptions.firstObject;
        const AudioStreamBasicDescription *description = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
        out[@"audio"] = [NSString stringWithFormat:@"%@ %.0f Hz %u ch", format ? VGFourCC(CMFormatDescriptionGetMediaSubType(format)) : @"?",
                         description ? description->mSampleRate : 0, description ? (unsigned)description->mChannelsPerFrame : 0];
        out[@"audioSeconds"] = @(CMTimeGetSeconds(audio.timeRange.duration));
        out[@"audioStart"] = @(CMTimeGetSeconds(audio.timeRange.start));
    }
    return out;
}
