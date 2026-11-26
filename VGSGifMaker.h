#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VGSGifPreset) {
    VGSGifPresetSmall = 0,       // 320 px, up to 12 frames a second
    VGSGifPresetBalanced = 1,    // 480 px, up to 16 frames a second (every second frame of most videos)
    VGSGifPresetHigh = 2,        // 640 px, every frame up to 30 a second, smoothed gradients
};

extern const double VGSGifMaxSeconds;        // a GIF covers at most this much of a video

NSString *VGSGifPresetName(VGSGifPreset preset);

@interface VGSGifResult : NSObject
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger frames;
@property (nonatomic) double duration;          // of the GIF
@property (nonatomic) double videoDuration;
@property (nonatomic) long long bytes;
@property (nonatomic) BOOL trimmed;
@end

/// Turns a video file into a GIF. Synchronous: call it off the main thread.
@interface VGSGifMaker : NSObject
+ (nullable VGSGifResult *)makeGIFAtURL:(NSURL *)gifURL
                             fromVideo:(NSURL *)videoURL
                                preset:(VGSGifPreset)preset
                             posterURL:(nullable NSURL *)posterURL
                              progress:(nullable void (^)(double fraction))progress
                                 error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
