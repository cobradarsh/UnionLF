// Runs a download and hands the finished file on: Photos (with a VidGrab album), the share
// sheet, or GIF Stash.
#import "VidGrabUI.h"
#import <Photos/Photos.h>
#import "VGSGifMaker.h"
#include <notify.h>

static VGJob *gJob;
static UIBackgroundTaskIdentifier gBackground;
static NSString *gLastResult = @"none yet";
static NSString *const kAlbum = @"VidGrab";

BOOL VGDownloadRunning(void) { return gJob != nil; }
NSString *VGLastDownloadResult(void) { return gLastResult; }

void VGCancelDownload(void) {
    [gJob cancel];
}

static void VGEnd(VGJob *job, BOOL success, NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gLastResult = [NSString stringWithFormat:@"%@: %@ [%@]", success ? @"ok" : @"failed", text, job.report];
        VGLog(@"download %@", gLastResult);
        [job cleanUp];
        if (gJob == job) gJob = nil;
        if (success) [VGPill succeed:text]; else [VGPill fail:text];
        if (gBackground != UIBackgroundTaskInvalid) {
            UIBackgroundTaskIdentifier task = gBackground;
            gBackground = UIBackgroundTaskInvalid;
            [UIApplication.sharedApplication endBackgroundTask:task];
        }
    });
}

#pragma mark - Photos

static BOOL VGAllowed(PHAuthorizationStatus status) {
    return status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited;
}

static PHAssetCollection *VGFindAlbum(void) {
    PHFetchResult<PHAssetCollection *> *albums = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                          subtype:PHAssetCollectionSubtypeAlbumRegular options:nil];
    __block PHAssetCollection *found = nil;
    [albums enumerateObjectsUsingBlock:^(PHAssetCollection *album, NSUInteger index, BOOL *stop) {
        if ([album.localizedTitle isEqualToString:kAlbum]) {
            found = album;
            *stop = YES;
        }
    }];
    return found;
}

static void VGWriteToPhotos(VGJob *job, NSURL *file, BOOL intoAlbum, void (^done)(BOOL ok, BOOL inAlbum, NSError *error)) {
    PHAssetCollection *album = intoAlbum ? VGFindAlbum() : nil;
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        [request addResourceWithType:PHAssetResourceTypeVideo fileURL:file options:nil];
        if (!intoAlbum) return;
        PHAssetCollectionChangeRequest *change = album ? [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album]
                                                       : [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:kAlbum];
        PHObjectPlaceholder *placeholder = request.placeholderForCreatedAsset;
        if (change && placeholder) [change addAssets:@[placeholder]];
    } completionHandler:^(BOOL success, NSError *error) {
        done(success, success && intoAlbum, error);
    }];
}

static void VGShare(VGJob *job, NSURL *file, UIWindow *window, NSString *note);

static void VGSaveToPhotos(VGJob *job, NSURL *file, UIWindow *window) {
    NSBundle *main = NSBundle.mainBundle;
    BOOL mayAdd = [main objectForInfoDictionaryKey:@"NSPhotoLibraryAddUsageDescription"] != nil;
    BOOL mayRead = [main objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"] != nil;
    if (!mayAdd && !mayRead) {
        // iOS ends an app that asks for Photos without having declared it: hand the file over another way
        VGShare(job, file, window, [NSString stringWithFormat:@"%@ cannot save to Photos itself. Choose Save Video here.", VGAppName()]);
        return;
    }
    // An album can only be made or found with full access; adding alone goes without.
    BOOL wantAlbum = [VGPrefs album] && mayRead;
    PHAccessLevel level = wantAlbum || !mayAdd ? PHAccessLevelReadWrite : PHAccessLevelAddOnly;
    [VGPill update:0.99 text:@"Saving to Photos"];
    [PHPhotoLibrary requestAuthorizationForAccessLevel:level handler:^(PHAuthorizationStatus status) {
        if (!VGAllowed(status)) {
            // full access was refused; adding alone may still be allowed
            PHAuthorizationStatus addOnly = mayAdd ? [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly] : status;
            if (level == PHAccessLevelReadWrite && mayAdd && (VGAllowed(addOnly) || addOnly == PHAuthorizationStatusNotDetermined)) {
                [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus second) {
                    if (!VGAllowed(second)) {
                        VGEnd(job, NO, [NSString stringWithFormat:@"Photos access is off for %@. Turn it on in Settings › Privacy › Photos, or use Share.", VGAppName()]);
                        return;
                    }
                    VGWriteToPhotos(job, file, NO, ^(BOOL ok, BOOL inAlbum, NSError *error) {
                        if (ok) VGEnd(job, YES, @"Saved to Photos");
                        else VGEnd(job, NO, [NSString stringWithFormat:@"Photos did not take the video (%@).", error.localizedDescription ?: @"no reason given"]);
                    });
                }];
                return;
            }
            VGEnd(job, NO, [NSString stringWithFormat:@"Photos access is off for %@. Turn it on in Settings › Privacy › Photos, or use Share.", VGAppName()]);
            return;
        }
        BOOL album = wantAlbum && level == PHAccessLevelReadWrite && status == PHAuthorizationStatusAuthorized;
        VGWriteToPhotos(job, file, album, ^(BOOL ok, BOOL inAlbum, NSError *error) {
            if (ok) {
                VGEnd(job, YES, inAlbum ? @"Saved to Photos · VidGrab album" : @"Saved to Photos");
                return;
            }
            if (album) {                                    // the album was the obstacle: the video alone
                VGLog(@"saving with the album failed (%@), saving without", error.localizedDescription);
                VGWriteToPhotos(job, file, NO, ^(BOOL secondOK, BOOL secondAlbum, NSError *secondError) {
                    if (secondOK) VGEnd(job, YES, @"Saved to Photos");
                    else VGEnd(job, NO, [NSString stringWithFormat:@"Photos did not take the video (%@).", secondError.localizedDescription ?: @"no reason given"]);
                });
                return;
            }
            VGEnd(job, NO, [NSString stringWithFormat:@"Photos did not take the video (%@).", error.localizedDescription ?: @"no reason given"]);
        });
    }];
}

NSString *VGAppName(void) {
    NSBundle *main = NSBundle.mainBundle;
    return [main objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [main objectForInfoDictionaryKey:@"CFBundleName"] ?: @"this app";
}

#pragma mark - share sheet

static void VGShare(VGJob *job, NSURL *file, UIWindow *window, NSString *note) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [VGPill hide];
        UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
        sheet.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
            gLastResult = [NSString stringWithFormat:@"share sheet closed (%@, %@) [%@]", completed ? @"used" : @"not used", type ?: @"-", job.report];
            VGLog(@"download %@", gLastResult);
            // the app that took the file has its own copy by now
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [job cleanUp];
                [VGOverlay releaseIfIdle];
            });
        };
        UIWindow *overlay = [VGOverlay window];
        sheet.popoverPresentationController.sourceView = overlay.rootViewController.view ?: window;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds), 1, 1);
        [VGOverlay present:sheet from:window];
        if (note) [VGPill note:note from:window];
        if (gJob == job) gJob = nil;
        if (gBackground != UIBackgroundTaskInvalid) {
            UIBackgroundTaskIdentifier task = gBackground;
            gBackground = UIBackgroundTaskInvalid;
            [UIApplication.sharedApplication endBackgroundTask:task];
        }
    });
}

#pragma mark - GIF Stash

static NSString *VGHash(NSString *text) {
    uint64_t hash = 1469598103934665603ULL;                 // FNV-1a
    const char *bytes = text.UTF8String;
    for (size_t i = 0; bytes && bytes[i]; i++) {
        hash ^= (uint8_t)bytes[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", hash];
}

// GIF Stash keeps its library in its own container, where this app may not write. The clip is
// made here, put in this app's temporary folder, and SpringBoard (VidGrabSB) moves it across.
static void VGSendToStash(VGJob *job, NSURL *file, VGSource *source) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *address = source.url.absoluteString ?: file.lastPathComponent;
        NSURL *plain = source.url ? [[NSURLComponents componentsWithURL:source.url resolvingAgainstBaseURL:YES] URL] : nil;
        NSURLComponents *withoutQuery = plain ? [NSURLComponents componentsWithURL:plain resolvingAgainstBaseURL:YES] : nil;
        withoutQuery.query = nil;
        NSString *itemID = [@"vg-" stringByAppendingString:VGHash(withoutQuery.URL.absoluteString ?: address)];
        NSString *outbox = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"vidgrab-outbox"] stringByAppendingPathComponent:itemID];
        [files removeItemAtPath:outbox error:NULL];
        [files createDirectoryAtPath:outbox withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *gif = [NSURL fileURLWithPath:[outbox stringByAppendingPathComponent:[itemID stringByAppendingString:@".gif"]]];
        NSURL *poster = [NSURL fileURLWithPath:[outbox stringByAppendingPathComponent:[itemID stringByAppendingString:@".jpg"]]];
        NSURL *video = [NSURL fileURLWithPath:[outbox stringByAppendingPathComponent:[itemID stringByAppendingString:@".mp4"]]];

        NSInteger preset = VGSGifPresetBalanced;
        VGSGifResult *result = nil;
        NSError *problem = nil;
        while (YES) {
            result = [VGSGifMaker makeGIFAtURL:gif fromVideo:file preset:(VGSGifPreset)preset posterURL:poster progress:^(double fraction) {
                dispatch_async(dispatch_get_main_queue(), ^{ [VGPill update:0.99 text:[NSString stringWithFormat:@"Making the GIF · %.0f%%", fraction * 100]]; });
            } error:&problem];
            // a very large GIF is slow to send anywhere: one size down
            if (result && result.bytes > 12 * 1000 * 1000 && preset > VGSGifPresetSmall && !job.cancelled) { preset--; continue; }
            break;
        }
        if (!result || job.cancelled) {
            [files removeItemAtPath:outbox error:NULL];
            VGEnd(job, NO, job.cancelled ? @"Cancelled." : (problem.localizedDescription ?: @"The GIF could not be made."));
            return;
        }
        if (![files linkItemAtURL:file toURL:video error:NULL]) [files copyItemAtURL:file toURL:video error:NULL];
        NSDictionary *item = @{
            @"id": itemID,
            @"kind": [source.url.path containsString:@"tweet_video"] ? @"gif" : @"video",
            @"sourceURL": address,
            @"author": VGAppName(),
            @"width": @(result.width), @"height": @(result.height), @"frames": @(result.frames),
            @"gifDuration": @(result.duration), @"videoDuration": @(result.videoDuration),
            @"gifBytes": @(result.bytes),
            @"videoBytes": @([[files attributesOfItemAtPath:video.path error:NULL] fileSize]),
            @"preset": @(preset), @"trimmed": @(result.trimmed), @"favorite": @NO,
            @"savedAt": @(NSDate.date.timeIntervalSince1970),
        };
        NSString *json = [outbox stringByAppendingPathComponent:[itemID stringByAppendingString:@".json"]];
        [[NSJSONSerialization dataWithJSONObject:item options:0 error:NULL] writeToFile:json atomically:YES];
        NSString *answer = [[outbox stringByDeletingLastPathComponent] stringByAppendingPathComponent:[itemID stringByAppendingString:@".result"]];
        [files removeItemAtPath:answer error:NULL];

        dispatch_async(dispatch_get_main_queue(), ^{ [VGPill update:0.995 text:@"Handing over to GIF Stash"]; });
        notify_post("com.adarsh.vidgrab/stash");
        NSString *reply = nil;
        for (int i = 0; i < 60 && !reply; i++) {             // SpringBoard answers within a moment; give it 15 seconds
            [NSThread sleepForTimeInterval:0.25];
            reply = [NSString stringWithContentsOfFile:answer encoding:NSUTF8StringEncoding error:NULL];
            if (i == 20) notify_post("com.adarsh.vidgrab/stash");
        }
        [files removeItemAtPath:answer error:NULL];
        [files removeItemAtPath:outbox error:NULL];
        if ([reply hasPrefix:@"ok"]) {
            NSString *size = VGByteString(result.bytes);
            VGEnd(job, YES, result.trimmed ? [NSString stringWithFormat:@"Added to GIF Stash · first %.0f s · %@", result.duration, size]
                                           : [NSString stringWithFormat:@"Added to GIF Stash · %@", size]);
        } else {
            VGEnd(job, NO, reply.length ? reply : @"GIF Stash did not answer. Respring once after installing VidGrab, then try again.");
        }
    });
}

#pragma mark - start

void VGStartDownload(VGSource *source, VGDelivery delivery, VGVariant *variant, UIWindow *window) {
    if (!source) return;
    if (gJob) {
        [VGPill note:@"One download at a time: the other one is still running." from:window];
        return;
    }
    VGJob *job = [[VGJob alloc] initWithSource:source];
    job.maxLines = [VGPrefs maxHeight];
    job.variant = variant;
    gJob = job;
    UIApplication *app = UIApplication.sharedApplication;
    // leaving the app for a moment does not stop the download; iOS allows about half a minute
    gBackground = [app beginBackgroundTaskWithName:@"VidGrab download" expirationHandler:^{
        [job cancel];
        if (gBackground != UIBackgroundTaskInvalid) {
            UIBackgroundTaskIdentifier task = gBackground;
            gBackground = UIBackgroundTaskInvalid;
            [app endBackgroundTask:task];
        }
    }];
    __weak VGJob *weakJob = job;
    [VGPill showProgress:0.01 text:@"Getting ready" from:window onCancel:^{ [weakJob cancel]; }];

    __block CFAbsoluteTime lastShown = 0;
    job.onProgress = ^(double fraction, NSString *stage) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastShown < 0.1 && fraction < 0.999) return;      // ten updates a second are plenty
        lastShown = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gJob == weakJob) [VGPill update:fraction text:stage];
        });
    };
    VGLog(@"download: %@ → %ld", source.shortName, (long)delivery);
    [job start:^(NSURL *file, NSError *error) {
        if (!file) {
            if (error.code == VGErrorCancelled) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    gLastResult = [NSString stringWithFormat:@"cancelled [%@]", job.report];
                    if (gJob == job) gJob = nil;
                    [VGPill note:@"Cancelled" from:nil];
                    if (gBackground != UIBackgroundTaskInvalid) {
                        UIBackgroundTaskIdentifier task = gBackground;
                        gBackground = UIBackgroundTaskInvalid;
                        [app endBackgroundTask:task];
                    }
                });
                return;
            }
            VGEnd(job, NO, error.localizedDescription ?: @"The video could not be saved.");
            return;
        }
        if (delivery == VGDeliverPhotos) {
            dispatch_async(dispatch_get_main_queue(), ^{ VGSaveToPhotos(job, file, window); });
        } else if (delivery == VGDeliverShare) {
            VGShare(job, file, window, nil);
        } else if (delivery == VGDeliverStash) {
            VGSendToStash(job, file, source);
        } else {
            NSDictionary *about = VGDescribeFile(file);
            VGEnd(job, YES, [NSString stringWithFormat:@"Fetched: %@, %@, %.1f s, %@", about[@"video"] ?: @"no picture", about[@"audio"] ?: @"no sound",
                             [about[@"seconds"] doubleValue], VGByteString([about[@"bytes"] longLongValue])]);
        }
    }];
}
