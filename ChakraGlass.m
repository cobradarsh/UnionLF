/*  ChakraGlass.m — the pane behind the wheel.

    Two looks:

      Glass    after the glass of the newest iOS: what is behind shows through, only lightly
               blurred and a little richer in colour; a bright rim that catches the light at the
               top left and again at the bottom right; a soft sheen across the pane; a shadow
               underneath. iOS 16 has no system glass, so this one is put together from a
               backdrop layer (the same Core Animation layer every system blur is made of) with
               its own, much lighter, filters.
      Frosted  the dark frosted material Chakra 1.0.0 had.

    A backdrop only sees what is behind it while nothing above it clips or fades as a group, so
    the pane never clips its children: each layer rounds its own corners.                      */

#import "Chakra.h"

static id ChakraFilter(NSString *type) {
    Class cls = NSClassFromString(@"CAFilter");
    SEL make = NSSelectorFromString(@"filterWithType:");
    if (!cls || ![cls respondsToSelector:make]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(cls, make, type); } @catch (__unused id e) {}
    return nil;
}

// A view whose own layer is a backdrop layer.
@interface ChakraBackdropView : UIView
@end

@implementation ChakraBackdropView
+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: [CALayer class]; }
@end

@implementation ChakraGlassView {
    CGFloat _radius;
}

+ (BOOL)canDrawGlass {
    return NSClassFromString(@"CABackdropLayer") != nil && ChakraFilter(@"gaussianBlur") != nil;
}

- (instancetype)initWithFrame:(CGRect)frame cornerRadius:(CGFloat)radius glass:(BOOL)glass accent:(UIColor *)accent {
    if ((self = [super initWithFrame:frame])) {
        _radius = radius;
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        CGRect b = self.bounds;
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:radius];

        // the shadow the pane throws on what is underneath
        self.layer.shadowPath = shape.CGPath;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = glass ? 0.30 : 0.22;
        self.layer.shadowRadius = 22;
        self.layer.shadowOffset = CGSizeMake(0, 10);

        if (glass && [ChakraGlassView canDrawGlass]) {
            ChakraBackdropView *backdrop = [[ChakraBackdropView alloc] initWithFrame:b];
            backdrop.userInteractionEnabled = NO;
            backdrop.layer.cornerRadius = radius;
            backdrop.layer.masksToBounds = YES;
            id rich = ChakraFilter(@"colorSaturate");
            id blur = ChakraFilter(@"gaussianBlur");
            @try {
                [rich setValue:@1.7 forKey:@"inputAmount"];
                [blur setValue:@9.0 forKey:@"inputRadius"];
                [blur setValue:@YES forKey:@"inputNormalizeEdges"];
                NSMutableArray *filters = [NSMutableArray array];
                if (rich) [filters addObject:rich];
                if (blur) [filters addObject:blur];
                [backdrop.layer setValue:filters forKey:@"filters"];
                [backdrop.layer setValue:@0.5 forKey:@"scale"];            // sample at half size: a blur hides it, and it is cheaper
            } @catch (NSException *e) {
                ChakraLog(@"glass: the backdrop filters threw %@", e.reason);
            }
            [self addSubview:backdrop];

            // a breath of smoke, so white names stay readable over a white page
            UIView *smoke = [[UIView alloc] initWithFrame:b];
            smoke.userInteractionEnabled = NO;
            smoke.backgroundColor = [UIColor colorWithWhite:0 alpha:0.16];
            smoke.layer.cornerRadius = radius;
            smoke.layer.masksToBounds = YES;
            [self addSubview:smoke];

            // the sheen: light falling across the pane from the top left
            CAGradientLayer *sheen = [CAGradientLayer layer];
            sheen.frame = b;
            sheen.cornerRadius = radius;
            sheen.masksToBounds = YES;
            sheen.startPoint = CGPointMake(0.15, 0.0);
            sheen.endPoint = CGPointMake(0.85, 1.0);
            sheen.colors = @[ (__bridge id)[UIColor colorWithWhite:1 alpha:0.20].CGColor,
                              (__bridge id)[UIColor colorWithWhite:1 alpha:0.05].CGColor,
                              (__bridge id)[UIColor colorWithWhite:1 alpha:0.02].CGColor,
                              (__bridge id)[UIColor colorWithWhite:1 alpha:0.10].CGColor ];
            sheen.locations = @[ @0.0, @0.35, @0.7, @1.0 ];
            [self.layer addSublayer:sheen];

            // a touch of the accent colour in the glass
            UIView *tint = [[UIView alloc] initWithFrame:b];
            tint.userInteractionEnabled = NO;
            tint.backgroundColor = [accent colorWithAlphaComponent:0.07];
            tint.layer.cornerRadius = radius;
            tint.layer.masksToBounds = YES;
            [self addSubview:tint];
        } else {
            UIVisualEffectView *frost = [[UIVisualEffectView alloc] initWithEffect:
                                         [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
            frost.frame = b;
            frost.userInteractionEnabled = NO;
            frost.clipsToBounds = YES;
            frost.layer.cornerRadius = radius;
            UIView *tint = [[UIView alloc] initWithFrame:b];
            tint.userInteractionEnabled = NO;
            tint.backgroundColor = [accent colorWithAlphaComponent:0.10];
            [frost.contentView addSubview:tint];
            [self addSubview:frost];
        }

        // whatever the wheel draws on the pane (its rings and spokes)
        _contentView = [[UIView alloc] initWithFrame:b];
        _contentView.userInteractionEnabled = NO;
        _contentView.backgroundColor = UIColor.clearColor;
        _contentView.layer.cornerRadius = radius;
        _contentView.layer.masksToBounds = YES;
        [self addSubview:_contentView];

        if (glass) {
            // the thickness of the glass: a soft light band just inside the edge
            CAShapeLayer *bevel = [CAShapeLayer layer];
            bevel.frame = b;
            bevel.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 2.5, 2.5) cornerRadius:MAX(0, radius - 2.5)].CGPath;
            bevel.fillColor = UIColor.clearColor.CGColor;
            bevel.strokeColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
            bevel.lineWidth = 5;
            [_contentView.layer addSublayer:bevel];
        }

        // the rim: bright where the light catches it, nearly gone in between
        CAGradientLayer *rim = [CAGradientLayer layer];
        rim.frame = b;
        rim.startPoint = CGPointMake(0.0, 0.0);
        rim.endPoint = CGPointMake(1.0, 1.0);
        if (glass) {
            rim.colors = @[ (__bridge id)[UIColor colorWithWhite:1 alpha:0.90].CGColor,
                            (__bridge id)[UIColor colorWithWhite:1 alpha:0.22].CGColor,
                            (__bridge id)[UIColor colorWithWhite:1 alpha:0.12].CGColor,
                            (__bridge id)[UIColor colorWithWhite:1 alpha:0.60].CGColor ];
            rim.locations = @[ @0.0, @0.38, @0.68, @1.0 ];
        } else {
            rim.colors = @[ (__bridge id)[UIColor colorWithWhite:1 alpha:0.20].CGColor,
                            (__bridge id)[UIColor colorWithWhite:1 alpha:0.12].CGColor ];
        }
        CAShapeLayer *edge = [CAShapeLayer layer];
        edge.frame = b;
        CGFloat line = glass ? 1.5 : 1.0;
        edge.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, line / 2.0, line / 2.0) cornerRadius:MAX(0, radius - line / 2.0)].CGPath;
        edge.fillColor = UIColor.clearColor.CGColor;
        edge.strokeColor = UIColor.blackColor.CGColor;
        edge.lineWidth = line;
        rim.mask = edge;
        [self.layer addSublayer:rim];
    }
    return self;
}

@end
