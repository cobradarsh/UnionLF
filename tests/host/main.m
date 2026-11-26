// "Clips": a stand-in for a social app, for testing VidGrab in the simulator. It plays one
// stream the way such apps do: an AVPlayerLayer inside a card in a scrolling feed, with the
// app's own see-through controls lying over the video and its own tap and hold on the card.
//
// Environment:  VG_PLAY_URL   the stream or file to play (default: Apple's sample stream)
//               VG_HOST_MODE  "cover": a solid panel of the app lies over the video's right half
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface PlayerView : UIView
@end
@implementation PlayerView
+ (Class)layerClass { return AVPlayerLayer.class; }
@end

@interface FeedController : UIViewController
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic) NSInteger taps, holds;
@end

@implementation FeedController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    CGFloat width = self.view.bounds.size.width;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, width - 40, 40)];
    title.text = @"Clips";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    [scroll addSubview:title];

    UILabel *author = [[UILabel alloc] initWithFrame:CGRectMake(20, 124, width - 40, 22)];
    author.text = @"Sample Channel · 2 h";
    author.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    author.font = [UIFont systemFontOfSize:15];
    [scroll addSubview:author];

    CGFloat cardWidth = width - 32, cardHeight = round(cardWidth * 9 / 16);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 156, cardWidth, cardHeight)];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    [scroll addSubview:card];

    PlayerView *video = [[PlayerView alloc] initWithFrame:card.bounds];
    [card addSubview:video];

    // the app's own controls: a see-through layer over the video, as feeds have
    UIView *controls = [[UIView alloc] initWithFrame:card.bounds];
    controls.backgroundColor = UIColor.clearColor;
    [card addSubview:controls];
    UILabel *time = [[UILabel alloc] initWithFrame:CGRectMake(10, cardHeight - 32, 54, 22)];
    time.text = @"0:12";
    time.textAlignment = NSTextAlignmentCenter;
    time.textColor = UIColor.whiteColor;
    time.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    time.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    time.layer.cornerRadius = 6;
    time.layer.masksToBounds = YES;
    [controls addSubview:time];
    UIButton *mute = [UIButton buttonWithType:UIButtonTypeSystem];
    mute.frame = CGRectMake(cardWidth - 42, cardHeight - 40, 32, 32);
    [mute setImage:[UIImage systemImageNamed:@"speaker.slash.fill"] forState:UIControlStateNormal];
    mute.tintColor = UIColor.whiteColor;
    [controls addSubview:mute];

    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped)]];
    [card addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cardHeld:)]];

    if ([NSProcessInfo.processInfo.environment[@"VG_HOST_MODE"] isEqualToString:@"cover"]) {
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(cardWidth / 2, 0, cardWidth / 2, cardHeight)];
        panel.backgroundColor = [UIColor colorWithRed:0.16 green:0.17 blue:0.22 alpha:1];
        UILabel *note = [[UILabel alloc] initWithFrame:CGRectInset(panel.bounds, 12, 12)];
        note.text = @"Up next\nAnother clip";
        note.numberOfLines = 0;
        note.textColor = UIColor.whiteColor;
        note.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        [panel addSubview:note];
        [scroll addSubview:panel];
        panel.frame = [scroll convertRect:panel.frame fromView:card];
    }

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(20, CGRectGetMaxY(card.frame) + 14, width - 40, 22)];
    self.status.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    self.status.font = [UIFont systemFontOfSize:14];
    self.status.text = @"The app's own tap: 0 · hold: 0";
    [scroll addSubview:self.status];

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectMake(20, CGRectGetMaxY(self.status.frame) + 12, width - 40, 120)];
    body.numberOfLines = 0;
    body.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    body.font = [UIFont systemFontOfSize:16];
    body.text = @"A test pattern with a counter and beeps, played from a public sample stream. The rest of this feed is text.";
    [scroll addSubview:body];
    scroll.contentSize = CGSizeMake(width, CGRectGetMaxY(body.frame) + 500);

    NSString *address = NSProcessInfo.processInfo.environment[@"VG_PLAY_URL"]
        ?: @"https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8";
    self.player = [AVPlayer playerWithURL:[NSURL URLWithString:address]];
    self.player.muted = YES;
    ((AVPlayerLayer *)video.layer).player = self.player;
    ((AVPlayerLayer *)video.layer).videoGravity = AVLayerVideoGravityResizeAspect;
    [self.player play];
}

- (void)cardTapped {
    self.taps++;
    self.status.text = [NSString stringWithFormat:@"The app's own tap: %ld · hold: %ld", (long)self.taps, (long)self.holds];
}

- (void)cardHeld:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    self.holds++;
    self.status.text = [NSString stringWithFormat:@"The app's own tap: %ld · hold: %ld", (long)self.taps, (long)self.holds];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [FeedController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
