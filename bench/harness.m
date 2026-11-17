/*
 * IWTHarness: a small app for the iOS simulator that measures what a set of hooks costs and shows
 * what it does to a context menu. It is started three times: with no hooks ("none"), with the
 * original IWantTranslucent 0.9.4 ("orig", upstream/Tweak.m, built unchanged) and with the lean
 * rebuild ("opt", Tweak.m). tools/sim_bench.sh builds it, runs it and compares the three runs.
 *
 *   IWT_VARIANT   none | orig | opt     which library to load before UIKit starts
 *   IWT_OUT       a folder              result-<variant>.txt goes there; screenshots are asked for
 *                                       by creating shot-request-<name> and waiting until the
 *                                       script has taken the picture and removed the file
 *
 * What is measured:
 *   moves     the cost of -didMoveToWindow on a collection view cell, called directly and through
 *             real addSubview / removeFromSuperview pairs; a plain UIView is the yardstick
 *   scroll    a collection view scrolled through 6000 items: time, and how often a cell really
 *             changes window while scrolling
 *   routing   stand-ins for the AirPlay list's classes: what the separator getter costs
 *   menu      a menu with a title and three groups: what is on screen (blur strength, separators,
 *             title background), how often the menu's collection view lays out while the menu
 *             just sits there, and how much CPU the main thread uses meanwhile
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <time.h>

static NSString *gOut;
static NSString *gVariant;
static FILE *gLog;

static void Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    if (gLog) {
        fprintf(gLog, "%s\n", line.UTF8String);
        fflush(gLog);
    }
    NSLog(@"[IWTHarness] %@", line);
}

static double NowMs(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1e6;
}

static double ThreadCpuMs(void) {
    return (double)clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1e6;
}

static void After(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}


#pragma mark - Stand-ins for Control Centre's classes

// The real classes live in MediaControls and ControlCenterUIKit, which an app does not load.
// These have the same names and use their separator the way a cell usually does (made in init,
// reached through the getter afterwards), so that the hooks have something to take hold of.
@interface MRURoutingTableViewCell : UITableViewCell
@property (nonatomic, strong) UIView *separatorView;
@end

@implementation MRURoutingTableViewCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _separatorView = [UIView new];
        [self.contentView addSubview:_separatorView];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.separatorView.backgroundColor = UIColor.redColor;
    self.separatorView.hidden = NO;
    self.separatorView.frame = CGRectMake(0, self.bounds.size.height - 2, self.bounds.size.width, 2);
}
@end

@interface MRURoutingHeaderView : UITableViewHeaderFooterView
@property (nonatomic, strong) UIView *separatorView;
@end

@implementation MRURoutingHeaderView
- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (self) {
        _separatorView = [UIView new];
        [self.contentView addSubview:_separatorView];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.separatorView.backgroundColor = UIColor.redColor;
    self.separatorView.frame = CGRectMake(0, self.bounds.size.height - 2, self.bounds.size.width, 2);
}
@end

@interface MRUNowPlayingContainerView : UIView
@property (nonatomic, strong) UIView *separatorView;
@end

@implementation MRUNowPlayingContainerView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _separatorView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 2)];
        _separatorView.backgroundColor = UIColor.redColor;
        [self addSubview:_separatorView];
    }
    return self;
}
@end

@interface CCUIMenuModuleItemView : UIControl
- (double)_separatorHeight;
@end

@implementation CCUIMenuModuleItemView
- (double)_separatorHeight {
    return 1.0;
}
@end


#pragma mark - Cells

static NSUInteger gCellWindowMoves;
static NSUInteger gCellsConfigured;

@interface BenchCountingCell : UICollectionViewCell
@end

@implementation BenchCountingCell
- (void)didMoveToWindow {
    [super didMoveToWindow];
    gCellWindowMoves++;
}
@end

@interface BenchSource : NSObject <UICollectionViewDataSource>
@end

@implementation BenchSource
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return 6000;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"bench" forIndexPath:indexPath];
    cell.contentView.backgroundColor = (indexPath.item & 1) ? UIColor.systemTealColor : UIColor.systemIndigoColor;
    gCellsConfigured++;
    return cell;
}
@end


#pragma mark - The harness

@interface IWTHarnessController : UIViewController
@property (nonatomic, strong) UIButton *menuButton;
@end

@implementation IWTHarnessController

// Stripes and text behind the menu, so that "blurred" and "see-through" look different in a picture.
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    NSArray<UIColor *> *colours = @[UIColor.systemRedColor, UIColor.systemYellowColor, UIColor.systemGreenColor,
                                    UIColor.systemBlueColor, UIColor.systemOrangeColor, UIColor.systemPurpleColor];
    CGFloat width = UIScreen.mainScreen.bounds.size.width, height = UIScreen.mainScreen.bounds.size.height;
    for (int i = 0; i < 28; i++) {
        UIView *stripe = [[UIView alloc] initWithFrame:CGRectMake(0, 60 + i * 30, width, 16)];
        stripe.backgroundColor = colours[(NSUInteger)i % colours.count];
        [self.view addSubview:stripe];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12 + (i % 3) * 40, 60 + i * 30 - 2, width - 24, 20)];
        label.text = [NSString stringWithFormat:@"line %02d  ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789", i];
        label.font = [UIFont boldSystemFontOfSize:15];
        label.textColor = UIColor.whiteColor;
        [self.view addSubview:label];
    }
    self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.menuButton.frame = CGRectMake(width / 2 - 60, MIN(height - 160, 120), 120, 40);
    [self.menuButton setTitle:@"Menu" forState:UIControlStateNormal];
    self.menuButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [self.view addSubview:self.menuButton];
}

@end

static IWTHarnessController *gController;
static BenchSource *gSource;
static NSUInteger gCollectionLayouts;
static void (*gOrigCollectionLayout)(id, SEL);

static void CountingCollectionLayout(id self, SEL _cmd) {
    gCollectionLayouts++;
    gOrigCollectionLayout(self, _cmd);
}

static NSArray<UIWindow *> *AllWindows(void) {
    SEL all = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    if ([UIWindow respondsToSelector:all]) {
        NSArray *windows = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)([UIWindow class], all, YES, NO);
        if (windows.count) return windows;
    }
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return windows;
}

static void Walk(UIView *view, void (^visit)(UIView *)) {
    visit(view);
    for (UIView *subview in [view.subviews copy]) Walk(subview, visit);
}

static id SafeValue(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

// Something that would put pixels on the screen: in a window, not hidden (nor any ancestor), not
// transparent, and with a colour or a visible subview of its own.
static BOOL DrawsSomething(UIView *view) {
    if (!view.window) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    if (view.backgroundColor && CGColorGetAlpha(view.backgroundColor.CGColor) > 0.01) return YES;
    if (view.layer.contents) return YES;
    for (UIView *subview in view.subviews) {
        if (!subview.hidden && subview.alpha >= 0.01) return YES;
    }
    return NO;
}

static NSString *KindOf(UIView *view) {
    SEL sel = NSSelectorFromString(@"_elementKind");
    if (![view respondsToSelector:sel]) return @"-";
    id kind = ((id (*)(id, SEL))objc_msgSend)(view, sel);
    return [kind isKindOfClass:[NSString class]] ? kind : @"-";
}


#pragma mark - moves

static double DirectCallNs(Class cls, UIView *host) {
    UIView *view = [[cls alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    SEL setReuse = NSSelectorFromString(@"_setReuseIdentifier:");
    if ([view respondsToSelector:setReuse]) ((void (*)(id, SEL, id))objc_msgSend)(view, setReuse, @"bench");
    [host addSubview:view];
    SEL sel = @selector(didMoveToWindow);
    void (*send)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    const int calls = 200000;
    double best = 1e18;
    for (int rep = 0; rep < 5; rep++) {
        double t0 = NowMs();
        for (int i = 0; i < calls; i++) send(view, sel);
        double t = NowMs() - t0;
        if (t < best) best = t;
    }
    [view removeFromSuperview];
    return best * 1e6 / calls;
}

static double AttachDetachNs(Class cls, UIView *host) {
    const int count = 200, rounds = 25;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    SEL setReuse = NSSelectorFromString(@"_setReuseIdentifier:");
    for (int i = 0; i < count; i++) {
        UIView *view = [[cls alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
        if ([view respondsToSelector:setReuse]) ((void (*)(id, SEL, id))objc_msgSend)(view, setReuse, @"bench");
        [views addObject:view];
    }
    double best = 1e18;
    for (int rep = 0; rep < 4; rep++) {
        double t0 = NowMs();
        for (int round = 0; round < rounds; round++) {
            for (UIView *view in views) [host addSubview:view];
            for (UIView *view in views) [view removeFromSuperview];
        }
        double t = NowMs() - t0;
        if (t < best) best = t;
    }
    return best * 1e6 / (count * rounds);
}

static void RunMoves(void) {
    UIView *host = gController.view;
    Log(@"moves.direct.UIView.ns=%.1f", DirectCallNs([UIView class], host));
    Log(@"moves.direct.UICollectionReusableView.ns=%.1f", DirectCallNs([UICollectionReusableView class], host));
    Log(@"moves.direct.UICollectionViewCell.ns=%.1f", DirectCallNs([UICollectionViewCell class], host));
    Log(@"moves.pair.UIView.ns=%.1f", AttachDetachNs([UIView class], host));
    Log(@"moves.pair.UICollectionViewCell.ns=%.1f", AttachDetachNs([UICollectionViewCell class], host));
}


#pragma mark - scroll

static void RunScroll(void) {
    UIView *host = gController.view;
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(80, 80);
    layout.minimumInteritemSpacing = 4;
    layout.minimumLineSpacing = 4;
    UICollectionView *collection = [[UICollectionView alloc] initWithFrame:host.bounds collectionViewLayout:layout];
    collection.prefetchingEnabled = NO;
    [collection registerClass:[BenchCountingCell class] forCellWithReuseIdentifier:@"bench"];
    gSource = [BenchSource new];
    collection.dataSource = gSource;
    [host addSubview:collection];
    [collection layoutIfNeeded];
    double best = 1e18;
    NSUInteger configured = 0, moves = 0;
    for (int rep = 0; rep < 3; rep++) {
        collection.contentOffset = CGPointZero;
        [collection layoutIfNeeded];
        gCellsConfigured = 0;
        gCellWindowMoves = 0;
        double t0 = NowMs();
        for (int step = 1; step <= 400; step++) {
            collection.contentOffset = CGPointMake(0, step * 252.0);
            [collection layoutIfNeeded];
        }
        double t = NowMs() - t0;
        if (t < best) {
            best = t;
            configured = gCellsConfigured;
            moves = gCellWindowMoves;
        }
    }
    [collection removeFromSuperview];
    Log(@"scroll.ms=%.2f", best);
    Log(@"scroll.cells_configured=%lu", (unsigned long)configured);
    Log(@"scroll.cell_window_moves=%lu", (unsigned long)moves);
    Log(@"scroll.us_per_cell=%.2f", configured ? best * 1000.0 / configured : 0);
}


#pragma mark - routing (stand-ins)

static void RunRouting(void) {
    UIView *host = gController.view;
    MRURoutingTableViewCell *cell = [[MRURoutingTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"r"];
    cell.frame = CGRectMake(0, 0, 320, 44);
    [host addSubview:cell];
    [cell layoutIfNeeded];
    UIView *first = cell.separatorView, *second = cell.separatorView;
    UIView *real = SafeValue(cell, @"_separatorView");
    Log(@"routing.getter_same_object=%d", first == second);
    Log(@"routing.getter_returns_real_view=%d", first == real);
    Log(@"routing.real_separator_draws=%d", real ? (DrawsSomething(real) && real.frame.size.height > 0) : -1);
    Log(@"routing.handed_out_view_draws=%d", DrawsSomething(first) && first.frame.size.height > 0 && first.superview != nil);
    const int passes = 20000;
    double best = 1e18;
    for (int rep = 0; rep < 4; rep++) {
        double t0 = NowMs();
        for (int i = 0; i < passes; i++) {
            [cell setNeedsLayout];
            [cell layoutIfNeeded];
        }
        double t = NowMs() - t0;
        if (t < best) best = t;
    }
    Log(@"routing.layout_pass.ns=%.0f", best * 1e6 / passes);
    [cell removeFromSuperview];

    MRURoutingHeaderView *header = [[MRURoutingHeaderView alloc] initWithReuseIdentifier:@"h"];
    header.frame = CGRectMake(0, 0, 320, 30);
    [host addSubview:header];
    [header layoutIfNeeded];
    Log(@"routing.header_getter_same_object=%d", header.separatorView == header.separatorView);
    [header removeFromSuperview];

    MRUNowPlayingContainerView *container = [[MRUNowPlayingContainerView alloc] initWithFrame:CGRectMake(0, 0, 320, 80)];
    [host addSubview:container];
    UIView *line = SafeValue(container, @"_separatorView");
    Log(@"nowplaying.separator_in_view=%d", line.superview != nil);
    [container removeFromSuperview];

    CCUIMenuModuleItemView *item = [[CCUIMenuModuleItemView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    Log(@"ccmenu.separator_height=%.1f", [item _separatorHeight]);
}


#pragma mark - menu

static UIMenu *MakeMenu(void) {
    NSArray<NSArray<NSString *> *> *groups = @[@[@"Copy", @"Share", @"Favourite"], @[@"Rename", @"Move"], @[@"Duplicate", @"Delete"]];
    NSArray<NSString *> *images = @[@"doc.on.doc", @"square.and.arrow.up", @"star", @"pencil", @"folder", @"plus.square.on.square", @"trash"];
    NSMutableArray<UIMenuElement *> *sections = [NSMutableArray array];
    NSUInteger n = 0;
    for (NSArray<NSString *> *group in groups) {
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        for (NSString *title in group) {
            [actions addObject:[UIAction actionWithTitle:title image:[UIImage systemImageNamed:images[n++ % images.count]] identifier:nil
                                                 handler:^(__kindof UIAction *action) {}]];
        }
        [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:actions]];
    }
    return [UIMenu menuWithTitle:@"Bench menu with a title" image:nil identifier:nil options:0 children:sections];
}

// What is on screen while the menu is open. Returns the menu's list views.
static NSArray<UIView *> *InspectMenu(NSString *tag) {
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    for (UIWindow *window in AllWindows()) {
        Walk(window, ^(UIView *view) {
            if ([NSStringFromClass([view class]) isEqualToString:@"_UIContextMenuListView"]) [lists addObject:view];
        });
    }
    Log(@"%@.lists=%lu", tag, (unsigned long)lists.count);
    NSUInteger index = 0;
    for (UIView *list in lists) {
        NSString *p = [NSString stringWithFormat:@"%@.list%lu", tag, (unsigned long)index++];
        UIView *background = SafeValue(list, @"backgroundView");
        Log(@"%@.background=%@ alpha=%.2f", p, background ? NSStringFromClass([background class]) : @"nil", background ? background.alpha : -1);
        UICollectionView *collection = SafeValue(list, @"collectionView");
        if (![collection isKindOfClass:[UICollectionView class]]) {
            Log(@"%@.collection=none", p);
            continue;
        }
        Log(@"%@.delegate_is_list=%d delegate=%@ layout=%@", p, collection.delegate == (id)list,
            collection.delegate ? NSStringFromClass([(id)collection.delegate class]) : @"nil", NSStringFromClass([collection.collectionViewLayout class]));
        Log(@"%@.list_has_willDisplaySupplementary=%d", p,
            [list respondsToSelector:@selector(collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:)]);

        // what the layout asks for
        NSCountedSet *wanted = [NSCountedSet set];
        for (UICollectionViewLayoutAttributes *a in [collection.collectionViewLayout layoutAttributesForElementsInRect:
                                                     CGRectMake(0, 0, collection.contentSize.width, MAX(collection.contentSize.height, collection.bounds.size.height))]) {
            NSString *category = a.representedElementCategory == UICollectionElementCategoryCell ? @"cell"
                : a.representedElementCategory == UICollectionElementCategorySupplementaryView ? @"supplementary" : @"decoration";
            [wanted addObject:[NSString stringWithFormat:@"%@:%@", category, a.representedElementKind ?: @"-"]];
        }
        for (NSString *key in [[wanted allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            Log(@"%@.layout %@ x%lu", p, key, (unsigned long)[wanted countForObject:key]);
        }

        // what is really in the menu
        __block NSUInteger cells = 0, separatorsFound = 0, separatorsDrawing = 0;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        Walk(list, ^(UIView *view) {
            if (![view isKindOfClass:[UICollectionReusableView class]]) return;
            if ([view isKindOfClass:[UICollectionViewCell class]]) {
                cells++;
                return;
            }
            UICollectionReusableView *reusable = (UICollectionReusableView *)view;
            NSString *name = NSStringFromClass([view class]);
            NSString *kind = KindOf(view);
            BOOL separator = [name containsString:@"Separator"] || [kind containsString:@"Separator"]
                || [reusable.reuseIdentifier containsString:@"Separator"];
            BOOL draws = DrawsSomething(view);
            if (separator) {
                separatorsFound++;
                if (draws) separatorsDrawing++;
            }
            [lines addObject:[NSString stringWithFormat:@"%@ kind=%@ reuse=%@ hidden=%d alpha=%.2f h=%.2f subviews=%lu draws=%d", name, kind,
                              reusable.reuseIdentifier ?: @"-", view.hidden, view.alpha, view.frame.size.height, (unsigned long)view.subviews.count, draws]];
        });
        NSCountedSet *grouped = [NSCountedSet setWithArray:lines];
        for (NSString *line in [[grouped allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            Log(@"%@.view x%lu %@", p, (unsigned long)[grouped countForObject:line], line);
        }
        Log(@"%@.cells=%lu", p, (unsigned long)cells);
        Log(@"%@.separators_in_menu=%lu", p, (unsigned long)separatorsFound);
        Log(@"%@.separators_drawing=%lu", p, (unsigned long)separatorsDrawing);

        // views the collection view believes it is showing, whether or not they are still in it
        for (NSString *kind in @[@"kContextMenuSectionSeparator", @"kContextMenuItemSeparator", @"kContextMenuHeader"]) {
            NSArray<UICollectionReusableView *> *shown = [collection visibleSupplementaryViewsOfKind:kind];
            NSUInteger detached = 0, drawing = 0;
            for (UICollectionReusableView *view in shown) {
                if (!view.superview) detached++;
                if (DrawsSomething(view)) drawing++;
            }
            Log(@"%@.supplementary %@ shown=%lu detached=%lu drawing=%lu", p, kind, (unsigned long)shown.count, (unsigned long)detached, (unsigned long)drawing);
        }

        Walk(list, ^(UIView *view) {
            if (![NSStringFromClass([view class]) isEqualToString:@"_UIContextMenuHeaderView"]) return;
            UIView *bg = SafeValue(view, @"bgView");
            UIView *line = SafeValue(view, @"separator");
            Log(@"%@.header bgView_hidden=%d separator_height=%.2f height=%.1f", p, bg ? bg.hidden : -1, line ? line.frame.size.height : -1, view.frame.size.height);
        });
    }
    return lists;
}

static void RequestShot(NSString *name, dispatch_block_t then) {
    NSString *path = [gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"shot-request-%@-%@", gVariant, name]];
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    __block int tries = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path] || ++tries > 200) {
            [timer invalidate];
            then();
        }
    }];
}

static void Finish(void) {
    Log(@"done=1");
    if (gLog) fclose(gLog);
    [@"done" writeToFile:[gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"done-%@", gVariant]] atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    After(0.3, ^{
        exit(0);
    });
}

static void RunMenu(void) {
    UIButton *button = gController.menuButton;
    button.menu = MakeMenu();
    button.showsMenuAsPrimaryAction = YES;
    UIContextMenuInteraction *interaction = button.contextMenuInteraction;
    SEL present = NSSelectorFromString(@"_presentMenuAtLocation:");
    Log(@"menu.interaction=%d can_present=%d", interaction != nil, [interaction respondsToSelector:present]);
    if (!interaction || ![interaction respondsToSelector:present]) {
        Log(@"menu.presented=0");
        Finish();
        return;
    }

    Method layout = class_getInstanceMethod([UICollectionView class], @selector(layoutSubviews));
    gOrigCollectionLayout = (void (*)(id, SEL))method_getImplementation(layout);
    method_setImplementation(layout, (IMP)CountingCollectionLayout);

    gCollectionLayouts = 0;
    double cpu0 = ThreadCpuMs();
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(interaction, present, CGPointMake(60, 20));
    After(2.0, ^{
        double openCpu = ThreadCpuMs() - cpu0;
        NSUInteger openLayouts = gCollectionLayouts;
        NSArray<UIView *> *lists = InspectMenu(@"menu");
        Log(@"menu.presented=%d", lists.count > 0);
        Log(@"menu.open.cpu_ms=%.1f", openCpu);
        Log(@"menu.open.collection_layouts=%lu", (unsigned long)openLayouts);
        RequestShot(@"menu", ^{
            // the menu just sits there for three seconds: anything that still runs is waste
            gCollectionLayouts = 0;
            double idle0 = ThreadCpuMs();
            After(3.0, ^{
                Log(@"menu.idle3s.cpu_ms=%.2f", ThreadCpuMs() - idle0);
                Log(@"menu.idle3s.collection_layouts=%lu", (unsigned long)gCollectionLayouts);
                InspectMenu(@"menu.after");
                [interaction dismissMenu];
                After(1.5, ^{
                    NSUInteger left = 0;
                    for (UIWindow *window in AllWindows()) {
                        __block NSUInteger found = 0;
                        Walk(window, ^(UIView *view) {
                            if ([NSStringFromClass([view class]) isEqualToString:@"_UIContextMenuListView"]) found++;
                        });
                        left += found;
                    }
                    Log(@"menu.lists_left_after_dismiss=%lu", (unsigned long)left);
                    Finish();
                });
            });
        });
    });
}


#pragma mark - start

static BOOL HasOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) found = YES;
    }
    free(methods);
    return found;
}

static void RunAll(void) {
    Log(@"variant=%@", gVariant);
    Log(@"ios=%@ model=%@", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model);
    for (NSString *name in @[@"_UIContextMenuListView", @"_UIContextMenuReusableSeparatorView", @"_UIContextMenuHeaderView",
                             @"_UIContextMenuTitleView", @"_UIElasticContextMenuBackgroundView"]) {
        Log(@"class.%@=%d", name, NSClassFromString(name) != Nil);
    }
    Log(@"hook.UICollectionReusableView_has_own_didMoveToWindow=%d", HasOwnMethod([UICollectionReusableView class], @selector(didMoveToWindow)));
    Class list = NSClassFromString(@"_UIContextMenuListView");
    Log(@"hook.list_has_own_willDisplaySupplementary=%d",
        list ? HasOwnMethod(list, @selector(collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:)) : -1);
    Class separator = NSClassFromString(@"_UIContextMenuReusableSeparatorView");
    Log(@"hook.separator_has_own_didMoveToWindow=%d", separator ? HasOwnMethod(separator, @selector(didMoveToWindow)) : -1);

    RunMoves();
    RunScroll();
    RunRouting();
    After(0.5, ^{
        RunMenu();
    });
}

@interface IWTHarnessDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation IWTHarnessDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    gController = [IWTHarnessController new];
    self.window.rootViewController = gController;
    [self.window makeKeyAndVisible];
    After(2.0, ^{
        RunAll();
    });
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        const char *variant = getenv("IWT_VARIANT");
        const char *out = getenv("IWT_OUT");
        gVariant = variant ? @(variant) : @"none";
        gOut = out ? @(out) : NSTemporaryDirectory();
        gLog = fopen([gOut stringByAppendingPathComponent:[NSString stringWithFormat:@"result-%@.txt", gVariant]].fileSystemRepresentation, "w");
        if (![gVariant isEqualToString:@"none"]) {
            NSString *library = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:[gVariant stringByAppendingString:@".dylib"]];
            double t0 = NowMs();
            void *handle = dlopen(library.fileSystemRepresentation, RTLD_NOW);
            Log(@"load.ms=%.3f", NowMs() - t0);
            Log(@"load.ok=%d %s", handle != NULL, handle ? "" : dlerror());
        }
        return UIApplicationMain(argc, argv, nil, @"IWTHarnessDelegate");
    }
}
