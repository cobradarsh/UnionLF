/*  probe/main.m — AtelierProbe, a small app for the simulator test (not part of the package).

    It shows where it is touched and whether its keyboard came up, and writes the same to
    Documents/probe.log, so a test can tell what an app on the bench actually receives:

      - the size it is laid out at (does "Resize apps" reach the app?)
      - active / background / foreground (does freezing really send it to the background?)
      - a text field that asks for the keyboard a moment after the app becomes active
        (does a hosted app get its keyboard?)
      - every touch, in the app's own coordinates (do touches land where they should through
        the scaled picture?)

    A ruler every 100 points makes the scale readable in a screenshot.                       */

#import <UIKit/UIKit.h>
#import <unistd.h>

static void ProbeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ProbeLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSString *path;
    static NSDateFormatter *df;
    if (!path) {
        path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"probe.log"];
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    }
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

@interface ProbeView : UIView
@property (nonatomic) CGPoint last;
@property (nonatomic) NSInteger touches;
@end

@implementation ProbeView

- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    [[UIColor colorWithRed:0.07 green:0.16 blue:0.30 alpha:1] setFill];
    CGContextFillRect(c, self.bounds);
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.7] };
    [[UIColor colorWithWhite:1 alpha:0.25] setFill];
    for (CGFloat y = 100; y < self.bounds.size.height; y += 100) {
        CGContextFillRect(c, CGRectMake(0, y, self.bounds.size.width, 1));
        [[NSString stringWithFormat:@"y %.0f", y] drawAtPoint:CGPointMake(6, y + 3) withAttributes:attrs];
    }
    for (CGFloat x = 100; x < self.bounds.size.width; x += 100) {
        [[UIColor colorWithWhite:1 alpha:0.25] setFill];
        CGContextFillRect(c, CGRectMake(x, 0, 1, self.bounds.size.height));
        [[NSString stringWithFormat:@"x %.0f", x] drawAtPoint:CGPointMake(x + 3, self.bounds.size.height - 60) withAttributes:attrs];
    }
    if (self.touches > 0) {
        [[UIColor colorWithRed:1 green:0.8 blue:0.2 alpha:1] setFill];
        CGContextFillEllipseInRect(c, CGRectMake(self.last.x - 16, self.last.y - 16, 32, 32));
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.last = [touches.anyObject locationInView:self];
    self.touches++;
    ProbeLog(@"touch %ld at %.0f,%.0f", (long)self.touches, self.last.x, self.last.y);
    [self setNeedsDisplay];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ProbeChanged" object:nil];
}

@end

@interface ProbeController : UIViewController
@end

@implementation ProbeController {
    ProbeView *_probe;
    UITextField *_field;
    UILabel *_status;
    NSString *_keyboard;
    NSString *_life;
    CGSize _size;
}

- (void)loadView {
    _probe = [[ProbeView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _probe.contentMode = UIViewContentModeRedraw;
    self.view = _probe;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _keyboard = @"keyboard: not asked yet";
    _life = @"launched";
    _field = [[UITextField alloc] initWithFrame:CGRectMake(20, 130, 300, 44)];
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.placeholder = @"type here";
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    [_field addTarget:self action:@selector(_typed) forControlEvents:UIControlEventEditingChanged];
    [self.view addSubview:_field];
    _status = [[UILabel alloc] initWithFrame:CGRectMake(20, 186, 380, 190)];
    _status.numberOfLines = 0;
    _status.textColor = UIColor.whiteColor;
    _status.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    [self.view addSubview:_status];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, 380, 44)];
    title.text = @"Atelier Probe";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    [self.view addSubview:title];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[ UIKeyboardWillShowNotification, UIKeyboardDidShowNotification, UIKeyboardWillHideNotification, UIKeyboardDidHideNotification ])
        [nc addObserver:self selector:@selector(_keyboard:) name:name object:nil];
    for (NSString *name in @[ UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                              UIApplicationDidEnterBackgroundNotification, UIApplicationWillEnterForegroundNotification ])
        [nc addObserver:self selector:@selector(_life:) name:name object:nil];
    [nc addObserver:self selector:@selector(_refresh) name:@"ProbeChanged" object:nil];
    [nc addObserver:self selector:@selector(_refresh) name:UIWindowDidBecomeKeyNotification object:nil];
    [nc addObserver:self selector:@selector(_refresh) name:UIWindowDidResignKeyNotification object:nil];
    [self _refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize s = self.view.bounds.size;
    if (!CGSizeEqualToSize(s, _size)) {
        _size = s;
        UIEdgeInsets i = self.view.safeAreaInsets;
        ProbeLog(@"size %.0fx%.0f safe %.0f/%.0f screen %.0fx%.0f", s.width, s.height, i.top, i.bottom,
                 UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height);
        _field.frame = CGRectMake(20, 130, MIN(300, s.width - 40), 44);
        _status.frame = CGRectMake(20, 186, s.width - 40, 190);
        [self _refresh];
    }
}

- (void)_life:(NSNotification *)n {
    _life = [[n.name stringByReplacingOccurrencesOfString:@"UIApplication" withString:@""] stringByReplacingOccurrencesOfString:@"Notification" withString:@""];
    ProbeLog(@"life %@ (state %ld)", _life, (long)UIApplication.sharedApplication.applicationState);
    [self _refresh];
    if ([n.name isEqualToString:UIApplicationDidBecomeActiveNotification]) {
        // a moment after becoming active the field asks for the keyboard, every time
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL ok = [self->_field becomeFirstResponder];
            ProbeLog(@"becomeFirstResponder -> %d, window key %d, first responder %d", (int)ok, (int)self.view.window.isKeyWindow, (int)self->_field.isFirstResponder);
            if ([self->_keyboard hasSuffix:@"yet"]) self->_keyboard = ok ? @"keyboard: asked, not shown" : @"keyboard: field refused";
            [self _refresh];
        });
    }
}

- (void)_keyboard:(NSNotification *)n {
    CGRect end = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSString *what = [[n.name stringByReplacingOccurrencesOfString:@"UIKeyboard" withString:@""] stringByReplacingOccurrencesOfString:@"Notification" withString:@""];
    _keyboard = [NSString stringWithFormat:@"keyboard: %@ %.0fx%.0f at y %.0f", what, end.size.width, end.size.height, end.origin.y];
    ProbeLog(@"%@", _keyboard);
    [self _refresh];
}

- (void)_typed {
    ProbeLog(@"text \"%@\"", _field.text);
    [self _refresh];
}

- (void)_refresh {
    _status.text = [NSString stringWithFormat:@"size %.0f x %.0f\n%@\nwindow key: %@\n%@\ntouches %ld, last %.0f,%.0f\ntext \"%@\"",
                    self.view.bounds.size.width, self.view.bounds.size.height, _life, self.view.window.isKeyWindow ? @"yes" : @"no",
                    _keyboard, (long)_probe.touches, _probe.last.x, _probe.last.y, _field.text ?: @""];
}

@end

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    ProbeLog(@"launch pid %d state %ld", (int)getpid(), (long)application.applicationState);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ProbeController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeDelegate class]));
    }
}
