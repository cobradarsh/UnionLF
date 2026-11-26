// Test commands. Off unless a marker file exists:
//   on the phone   <jailbreak root>/var/mobile/Library/VidGrab/diag      (tools/phone.sh diag on)
//   in tests       $VIDGRAB_DIR/diag
// While it exists, an app with VidGrab looks twice a second for a command file in that folder
// (cmd-<executable name>.txt, or cmd.txt for whichever app is running). Its first line is a
// token; a file is run once per token. The answers go to the log (vidgrab.log in the app's
// temporary folder), pictures next to it.
//
//   state                 version, hooks, settings, windows
//   layers [full]         every player layer: where, ready, playing, what it plays, its button
//   press [x y]           what a hold at that point does (default: the middle of the first video)
//   tap                   what a tap on the first download button does (saves, unless Settings say otherwise)
//   buttonhold            what a hold on the first download button does (the menu)
//   pictures              every picture with a button or a claim to one: what it is, where, its button
//   pictap [n]            what a tap on the button of the n-th picture with a button does (default the first)
//   pichold [n]           the same for a hold on that button (the menu)
//   scan                  everything on screen drawn as a large image, known to VidGrab or not
//   hit [x y]             what a touch at the point (default: the first button) lands on in the app
//   menu                  the entries of the open menu
//   choose <title>        run the entry whose title starts so
//   dismiss               close the menu or sheet
//   fetch|save|share|stash <url>   run a download of that address (fetch: only make the file)
//   result                how the last download ended
//   cancel                stop the running download
//   photos                how many videos Photos holds, and whether the VidGrab album exists
//   shot <name>           picture of the screen as the app draws it → vidgrab-<name>.jpg
//   set <key> <value>     tests only: change a setting
//   wait <seconds>, mark <text>
#import "VidGrabUI.h"
#import <Photos/Photos.h>

static NSMutableArray<NSString *> *gLines;
static BOOL gRunning;
static NSString *gLastToken;

static NSString *VGDebugFolder(void) {
    return VGTestFolder() ?: [VGRoot() stringByAppendingPathComponent:@"var/mobile/Library/VidGrab"];
}

static NSString *VGDebugOut(void) {
    return VGTestFolder() ?: NSTemporaryDirectory();
}

static NSString *VGShort(VGSource *source, BOOL full) {
    if (!source) return @"nothing VidGrab can save";
    if (source.isPicture) return full && source.url ? [NSString stringWithFormat:@"%@ from %@", source.shortName, source.url.absoluteString] : source.shortName;
    if (full) return [NSString stringWithFormat:@"%@ headers:%@", source.url.absoluteString ?: NSStringFromClass(source.asset.class), source.headers.allKeys ?: @[]];
    return [NSString stringWithFormat:@"%@ (%@%@)", source.shortName, source.url.path.lastPathComponent ?: NSStringFromClass(source.asset.class),
            source.headers.count ? @", with headers" : @""];
}

static UIWindow *VGFirstWindowWithVideo(AVPlayerLayer **layerOut) {
    for (UIWindow *window in VGAppWindows()) {
        for (AVPlayerLayer *layer in VGKnownPlayerLayers()) {
            if (CGRectIsNull(VGLayerFrameInWindow(layer, window)) || !VGSourceForPlayerLayer(layer)) continue;
            if (layerOut) *layerOut = layer;
            return window;
        }
    }
    return VGAppWindows().firstObject;
}

static void VGShot(NSString *name) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray new];
    UIWindowScene *first = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (!first) first = (UIWindowScene *)scene;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (!window.isHidden) [windows addObject:window];
    }
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        return a.windowLevel < b.windowLevel ? NSOrderedAscending : (a.windowLevel > b.windowLevel ? NSOrderedDescending : NSOrderedSame);
    }];
    CGRect bounds = first ? first.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blackColor setFill];
        UIRectFill(bounds);
        for (UIWindow *window in windows) [window drawViewHierarchyInRect:window.frame afterScreenUpdates:NO];
    }];
    NSString *path = [VGDebugOut() stringByAppendingPathComponent:[NSString stringWithFormat:@"vidgrab-%@.jpg", name]];
    BOOL ok = [UIImageJPEGRepresentation(image, 0.8) writeToFile:path atomically:YES];
    VGLog(@"shot %@: %@ (%lu windows)", name, ok ? path : @"could not be written", (unsigned long)windows.count);
}

static void VGRunNext(void);

static void VGRunLine(NSString *line) {
    NSArray<NSString *> *words = [line componentsSeparatedByString:@" "];
    NSString *command = words.firstObject;
    NSString *rest = words.count > 1 ? [[words subarrayWithRange:NSMakeRange(1, words.count - 1)] componentsJoinedByString:@" "] : @"";

    if ([command isEqualToString:@"mark"]) {
        VGLog(@"mark: %@", rest);
    } else if ([command isEqualToString:@"wait"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.05, rest.doubleValue) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VGRunNext(); });
        return;
    } else if ([command isEqualToString:@"state"]) {
        NSMutableArray<NSString *> *windows = [NSMutableArray new];
        for (UIWindow *window in VGAppWindows()) [windows addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(window.class), window.isKeyWindow ? @" (key)" : @""]];
        UIWindow *overlay = [VGOverlay window];
        VGLog(@"state: VidGrab %@, %@, enabled %d, button %d pictures %d corner %ld, hold %ld fingers %.2f s, block app hold %d, action %ld, quality %ld, album %d; "
              @"windows: %@; overlay %@; pill %@; download %@; players known %lu",
              VG_VERSION, VGCaptureHookSummary(), [VGPrefs enabled], [VGPrefs badge], [VGPrefs pictures], (long)[VGPrefs badgeCorner], (long)[VGPrefs holdFingers],
              [VGPrefs holdTime], [VGPrefs blockAppHold], (long)[VGPrefs action], (long)[VGPrefs maxHeight], [VGPrefs album],
              [windows componentsJoinedByString:@", "], overlay ? (overlay.isHidden ? @"hidden" : (overlay.isKeyWindow ? @"shown, key" : @"shown")) : @"none",
              [VGPill stateForLog], VGDownloadRunning() ? @"running" : @"idle", (unsigned long)VGKnownPlayerLayers().count);
    } else if ([command isEqualToString:@"layers"]) {
        BOOL full = [rest isEqualToString:@"full"];
        NSArray<AVPlayerLayer *> *layers = VGKnownPlayerLayers();
        NSArray<UIWindow *> *windows = VGAppWindows();
        VGLog(@"layers: %lu known", (unsigned long)layers.count);
        NSUInteger number = 0;
        for (AVPlayerLayer *layer in layers) {
            UIWindow *home = nil;
            CGRect frame = CGRectNull;
            for (UIWindow *window in windows) {
                frame = VGLayerFrameInWindow(layer, window);
                if (!CGRectIsNull(frame)) { home = window; break; }
            }
            CGRect badge = home ? VGBadgeFrameInWindow(layer, home) : CGRectNull;
            CGPoint centre = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
            VGLog(@"    %lu: %@ ready %d rate %.1f; %@; button %@%@", (unsigned long)number++,
                  home ? [NSString stringWithFormat:@"%@ in %@", NSStringFromCGRect(frame), NSStringFromClass(home.class)] : @"not on screen",
                  layer.isReadyForDisplay, layer.player.rate, VGShort(VGSourceForPlayerLayer(layer), full),
                  CGRectIsNull(badge) ? @"hidden" : NSStringFromCGRect(badge),
                  home ? (VGLayerCoveredAtPoint(layer, home, centre) ? @"; covered at its middle" : @"; open at its middle") : @"");
        }
    } else if ([command isEqualToString:@"press"] || [command isEqualToString:@"tap"] || [command isEqualToString:@"buttonhold"] || [command isEqualToString:@"hit"]) {
        AVPlayerLayer *first = nil;
        UIWindow *window = VGFirstWindowWithVideo(&first);
        CGPoint point = CGPointZero;
        BOOL given = words.count >= 3;
        if (given) {
            point = CGPointMake(words[1].doubleValue, words[2].doubleValue);
        } else if (first && window) {
            CGRect badge = VGBadgeFrameInWindow(first, window);
            CGRect frame = VGLayerFrameInWindow(first, window);
            BOOL useBadge = ![command isEqualToString:@"press"] && !CGRectIsNull(badge);
            point = useBadge ? CGPointMake(CGRectGetMidX(badge), CGRectGetMidY(badge)) : CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        }
        if (!window) {
            VGLog(@"%@: no window", command);
        } else if ([command isEqualToString:@"hit"]) {
            VGLog(@"hit %@: %@; a tap here would be %@", NSStringFromCGPoint(point), VGDescribeTouchAt(window, point),
                  VGBadgeLayerAtPoint(window, point) ? @"VidGrab's" : @"the app's");
        } else if ([command isEqualToString:@"press"]) {
            AVPlayerLayer *layer = VGPlayerLayerAtPoint(window, point);
            VGLog(@"press %@: %@", NSStringFromCGPoint(point), layer ? VGShort(VGSourceForPlayerLayer(layer), NO) : @"no video there: VidGrab stays out of it");
            if (layer) VGTrigger(VGSourceForPlayerLayer(layer), window, CGRectMake(point.x, point.y, 1, 1));
        } else {
            CALayer *layer = VGBadgeLayerAtPoint(window, point);
            VGLog(@"tap %@: %@", NSStringFromCGPoint(point), layer ? VGShort(VGSourceForBadgeLayer(layer), NO) : @"no download button there");
            if (layer) VGTriggerAction(VGSourceForBadgeLayer(layer), window, VGBadgeFrameInWindow(layer, window), [command isEqualToString:@"buttonhold"] ? 0 : [VGPrefs tapAction]);
        }
    } else if ([command isEqualToString:@"pictures"] || [command isEqualToString:@"pictap"] || [command isEqualToString:@"pichold"]) {
        VGLayoutPictures();
        NSMutableArray<CALayer *> *withButton = [NSMutableArray new];
        NSMutableArray<UIWindow *> *homes = [NSMutableArray new];
        NSUInteger listed = 0;
        for (UIWindow *window in VGAppWindows()) {
            for (CALayer *layer in VGKnownPictureLayers()) {
                if (VGHostView(layer).window != window || CGRectIsNull(VGLayerFrameInWindow(layer, window))) continue;
                if (!CGRectIsNull(VGBadgeFrameInWindow(layer, window))) {
                    [withButton addObject:layer];
                    [homes addObject:window];
                }
                if ([command isEqualToString:@"pictures"] && listed < 30) VGLog(@"    picture %lu: %@", (unsigned long)listed++, VGDescribePictureLayer(layer, window));
            }
        }
        if ([command isEqualToString:@"pictures"]) {
            VGLog(@"pictures: %lu known, %lu on screen, %lu with a button", (unsigned long)VGKnownPictureLayers().count, (unsigned long)listed,
                  (unsigned long)withButton.count);
        } else {
            NSUInteger index = (NSUInteger)MAX(0, rest.integerValue);
            if (index >= withButton.count) {
                VGLog(@"pictap %lu: no such picture button (%lu on screen)", (unsigned long)index, (unsigned long)withButton.count);
            } else {
                CALayer *layer = withButton[index];
                UIWindow *window = homes[index];
                CGRect badge = VGBadgeFrameInWindow(layer, window);
                CGPoint point = CGPointMake(CGRectGetMidX(badge), CGRectGetMidY(badge));
                CALayer *hit = VGBadgeLayerAtPoint(window, point);
                VGLog(@"pictap %lu at %@: %@", (unsigned long)index, NSStringFromCGPoint(point),
                      hit ? VGShort(VGSourceForBadgeLayer(hit), YES) : @"the button takes no tap there");
                if (hit) VGTriggerAction(VGSourceForBadgeLayer(hit), window, badge, [command isEqualToString:@"pichold"] ? 0 : [VGPrefs tapAction]);
            }
        }
    } else if ([command isEqualToString:@"scan"]) {
        VGLogPictureScan(VGAppWindows().firstObject);
    } else if ([command isEqualToString:@"menu"]) {
        VGMenu *menu = [VGMenu current];
        VGLog(@"menu: %@", menu ? [menu.titles componentsJoinedByString:@" | "] : @"none open");
    } else if ([command isEqualToString:@"choose"]) {
        VGMenu *menu = [VGMenu current];
        VGLog(@"choose %@: %@", rest, menu ? ([menu choose:rest] ? @"done" : @"no such entry") : @"no menu open");
    } else if ([command isEqualToString:@"dismiss"]) {
        [VGOverlay dismissPresented:nil];
        VGLog(@"dismiss");
    } else if ([@[@"fetch", @"save", @"share", @"stash"] containsObject:command]) {
        VGSource *source = [VGSource new];
        source.url = [NSURL URLWithString:rest];
        VGDelivery delivery = [command isEqualToString:@"save"] ? VGDeliverPhotos : [command isEqualToString:@"share"] ? VGDeliverShare
            : [command isEqualToString:@"stash"] ? VGDeliverStash : VGDeliverNothing;
        VGLog(@"%@ %@", command, source.url ? source.shortName : @"(not an address)");
        if (source.url) VGStartDownload(source, delivery, nil, VGAppWindows().firstObject);
    } else if ([command isEqualToString:@"result"]) {
        VGLog(@"result: %@; download %@; queue %lu; pill %@", VGLastDownloadResult(), VGDownloadRunning() ? @"running" : @"idle",
              (unsigned long)VGQueueCount(), [VGPill stateForLog]);
    } else if ([command isEqualToString:@"cancel"]) {
        VGCancelDownload();
        VGLog(@"cancel");
    } else if ([command isEqualToString:@"photos"]) {
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        if (status != PHAuthorizationStatusAuthorized) {
            VGLog(@"photos: full access not given (status %ld), cannot count", (long)status);
        } else {
            NSUInteger videos = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeVideo options:nil].count;
            NSUInteger pictures = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeImage options:nil].count;
            PHFetchResult<PHAssetCollection *> *albums = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                                  subtype:PHAssetCollectionSubtypeAlbumRegular options:nil];
            __block NSInteger inAlbum = -1;
            [albums enumerateObjectsUsingBlock:^(PHAssetCollection *album, NSUInteger index, BOOL *stop) {
                if ([album.localizedTitle isEqualToString:@"VidGrab"]) inAlbum = (NSInteger)[PHAsset fetchAssetsInAssetCollection:album options:nil].count;
            }];
            VGLog(@"photos: %lu videos, %lu pictures; VidGrab album %@", (unsigned long)videos, (unsigned long)pictures,
                  inAlbum < 0 ? @"does not exist" : [NSString stringWithFormat:@"holds %ld", (long)inAlbum]);
        }
    } else if ([command isEqualToString:@"shot"]) {
        VGShot(rest.length ? rest : @"shot");
    } else if ([command isEqualToString:@"set"] && VGTestFolder() && words.count >= 3) {
        NSString *path = [VGTestFolder() stringByAppendingPathComponent:@"prefs.plist"];
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary new];
        prefs[words[1]] = @(words[2].doubleValue);
        [prefs writeToFile:path atomically:YES];
        [VGPrefs reload];
        VGLog(@"set %@ = %@", words[1], words[2]);
    } else if (command.length) {
        VGLog(@"unknown command: %@", line);
    }
    dispatch_async(dispatch_get_main_queue(), ^{ VGRunNext(); });
}

static void VGRunNext(void) {
    if (gLines.count == 0) {
        gRunning = NO;
        return;
    }
    NSString *line = [gLines.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [gLines removeObjectAtIndex:0];
    @try {
        VGRunLine(line);
    } @catch (NSException *exception) {
        VGLog(@"command \"%@\" threw %@: %@", line, exception.name, exception.reason);
        dispatch_async(dispatch_get_main_queue(), ^{ VGRunNext(); });
    }
}

static void VGPoll(void) {
    if (gRunning) return;
    NSString *folder = VGDebugFolder();
    NSString *name = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"app";
    NSString *text = nil;
    for (NSString *file in @[[NSString stringWithFormat:@"cmd-%@.txt", name], @"cmd.txt"]) {
        text = [NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:file] encoding:NSUTF8StringEncoding error:NULL];
        if (text.length) break;
    }
    if (!text.length) return;
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] mutableCopy];
    NSString *token = [lines.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!token.length || [token isEqualToString:gLastToken]) return;
    // a command file is run once, also across restarts of the app
    NSString *seen = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vidgrab-cmd.last"];
    if (!gLastToken) {
        NSString *before = [NSString stringWithContentsOfFile:seen encoding:NSUTF8StringEncoding error:NULL];
        if ([before isEqualToString:token]) {
            gLastToken = token;
            return;
        }
    }
    gLastToken = token;
    [token writeToFile:seen atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [lines removeObjectAtIndex:0];
    gLines = lines;
    gRunning = YES;
    VGLog(@"commands %@: %lu lines", token, (unsigned long)lines.count);
    VGRunNext();
}

void VGDebugStart(void) {
    NSString *marker = [VGDebugFolder() stringByAppendingPathComponent:@"diag"];
    if (![NSFileManager.defaultManager fileExistsAtPath:marker]) return;
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        // the marker being taken away ends the watching, without a restart of the app
        if (![NSFileManager.defaultManager fileExistsAtPath:marker]) {
            dispatch_source_cancel(timer);
            VGLog(@"test commands off (marker removed)");
            return;
        }
        VGPoll();
    });
    dispatch_resume(timer);
    VGLog(@"test commands on (%@)", marker);
}
