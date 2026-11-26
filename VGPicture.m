// Pictures: the download button on what image views show.
//
// Two hooks tell which layers show pictures; nothing is looked for while the app scrolls:
//   -[UIImageView setImage:], -[UIImageView didMoveToWindow]   image views of every kind
//   -[_ASDisplayLayer setContents:]                             image nodes in apps built with Texture
//                                                               (only where the app has that class)
// A picture gets a button when it is big enough to be a photo rather than an icon or a face, is
// not the cover of a video that already has one, and is not the backdrop of a smaller picture.
// Saving fetches the picture's original where its address tells how (Pinterest, X, Reddit) and
// otherwise keeps exactly what is on screen.
#import "VidGrabUI.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>
#include <stdatomic.h>

static const CGFloat kMinSide = 110;          // points: smaller ones are faces, icons, thumbnails
static const CGFloat kMinPixels = 160;        // the image's own shorter side
static NSInteger gPictureHooks;
static Class gImageNodeClass;                 // ASImageNode, in apps built with Texture

static NSHashTable<CALayer *> *VGPictureTable(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

NSArray<CALayer *> *VGKnownPictureLayers(void) {
    return NSThread.isMainThread ? VGPictureTable().allObjects : @[];
}

static void VGRememberPicture(CALayer *layer) {
    if (layer) [VGPictureTable() addObject:layer];
}

#pragma mark - what a layer shows

static id VGCall(id object, NSString *name) {                // an object-returning getter, when there is one
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static id VGNodeOf(CALayer *layer) {
    if (!gImageNodeClass) return nil;
    id node = VGCall(layer, @"asyncdisplaykit_node");
    return [node isKindOfClass:gImageNodeClass] ? node : nil;
}

static BOOL VGImageBigEnough(UIImage *image) {
    if (![image isKindOfClass:UIImage.class]) return NO;
    CGFloat scale = image.scale > 0 ? image.scale : 1;
    return image.size.width * scale >= kMinPixels && image.size.height * scale >= kMinPixels;
}

static BOOL VGLooksLikePhoto(UIImage *image) {
    if (!VGImageBigEnough(image)) return NO;
    if (image.isSymbolImage || image.renderingMode == UIImageRenderingModeAlwaysTemplate) return NO;    // icons
    if (!UIEdgeInsetsEqualToEdgeInsets(image.capInsets, UIEdgeInsetsZero)) return NO;               // stretched backgrounds
    return YES;
}

/// Where an image view loaded its picture from, for the image libraries that say so.
static NSURL *VGAddressOfView(UIView *view) {
    for (NSString *getter in @[@"sd_imageURL", @"imageURL"]) {
        id found = VGCall(view, getter);
        if (![found isKindOfClass:NSURL.class]) continue;
        NSURL *url = found;
        if ([@[@"http", @"https"] containsObject:url.scheme.lowercaseString ?: @""]) return url;
    }
    return nil;
}

/// The picture a layer shows: its image, where it is drawn in the layer, the address it came from.
static UIImage *VGPictureOf(CALayer *layer, CGRect *drawnOut, NSURL **addressOut) {
    UIImage *image = nil;
    NSURL *address = nil;
    CGRect drawn = layer.bounds;
    id delegate = layer.delegate;
    if ([delegate isKindOfClass:UIImageView.class]) {
        UIImageView *view = delegate;
        image = view.isHighlighted && view.highlightedImage ? view.highlightedImage : view.image;
        if (view.contentMode == UIViewContentModeScaleAspectFit && image.size.width > 0 && image.size.height > 0) {
            CGSize box = view.bounds.size;
            CGFloat fit = MIN(box.width / image.size.width, box.height / image.size.height);
            CGSize size = CGSizeMake(image.size.width * fit, image.size.height * fit);
            drawn = CGRectMake((box.width - size.width) / 2, (box.height - size.height) / 2, size.width, size.height);
        }
        if (image) address = VGAddressOfView(view);
    } else {
        id node = VGNodeOf(layer);
        if (!node) return nil;
        image = VGCall(node, @"image");
        if (image && image == VGCall(node, @"defaultImage")) return nil;      // still the placeholder
        id url = VGCall(node, @"URL");
        if ([url isKindOfClass:NSURL.class]) address = url;
    }
    if (!VGLooksLikePhoto(image)) return nil;
    if (drawnOut) *drawnOut = drawn;
    if (addressOut) *addressOut = address;
    return image;
}

VGSource *VGSourceForPictureLayer(CALayer *layer) {
    NSURL *address = nil;
    UIImage *image = VGPictureOf(layer, NULL, &address);
    if (!image) return nil;
    VGSource *source = [VGSource new];
    source.isPicture = YES;
    source.picture = image;
    source.url = address;
    CGFloat scale = image.scale > 0 ? image.scale : 1;
    source.pictureWidth = (NSInteger)round(image.size.width * scale);
    source.pictureHeight = (NSInteger)round(image.size.height * scale);
    return source;
}

#pragma mark - the buttons

static CGFloat VGArea(CGRect rect) { return CGRectIsNull(rect) ? 0 : rect.size.width * rect.size.height; }

@interface VGPictureSpot : NSObject
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic) CGRect frame;          // what is seen of it, in the window
@property (nonatomic) CGRect drawn;          // where the picture is, in the layer
@property (nonatomic) BOOL backdrop;
@end
@implementation VGPictureSpot
@end

void VGLayoutPictures(void) {
    if (!NSThread.isMainThread) return;
    NSArray<CALayer *> *layers = VGKnownPictureLayers();
    if (!layers.count) return;
    if (!VGButtonsWanted() || ![VGPrefs pictures]) {
        for (CALayer *layer in layers) if (VGHasBadge(layer)) VGPlaceBadge(layer, NO, CGRectNull);
        return;
    }
    // videos with a button of their own: their covers get none
    NSMutableArray<NSArray *> *videos = [NSMutableArray new];
    for (AVPlayerLayer *player in VGKnownPlayerLayers()) {
        UIWindow *window = VGHostView(player).window;
        if (!window || !player.player.currentItem) continue;
        CGRect frame = VGLayerFrameInWindow(player, window);
        if (!CGRectIsNull(frame)) [videos addObject:@[window, [NSValue valueWithCGRect:frame]]];
    }
    NSMutableArray<VGPictureSpot *> *spots = [NSMutableArray new];
    for (CALayer *layer in layers) {
        UIWindow *window = VGHostView(layer).window;
        CGRect drawn = CGRectNull;
        BOOL ok = window && layer.bounds.size.width >= kMinSide && layer.bounds.size.height >= kMinSide && VGWindowIsWatched(window)
                  && VGPictureOf(layer, &drawn, NULL) != nil;
        CGRect frame = ok ? VGLayerFrameInWindow(layer, window) : CGRectNull;
        if (ok && CGRectIsNull(frame)) ok = NO;
        for (NSArray *video in ok ? videos : @[]) {
            if (video[0] != window) continue;
            if (VGArea(CGRectIntersection([video[1] CGRectValue], frame)) > 0.5 * VGArea(frame)) { ok = NO; break; }
        }
        if (!ok) {
            if (VGHasBadge(layer)) VGPlaceBadge(layer, NO, CGRectNull);
            continue;
        }
        VGPictureSpot *spot = [VGPictureSpot new];
        spot.layer = layer;
        spot.window = window;
        spot.frame = frame;
        spot.drawn = drawn;
        [spots addObject:spot];
    }
    // a picture that has a smaller one lying on it is a backdrop (a blurred copy behind the photo)
    for (VGPictureSpot *big in spots) {
        for (VGPictureSpot *small in spots) {
            if (small == big || small.window != big.window) continue;
            if (VGArea(small.frame) >= 0.9 * VGArea(big.frame)) continue;
            if (VGArea(CGRectIntersection(small.frame, big.frame)) >= 0.8 * VGArea(small.frame)) { big.backdrop = YES; break; }
        }
    }
    for (VGPictureSpot *spot in spots) VGPlaceBadge(spot.layer, !spot.backdrop, spot.drawn);
}

void VGLayoutPicturesSoon(void) {
    static BOOL pending;
    static CFTimeInterval last;
    if (pending) return;
    pending = YES;
    // pictures arrive in bursts while a feed loads: at most fifteen passes a second
    CFTimeInterval wait = MAX(0, last + 1.0 / 15 - CACurrentMediaTime());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pending = NO;
        last = CACurrentMediaTime();
        VGLayoutPictures();
    });
}

#pragma mark - hooks

static void (*gSetImage)(UIImageView *, SEL, UIImage *);
static void VGSetImage(UIImageView *self, SEL _cmd, UIImage *image) {
    gSetImage(self, _cmd, image);
    if (!NSThread.isMainThread) return;
    CALayer *layer = self.layer;
    BOOL big = VGImageBigEnough(image);
    if (big) VGRememberPicture(layer);
    if (big || VGHasBadge(layer)) VGLayoutPicturesSoon();
}

static void (*gMoveToWindow)(UIImageView *, SEL);
static void VGMoveToWindow(UIImageView *self, SEL _cmd) {
    gMoveToWindow(self, _cmd);
    if (!NSThread.isMainThread || !self.window) return;
    if (VGImageBigEnough(self.image)) {
        VGRememberPicture(self.layer);
        VGLayoutPicturesSoon();
    }
}

static void (*gSetContents)(CALayer *, SEL, id);
static void VGSetContents(CALayer *self, SEL _cmd, id contents) {
    gSetContents(self, _cmd, contents);
    if (!contents || !NSThread.isMainThread) return;
    if (CFGetTypeID((__bridge CFTypeRef)contents) != CGImageGetTypeID()) return;
    CGImageRef picture = (__bridge CGImageRef)contents;
    if (CGImageGetWidth(picture) < kMinPixels || CGImageGetHeight(picture) < kMinPixels) return;
    if (!VGNodeOf(self)) return;                               // a text node, a drawn shape
    VGRememberPicture(self);
    VGLayoutPicturesSoon();
}

void VGPicturesInstall(void) {
    gPictureHooks = 0;
    if (VGHook(UIImageView.class, @selector(setImage:), (IMP)VGSetImage, (IMP *)&gSetImage)) gPictureHooks++;
    if (VGHook(UIImageView.class, @selector(didMoveToWindow), (IMP)VGMoveToWindow, (IMP *)&gMoveToWindow)) gPictureHooks++;
    gImageNodeClass = NSClassFromString(@"ASImageNode");
    Class displayLayer = NSClassFromString(@"_ASDisplayLayer");
    if (gImageNodeClass && displayLayer && VGHook(displayLayer, @selector(setContents:), (IMP)VGSetContents, (IMP *)&gSetContents)) gPictureHooks++;
    VGLog(@"pictures: %ld hooks%@", (long)gPictureHooks, gImageNodeClass ? @" (the app is built with Texture)" : @"");
}

#pragma mark - tests

NSString *VGDescribePictureLayer(CALayer *layer, UIWindow *window) {
    UIView *host = VGHostView(layer);
    CGRect frame = window ? VGLayerFrameInWindow(layer, window) : CGRectNull;
    CGRect badge = window ? VGBadgeFrameInWindow(layer, window) : CGRectNull;
    VGSource *source = VGSourceForPictureLayer(layer);
    id node = VGNodeOf(layer);
    return [NSString stringWithFormat:@"%@%@ in %@: %@; %@; button %@",
            NSStringFromClass(host.class), node ? [NSString stringWithFormat:@" (%@)", NSStringFromClass([node class])] : @"",
            NSStringFromClass(host.superview.class), CGRectIsNull(frame) ? @"not on screen" : NSStringFromCGRect(frame),
            source ? [NSString stringWithFormat:@"%@%@", source.shortName, source.url ? [@" from " stringByAppendingString:source.url.absoluteString] : @""] : @"not a picture VidGrab takes",
            CGRectIsNull(badge) ? @"hidden" : NSStringFromCGRect(badge)];
}

/// Everything in the window drawn as a large image, known to VidGrab or not: for finding out how an app draws its pictures.
void VGLogPictureScan(UIWindow *window) {
    if (!window) return;
    NSHashTable *known = VGPictureTable();
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger seen = 0, listed = 0;
    while (queue.count && seen < 6000) {
        UIView *view = queue.lastObject;
        [queue removeLastObject];
        seen++;
        if (view.isHidden || view.alpha < 0.02) continue;
        for (UIView *child in view.subviews) [queue addObject:child];
        id contents = view.layer.contents;
        BOOL drawnImage = contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID();
        BOOL imageView = [view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image;
        if (!drawnImage && !imageView) continue;
        if (view.bounds.size.width < 80 || view.bounds.size.height < 80) continue;
        CGRect frame = VGLayerFrameInWindow(view.layer, window);
        if (CGRectIsNull(frame)) continue;
        if (listed++ >= 40) break;
        NSMutableArray<NSString *> *chain = [NSMutableArray new];
        for (UIView *up = view.superview; up && chain.count < 4; up = up.superview) [chain addObject:NSStringFromClass(up.class)];
        CGImageRef picture = drawnImage ? (__bridge CGImageRef)contents : ((UIImageView *)view).image.CGImage;
        VGLog(@"    scan: %@ %@ image %zux%zu, %@; known %d; < %@", NSStringFromClass(view.class), NSStringFromCGRect(frame),
              picture ? CGImageGetWidth(picture) : 0, picture ? CGImageGetHeight(picture) : 0,
              VGSourceForPictureLayer(view.layer) ? @"taken" : @"not taken", [known containsObject:view.layer],
              [chain componentsJoinedByString:@" < "]);
    }
    VGLog(@"scan: %lu views looked at, %lu large images on screen; %lu picture layers known", (unsigned long)seen, (unsigned long)listed,
          (unsigned long)known.count);
}

#pragma mark - saving a picture

@interface VGPictureJob : VGJob
@end

@implementation VGPictureJob {
    VGSource *_picture;
    NSString *_folder;
    NSMutableArray<NSString *> *_notes;
    NSURLSession *_session;
    atomic_bool _stopped;
}

- (instancetype)initWithSource:(VGSource *)source {
    if ((self = [super initWithSource:source])) {
        _picture = source;
        _notes = [NSMutableArray new];
    }
    return self;
}

- (BOOL)cancelled { return atomic_load(&_stopped); }
- (NSString *)workFolder { return _folder; }
- (NSString *)report { @synchronized (_notes) { return [_notes componentsJoinedByString:@"; "]; } }
- (void)remark:(NSString *)text { @synchronized (_notes) { [_notes addObject:text]; } }

- (void)cancel {
    atomic_store(&_stopped, true);
    NSURLSession *session;
    @synchronized (self) { session = _session; }
    [session invalidateAndCancel];
}

- (void)cleanUp {
    if (_folder) [NSFileManager.defaultManager removeItemAtPath:_folder error:NULL];
}

- (void)loadVariants:(void (^)(NSArray<VGVariant *> *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ completion(@[], nil); });
}

- (void)stage:(NSString *)text fraction:(double)fraction {
    void (^handler)(double, NSString *) = self.onProgress;
    if (handler) handler(fraction, text);
}

/// The bytes at the address, when it answers with a picture. Blocks.
- (NSData *)fetch:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20];
    [_picture.headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) { [request setValue:value forHTTPHeaderField:key]; }];
    [request setValue:@"image/avif,image/webp,image/heic,image/jpeg,image/png,image/*;q=0.8" forHTTPHeaderField:@"Accept"];
    __block NSData *answer = nil;
    __block NSString *why = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSession *session;
    @synchronized (self) { session = _session; }
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error) why = error.localizedDescription;
        else if (status < 200 || status > 299) why = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        else if ([response.MIMEType hasPrefix:@"text/"]) why = response.MIMEType;
        else answer = data;
        dispatch_semaphore_signal(done);
    }];
    if (!task) return nil;
    [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!answer) [self remark:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent.length ? url.lastPathComponent : url.host, why ?: @"nothing"]];
    return answer;
}

- (void)start:(void (^)(NSURL *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *file = [self run:&error];
        if (!file && self.cancelled) error = VGError(VGErrorCancelled, @"Cancelled.");
        completion(file, file ? nil : (error ?: VGError(VGErrorMedia, @"The picture could not be saved.")));
    });
}

- (NSURL *)run:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    _folder = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"vidgrab-work"]
               stringByAppendingPathComponent:[@"picture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [files createDirectoryAtPath:_folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *name = [@"VidGrab " stringByAppendingString:[stamp stringFromDate:NSDate.date]];
    double shown = (double)_picture.pictureWidth * _picture.pictureHeight;

    NSArray<NSURL *> *candidates = VGPictureCandidateURLs(_picture.url);
    if (candidates.count) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForResource = 60;
        @synchronized (self) { _session = [NSURLSession sessionWithConfiguration:configuration]; }
    }
    NSUInteger tried = 0;
    for (NSURL *url in candidates) {
        if (self.cancelled) return nil;
        [self stage:@"Getting the picture" fraction:0.1 + 0.8 * tried++ / candidates.count];
        NSData *data = [self fetch:url];
        if (!data.length) continue;
        CGImageSourceRef reader = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!reader) continue;
        NSString *type = (__bridge NSString *)CGImageSourceGetType(reader);
        NSDictionary *about = CGImageSourceGetCount(reader) ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(reader, 0, NULL)) : nil;
        double width = [about[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        double height = [about[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        if (width < 1 || height < 1) {
            CFRelease(reader);
            [self remark:[NSString stringWithFormat:@"%@: not a picture", url.host]];
            continue;
        }
        if (shown > 0 && width * height < 0.8 * shown) {                // smaller than what the app shows: keep looking
            CFRelease(reader);
            [self remark:[NSString stringWithFormat:@"%@: %.0fx%.0f, smaller than on screen", url.lastPathComponent, width, height]];
            continue;
        }
        NSDictionary *endings = @{@"public.jpeg": @"jpg", @"public.png": @"png", @"public.heic": @"heic", @"public.heif": @"heif",
                                  @"com.compuserve.gif": @"gif"};
        NSString *ending = type ? endings[type] : nil;
        NSString *path;
        if (ending) {
            path = [_folder stringByAppendingPathComponent:[name stringByAppendingPathExtension:ending]];
            [data writeToFile:path atomically:YES];
        } else {
            // WebP, AVIF and the like: Photos keeps JPEG, PNG, HEIC and GIF; the rest is turned into JPEG
            path = [_folder stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"jpg"]];
            CGImageRef image = CGImageSourceCreateImageAtIndex(reader, 0, NULL);
            CGImageDestinationRef writer = image ? CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.jpeg"), 1, NULL) : NULL;
            if (writer) {
                CGImageDestinationAddImage(writer, image, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.95});
                if (!CGImageDestinationFinalize(writer)) path = nil;
                CFRelease(writer);
            } else {
                path = nil;
            }
            if (image) CGImageRelease(image);
        }
        CFRelease(reader);
        if (!path || ![files fileExistsAtPath:path]) continue;
        [self remark:[NSString stringWithFormat:@"%@ %.0fx%.0f %@ from %@", ending ?: @"jpg (from another kind)", width, height,
                    VGByteString((long long)[[files attributesOfItemAtPath:path error:NULL] fileSize]), url.absoluteString]];
        [self stage:@"Getting the picture" fraction:0.95];
        return [NSURL fileURLWithPath:path];
    }
    if (self.cancelled) return nil;

    // what is on screen, exactly as the app has it
    UIImage *image = _picture.picture;
    if (![image isKindOfClass:UIImage.class]) {
        if (error) *error = VGError(VGErrorMedia, @"The picture is gone from the screen.");
        return nil;
    }
    CGImageAlphaInfo alpha = image.CGImage ? CGImageGetAlphaInfo(image.CGImage) : kCGImageAlphaNone;
    BOOL opaque = alpha == kCGImageAlphaNone || alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast;
    NSData *data = opaque ? UIImageJPEGRepresentation(image, 0.95) : UIImagePNGRepresentation(image);
    NSString *path = [_folder stringByAppendingPathComponent:[name stringByAppendingPathExtension:opaque ? @"jpg" : @"png"]];
    if (!data.length || ![data writeToFile:path atomically:YES]) {
        if (error) *error = VGError(VGErrorStorage, @"The picture could not be written.");
        return nil;
    }
    [self remark:[NSString stringWithFormat:@"as shown: %ldx%ld %@ %@", (long)_picture.pictureWidth, (long)_picture.pictureHeight,
                opaque ? @"jpg" : @"png", VGByteString((long long)data.length)]];
    return [NSURL fileURLWithPath:path];
}

@end

VGJob *VGMakePictureJob(VGSource *source) {
    return [[VGPictureJob alloc] initWithSource:source];
}
