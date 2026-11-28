// The locked gallery: a window that covers Photos while Guest Mode is on and shows only the chosen
// items. A grid, and each item full screen: swipe between them, pinch or double tap to zoom, Live
// Photos play on a hold, videos play with iOS's own player. Nothing here shares, edits, deletes
// or leads anywhere else.
#import "GuestMode.h"
#import <PhotosUI/PhotosUI.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface GMCoverWindow : UIWindow
@end
@implementation GMCoverWindow
@end

@class GMViewerController;

static NSString *GMDuration(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)llround(seconds);
    if (total >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(total / 3600), (long)((total / 60) % 60), (long)(total % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

static BOOL GMIsLive(PHAsset *asset) {
    return asset.mediaType == PHAssetMediaTypeImage && (asset.mediaSubtypes & PHAssetMediaSubtypePhotoLive) != 0;
}

static NSString *GMCountText(NSArray<PHAsset *> *assets) {
    NSInteger photos = 0, videos = 0;
    for (PHAsset *asset in assets) {
        if (asset.mediaType == PHAssetMediaTypeVideo) videos++; else photos++;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if (photos) [parts addObject:[NSString stringWithFormat:@"%ld Photo%@", (long)photos, photos == 1 ? @"" : @"s"]];
    if (videos) [parts addObject:[NSString stringWithFormat:@"%ld Video%@", (long)videos, videos == 1 ? @"" : @"s"]];
    return parts.count ? [parts componentsJoinedByString:@", "] : @"No Items";
}

#pragma mark - one item, full screen

@interface GMItemController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) PHAsset *asset;
@property (nonatomic) NSInteger index;
@property (nonatomic, weak) GMViewerController *viewer;
@end

@interface GMViewerController : UIViewController <UIPageViewControllerDataSource, UIPageViewControllerDelegate>
- (instancetype)initWithAssets:(NSArray<PHAsset *> *)assets index:(NSInteger)index;
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) BOOL barsHidden;
- (void)setBarsHidden:(BOOL)hidden animated:(BOOL)animated;
- (void)toggleBars;
@end

@implementation GMItemController {
    UIScrollView *_scroll;
    UIView *_content;
    UIImageView *_image;
    PHLivePhotoView *_live;
    UIImageView *_liveBadge;
    AVPlayerViewController *_player;
    UIButton *_play;
    UIProgressView *_progress;
    PHImageRequestID _imageRequest, _extraRequest;
}

- (BOOL)isVideo { return self.asset.mediaType == PHAssetMediaTypeVideo; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _image = [UIImageView new];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    _image.clipsToBounds = YES;

    if ([self isVideo]) {
        [self.view addSubview:_image];
        _player = [AVPlayerViewController new];
        _player.showsPlaybackControls = YES;
        _player.allowsPictureInPicturePlayback = NO;        // a video in a floating window would leave the gallery
        _player.updatesNowPlayingInfoCenter = NO;
        _player.videoGravity = AVLayerVideoGravityResizeAspect;
        if (@available(iOS 16.0, *)) _player.allowsVideoFrameAnalysis = NO;    // no Live Text look-ups out of a frame
        _player.view.backgroundColor = UIColor.clearColor;
        [self addChildViewController:_player];
        [self.view addSubview:_player.view];
        [_player didMoveToParentViewController:self];
        // iOS's player hides its controls after a moment even while paused: a play button of our own
        // says "this is a video" until it has been started once.
        _play = [UIButton buttonWithType:UIButtonTypeCustom];
        UIVisualEffectView *disc = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        disc.frame = CGRectMake(0, 0, 72, 72);
        disc.layer.cornerRadius = 36;
        disc.clipsToBounds = YES;
        disc.userInteractionEnabled = NO;
        [_play addSubview:disc];
        UIImageView *glyph = [[UIImageView alloc] initWithImage:GMSymbol(@[@"play.fill"], 28, UIImageSymbolWeightSemibold)];
        glyph.tintColor = UIColor.whiteColor;
        glyph.contentMode = UIViewContentModeCenter;
        glyph.frame = CGRectMake(3, 0, 72, 72);
        glyph.userInteractionEnabled = NO;
        [_play addSubview:glyph];
        _play.accessibilityLabel = @"Play";
        _play.hidden = YES;                                 // shown once the video can play
        [_play addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_play];
    } else {
        _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
        _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scroll.delegate = self;
        _scroll.minimumZoomScale = 1;
        _scroll.maximumZoomScale = 5;
        _scroll.showsVerticalScrollIndicator = NO;
        _scroll.showsHorizontalScrollIndicator = NO;
        _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        _scroll.backgroundColor = UIColor.blackColor;
        [self.view addSubview:_scroll];
        _content = [[UIView alloc] initWithFrame:_scroll.bounds];
        [_scroll addSubview:_content];
        _image.frame = _content.bounds;
        _image.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_content addSubview:_image];
        if (GMIsLive(self.asset)) {
            _live = [[PHLivePhotoView alloc] initWithFrame:_content.bounds];
            _live.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            _live.contentMode = UIViewContentModeScaleAspectFit;
            [_content addSubview:_live];
            _liveBadge = [[UIImageView alloc] initWithImage:[PHLivePhotoView livePhotoBadgeImageWithOptions:PHLivePhotoBadgeOptionsOverContent]];
            [self.view addSubview:_liveBadge];
        }
        UITapGestureRecognizer *twice = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
        twice.numberOfTapsRequired = 2;
        [_scroll addGestureRecognizer:twice];
        UITapGestureRecognizer *once = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(singleTapped)];
        [once requireGestureRecognizerToFail:twice];
        [_scroll addGestureRecognizer:once];
    }

    _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    _progress.progressTintColor = UIColor.whiteColor;
    _progress.trackTintColor = [UIColor colorWithWhite:1 alpha:0.2];
    _progress.hidden = YES;
    [self.view addSubview:_progress];
    [self load];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    if (_player) {
        CGRect inside = UIEdgeInsetsInsetRect(bounds, safe);
        _player.view.frame = inside;
        _image.frame = inside;
        _play.bounds = CGRectMake(0, 0, 72, 72);
        _play.center = CGPointMake(CGRectGetMidX(inside), CGRectGetMidY(inside));
    } else if (_scroll.zoomScale <= 1.001) {
        _content.frame = _scroll.bounds;
        _scroll.contentSize = _scroll.bounds.size;
    }
    _liveBadge.frame = CGRectMake(safe.left + 12, safe.top + 10, _liveBadge.image.size.width, _liveBadge.image.size.height);
    _progress.frame = CGRectMake(bounds.size.width * 0.3, bounds.size.height - safe.bottom - 24, bounds.size.width * 0.4, 3);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [_scroll setZoomScale:1 animated:NO];
}

- (void)showProgress:(double)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_progress.hidden = progress >= 1;             // only shows for items that come from iCloud
        self->_progress.progress = (float)progress;
    });
}

- (void)load {
    __weak typeof(self) weak = self;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat side = MAX(screen.width, screen.height) * UIScreen.mainScreen.scale * 1.5;
    PHImageRequestOptions *options = [PHImageRequestOptions new];
    options.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
    options.networkAccessAllowed = YES;
    options.progressHandler = ^(double progress, NSError *error, BOOL *stop, NSDictionary *info) {
        [weak showProgress:progress];
    };
    _imageRequest = [PHImageManager.defaultManager requestImageForAsset:self.asset targetSize:CGSizeMake(side, side)
                                                           contentMode:PHImageContentModeAspectFit options:options
                                                         resultHandler:^(UIImage *image, NSDictionary *info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weak;
            if (!me) return;
            if (image) me->_image.image = image;
            if (![info[PHImageResultIsDegradedKey] boolValue]) me->_progress.hidden = YES;
        });
    }];

    if ([self isVideo]) {
        PHVideoRequestOptions *video = [PHVideoRequestOptions new];
        video.networkAccessAllowed = YES;
        video.deliveryMode = PHVideoRequestOptionsDeliveryModeAutomatic;
        video.progressHandler = ^(double progress, NSError *error, BOOL *stop, NSDictionary *info) {
            [weak showProgress:progress];
        };
        _extraRequest = [PHImageManager.defaultManager requestPlayerItemForVideo:self.asset options:video
                                                                  resultHandler:^(AVPlayerItem *item, NSDictionary *info) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) me = weak;
                if (!me) return;
                me->_progress.hidden = YES;
                if (!item) {
                    GMLog(@"viewer: item %d: no player item (%@)", (int)me.index, info[PHImageErrorKey]);
                    return;
                }
                me->_player.player = [AVPlayer playerWithPlayerItem:item];
                me->_play.hidden = NO;
                GMLog(@"viewer: item %d: video ready (%.0f s)", (int)me.index, me.asset.duration);
            });
        }];
    } else if (_live) {
        PHLivePhotoRequestOptions *live = [PHLivePhotoRequestOptions new];
        live.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
        live.networkAccessAllowed = YES;
        _extraRequest = [PHImageManager.defaultManager requestLivePhotoForAsset:self.asset targetSize:CGSizeMake(side, side)
                                                                   contentMode:PHImageContentModeAspectFit options:live
                                                                 resultHandler:^(PHLivePhoto *photo, NSDictionary *info) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) me = weak;
                if (me && photo) me->_live.livePhoto = photo;
            });
        }];
    }
}

- (void)dealloc {
    if (_imageRequest) [PHImageManager.defaultManager cancelImageRequest:_imageRequest];
    if (_extraRequest) [PHImageManager.defaultManager cancelImageRequest:_extraRequest];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if ([self isVideo]) {
        // sound also with the ring switch on silent, as in Photos
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
    }
}

- (void)playTapped {
    _play.hidden = YES;
    [_player.player play];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_player.player pause];
    if (_player.player) {                                   // back at the start, with the play button, for the next look
        [_player.player seekToTime:kCMTimeZero];
        _play.hidden = NO;
    }
    [_live stopPlayback];
    [_scroll setZoomScale:1 animated:NO];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return _content; }

- (void)singleTapped {
    [self.viewer toggleBars];
}

- (void)doubleTapped:(UITapGestureRecognizer *)tap {
    if (_scroll.zoomScale > 1.01) {
        [_scroll setZoomScale:1 animated:YES];
        return;
    }
    CGPoint point = [tap locationInView:_content];
    CGFloat scale = 2.5;
    CGSize size = CGSizeMake(_scroll.bounds.size.width / scale, _scroll.bounds.size.height / scale);
    [_scroll zoomToRect:CGRectMake(point.x - size.width / 2, point.y - size.height / 2, size.width, size.height) animated:YES];
}

@end

#pragma mark - the pager

@implementation GMViewerController {
    NSArray<PHAsset *> *_assets;
    UIPageViewController *_pages;
    NSInteger _index;
    BOOL _barsHidden;
}

- (instancetype)initWithAssets:(NSArray<PHAsset *> *)assets index:(NSInteger)index {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _assets = [assets copy];
        _index = MAX(0, MIN((NSInteger)assets.count - 1, index));
    }
    return self;
}

- (NSInteger)index { return _index; }
- (BOOL)barsHidden { return _barsHidden; }

- (GMItemController *)pageAt:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_assets.count) return nil;
    GMItemController *page = [GMItemController new];
    page.asset = _assets[index];
    page.index = index;
    page.viewer = self;
    return page;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _pages = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll
                                             navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                                                           options:@{UIPageViewControllerOptionInterPageSpacingKey: @16}];
    _pages.dataSource = _assets.count > 1 ? self : nil;
    _pages.delegate = self;
    [self addChildViewController:_pages];
    _pages.view.frame = self.view.bounds;
    _pages.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_pages.view];
    [_pages didMoveToParentViewController:self];
    GMItemController *first = [self pageAt:_index];
    if (first) [_pages setViewControllers:@[first] direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
    [self retitle];
}

- (void)retitle {
    self.navigationItem.title = _assets.count > 1 ? [NSString stringWithFormat:@"%ld of %ld", (long)(_index + 1), (long)_assets.count] : @"Guest Mode";
}

- (UIViewController *)pageViewController:(UIPageViewController *)pages viewControllerBeforeViewController:(UIViewController *)current {
    return [self pageAt:((GMItemController *)current).index - 1];
}

- (UIViewController *)pageViewController:(UIPageViewController *)pages viewControllerAfterViewController:(UIViewController *)current {
    return [self pageAt:((GMItemController *)current).index + 1];
}

- (void)pageViewController:(UIPageViewController *)pages didFinishAnimating:(BOOL)finished
   previousViewControllers:(NSArray<UIViewController *> *)previous transitionCompleted:(BOOL)completed {
    GMItemController *now = (GMItemController *)pages.viewControllers.firstObject;
    if (!now) return;
    _index = now.index;
    [self retitle];
    // a video has controls of its own to tap: the bars (and the Guest Mode button) come back for it
    if (now.asset.mediaType == PHAssetMediaTypeVideo && _barsHidden) [self setBarsHidden:NO animated:YES];
}

- (void)setBarsHidden:(BOOL)hidden animated:(BOOL)animated {
    _barsHidden = hidden;
    [self.navigationController setNavigationBarHidden:hidden animated:animated];
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [GMButtonController.shared setTuckedAway:hidden];
}

- (void)toggleBars {
    GMItemController *now = (GMItemController *)_pages.viewControllers.firstObject;
    if (now.asset.mediaType == PHAssetMediaTypeVideo && !_barsHidden) return;
    [self setBarsHidden:!_barsHidden animated:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (_barsHidden) [self setBarsHidden:NO animated:animated];
}

- (BOOL)prefersStatusBarHidden { return _barsHidden; }
- (BOOL)prefersHomeIndicatorAutoHidden { return _barsHidden; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

@end

#pragma mark - the grid

@interface GMGridCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *picture;
@property (nonatomic, strong) UILabel *duration;
@property (nonatomic, strong) UIImageView *kind;
@property (nonatomic, strong) CAGradientLayer *shade;
@property (nonatomic, copy) NSString *assetId;
@property (nonatomic) PHImageRequestID request;
@end

@implementation GMGridCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
        self.contentView.clipsToBounds = YES;
        _picture = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _picture.contentMode = UIViewContentModeScaleAspectFill;
        _picture.clipsToBounds = YES;
        _picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.contentView addSubview:_picture];
        _shade = [CAGradientLayer layer];
        _shade.colors = @[(id)UIColor.clearColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:0.55].CGColor];
        _shade.hidden = YES;
        [self.contentView.layer addSublayer:_shade];
        _duration = [UILabel new];
        _duration.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        _duration.textColor = UIColor.whiteColor;
        _duration.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_duration];
        _kind = [UIImageView new];
        _kind.tintColor = UIColor.whiteColor;
        _kind.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_kind];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shade.frame = CGRectMake(0, b.size.height - 34, b.size.width, 34);
    [CATransaction commit];
    _duration.frame = CGRectMake(30, b.size.height - 22, b.size.width - 36, 18);
    _kind.frame = CGRectMake(6, b.size.height - 22, 20, 18);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    if (self.request) [PHImageManager.defaultManager cancelImageRequest:self.request];
    self.request = 0;
    self.picture.image = nil;
    self.assetId = nil;
}

@end

@interface GMGridFooter : UICollectionReusableView
@property (nonatomic, strong) UILabel *label;
@end

@implementation GMGridFooter
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _label = [[UILabel alloc] initWithFrame:CGRectInset(self.bounds, 20, 0)];
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _label.numberOfLines = 0;
        _label.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_label];
    }
    return self;
}
@end

@interface GMGridController : UICollectionViewController <UICollectionViewDelegateFlowLayout>
- (instancetype)initWithAssets:(NSArray<PHAsset *> *)assets;
@property (nonatomic, copy, readonly) NSArray<PHAsset *> *assets;
@end

@implementation GMGridController

- (instancetype)initWithAssets:(NSArray<PHAsset *> *)assets {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 2;
    layout.minimumLineSpacing = 2;
    if ((self = [super initWithCollectionViewLayout:layout])) {
        _assets = [assets copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"Guest Mode";
    self.navigationItem.backButtonTitle = @"All";
    self.collectionView.backgroundColor = UIColor.blackColor;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:GMGridCell.class forCellWithReuseIdentifier:@"cell"];
    [self.collectionView registerClass:GMGridFooter.class forSupplementaryViewOfKind:UICollectionElementKindSectionFooter withReuseIdentifier:@"footer"];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self.collectionViewLayout invalidateLayout];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.assets.count;
}

- (CGFloat)cellSide {
    UIEdgeInsets safe = self.collectionView.safeAreaInsets;
    CGFloat width = self.collectionView.bounds.size.width - safe.left - safe.right;
    NSInteger columns = width > 600 ? 5 : 3;
    return floor((width - (columns - 1) * 2) / columns);
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat side = [self cellSide];
    return CGSizeMake(side, side);
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout referenceSizeForFooterInSection:(NSInteger)section {
    return CGSizeMake(collectionView.bounds.size.width, self.assets.count ? 84 : 220);
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    GMGridFooter *footer = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"footer" forIndexPath:indexPath];
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    NSDictionary *strong = @{NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: UIColor.whiteColor};
    NSDictionary *soft = @{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor colorWithWhite:0.6 alpha:1]};
    if (self.assets.count) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:GMCountText(self.assets) attributes:strong]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\nGuest Mode shows only these." attributes:soft]];
    } else {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"Nothing to Show" attributes:strong]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\nThe chosen items are no longer in the library.\nTap the lock to end Guest Mode." attributes:soft]];
    }
    footer.label.attributedText = text;
    return footer;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    GMGridCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:indexPath];
    PHAsset *asset = self.assets[indexPath.item];
    cell.assetId = asset.localIdentifier;
    BOOL video = asset.mediaType == PHAssetMediaTypeVideo;
    BOOL live = GMIsLive(asset);
    cell.duration.text = video ? GMDuration(asset.duration) : nil;
    cell.kind.image = video ? GMSymbol(@[@"video.fill"], 12, UIImageSymbolWeightSemibold)
                            : (live ? GMSymbol(@[@"livephoto"], 13, UIImageSymbolWeightSemibold) : nil);
    cell.shade.hidden = !(video || live);
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = video ? [NSString stringWithFormat:@"Video, %@", GMDuration(asset.duration)] : (live ? @"Live Photo" : @"Photo");

    CGFloat side = [self cellSide] * UIScreen.mainScreen.scale;
    PHImageRequestOptions *options = [PHImageRequestOptions new];
    options.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
    options.resizeMode = PHImageRequestOptionsResizeModeFast;
    options.networkAccessAllowed = YES;
    NSString *wanted = asset.localIdentifier;
    __weak GMGridCell *weakCell = cell;
    cell.request = [PHImageManager.defaultManager requestImageForAsset:asset targetSize:CGSizeMake(side, side)
                                                          contentMode:PHImageContentModeAspectFill options:options
                                                        resultHandler:^(UIImage *image, NSDictionary *info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GMGridCell *target = weakCell;
            if (image && [target.assetId isEqualToString:wanted]) target.picture.image = image;
        });
    }];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    GMViewerController *viewer = [[GMViewerController alloc] initWithAssets:self.assets index:indexPath.item];
    [self.navigationController pushViewController:viewer animated:YES];
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

@end

#pragma mark - the window

@interface GMNavController : UINavigationController
@end

@implementation GMNavController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
- (UIViewController *)childViewControllerForStatusBarHidden { return self.topViewController; }
- (UIViewController *)childViewControllerForStatusBarStyle { return self.topViewController; }
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden { return self.topViewController; }
@end

@implementation GMGallery {
    GMCoverWindow *_window;
    GMNavController *_nav;
    GMGridController *_grid;
}

+ (instancetype)shared {
    static GMGallery *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [GMGallery new]; });
    return shared;
}

- (BOOL)isUp { return _window != nil; }

static UIWindow *GMWindowUnderneath(UIWindowScene *scene) {
    UIWindow *found = nil;
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.windowLevel > UIWindowLevelNormal + 1) continue;
        if (!found || window.isKeyWindow) found = window;
    }
    return found;
}

- (void)showAnimated:(BOOL)animated {
    if (_window) return;
    UIWindowScene *scene = GMActiveScene();
    if (!scene) {
        GMLog(@"gallery: no scene yet, waiting");
        return;
    }
    NSArray<PHAsset *> *assets = [GMState.shared assets];
    [GMWindowUnderneath(scene) endEditing:YES];             // a keyboard of Photos' would float over the gallery

    _window = [[GMCoverWindow alloc] initWithWindowScene:scene];
    _window.frame = scene.coordinateSpace.bounds;
    _window.windowLevel = UIWindowLevelStatusBar + 50;      // over everything Photos can put up; the button is at + 60
    _window.backgroundColor = UIColor.blackColor;
    _window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _window.accessibilityViewIsModal = YES;                 // VoiceOver stays out of what is underneath

    _grid = [[GMGridController alloc] initWithAssets:assets];
    _nav = [[GMNavController alloc] initWithRootViewController:_grid];
    UINavigationBarAppearance *bar = [UINavigationBarAppearance new];
    [bar configureWithDefaultBackground];
    _nav.navigationBar.standardAppearance = bar;
    _nav.navigationBar.scrollEdgeAppearance = bar;
    _nav.navigationBar.compactAppearance = bar;
    _nav.navigationBar.tintColor = UIColor.whiteColor;
    if (assets.count == 1) {                                // a single item is shown straight away
        [_nav pushViewController:[[GMViewerController alloc] initWithAssets:assets index:0] animated:NO];
    }
    _window.rootViewController = _nav;
    [_window makeKeyAndVisible];
    GMLog(@"gallery: up over Photos with %d of %d item(s): %@", (int)assets.count, (int)GMState.shared.identifiers.count, GMCountText(assets));
    if (animated) {
        _window.alpha = 0;
        [UIView animateWithDuration:0.25 animations:^{ self->_window.alpha = 1; }];
    }
}

- (void)hideAnimated:(BOOL)animated {
    GMCoverWindow *window = _window;
    if (!window) return;
    _window = nil;
    _nav = nil;
    _grid = nil;
    UIWindowScene *scene = window.windowScene;
    void (^gone)(void) = ^{
        window.hidden = YES;
        window.rootViewController = nil;
        [GMWindowUnderneath(scene) makeKeyWindow];
        GMLog(@"gallery: down, Photos is back to normal");
    };
    [GMButtonController.shared setTuckedAway:NO];
    if (!animated) {
        gone();
        return;
    }
    [UIView animateWithDuration:0.25 animations:^{ window.alpha = 0; } completion:^(BOOL finished) { gone(); }];
}

#pragma mark - tests

- (GMViewerController *)viewer {
    UIViewController *top = _nav.topViewController;
    return [top isKindOfClass:GMViewerController.class] ? (GMViewerController *)top : nil;
}

- (BOOL)openItemAtIndex:(NSInteger)index {
    if (!_window || index < 0 || index >= (NSInteger)_grid.assets.count) return NO;
    [_nav popToRootViewControllerAnimated:NO];
    [_nav pushViewController:[[GMViewerController alloc] initWithAssets:_grid.assets index:index] animated:NO];
    return YES;
}

- (void)backToGrid {
    [_nav popToRootViewControllerAnimated:NO];
}

- (void)toggleBars {
    [[self viewer] toggleBars];
}

- (NSString *)describe {
    if (!_window) return @"gallery: down";
    GMViewerController *viewer = [self viewer];
    NSMutableArray<NSString *> *kinds = [NSMutableArray new];
    for (PHAsset *asset in _grid.assets) {
        [kinds addObject:asset.mediaType == PHAssetMediaTypeVideo ? [NSString stringWithFormat:@"video %.0fs", asset.duration]
                                                                 : (GMIsLive(asset) ? @"live" : @"photo")];
    }
    return [NSString stringWithFormat:@"gallery: UP, level %.0f, key %d, %d item(s) [%@], showing %@, bars %@",
            _window.windowLevel, _window.isKeyWindow, (int)_grid.assets.count, [kinds componentsJoinedByString:@", "],
            viewer ? [NSString stringWithFormat:@"item %d", (int)viewer.index] : @"the grid",
            (viewer && viewer.barsHidden) ? @"hidden" : @"shown"];
}

@end
