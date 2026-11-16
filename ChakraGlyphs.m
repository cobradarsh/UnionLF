/*  ChakraGlyphs.m — the icons Chakra draws itself.

    • the wheel mark on the ball (a rim, a hub and eight spokes)
    • a glyph disc for every action and shortcut: a filled circle with a white symbol, the way
      Control Centre draws its buttons. App entries use the app's own icon instead.
    • the Bluetooth rune, which SF Symbols does not have

    Symbol names are SF Symbols that exist on iOS 15 and later; ck.* names are the drawn ones.  */

#import "Chakra.h"

@implementation ChakraGlyphs

+ (UIGraphicsImageRenderer *)_rendererWithSize:(CGSize)size {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    return [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
}

+ (UIImage *)chakraWithSize:(CGFloat)size {
    if (size < 4) size = 4;
    UIImage *img = [[self _rendererWithSize:CGSizeMake(size, size)] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat c = size / 2.0;
        CGFloat line = MAX(1.25, size * 0.085);
        CGFloat rim = size * 0.46 - line / 2.0;
        CGFloat hub = size * 0.105;
        [UIColor.blackColor set];

        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(c, c) radius:rim startAngle:0 endAngle:2 * M_PI clockwise:YES];
        ring.lineWidth = line;
        [ring stroke];

        UIBezierPath *spokes = [UIBezierPath bezierPath];
        for (int i = 0; i < 8; i++) {
            CGFloat a = i * M_PI / 4.0 + M_PI / 8.0;
            [spokes moveToPoint:CGPointMake(c + cos(a) * hub, c + sin(a) * hub)];
            [spokes addLineToPoint:CGPointMake(c + cos(a) * (rim - line * 0.2), c + sin(a) * (rim - line * 0.2))];
        }
        spokes.lineWidth = line * 0.72;
        spokes.lineCapStyle = kCGLineCapRound;
        [spokes stroke];

        [[UIBezierPath bezierPathWithArcCenter:CGPointMake(c, c) radius:hub startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// The Bluetooth rune: an upright with two arrowheads that cross it.
+ (UIImage *)_bluetoothWithSize:(CGFloat)size {
    if (size < 4) size = 4;
    UIImage *img = [[self _rendererWithSize:CGSizeMake(size, size)] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGPoint (^pt)(CGFloat, CGFloat) = ^CGPoint(CGFloat u, CGFloat v) { return CGPointMake(u * size, v * size); };
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:pt(0.28, 0.30)];
        [p addLineToPoint:pt(0.71, 0.70)];
        [p addLineToPoint:pt(0.50, 0.92)];
        [p addLineToPoint:pt(0.50, 0.08)];
        [p addLineToPoint:pt(0.71, 0.30)];
        [p addLineToPoint:pt(0.28, 0.70)];
        p.lineWidth = MAX(1.25, size * 0.088);
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [UIColor.blackColor set];
        [p stroke];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)glyphNamed:(NSString *)name pointSize:(CGFloat)pointSize {
    if (name.length == 0) return nil;
    if ([name isEqualToString:@"ck.chakra"])    return [self chakraWithSize:pointSize * 1.22];
    if ([name isEqualToString:@"ck.bluetooth"]) return [self _bluetoothWithSize:pointSize * 1.22];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)discWithGlyph:(NSString *)glyph size:(CGFloat)size fill:(UIColor *)fill {
    if (size < 8) size = 8;
    UIColor *base = fill ?: [UIColor colorWithWhite:0.35 alpha:1];
    UIImage *mark = [self glyphNamed:glyph pointSize:size * 0.42] ?: [self glyphNamed:@"questionmark" pointSize:size * 0.42];
    return [[self _rendererWithSize:CGSizeMake(size, size)] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect bounds = CGRectMake(0, 0, size, size);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(bounds, 0.5, 0.5)];

        // the fill: a touch lighter at the top, like a lit button
        CGFloat r = 0, g = 0, b = 0, a = 1;
        if (![base getRed:&r green:&g blue:&b alpha:&a]) {
            CGFloat w = 0.35;
            [base getWhite:&w alpha:&a];
            r = g = b = w;
        }
        UIColor *top = [UIColor colorWithRed:r + (1 - r) * 0.22 green:g + (1 - g) * 0.22 blue:b + (1 - b) * 0.22 alpha:a];
        UIColor *bottom = [UIColor colorWithRed:r * 0.90 green:g * 0.90 blue:b * 0.90 alpha:a];
        CGContextSaveGState(c);
        [circle addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[ (__bridge id)top.CGColor, (__bridge id)bottom.CGColor ];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        if (gradient) {
            CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(0, size), 0);
            CGGradientRelease(gradient);
        } else {
            [base setFill];
            [circle fill];
        }
        CGColorSpaceRelease(space);
        CGContextRestoreGState(c);

        [[UIColor colorWithWhite:1 alpha:0.22] setStroke];
        circle.lineWidth = 1;
        [circle stroke];

        if (mark) {
            CGSize ms = mark.size;
            CGFloat room = size * 0.60;
            CGFloat k = MIN(1.0, room / MAX(1, MAX(ms.width, ms.height)));
            CGSize ds = CGSizeMake(ms.width * k, ms.height * k);
            CGRect where = CGRectMake((size - ds.width) / 2.0, (size - ds.height) / 2.0, ds.width, ds.height);
            [[mark imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:where];
        }
    }];
}

@end
