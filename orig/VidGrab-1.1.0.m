//
//  VidGrab — long-press video downloader for X, Instagram, TikTok, YouTube,
//  Reddit, Facebook, Threads, Tumblr, Pinterest, Twitch, WhatsApp & more.
//
//  Version-resilient design: hooks AVFoundation (stable Apple API),
//  never app-internal classes, so app updates don't break it.
//
//  Target: rootless / roothide jailbreaks, iOS 13+
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// CydiaSubstrate entry point — resolved at load time from the host process
// (substrate / ellekit shim is guaranteed loaded, it loaded us).
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);

#define XSLog(...) NSLog(@"[VidGrab] " __VA_ARGS__)

#pragma mark - App / URL matching

static BOOL xs_isSupportedApp(void) {
    static NSSet *bundleIDs = nil;
    static NSSet *execNames = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundleIDs = [NSSet setWithArray:@[
            @"com.atebits.Tweetie2",      // X / Twitter
            @"com.burbn.instagram",       // Instagram
            @"com.burbn.barcelona",       // Threads
            @"com.facebook.Facebook",
            @"com.facebook.Messenger",
            @"com.zhiliaoapp.musically",  // TikTok
            @"com.google.ios.youtube",
            @"com.reddit.Reddit",
            @"com.tumblr.tumblr",
            @"com.pinterest",
            @"tv.twitch",
            @"net.whatsapp.WhatsApp",
            @"net.whatsapp.WhatsAppSMB",
            @"com.linkedin.LinkedIn",
            @"com.vk.vkclient",
            @"com.tellm.jodel",
        ]];
        execNames = [NSSet setWithArray:@[
            @"Twitter", @"X", @"Instagram", @"Barcelona", @"Threads", @"Facebook",
            @"Messenger", @"TikTok", @"YouTube", @"Reddit", @"RedditApp", @"Tumblr",
            @"Pinterest", @"Consumer", @"Twitch", @"WhatsApp", @"LinkedIn", @"Flickr",
            @"VKClient", @"Jodel", @"LIKE",
        ]];
    });
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (bid && [bundleIDs containsObject:bid]) return YES;
    NSString *exec = NSBundle.mainBundle.executableURL.lastPathComponent;
    return exec && [execNames containsObject:exec];
}

static NSArray<NSString *> *xs_videoHosts(void) {
    static NSArray *hosts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[
            @"twimg.com",         // X / Twitter
            @"cdninstagram.com",  // Instagram
            @"fbcdn.net",         // Meta (FB/IG/Threads/Messenger)
            @"fbsbx.com",         // Meta attachments
            @"tiktokcdn.com", @"tiktokcdn-us.com", @"tiktokv.com", @"tiktokv.us",
            @"tiktokd.net", @"tiktokd.org", @"tiktokw.us", @"muscdn.com",
            @"musical.ly", @"bytecdn.com", @"ibyteimg.com",
            @"googlevideo.com",   // YouTube
            @"redd.it",           // v.redd.it
            @"redditmedia.com",
            @"tumblr.com",        // va.media.tumblr.com
            @"pinimg.com",        // Pinterest
            @"twitch.tv", @"ttvnw.net", @"jtvnw.net",
            @"licdn.com",         // LinkedIn
            @"staticflickr.com", @"flickr.com",
            @"vk.com", @"vk-cdn.net", @"mycdn.me", @"userapi.com",
            @"likee.video", @"like.video", @"b-cdn.net",
        ];
    });
    return hosts;
}

static BOOL xs_isVideoURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    NSString *ext = url.pathExtension.lowercaseString;

    if ([scheme isEqualToString:@"file"]) {
        // WhatsApp statuses & other local media the app is already playing
        static NSSet *fileExts = nil;
        static dispatch_once_t fonce;
        dispatch_once(&fonce, ^{ fileExts = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"3gp"]]; });
        return [fileExts containsObject:ext];
    }

    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;

    NSString *host = url.host.lowercaseString ?: @"";
    for (NSString *suffix in xs_videoHosts()) {
        if ([host hasSuffix:suffix]) return YES;
    }
    // generic fallback: video-ish extension on any CDN
    static NSSet *netExts = nil;
    static dispatch_once_t nonce;
    dispatch_once(&nonce, ^{ netExts = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"m3u8", @"mpd", @"webm"]]; });
    return [netExts containsObject:ext];
}

#pragma mark - URL registry

static NSMapTable<AVPlayerItem *, NSString *> *xs_itemURLs;   // item -> url (fallback)
static NSMutableArray<NSDictionary *> *xs_recentURLs;          // @{url, date}

static void xs_recordURL(NSURL *url, AVPlayerItem *item) {
    if (!xs_isVideoURL(url)) return;
    @synchronized (xs_recentURLs) {
        NSString *s = url.absoluteString;
        for (NSDictionary *d in xs_recentURLs) {
            if ([d[@"url"] isEqualToString:s]) {
                [xs_recentURLs removeObject:d];
                break;
            }
        }
        [xs_recentURLs insertObject:@{@"url": s, @"date": [NSDate date]} atIndex:0];
        while (xs_recentURLs.count > 40) [xs_recentURLs removeLastObject];
    }
    if (item) {
        @synchronized (xs_itemURLs) {
            [xs_itemURLs setObject:url.absoluteString forKey:item];
        }
    }
    XSLog(@"captured %@", url.absoluteString);
}

static NSString *xs_urlForItem(AVPlayerItem *item) {
    if (!item) return nil;
    AVAsset *asset = item.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        NSURL *u = ((AVURLAsset *)asset).URL;
        if (xs_isVideoURL(u)) return u.absoluteString;
    }
    NSString *s = nil;
    @synchronized (xs_itemURLs) { s = [xs_itemURLs objectForKey:item]; }
    return s;
}

static NSString *xs_mostRecentURL(NSTimeInterval maxAge) {
    @synchronized (xs_recentURLs) {
        if (xs_recentURLs.count == 0) return nil;
        NSDictionary *d = xs_recentURLs.firstObject;
        if ([[NSDate date] timeIntervalSinceDate:d[@"date"]] <= maxAge) return d[@"url"];
    }
    return nil;
}

#pragma mark - AVFoundation hooks

static id (*orig_itemInitWithURL)(AVPlayerItem *, SEL, NSURL *);
static id hook_itemInitWithURL(AVPlayerItem *self, SEL _cmd, NSURL *url) {
    self = orig_itemInitWithURL(self, _cmd, url);
    if (self) xs_recordURL(url, self);
    return self;
}

static id (*orig_itemWithURL)(id, SEL, NSURL *);
static id hook_playerItemWithURL(id self, SEL _cmd, NSURL *url) {
    AVPlayerItem *item = orig_itemWithURL(self, _cmd, url);
    if (item) xs_recordURL(url, item);
    return item;
}

static id (*orig_itemInitWithAsset)(AVPlayerItem *, SEL, AVAsset *);
static id hook_itemInitWithAsset(AVPlayerItem *self, SEL _cmd, AVAsset *asset) {
    self = orig_itemInitWithAsset(self, _cmd, asset);
    if (self && [asset isKindOfClass:[AVURLAsset class]]) xs_recordURL(((AVURLAsset *)asset).URL, self);
    return self;
}

static id (*orig_itemWithAsset)(id, SEL, AVAsset *);
static id hook_playerItemWithAsset(id self, SEL _cmd, AVAsset *asset) {
    AVPlayerItem *item = orig_itemWithAsset(self, _cmd, asset);
    if (item && [asset isKindOfClass:[AVURLAsset class]]) xs_recordURL(((AVURLAsset *)asset).URL, item);
    return item;
}

static id (*orig_assetInitWithURL)(id, SEL, NSURL *, NSDictionary *);
static id hook_assetInitWithURL(id self, SEL _cmd, NSURL *url, NSDictionary *options) {
    self = orig_assetInitWithURL(self, _cmd, url, options);
    if (self) xs_recordURL(url, nil);
    return self;
}

#pragma mark - HUD

@interface VGHUD : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIProgressView *bar;
+ (instancetype)shared;
+ (void)showText:(NSString *)text;
+ (void)showProgress:(float)progress text:(NSString *)text;
+ (void)succeed:(NSString *)text;
+ (void)fail:(NSString *)text;
+ (void)hide;
@end

@implementation VGHUD

+ (instancetype)shared {
    static VGHUD *hud = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hud = [[VGHUD alloc] initWithFrame:CGRectMake(0, 0, 240, 86)];
    });
    return hud;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;

        _label = [[UILabel alloc] initWithFrame:CGRectMake(12, 14, 216, 40)];
        _label.textColor = UIColor.whiteColor;
        _label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 2;
        [self addSubview:_label];

        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.frame = CGRectMake(20, 62, 200, 4);
        _bar.progressTintColor = [UIColor colorWithRed:0.11 green:0.63 blue:0.95 alpha:1];
        _bar.hidden = YES;
        [self addSubview:_bar];
    }
    return self;
}

+ (UIWindow *)vg_mainWindow {
    UIApplication *app = UIApplication.sharedApplication;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
#pragma clang diagnostic pop
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.windows.firstObject;
#pragma clang diagnostic pop
}

+ (void)presentOnWindow:(void (^)(VGHUD *))block {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self vg_mainWindow];
        if (!win) return;
        VGHUD *hud = [self shared];
        if (hud.superview != win) {
            [hud removeFromSuperview];
            [win addSubview:hud];
        }
        hud.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height / 2);
        hud.alpha = 0;
        [UIView animateWithDuration:0.15 animations:^{ hud.alpha = 1; }];
        block(hud);
    });
}

+ (void)showText:(NSString *)text {
    [self presentOnWindow:^(VGHUD *hud) {
        hud.label.text = text;
        hud.bar.hidden = YES;
        hud.bar.progress = 0;
    }];
}

+ (void)showProgress:(float)progress text:(NSString *)text {
    [self presentOnWindow:^(VGHUD *hud) {
        hud.label.text = text;
        hud.bar.hidden = NO;
        [hud.bar setProgress:progress animated:YES];
    }];
}

+ (void)finishWithText:(NSString *)text success:(BOOL)success {
    [self presentOnWindow:^(VGHUD *hud) {
        hud.label.text = text;
        hud.bar.hidden = YES;
        hud.backgroundColor = success ? [UIColor colorWithRed:0.1 green:0.65 blue:0.35 alpha:0.92]
                                      : [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.92];
        if (success) {
            UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [gen impactOccurred];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self hide];
            hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        });
    }];
}

+ (void)succeed:(NSString *)text { [self finishWithText:text success:YES]; }
+ (void)fail:(NSString *)text    { [self finishWithText:text success:NO];  }

+ (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ [self shared].alpha = 0; }
                         completion:^(BOOL f) { [[self shared] removeFromSuperview]; }];
    });
}

@end

#pragma mark - HLS pipeline (recursive — handles split audio via EXT-X-MEDIA)

@interface VGHLSDownloader : NSObject
+ (void)downloadMasterPlaylist:(NSString *)urlString completion:(void (^)(NSArray<NSDictionary *> *variants, NSError *error))completion;
+ (void)downloadHLSSegmentsFromPlaylistURL:(NSURL *)playlistURL completion:(void (^)(NSURL *localPlaylist, NSString *workDir, NSError *error))completion;
+ (void)exportLocalPlaylist:(NSURL *)playlistURL workDir:(NSString *)workDir completion:(void (^)(NSURL *mp4URL, NSError *error))completion;
@end

@implementation VGHLSDownloader

+ (NSURLSession *)session {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 600;
        cfg.HTTPAdditionalHeaders = @{@"User-Agent": @"VidGrab/1.1 (iPhone)"};
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

+ (NSError *)errorWithMessage:(NSString *)msg code:(NSInteger)code {
    return [NSError errorWithDomain:@"VidGrab" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// Parse a master playlist into variants: @{@"url":..., @"resolution":..., @"bandwidth":...}
+ (void)downloadMasterPlaylist:(NSString *)urlString completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { completion(nil, [self errorWithMessage:@"Bad URL" code:1]); return; }
    [[[self session] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) { completion(nil, err ?: [self errorWithMessage:@"Network error" code:2]); return; }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
        NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSMutableDictionary *pending = nil;
        for (NSString *raw in lines) {
            NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([line hasPrefix:@"#EXT-X-STREAM-INF"]) {
                NSMutableDictionary *info = [NSMutableDictionary dictionary];
                NSRange b = [line rangeOfString:@"BANDWIDTH="];
                if (b.location != NSNotFound) {
                    NSScanner *sc = [NSScanner scannerWithString:[line substringFromIndex:b.location + b.length]];
                    long long bw = 0; [sc scanLongLong:&bw];
                    info[@"bandwidth"] = @(bw);
                }
                NSRange r = [line rangeOfString:@"RESOLUTION="];
                if (r.location != NSNotFound) {
                    NSString *rest = [line substringFromIndex:r.location + r.length];
                    NSRange end = [rest rangeOfString:@","];
                    info[@"resolution"] = end.location != NSNotFound ? [rest substringToIndex:end.location] : rest;
                }
                pending = info;
            } else if (pending && line.length > 0 && ![line hasPrefix:@"#"]) {
                NSURL *u = [NSURL URLWithString:line relativeToURL:url];
                pending[@"url"] = u.absoluteString;
                [variants addObject:pending];
                pending = nil;
            }
        }
        [variants sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"bandwidth"] compare:a[@"bandwidth"]];
        }];
        if (variants.count == 0) {
            // not a master playlist — it's already a media playlist
            completion(@[@{@"url": urlString, @"resolution": @"Auto", @"bandwidth": @0}], nil);
        } else {
            completion(variants, nil);
        }
    }] resume];
}

// Download one media playlist (segments + EXT-X-MAP init + EXT-X-MEDIA sub-playlists)
// into workDir, rewrite all URIs to local files, write as <baseName>.m3u8.
+ (void)processPlaylistAtURL:(NSURL *)playlistURL
                     workDir:(NSString *)workDir
                    baseName:(NSString *)baseName
                     isAudio:(BOOL)isAudio
                  completion:(void (^)(NSError *error))completion {
    [[[self session] dataTaskWithURL:playlistURL completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            completion(err ?: [self errorWithMessage:@"Failed to fetch playlist" code:3]);
            return;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

        if ([text containsString:@"EXT-X-KEY:METHOD=AES"] || [text containsString:@"EXT-X-KEY: METHOD=AES"]) {
            completion([self errorWithMessage:@"Encrypted stream not supported" code:4]);
            return;
        }
        if (![text containsString:@"#EXT-X-ENDLIST"]) {
            completion([self errorWithMessage:@"Live streams not supported" code:5]);
            return;
        }

        NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSMutableArray<NSString *> *segmentURIs = [NSMutableArray array];
        NSString *mapURI = nil;
        NSMutableArray<NSString *> *mediaURIs = [NSMutableArray array];      // unique, in order
        NSMutableSet *seenMediaURIs = [NSMutableSet set];

        for (NSString *raw in lines) {
            NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([line hasPrefix:@"#EXT-X-MAP"]) {
                NSRange r = [line rangeOfString:@"URI=\""];
                if (r.location != NSNotFound) {
                    NSString *rest = [line substringFromIndex:r.location + r.length];
                    NSRange end = [rest rangeOfString:@"\""];
                    if (end.location != NSNotFound) mapURI = [rest substringToIndex:end.location];
                }
            } else if ([line hasPrefix:@"#EXT-X-MEDIA"]) {
                NSRange r = [line rangeOfString:@"URI=\""];
                if (r.location != NSNotFound) {
                    NSString *rest = [line substringFromIndex:r.location + r.length];
                    NSRange end = [rest rangeOfString:@"\""];
                    if (end.location != NSNotFound) {
                        NSString *uri = [rest substringToIndex:end.location];
                        if (![seenMediaURIs containsObject:uri]) {
                            [seenMediaURIs addObject:uri];
                            [mediaURIs addObject:uri];
                        }
                    }
                }
            } else if (line.length > 0 && ![line hasPrefix:@"#"]) {
                [segmentURIs addObject:line];
            }
        }

        if (segmentURIs.count == 0 && !mapURI) {
            completion([self errorWithMessage:@"No segments found" code:6]);
            return;
        }

        NSString *label = isAudio ? @"Downloading audio" : @"Downloading";
        NSMutableArray<NSError *> *errors = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        __block NSInteger doneCount = 0;
        NSObject *lock = [[NSObject alloc] init];

        // init segment (fMP4)
        NSString *mapFileName = nil;
        if (mapURI) {
            NSURL *u = [NSURL URLWithString:mapURI relativeToURL:playlistURL];
            NSString *ext = u.pathExtension.length ? u.pathExtension : @"mp4";
            mapFileName = [NSString stringWithFormat:@"%@_map.%@", baseName, ext];
            NSString *dest = [workDir stringByAppendingPathComponent:mapFileName];
            dispatch_group_enter(group);
            [[[self session] downloadTaskWithURL:u completionHandler:^(NSURL *location, NSURLResponse *r, NSError *e) {
                @synchronized (lock) {
                    if (!e && location) [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:nil];
                    else [errors addObject:e ?: [self errorWithMessage:@"init segment failed" code:7]];
                }
                dispatch_group_leave(group);
            }] resume];
        }

        // media segments
        for (NSUInteger i = 0; i < segmentURIs.count; i++) {
            NSURL *segURL = [NSURL URLWithString:segmentURIs[i] relativeToURL:playlistURL];
            NSString *ext = segURL.pathExtension.length ? segURL.pathExtension : @"ts";
            NSString *fileName = [NSString stringWithFormat:@"%@_seg_%05lu.%@", baseName, (unsigned long)i, ext];
            NSString *dest = [workDir stringByAppendingPathComponent:fileName];

            dispatch_group_enter(group);
            [[[self session] downloadTaskWithURL:segURL completionHandler:^(NSURL *location, NSURLResponse *r, NSError *e) {
                @synchronized (lock) {
                    if (!e && location) {
                        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:nil];
                    } else {
                        [errors addObject:e ?: [self errorWithMessage:@"segment failed" code:8]];
                    }
                    doneCount++;
                    if (!isAudio) {
                        float p = 0.05f + 0.6f * ((float)doneCount / (float)MAX(segmentURIs.count, 1));
                        [VGHUD showProgress:p text:[NSString stringWithFormat:@"%@ (%ld/%lu)", label, (long)doneCount, (unsigned long)segmentURIs.count]];
                    }
                }
                dispatch_group_leave(group);
            }] resume];
        }

        // sub-playlists (e.g. separate audio track on Reddit / some X streams)
        NSMutableArray<dispatch_group_t> *noUnused = nil; (void)noUnused;
        dispatch_group_t subGroup = dispatch_group_create();
        for (NSUInteger i = 0; i < mediaURIs.count; i++) {
            NSURL *subURL = [NSURL URLWithString:mediaURIs[i] relativeToURL:playlistURL];
            NSString *subBase = [NSString stringWithFormat:@"%@_sub_%lu", baseName, (unsigned long)i];
            dispatch_group_enter(subGroup);
            [self processPlaylistAtURL:subURL workDir:workDir baseName:subBase isAudio:YES completion:^(NSError *e) {
                @synchronized (lock) { if (e) [errors addObject:e]; }
                dispatch_group_leave(subGroup);
            }];
        }

        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_group_notify(subGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (errors.count > 0) {
                    completion([self errorWithMessage:[NSString stringWithFormat:@"Failed to download %lu parts", (unsigned long)errors.count] code:9]);
                    return;
                }
                // Rewrite playlist with local file names
                NSMutableString *out = [NSMutableString string];
                NSUInteger segIndex = 0, subIndex = 0;
                for (NSString *raw in lines) {
                    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if ([line hasPrefix:@"#EXT-X-MAP"] && mapFileName) {
                        [out appendFormat:@"#EXT-X-MAP:URI=\"%@\"\n", mapFileName];
                    } else if ([line hasPrefix:@"#EXT-X-MEDIA"] && [line containsString:@"URI=\""]) {
                        // point to the local sub-playlist (match by URI)
                        NSRange r = [line rangeOfString:@"URI=\""];
                        NSString *rest = [line substringFromIndex:r.location + r.length];
                        NSRange end = [rest rangeOfString:@"\""];
                        NSString *uri = [rest substringToIndex:end.location];
                        NSUInteger idx = [mediaURIs indexOfObject:uri];
                        NSString *subFile = [NSString stringWithFormat:@"%@_sub_%lu.m3u8", baseName, (unsigned long)idx];
                        [out appendFormat:@"%@URI=\"%@\"%@\n",
                            [line substringToIndex:r.location + r.length], subFile,
                            [line substringFromIndex:r.location + r.length + uri.length + 1]];
                        (void)subIndex;
                    } else if (line.length > 0 && ![line hasPrefix:@"#"]) {
                        NSURL *segURL = [NSURL URLWithString:line relativeToURL:playlistURL];
                        NSString *ext = segURL.pathExtension.length ? segURL.pathExtension : @"ts";
                        [out appendFormat:@"%@_seg_%05lu.%@\n", baseName, (unsigned long)segIndex, ext];
                        segIndex++;
                    } else {
                        [out appendFormat:@"%@\n", raw];
                    }
                }
                NSString *path = [workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m3u8", baseName]];
                [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                completion(nil);
            });
        });
    }] resume];
}

+ (void)downloadHLSSegmentsFromPlaylistURL:(NSURL *)playlistURL completion:(void (^)(NSURL *, NSString *, NSError *))completion {
    NSString *workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"vidgrab_%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil];

    [self processPlaylistAtURL:playlistURL workDir:workDir baseName:@"local" isAudio:NO completion:^(NSError *error) {
        if (error) {
            completion(nil, workDir, error);
            return;
        }
        completion([NSURL fileURLWithPath:[workDir stringByAppendingPathComponent:@"local.m3u8"]], workDir, nil);
    }];
}

+ (void)exportLocalPlaylist:(NSURL *)playlistURL workDir:(NSString *)workDir completion:(void (^)(NSURL *, NSError *))completion {
    [VGHUD showProgress:0.7 text:@"Converting…"];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:playlistURL options:nil];

    NSArray *presets = @[AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality];
    __block NSUInteger presetIndex = 0;

    __block void (^tryExport)(void) = nil;
    void (^__weak weakTry)(void);
    tryExport = ^{
        if (presetIndex >= presets.count) {
            completion(nil, [self errorWithMessage:@"Export failed" code:10]);
            tryExport = nil;
            return;
        }
        NSString *preset = presets[presetIndex];
        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
        if (!exporter) { presetIndex++; weakTry(); return; }
        NSURL *outURL = [NSURL fileURLWithPath:[workDir stringByAppendingPathComponent:@"out.mp4"]];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
        exporter.outputURL = outURL;
        exporter.outputFileType = AVFileTypeMPEG4;
        exporter.shouldOptimizeForNetworkUse = NO;

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            [VGHUD showProgress:0.7f + 0.25f * exporter.progress text:@"Converting…"];
        }];

        [exporter exportAsynchronouslyWithCompletionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{ [timer invalidate]; });
            if (exporter.status == AVAssetExportSessionStatusCompleted) {
                completion(outURL, nil);
                tryExport = nil;
            } else {
                XSLog(@"export preset %@ failed: %@", preset, exporter.error);
                presetIndex++;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ weakTry(); });
            }
        }];
    };
    weakTry = tryExport;
    tryExport();
}

@end

#pragma mark - Download controller

@interface VGDownloadManager : NSObject
+ (void)startWithURLString:(NSString *)urlString;
+ (void)downloadHLS:(NSURL *)playlistURL;
@end

@implementation VGDownloadManager

+ (void)saveVideoAtURL:(NSURL *)fileURL workDir:(NSString *)workDir {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.0, *)) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
                [self saveVideoAtURL:fileURL workDir:workDir status:status];
            }];
        } else {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
                [self saveVideoAtURL:fileURL workDir:workDir status:status];
            }];
        }
    });
}

+ (void)saveVideoAtURL:(NSURL *)fileURL workDir:(NSString *)workDir status:(PHAuthorizationStatus)status {
    BOOL authorized = (status == PHAuthorizationStatusAuthorized);
    if (@available(iOS 14.0, *)) {
        authorized = authorized || (status == PHAuthorizationStatusLimited);
    }
    if (!authorized) {
        [VGHUD fail:@"Allow Photos access in Settings"];
        if (workDir) [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return;
    }
    [VGHUD showProgress:0.97 text:@"Saving to Photos…"];
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
        [req addResourceWithType:PHAssetResourceTypeVideo fileURL:fileURL options:nil];
    } completionHandler:^(BOOL success, NSError *error) {
        if (success) {
            [VGHUD succeed:@"Saved to Photos ✓"];
        } else {
            XSLog(@"photos save error: %@", error);
            [VGHUD fail:@"Failed to save"];
        }
        if (workDir) [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
    }];
}

+ (void)startWithURLString:(NSString *)urlString {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [VGHUD showProgress:0.02 text:@"Fetching info…"];
        NSURL *url = [NSURL URLWithString:urlString];

        // Local file (e.g. WhatsApp status) — copy straight to Photos
        if (url.isFileURL) {
            [self copyLocalFile:url];
            return;
        }

        NSString *host = url.host.lowercaseString ?: @"";
        NSString *path = url.path ?: @"";

        // Reddit serves DASH by default; rewrite to the HLS rendition we can remux
        if ([host isEqualToString:@"v.redd.it"]) {
            NSArray *comps = url.pathComponents;
            if (comps.count > 1) {
                NSURLComponents *uc = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
                uc.path = [NSString stringWithFormat:@"/%@/HLSPlaylist.m3u8", comps[1]];
                uc.query = nil;
                if (uc.URL) {
                    url = uc.URL;
                    path = url.path;
                }
            }
        }

        BOOL isPlaylist = [[path pathExtension].lowercaseString isEqualToString:@"m3u8"];
        if (!isPlaylist) {
            [self downloadDirect:url];
            return;
        }

        // HLS: resolve best variant from the master playlist
        [VGHLSDownloader downloadMasterPlaylist:url.absoluteString completion:^(NSArray<NSDictionary *> *variants, NSError *error) {
            if (error || variants.count == 0) {
                [VGHUD fail:@"Couldn't read stream info"];
                return;
            }
            // best = highest bandwidth (sorted), or the media playlist itself
            [self downloadHLS:[NSURL URLWithString:variants.firstObject[@"url"]]];
        }];
    });
}

+ (void)copyLocalFile:(NSURL *)url {
    NSString *workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"vidgrab_%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *ext = url.pathExtension.length ? url.pathExtension : @"mp4";
    NSURL *dest = [NSURL fileURLWithPath:[workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"video.%@", ext]]];
    NSError *err = nil;
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:dest error:&err];
    if (err) {
        [VGHUD fail:@"Couldn't read file"];
        [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
        return;
    }
    [VGHUD showProgress:0.6 text:@"Saving…"];
    [self saveVideoAtURL:dest workDir:workDir];
}

+ (void)downloadHLS:(NSURL *)playlistURL {
    [VGHUD showProgress:0.05 text:@"Downloading video…"];
    [VGHLSDownloader downloadHLSSegmentsFromPlaylistURL:playlistURL
        completion:^(NSURL *localPlaylist, NSString *workDir, NSError *error) {
        if (error || !localPlaylist) {
            [VGHUD fail:error.localizedDescription ?: @"Download failed"];
            if (workDir) [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
            return;
        }
        [VGHLSDownloader exportLocalPlaylist:localPlaylist workDir:workDir completion:^(NSURL *mp4URL, NSError *err) {
            if (err || !mp4URL) {
                [VGHUD fail:@"Conversion failed"];
                if (workDir) [[NSFileManager defaultManager] removeItemAtPath:workDir error:nil];
                return;
            }
            [self saveVideoAtURL:mp4URL workDir:workDir];
        }];
    }];
}

+ (void)downloadDirect:(NSURL *)url {
    [VGHUD showProgress:0.02 text:@"Downloading…"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForResource = 600;
    cfg.HTTPAdditionalHeaders = @{@"User-Agent": @"VidGrab/1.1 (iPhone)"};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *error) {
        if (error || !location) {
            [VGHUD fail:@"Download failed"];
            return;
        }
        NSString *workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"vidgrab_%@", NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *ext = url.pathExtension.length ? url.pathExtension : @"mp4";
        NSURL *dest = [NSURL fileURLWithPath:[workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"video.%@", ext]]];
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:dest error:nil];
        [VGHUD showProgress:0.95 text:@"Saving…"];
        [self saveVideoAtURL:dest workDir:workDir];
    }];
    [task resume];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (task.state == NSURLSessionTaskStateRunning) {
            float p = task.countOfBytesExpectedToReceive > 0
                ? (float)((double)task.countOfBytesReceived / (double)task.countOfBytesExpectedToReceive)
                : 0.1f;
            [VGHUD showProgress:0.05f + 0.85f * p text:@"Downloading…"];
            [NSThread sleepForTimeInterval:0.3];
        }
    });
}

@end

#pragma mark - Gesture handling & UI

@interface VGGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
@end

static UIViewController *vg_topViewController(UIViewController *vc) {
    while (vc.presentedViewController) vc = vg_topViewController(vc.presentedViewController);
    if ([vc isKindOfClass:[UINavigationController class]]) return vg_topViewController(((UINavigationController *)vc).visibleViewController);
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
        if (sel) return vg_topViewController(sel);
    }
    return vc;
}

static void vg_collectPlayerLayers(CALayer *layer, CALayer *root, CGPoint point, NSMutableArray<AVPlayerLayer *> *hits, NSMutableArray<AVPlayerLayer *> *all) {
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *pl = (AVPlayerLayer *)layer;
        if (pl.player) {
            [all addObject:pl];
            CGRect f = [layer convertRect:layer.bounds toLayer:root];
            if (CGRectContainsPoint(f, point)) [hits addObject:pl];
        }
    }
    for (CALayer *sub in layer.sublayers) vg_collectPlayerLayers(sub, root, point, hits, all);
}

@implementation VGGestureHandler

+ (instancetype)shared {
    static VGGestureHandler *h = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [[VGGestureHandler alloc] init]; });
    return h;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIWindow *window = [gesture.view isKindOfClass:[UIWindow class]] ? (UIWindow *)gesture.view : gesture.view.window;
    if (!window) return;
    CGPoint point = [gesture locationInView:window];

    NSMutableArray<AVPlayerLayer *> *hits = [NSMutableArray array];
    NSMutableArray<AVPlayerLayer *> *all = [NSMutableArray array];
    vg_collectPlayerLayers(window.layer, window.layer, point, hits, all);

    NSString *urlString = nil;

    // 1) player layer under the finger with a capturable URL
    for (AVPlayerLayer *pl in hits) {
        NSString *u = xs_urlForItem(pl.player.currentItem);
        if (u) { urlString = u; break; }
    }
    // 2) any currently-playing player with a capturable URL
    if (!urlString) {
        for (AVPlayerLayer *pl in all) {
            if (pl.player.rate > 0) {
                NSString *u = xs_urlForItem(pl.player.currentItem);
                if (u) { urlString = u; break; }
            }
        }
    }
    // 3) player under finger + a very recent capture
    if (!urlString && hits.count > 0) {
        urlString = xs_mostRecentURL(15);
    }

    if (!urlString) return; // not a video area — stay silent

    XSLog(@"long-press download: %@", urlString);
    [self presentOptionsForURLString:urlString inWindow:window atPoint:point];
}

- (void)presentOptionsForURLString:(NSString *)urlString inWindow:(UIWindow *)window atPoint:(CGPoint)point {
    UIViewController *vc = vg_topViewController(window.rootViewController);
    if (!vc) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VidGrab"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Download Video" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [VGDownloadManager startWithURLString:urlString];
    }]];

    NSURL *u = [NSURL URLWithString:urlString];
    BOOL isPlaylist = [u.path.pathExtension.lowercaseString isEqualToString:@"m3u8"];
    if (isPlaylist) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Choose Quality…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self presentQualityPickerForURLString:urlString viewController:vc window:window point:point];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Link" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = urlString;
        [VGHUD succeed:@"Link copied"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.sourceView = window;
    alert.popoverPresentationController.sourceRect = CGRectMake(point.x, point.y, 1, 1);
    [vc presentViewController:alert animated:YES completion:nil];
}

- (void)presentQualityPickerForURLString:(NSString *)urlString viewController:(UIViewController *)vc window:(UIWindow *)window point:(CGPoint)point {
    [VGHUD showText:@"Fetching qualities…"];
    [VGHLSDownloader downloadMasterPlaylist:urlString completion:^(NSArray<NSDictionary *> *variants, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VGHUD hide];
            if (error || variants.count == 0) {
                [VGHUD fail:@"Couldn't read qualities"];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Quality"
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *v in variants) {
                NSString *res = v[@"resolution"] ?: @"Auto";
                double mbps = [v[@"bandwidth"] doubleValue] / 1000000.0;
                NSString *title = mbps > 0 ? [NSString stringWithFormat:@"%@  (%.1f Mbps)", res, mbps] : res;
                [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    [VGDownloadManager downloadHLS:[NSURL URLWithString:v[@"url"]]];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            alert.popoverPresentationController.sourceView = window;
            alert.popoverPresentationController.sourceRect = CGRectMake(point.x, point.y, 1, 1);
            UIViewController *top = vg_topViewController(window.rootViewController);
            [top presentViewController:alert animated:YES completion:nil];
        });
    }];
}

@end

#pragma mark - Window hook (attach gesture lazily)

static char kVGGestureAttachedKey;

static void (*orig_sendEvent)(UIWindow *, SEL, UIEvent *);
static void hook_sendEvent(UIWindow *self, SEL _cmd, UIEvent *event) {
    if (!objc_getAssociatedObject(self, &kVGGestureAttachedKey)) {
        objc_setAssociatedObject(self, &kVGGestureAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[VGGestureHandler shared]
                                                                                         action:@selector(handleLongPress:)];
        lp.minimumPressDuration = 0.55;
        lp.allowableMovement = 40;
        lp.cancelsTouchesInView = NO;
        lp.delaysTouchesBegan = NO;
        lp.delegate = [VGGestureHandler shared];
        [self addGestureRecognizer:lp];
    }
    orig_sendEvent(self, _cmd, event);
}

#pragma mark - Constructor

__attribute__((constructor))
static void vidgrab_init(void) {
    @autoreleasepool {
        if (!xs_isSupportedApp()) return;

        xs_itemURLs = [NSMapTable weakToStrongObjectsMapTable];
        xs_recentURLs = [NSMutableArray array];

        // Make sure AVFoundation is loaded so the classes exist
        dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);

        Class itemCls = objc_getClass("AVPlayerItem");
        Class itemMeta = object_getClass((id)itemCls);
        Class assetCls = objc_getClass("AVURLAsset");
        Class windowCls = objc_getClass("UIWindow");

        if (!itemCls || !assetCls || !windowCls) {
            XSLog(@"required classes missing, tweak disabled");
            return;
        }

        MSHookMessageEx(itemCls, @selector(initWithURL:), (IMP)hook_itemInitWithURL, (IMP *)&orig_itemInitWithURL);
        MSHookMessageEx(itemMeta, @selector(playerItemWithURL:), (IMP)hook_playerItemWithURL, (IMP *)&orig_itemWithURL);
        MSHookMessageEx(itemCls, @selector(initWithAsset:), (IMP)hook_itemInitWithAsset, (IMP *)&orig_itemInitWithAsset);
        MSHookMessageEx(itemMeta, @selector(playerItemWithAsset:), (IMP)hook_playerItemWithAsset, (IMP *)&orig_itemWithAsset);
        MSHookMessageEx(assetCls, @selector(initWithURL:options:), (IMP)hook_assetInitWithURL, (IMP *)&orig_assetInitWithURL);
        MSHookMessageEx(windowCls, @selector(sendEvent:), (IMP)hook_sendEvent, (IMP *)&orig_sendEvent);

        XSLog(@"hooks installed (VidGrab 1.1.0) in %@", NSBundle.mainBundle.bundleIdentifier);
    }
}
