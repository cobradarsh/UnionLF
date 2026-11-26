// VidGrab 2 — shared declarations.
//
// The library goes into apps that play video. It hooks three AVFoundation methods and nothing
// that belongs to an app, so app updates do not break it:
//   -[AVURLAsset initWithURL:options:]   remembers the request headers an app plays a video with
//   -[AVPlayerLayer setPlayer:]          learns which layers show video
//   -[AVPlayerLayer layoutSublayers]     keeps the download button in its corner
// Everything else works through notifications and gesture recognizers.
//
// The engine (VGPlaylist, VGFetch, VGTS, VGMux, VGJob) uses Foundation, AVFoundation and
// CoreMedia only: tests/engine_test.m runs it on a Mac and in the simulator against real streams.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

#define VG_VERSION @"2.2.0"

#pragma mark - core (VGCore.m)

/// The jailbreak's root folder as this process sees it ("" when it cannot be told).
NSString *VGRoot(void);
/// Where tests keep their marker, command file and settings (nil outside tests).
NSString *_Nullable VGTestFolder(void);
void VGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
BOOL VGLogging(void);
/// Replaces an instance method with the Objective-C runtime alone.
BOOL VGHook(Class _Nullable cls, SEL sel, IMP replacement, IMP _Nullable *_Nonnull original);
NSError *VGError(NSInteger code, NSString *message);
NSString *VGByteString(long long bytes);

typedef NS_ENUM(NSInteger, VGErrorCode) {
    VGErrorCancelled = 1,
    VGErrorNetwork,
    VGErrorPlaylist,
    VGErrorProtected,
    VGErrorLive,
    VGErrorUnsupported,
    VGErrorMedia,
    VGErrorStorage,
    VGErrorPermission,
};

@interface VGPrefs : NSObject
+ (void)reload;
+ (BOOL)enabled;            // master switch and this app's switch
+ (BOOL)badge;              // the download button on videos
+ (BOOL)pictures;           // the download button on pictures
+ (NSInteger)badgeCorner;   // 0 top left, 1 top right, 2 bottom left, 3 bottom right (Automatic already worked out)
+ (NSInteger)holdFingers;   // 0 off, 1, 2
+ (double)holdTime;
+ (BOOL)blockAppHold;       // stop the app's own hold action when VidGrab takes the hold
+ (NSInteger)action;        // 0 menu, 1 save to Photos, 2 share, 3 GIF Stash
+ (NSInteger)maxHeight;     // 0 = best there is
+ (BOOL)album;
+ (BOOL)haptic;
@end
extern NSString *const VGPrefsChangedNotification;      // in this process, on the main queue

#pragma mark - playlists (VGPlaylist.m)

@interface VGVariant : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) long long bandwidth;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic, copy, nullable) NSString *codecs;
@property (nonatomic, copy, nullable) NSString *audioGroup;
/// The shorter side: what "720p" means for upright and wide videos alike.
@property (nonatomic, readonly) NSInteger lines;
@property (nonatomic, readonly) BOOL playableEverywhere;     // H.264 or unknown
@property (nonatomic, readonly) BOOL decodable;              // not AV1 / VP9
@property (nonatomic, readonly) NSString *title;             // "1080p · H.264 · 5.2 Mbps"
@end

@interface VGRendition : NSObject                            // an audio rendition
@property (nonatomic, copy) NSString *groupID;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic) BOOL isDefault;
@property (nonatomic, strong, nullable) NSURL *url;          // nil: the sound is inside the variant
@end

@interface VGMaster : NSObject
@property (nonatomic, copy) NSArray<VGVariant *> *variants; // best first
@property (nonatomic, copy) NSArray<VGRendition *> *audio;
@end

/// One stretch of bytes of one file on the server.
@interface VGPiece : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) long long offset;                      // -1: the whole file
@property (nonatomic) long long length;
@end

@interface VGMedia : NSObject
@property (nonatomic, copy) NSArray<VGPiece *> *segments;
@property (nonatomic, strong, nullable) VGPiece *map;        // the fMP4 header
@property (nonatomic) BOOL ended;
@property (nonatomic) BOOL encrypted;
@property (nonatomic) BOOL severalMaps;
@property (nonatomic) double duration;
@end

BOOL VGTextIsPlaylist(NSString *text);
BOOL VGTextIsMaster(NSString *text);
NSDictionary<NSString *, NSString *> *VGParseAttributes(NSString *list);
VGMaster *VGParseMaster(NSString *text, NSURL *base);
VGMedia *VGParseMedia(NSString *text, NSURL *base);
/// maxLines 0 = the best. Never returns nil for a non-empty list.
VGVariant *_Nullable VGPickVariant(NSArray<VGVariant *> *variants, NSInteger maxLines);
VGRendition *_Nullable VGPickAudio(VGMaster *master, VGVariant *variant);

#pragma mark - network (VGFetch.m)

@interface VGFetcher : NSObject
- (instancetype)initWithHeaders:(nullable NSDictionary<NSString *, NSString *> *)headers;
/// Small files (playlists). Blocks; never call on the main thread.
- (nullable NSData *)dataAtURL:(NSURL *)url error:(NSError **)error;
/// Every URL into its file, several at a time. Blocks. progress: 0…1, on any thread.
/// ranges: per URL a "bytes=a-b" string, or NSNull for the whole file. starts: filled with the
/// place in the server's file where each downloaded file begins (0 when the whole file came).
- (BOOL)downloadURLs:(NSArray<NSURL *> *)urls
             toPaths:(NSArray<NSString *> *)paths
              ranges:(nullable NSArray *)ranges
              starts:(nullable NSMutableArray<NSNumber *> *)starts
            progress:(nullable void (^)(double fraction, long long bytes))progress
               error:(NSError **)error;
- (void)cancel;
@property (atomic, readonly) BOOL cancelled;
@property (atomic, readonly) long long bytesReceived;
@end

#pragma mark - samples (VGTS.m, VGMux.m)

/// One elementary stream that hands out compressed samples in decode order.
@protocol VGTrack <NSObject>
@property (nonatomic, readonly) BOOL isVideo;
@property (nonatomic, readonly, nullable) CMFormatDescriptionRef format;
/// NO when the first timestamp is a guess (packed audio without a time stamp).
@property (nonatomic, readonly) BOOL timelineKnown;
@property (nonatomic, readonly) CGAffineTransform transform;
/// Set when reading stopped because of an error rather than at the end.
@property (nonatomic, readonly, nullable) NSError *failure;
- (nullable CMSampleBufferRef)copyNextSample CF_RETURNS_RETAINED;
@end

/// MPEG-2 transport stream (H.264 + AAC) or packed AAC audio, from one file.
@interface VGTSReader : NSObject
- (instancetype)initWithPath:(NSString *)path;
/// Reads far enough to know the streams. NO: not a stream this can read (error says why).
- (BOOL)prepare:(NSError **)error;
@property (nonatomic, readonly, nullable) id<VGTrack> video;
@property (nonatomic, readonly, nullable) id<VGTrack> audio;
@property (nonatomic, readonly) NSString *summary;
@end

typedef NS_ENUM(NSInteger, VGFileKind) { VGFileUnknown = 0, VGFileMP4, VGFileTS, VGFileAAC, VGFilePlaylist, VGFileText, VGFileWebM };
VGFileKind VGSniffFile(NSString *path);

/// The tracks of an assembled file (MP4 family, transport stream or packed audio).
NSArray<id<VGTrack>> *_Nullable VGOpenTracks(NSString *path, BOOL wantVideo, BOOL wantAudio, NSError **error);

/// Writes the tracks into one MP4 without re-encoding. Blocks.
BOOL VGMuxTracks(NSArray<id<VGTrack>> *tracks, NSURL *output, double expectedSeconds,
                 void (^_Nullable progress)(double fraction), BOOL (^_Nullable cancelled)(void), NSError **error);

/// What a finished file holds: @{video: "h264 1280x720", audio: "aac 44100 Hz 2 ch", seconds: @12.3, bytes: @…}.
NSDictionary *VGDescribeFile(NSURL *file);

#pragma mark - a download (VGJob.m)

/// Where a video comes from: what the player on screen was given. Or a picture: what an image
/// view shows, and the address it was loaded from when the app tells.
@interface VGSource : NSObject
@property (nonatomic, strong, nullable) NSURL *url;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, strong, nullable) AVAsset *asset;      // when there is no usable URL
@property (nonatomic) BOOL isPicture;
@property (nonatomic, strong, nullable) id picture;          // the UIImage on screen (pictures only)
@property (nonatomic) NSInteger pictureWidth, pictureHeight; // its pixels
@property (nonatomic, readonly) BOOL looksLikeHLS;
@property (nonatomic, readonly) NSString *shortName;         // "video.twimg.com · m3u8", "picture · i.pinimg.com · 474×711"
@end

/// The addresses to try for a picture, the largest first: apps load pictures in a size that fits
/// the screen, and some image servers hand out the original under a related address.
NSArray<NSURL *> *VGPictureCandidateURLs(NSURL *url);

@interface VGJob : NSObject
- (instancetype)initWithSource:(VGSource *)source;
@property (nonatomic) NSInteger maxLines;                    // 0 = best
@property (nonatomic, strong, nullable) VGVariant *variant;  // a choice made in the quality list
@property (nonatomic) NSInteger segmentLimit;                // tests: stop after this many segments (0 = all)
@property (nonatomic, copy, nullable) void (^onProgress)(double fraction, NSString *stage);
@property (atomic, readonly) BOOL cancelled;
@property (nonatomic, readonly) NSString *report;            // what was done, for the log
@property (nonatomic, readonly, nullable) NSString *workFolder;
/// The qualities a stream offers (empty for a plain file). Calls back on a background queue.
- (void)loadVariants:(void (^)(NSArray<VGVariant *> *variants, NSError *_Nullable error))completion;
/// Calls back on a background queue with a finished .mp4 / .mov in the work folder.
- (void)start:(void (^)(NSURL *_Nullable file, NSError *_Nullable error))completion;
- (void)cancel;
- (void)cleanUp;
+ (void)removeStaleWorkFolders;
@end

NS_ASSUME_NONNULL_END
