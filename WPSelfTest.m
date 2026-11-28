/*  WPSelfTest.m — on-device checks, run from a USB SSH session without anyone touching the phone.

    Write one command into /var/mobile/Library/WingmanPlus/cmd and SpringBoard runs it straight away (a vnode
    watch on the folder, no polling). Results are appended to /var/mobile/Library/WingmanPlus/log/selftest.log:
    counts and timings only, never any text from the screen.
      ocr      read the current screen with Vision (fast and accurate), then through the reply pipeline
      scroll   one synthetic swipe up the middle of the screen, logs whether the screen moved; only runs
               while Settings is in front, so a test swipe can never land in someone's chat
      hid      list the touch digitizers and the sender ID auto-scroll will use                              */

#import "WPlus.h"
#import <Vision/Vision.h>
#include <fcntl.h>
#include <unistd.h>

extern NSString *const kWPVersion;      // WPSheet.m

static NSString *const kWPTestDir = @"/var/mobile/Library/WingmanPlus";
static dispatch_source_t gWatch;

@interface WPSelfTest ()
+ (void)_check;
+ (void)_ocr;
+ (void)_scroll;
+ (void)_log:(NSString *)line;
@end

@implementation WPSelfTest

+ (void)_log:(NSString *)line {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
    NSString *row, *path = [kWPTestDir stringByAppendingPathComponent:@"log/selftest.log"];
    @synchronized (self) {
        row = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], line];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) { [row writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
        [h seekToEndOfFile];
        [h writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:[kWPTestDir stringByAppendingPathComponent:@"log"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        int fd = open(kWPTestDir.fileSystemRepresentation, O_EVTONLY);
        if (fd < 0) return;
        gWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, DISPATCH_VNODE_WRITE,
                                        dispatch_get_main_queue());
        if (!gWatch) { close(fd); return; }
        dispatch_source_set_event_handler(gWatch, ^{ [WPSelfTest _check]; });
        dispatch_source_set_cancel_handler(gWatch, ^{ close(fd); });
        dispatch_resume(gWatch);
        [WPSelfTest _log:[NSString stringWithFormat:@"self-test ready (Wingman Plus %@)", kWPVersion]];
        [WPSelfTest _check];                                    // a command written before the respring
    });
}

+ (void)_check {
    NSString *path = [kWPTestDir stringByAppendingPathComponent:@"cmd"];
    NSString *cmd = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!cmd) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    cmd = [cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    @try {
        if ([cmd isEqualToString:@"ocr"]) [self _ocr];
        else if ([cmd isEqualToString:@"scroll"]) [self _scroll];
        else if ([cmd isEqualToString:@"hid"]) [self _log:[@"hid: " stringByAppendingString:[WPScroll diagnostics]]];
        else [self _log:@"unknown command (use ocr, scroll or hid)"];
    } @catch (NSException *e) {
        [self _log:[@"failed: " stringByAppendingString:e.reason ?: @"exception"]];
    }
}

+ (void)_ocr {
    UIImage *img = [WPCapture captureNow];
    if (!img.CGImage) { [self _log:@"ocr: no screen image"]; return; }
    [self _log:[NSString stringWithFormat:@"ocr: front app %@, screen %zux%zu px", [WPHost frontmostBundleID] ?: @"(none)",
                CGImageGetWidth(img.CGImage), CGImageGetHeight(img.CGImage)]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int fast = 1; fast >= 0; fast--) {
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
            req.recognitionLevel = fast ? VNRequestTextRecognitionLevelFast : VNRequestTextRecognitionLevelAccurate;
            req.usesLanguageCorrection = NO;
            req.recognitionLanguages = @[@"en-US"];
            VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
            NSError *err = nil;
            BOOL ok = [h performRequests:@[req] error:&err];
            [self _log:[NSString stringWithFormat:@"vision %@: ok=%d lines=%lu in %.0f ms%@", fast ? @"fast" : @"accurate",
                        ok, (unsigned long)req.results.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                        err ? [@", error: " stringByAppendingString:err.localizedDescription] : @""]];
        }
        for (int fast = 1; fast >= 0; fast--) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            [WMOCR transcriptFromFrames:@[img] fast:(BOOL)fast completion:^(NSString *t, NSInteger n) {
                [self _log:[NSString stringWithFormat:@"pipeline %@: %ld messages, %lu characters in %.0f ms",
                            fast ? @"fast" : @"accurate", (long)n, (unsigned long)t.length,
                            (CFAbsoluteTimeGetCurrent() - t0) * 1000]];
                dispatch_semaphore_signal(done);
            }];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        }
    });
}

+ (void)_scroll {
    NSString *front = [WPHost frontmostBundleID] ?: @"(none)";
    if (![front isEqualToString:@"com.apple.Preferences"]) {
        [self _log:[NSString stringWithFormat:@"scroll: skipped, %@ is in front (open Settings first)", front]];
        return;
    }
    [self _log:[@"scroll: " stringByAppendingString:[WPScroll diagnostics]]];
    NSData *before = [WPCapture probeSignature];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL sent = [WPScroll swipeFrom:CGPointMake(0.5, 0.72) to:CGPointMake(0.5, 0.30) duration:0.30 hold:0.12];
        usleep(900000);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSData *after = [WPCapture probeSignature];
            NSUInteger diff = 0, n = MIN(before.length, after.length);
            const uint8_t *a = before.bytes, *b = after.bytes;
            for (NSUInteger i = 0; i < n; i++) if (abs((int)a[i] - (int)b[i]) > 12) diff++;
            [self _log:[NSString stringWithFormat:@"scroll: sent=%d, %lu of %lu cells changed: %@", sent,
                        (unsigned long)diff, (unsigned long)n, diff > n / 20 ? @"THE SCREEN MOVED" : @"no movement"]];
        });
    });
}

@end
