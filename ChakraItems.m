/*  ChakraItems.m — what sits on the wheel.

    An entry is one of three things:
      app       a bundle id; shows the app's own icon
      action    a system action from ChakraActions; shows a glyph disc (lit while a toggle is on)
      shortcut  one of the shortcuts filled in under Settings → Chakra: a link, a URL scheme or
                the name of a shortcut in the Shortcuts app; shows the glyph picked there

    The list is kept in the preferences as @[ @{ k = app|action|shortcut, id = … } ]. Until the
    wheel has been edited once, a starter set is shown instead.                              */

#import "Chakra.h"

static NSCache<NSString *, UIImage *> *gIcons;

static NSURL *ChakraRunShortcutURL(NSString *name) {
    NSString *plain = [name stringByRemovingPercentEncoding] ?: name;
    NSMutableCharacterSet *ok = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [ok removeCharactersInString:@"&=+?#"];
    NSString *enc = [plain stringByAddingPercentEncodingWithAllowedCharacters:ok];
    if (enc.length == 0) return nil;
    return [NSURL URLWithString:[@"shortcuts://run-shortcut?name=" stringByAppendingString:enc]];
}

// What a shortcut's "Link or Shortcut Name" field means:
//   weixin://scan, tel:123, https://…      a URL, opened as it is
//   example.com/page                       a web address without its https://
//   shortcut://Morning                     the spelling the app this idea came from used
//   Morning Routine                        anything else: a shortcut in the Shortcuts app, by name
static NSURL *ChakraURLForTarget(NSString *raw) {
    NSString *t = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (t.length == 0) return nil;
    BOOL spaces = [t rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound;
    if (!spaces) {
        NSRange scheme = [t rangeOfString:@"^[A-Za-z][A-Za-z0-9+.\\-]*:" options:NSRegularExpressionSearch];
        if (scheme.location == 0 && scheme.length > 0) {
            if ([t.lowercaseString hasPrefix:@"shortcut://"]) return ChakraRunShortcutURL([t substringFromIndex:11]);
            NSURL *u = [NSURL URLWithString:t];
            if (u) return u;
            NSString *enc = [t stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLFragmentAllowedCharacterSet];
            return enc.length ? [NSURL URLWithString:enc] : nil;
        }
        if ([t containsString:@"."] && ![t hasPrefix:@"."] && ![t hasSuffix:@"."]) {
            NSURL *u = [NSURL URLWithString:[@"https://" stringByAppendingString:t]];
            if (u) return u;
        }
    }
    return ChakraRunShortcutURL(t);
}

static UIColor *ChakraSlotColor(NSInteger slot) {
    switch (((slot - 1) % 4 + 4) % 4) {
        case 0:  return [UIColor colorWithRed:0xFF / 255.0 green:0x9F / 255.0 blue:0x0A / 255.0 alpha:1];   // orange
        case 1:  return [UIColor colorWithRed:0xBF / 255.0 green:0x5A / 255.0 blue:0xF2 / 255.0 alpha:1];   // purple
        case 2:  return [UIColor colorWithRed:0x32 / 255.0 green:0xAD / 255.0 blue:0xE6 / 255.0 alpha:1];   // cyan
        default: return [UIColor colorWithRed:0xFF / 255.0 green:0x37 / 255.0 blue:0x5F / 255.0 alpha:1];   // pink
    }
}

@implementation ChakraItem

+ (instancetype)itemWithKind:(ChakraKind)kind ident:(NSString *)ident {
    if (![ident isKindOfClass:NSString.class] || ident.length == 0) return nil;
    ChakraItem *item = [ChakraItem new];
    item->_kind = kind;
    item->_ident = [ident copy];
    return item;
}

+ (instancetype)itemFromDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:NSDictionary.class]) return nil;
    NSString *k = d[@"k"], *ident = d[@"id"];
    if (![k isKindOfClass:NSString.class] || ![ident isKindOfClass:NSString.class]) return nil;
    if ([k isEqualToString:@"app"])      return [self itemWithKind:ChakraKindApp ident:ident];
    if ([k isEqualToString:@"action"])   return [self itemWithKind:ChakraKindAction ident:ident];
    if ([k isEqualToString:@"shortcut"]) return [self itemWithKind:ChakraKindShortcut ident:ident];
    return nil;
}

- (NSString *)_kindName {
    switch (_kind) {
        case ChakraKindApp:    return @"app";
        case ChakraKindAction: return @"action";
        default:           return @"shortcut";
    }
}

- (NSDictionary *)dictionary { return @{ @"k": [self _kindName], @"id": _ident }; }
- (NSString *)key { return [NSString stringWithFormat:@"%@:%@", [self _kindName], _ident]; }
- (BOOL)isEqual:(id)other { return [other isKindOfClass:ChakraItem.class] && [[(ChakraItem *)other key] isEqualToString:self.key]; }
- (NSUInteger)hash { return self.key.hash; }
- (NSString *)description { return self.key; }

- (NSInteger)_slot { return _ident.integerValue; }

- (NSString *)title {
    switch (_kind) {
        case ChakraKindApp:
            return [ChakraHost displayNameForBundleID:_ident];
        case ChakraKindAction:
            return [ChakraActions actionWithID:_ident].title ?: _ident;
        default: {
            ChakraSettings *s = [ChakraSettings shared];
            NSString *name = [s slotName:[self _slot]];
            if (name.length) return name;
            NSString *target = [s slotTarget:[self _slot]];
            if (target.length == 0) return [NSString stringWithFormat:@"Shortcut %ld", (long)[self _slot]];
            NSURL *u = ChakraURLForTarget(target);
            if ([u.scheme isEqualToString:@"shortcuts"]) return target;          // a Shortcuts name
            if (u.host.length) return u.host;
            return u.scheme.length ? u.scheme : target;
        }
    }
}

- (NSString *)subtitle {
    switch (_kind) {
        case ChakraKindApp:
            return [self available] ? @"App" : @"App · not installed";
        case ChakraKindAction: {
            ChakraAction *a = [ChakraActions actionWithID:_ident];
            if (!a) return @"Action · unknown";
            if (![self available]) return @"Action · not available on this iOS";
            return a.toggle ? @"Switch" : @"Action";
        }
        default: {
            NSString *target = [[ChakraSettings shared] slotTarget:[self _slot]];
            if (target.length == 0) return @"Shortcut · empty: fill it in under Settings → Chakra";
            return [NSString stringWithFormat:@"Shortcut · %@", target];
        }
    }
}

- (BOOL)available {
    switch (_kind) {
        case ChakraKindApp:    return [ChakraHost applicationForBundleID:_ident] != nil;
        case ChakraKindAction: return [ChakraActions available:_ident];
        default: {
            NSInteger slot = [self _slot];
            return slot >= 1 && slot <= CHAKRA_SLOTS && [[ChakraSettings shared] slotTarget:slot].length > 0;
        }
    }
}

- (BOOL)isToggle { return _kind == ChakraKindAction && [ChakraActions actionWithID:_ident].toggle; }
- (BOOL)isOn     { return [self isToggle] && [ChakraActions isOn:_ident]; }

- (UIImage *)iconWithSize:(CGFloat)size {
    if (!gIcons) gIcons = [NSCache new];
    if (_kind == ChakraKindApp) {
        NSString *ck = [@"app|" stringByAppendingString:_ident];
        UIImage *img = [gIcons objectForKey:ck];
        if (!img) {
            img = [ChakraHost iconForBundleID:_ident];
            if (img) [gIcons setObject:img forKey:ck];
        }
        if (img) return img;
        return [ChakraGlyphs discWithGlyph:@"app.dashed" size:size fill:[UIColor colorWithWhite:0.25 alpha:1]];
    }
    NSString *glyph = nil;
    UIColor *fill = nil;
    if (_kind == ChakraKindAction) {
        ChakraAction *a = [ChakraActions actionWithID:_ident];
        BOOL lit = !a.toggle || [ChakraActions isOn:_ident];
        glyph = (!lit && a.glyphOff.length) ? a.glyphOff : (a.glyph ?: @"questionmark");
        fill = lit ? (a.tint ?: [ChakraSettings shared].accentColor) : [UIColor colorWithWhite:0.24 alpha:0.96];
    } else {
        glyph = [[ChakraSettings shared] slotGlyph:[self _slot]];
        if (glyph.length == 0) glyph = @"star.fill";
        fill = ChakraSlotColor([self _slot]);
    }
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [fill getRed:&r green:&g blue:&b alpha:&a];
    NSString *ck = [NSString stringWithFormat:@"%@|%@|%.0f|%.3f %.3f %.3f %.2f", self.key, glyph, size, r, g, b, a];
    UIImage *img = [gIcons objectForKey:ck];
    if (!img) {
        img = [ChakraGlyphs discWithGlyph:glyph size:size fill:fill];
        if (img) [gIcons setObject:img forKey:ck];
    }
    return img;
}

- (void)perform {
    switch (_kind) {
        case ChakraKindApp: {
            BOOL ok = [ChakraHost launchApp:_ident];
            ChakraLog(@"open app %@ -> %d", _ident, ok);
            break;
        }
        case ChakraKindAction:
            [ChakraActions perform:_ident];
            break;
        default: {
            NSString *target = [[ChakraSettings shared] slotTarget:[self _slot]];
            NSURL *u = ChakraURLForTarget(target);
            if (!u) {
                [ChakraHost toast:@"This shortcut is empty. Fill it in under Settings → Chakra."];
                break;
            }
            ChakraLog(@"shortcut %ld -> %@", (long)[self _slot], u.scheme);
            [ChakraHost openURL:u];
            break;
        }
    }
}

@end

@implementation ChakraItems

+ (NSArray<ChakraItem *> *)starterItems {
    NSMutableArray<ChakraItem *> *out = [NSMutableArray array];
    for (NSString *bid in @[ @"com.apple.mobilephone", @"com.apple.MobileSMS", @"com.apple.mobilesafari",
                             @"com.apple.camera", @"com.apple.Preferences" ]) {
        ChakraItem *item = [ChakraItem itemWithKind:ChakraKindApp ident:bid];
        if ([item available]) [out addObject:item];
    }
    for (NSString *ident in @[ @"lastapp", @"screenshot", @"flashlight" ]) {
        ChakraItem *item = [ChakraItem itemWithKind:ChakraKindAction ident:ident];
        if ([item available]) [out addObject:item];
    }
    return out;
}

+ (NSArray<ChakraItem *> *)all {
    NSArray<NSDictionary *> *saved = [[ChakraSettings shared] savedItems];
    if (!saved) return [self starterItems];
    NSMutableArray<ChakraItem *> *out = [NSMutableArray array];
    for (NSDictionary *d in saved) {
        ChakraItem *item = [ChakraItem itemFromDictionary:d];
        if (!item || [out containsObject:item]) continue;
        [out addObject:item];
        if (out.count >= CHAKRA_MAX_ITEMS) break;
    }
    return out;
}

+ (NSArray<ChakraItem *> *)visible {
    NSMutableArray<ChakraItem *> *out = [NSMutableArray array];
    for (ChakraItem *item in [self all]) if ([item available]) [out addObject:item];
    // the way into the editor, always last (unless it has been put on the wheel by hand, or switched off)
    if ([ChakraSettings shared].editEntry) {
        ChakraItem *edit = [ChakraItem itemWithKind:ChakraKindAction ident:@"edit"];
        if (edit && ![out containsObject:edit]) [out addObject:edit];
    }
    return out;
}

+ (NSArray<NSString *> *)_appsIn:(NSArray<ChakraItem *> *)items {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (ChakraItem *item in items) if (item.kind == ChakraKindApp) [out addObject:item.ident];
    return out;
}

+ (void)save:(NSArray<ChakraItem *> *)items {
    NSMutableArray *raw = [NSMutableArray array];
    NSMutableArray<ChakraItem *> *kept = [NSMutableArray array];
    for (ChakraItem *item in items) {
        [raw addObject:[item dictionary]];
        [kept addObject:item];
        if (raw.count >= CHAKRA_MAX_ITEMS) break;
    }
    [[ChakraSettings shared] setSavedItems:raw];
    // what Settings → Chakra → Apps on the Wheel shows as switched on
    [[ChakraSettings shared] setObject:[self _appsIn:kept] forKey:@"apps"];
}

// Settings → Chakra → Apps on the Wheel is a list of every app with a switch each; it writes the
// bundle ids that are switched on. The wheel itself keeps an ordered list that also holds actions
// and shortcuts, so the two are brought in line here: apps switched on there are added at the
// end, apps switched off are taken away, and nothing else moves. Whenever the wheel changes
// (the editor, or this), the list for Settings is written back, so any difference found here was
// made in Settings.
+ (void)syncPickedApps {
    ChakraSettings *s = [ChakraSettings shared];
    NSArray<NSString *> *picked = [s pickedApps];
    NSArray<ChakraItem *> *current = [self all];
    NSArray<NSString *> *have = [self _appsIn:current];
    if (!picked) {                                           // never written: tell Settings what is on the wheel
        [s setObject:have forKey:@"apps"];
        return;
    }
    if ([[NSSet setWithArray:picked] isEqualToSet:[NSSet setWithArray:have]]) return;

    NSMutableArray<ChakraItem *> *next = [NSMutableArray array];
    for (ChakraItem *item in current) {
        if (item.kind != ChakraKindApp || [picked containsObject:item.ident]) [next addObject:item];
    }
    NSUInteger removed = current.count - next.count, added = 0, noRoom = 0;
    for (NSString *bid in picked) {
        if ([have containsObject:bid]) continue;
        ChakraItem *item = [ChakraItem itemWithKind:ChakraKindApp ident:bid];
        if (!item || [next containsObject:item]) continue;
        if (next.count >= CHAKRA_MAX_ITEMS) { noRoom++; continue; }
        [next addObject:item];
        added++;
    }
    [self save:next];
    ChakraLog(@"apps picked in Settings: %lu added, %lu taken off%@", (unsigned long)added, (unsigned long)removed,
              noRoom ? [NSString stringWithFormat:@", %lu did not fit", (unsigned long)noRoom] : @"");
    if (noRoom) [ChakraHost toast:[NSString stringWithFormat:@"The wheel holds %d entries, so %lu of the apps you picked did not fit.",
                                   CHAKRA_MAX_ITEMS, (unsigned long)noRoom]];
}

// What a double tap, triple tap or hold on the ball is set to. nil = nothing (or something that can't run now).
+ (ChakraItem *)itemForGesture:(NSString *)which {
    ChakraSettings *s = [ChakraSettings shared];
    NSString *value = [s gesture:which];
    ChakraItem *item = nil;
    if ([value isEqualToString:@"app"]) item = [ChakraItem itemWithKind:ChakraKindApp ident:[s gestureApp:which]];
    else if ([value hasPrefix:@"action:"]) item = [ChakraItem itemWithKind:ChakraKindAction ident:[value substringFromIndex:7]];
    else if ([value hasPrefix:@"shortcut:"]) item = [ChakraItem itemWithKind:ChakraKindShortcut ident:[value substringFromIndex:9]];
    return [item available] ? item : nil;
}

// App icons come from the system the first time they are asked for, which can take a moment
// each. Asking ahead, one at a time, keeps the first open of the wheel from waiting for them.
+ (void)warmIcons {
    NSArray<ChakraItem *> *items = [self visible];
    CGFloat size = [ChakraSettings shared].iconSize;
    [items enumerateObjectsUsingBlock:^(ChakraItem *item, NSUInteger i, BOOL *stop) {
        ChakraAfter(0.15 * i, ^{
            @try { [item iconWithSize:size]; } @catch (__unused id e) {}
        });
    }];
}

+ (void)flushIcons { [gIcons removeAllObjects]; }

@end
