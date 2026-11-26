#import "VGSGifMaker.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import "VGSCommon.h"
#import "VGSGifWriter.h"

const double VGSGifMaxSeconds = 20.0;

typedef struct { int maxSide; double interval; int tolerance; int dither; } VGSPresetValues;

static VGSPresetValues VGSValues(VGSGifPreset preset) {
    switch (preset) {
        case VGSGifPresetSmall: return (VGSPresetValues){ 320, 0.08, 10, 0 };
        case VGSGifPresetHigh: return (VGSPresetValues){ 640, 0.033, 5, 1 };
        case VGSGifPresetBalanced: break;
    }
    return (VGSPresetValues){ 480, 0.06, 7, 0 };
}

NSString *VGSGifPresetName(VGSGifPreset preset) {
    switch (preset) {
        case VGSGifPresetSmall: return @"Small";
        case VGSGifPresetHigh: return @"High";
        case VGSGifPresetBalanced: break;
    }
    return @"Balanced";
}

@implementation VGSGifResult
@end

/// Copies a decoded frame into `dest` (outW x outH, 4 bytes a pixel, no padding), resizing and turning it as needed.
static BOOL VGSCopyFrame(CVPixelBufferRef buffer, int decodeW, int decodeH, int angle, uint8_t *dest, uint8_t **scratch) {
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) return NO;
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    const uint8_t *source = (const uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t sourceStride = CVPixelBufferGetBytesPerRow(buffer);
    const int sourceW = (int)CVPixelBufferGetWidth(buffer), sourceH = (int)CVPixelBufferGetHeight(buffer);
    BOOL ok = source != NULL && sourceW > 0 && sourceH > 0;

    const uint8_t *stage = source;
    size_t stageStride = sourceStride;
    if (ok && (sourceW != decodeW || sourceH != decodeH)) {
        if (!*scratch) *scratch = (uint8_t *)malloc((size_t)decodeW * decodeH * 4);
        if (!*scratch) {
            ok = NO;
        } else {
            vImage_Buffer from = { (void *)source, (vImagePixelCount)sourceH, (vImagePixelCount)sourceW, sourceStride };
            vImage_Buffer to = { *scratch, (vImagePixelCount)decodeH, (vImagePixelCount)decodeW, (size_t)decodeW * 4 };
            ok = vImageScale_ARGB8888(&from, &to, NULL, kvImageHighQualityResampling) == kvImageNoError;
            stage = *scratch;
            stageStride = (size_t)decodeW * 4;
        }
    }

    if (ok) {
        if (angle == 0) {
            for (int y = 0; y < decodeH; y++) {
                memcpy(dest + (size_t)y * decodeW * 4, stage + (size_t)y * stageStride, (size_t)decodeW * 4);
            }
        } else if (angle == 180) {
            for (int y = 0; y < decodeH; y++) {
                const uint32_t *from = (const uint32_t *)(stage + (size_t)(decodeH - 1 - y) * stageStride);
                uint32_t *to = (uint32_t *)(dest + (size_t)y * decodeW * 4);
                for (int x = 0; x < decodeW; x++) to[x] = from[decodeW - 1 - x];
            }
        } else {
            // A quarter turn: the picture becomes decodeH wide and decodeW tall.
            const int outW = decodeH, outH = decodeW;
            for (int y = 0; y < outH; y++) {
                uint32_t *to = (uint32_t *)(dest + (size_t)y * outW * 4);
                for (int x = 0; x < outW; x++) {
                    const int fromX = (angle == 90) ? y : (decodeW - 1 - y);
                    const int fromY = (angle == 90) ? (decodeH - 1 - x) : x;
                    to[x] = *(const uint32_t *)(stage + (size_t)fromY * stageStride + (size_t)fromX * 4);
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return ok;
}

static void VGSWritePoster(const uint8_t *bgra, int width, int height, NSURL *url) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate((void *)bgra, (size_t)width, (size_t)height, 8, (size_t)width * 4, space,
                                                 kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    if (image) {
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.jpeg"), 1, NULL);
        if (destination) {
            NSDictionary *options = @{(__bridge id)kCGImageDestinationLossyCompressionQuality: @0.82};
            CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)options);
            CGImageDestinationFinalize(destination);
            CFRelease(destination);
        }
        CGImageRelease(image);
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space);
}

@implementation VGSGifMaker

+ (VGSGifResult *)makeGIFAtURL:(NSURL *)gifURL fromVideo:(NSURL *)videoURL preset:(VGSGifPreset)preset
                    posterURL:(NSURL *)posterURL progress:(void (^)(double))progress error:(NSError **)error {
    const VGSPresetValues values = VGSValues(preset);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) {
        if (error) *error = VGSMakeError(VGSErrorVideo, @"The download is not a video this iPhone can read.");
        return nil;
    }

    const CGSize natural = track.naturalSize;
    const CGAffineTransform turn = track.preferredTransform;
    int angle = (int)lround(atan2(turn.b, turn.a) * 180.0 / M_PI);
    angle = ((angle % 360) + 360) % 360;
    angle = (int)(lround(angle / 90.0) * 90) % 360;
    const double longSide = MAX(natural.width, natural.height);
    if (!(longSide >= 2)) {
        if (error) *error = VGSMakeError(VGSErrorVideo, @"The video has no picture.");
        return nil;
    }
    const double scale = MIN(1.0, values.maxSide / longSide);
    const int decodeW = MAX(2, (int)lround(natural.width * scale));
    const int decodeH = MAX(2, (int)lround(natural.height * scale));
    const BOOL quarter = (angle == 90 || angle == 270);
    const int outW = quarter ? decodeH : decodeW, outH = quarter ? decodeW : decodeH;

    double videoDuration = CMTimeGetSeconds(asset.duration);
    if (!isfinite(videoDuration) || videoDuration < 0) videoDuration = 0;
    const double limit = (videoDuration > 0) ? MIN(videoDuration, VGSGifMaxSeconds) : VGSGifMaxSeconds;

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (!reader) {
        if (error) *error = VGSMakeError(VGSErrorVideo, readerError.localizedDescription ?: @"The video could not be opened.");
        return nil;
    }
    NSDictionary *settings = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge id)kCVPixelBufferWidthKey: @(decodeW),
        (__bridge id)kCVPixelBufferHeightKey: @(decodeH),
    };
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        if (error) *error = VGSMakeError(VGSErrorVideo, @"The video could not be decoded.");
        return nil;
    }
    [reader addOutput:output];
    reader.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(VGSGifMaxSeconds, 600));
    if (![reader startReading]) {
        if (error) *error = VGSMakeError(VGSErrorVideo, reader.error.localizedDescription ?: @"The video could not be decoded.");
        return nil;
    }

    VGSGifWriter *writer = VGSGifWriterOpen(gifURL.fileSystemRepresentation, outW, outH, values.tolerance, values.dither);
    uint8_t *pending = (uint8_t *)malloc((size_t)outW * outH * 4);
    uint8_t *scratch = NULL;
    if (!writer || !pending) {
        if (writer) VGSGifWriterClose(writer);
        free(pending);
        [reader cancelReading];
        if (error) *error = VGSMakeError(VGSErrorStorage, @"The GIF file could not be created.");
        return nil;
    }

    BOOL failed = NO;
    BOOL havePending = NO;
    double pendingTime = 0, firstTime = 0, lastSeen = 0;
    double written = 0;             // seconds of delay written so far
    NSInteger frames = 0;
    NSInteger decoded = 0;

    while (!failed) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;
            CVImageBufferRef picture = CMSampleBufferGetImageBuffer(sample);
            const double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
            if (picture && isfinite(time)) {
                decoded++;
                lastSeen = time;
                if (!havePending || time >= pendingTime + values.interval - 0.004) {
                    if (havePending) {
                        long delay = lround((time - firstTime - written) * 100.0);
                        if (delay < 2) delay = 2;
                        if (VGSGifWriterAddFrame(writer, pending, (size_t)outW * 4, (int)delay) != 0) failed = YES;
                        written += delay / 100.0;
                        frames++;
                    } else {
                        firstTime = time;
                    }
                    if (!failed && VGSCopyFrame(picture, decodeW, decodeH, angle, pending, &scratch)) {
                        if (!havePending && posterURL) VGSWritePoster(pending, outW, outH, posterURL);
                        havePending = YES;
                        pendingTime = time;
                    } else {
                        failed = YES;
                    }
                    if (progress && limit > 0) progress(MAX(0.0, MIN(1.0, (time - firstTime) / limit)));
                }
            }
            CFRelease(sample);
        }
    }

    if (!failed && reader.status == AVAssetReaderStatusFailed) failed = YES;
    if (!failed && havePending) {
        // The last frame stays up until the clip ends; when that is unknown, as long as the ones before it.
        double tail = MAX(limit, lastSeen) - pendingTime;
        const double typical = frames > 0 ? (pendingTime - firstTime) / frames : values.interval;
        if (tail < 0.02 || tail > 2.0) tail = MAX(typical, values.interval);
        long delay = lround(tail * 100.0);
        if (delay < 2) delay = 2;
        if (VGSGifWriterAddFrame(writer, pending, (size_t)outW * 4, (int)delay) != 0) failed = YES;
        written += delay / 100.0;
        frames++;
    }
    [reader cancelReading];
    const long long bytes = VGSGifWriterBytesWritten(writer);
    if (VGSGifWriterClose(writer) != 0) failed = YES;
    free(pending);
    free(scratch);

    if (failed || frames == 0) {
        [NSFileManager.defaultManager removeItemAtURL:gifURL error:NULL];
        if (error) {
            *error = VGSMakeError(VGSErrorVideo, reader.error.localizedDescription
                                 ?: (decoded == 0 ? @"The video has no frames that could be read." : @"The GIF could not be written."));
        }
        return nil;
    }
    if (progress) progress(1.0);

    VGSGifResult *result = [VGSGifResult new];
    result.width = outW;
    result.height = outH;
    result.frames = frames;
    result.duration = written;
    result.videoDuration = videoDuration;
    result.bytes = bytes + 1;       // the closing byte
    result.trimmed = videoDuration > VGSGifMaxSeconds + 0.25;
    return result;
}

@end
