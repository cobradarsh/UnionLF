/*  WMApps.m — decides which apps show the Wingman bubble.
    Chat + dating apps are auto-detected; anything else (e.g. Hopr)
    is picked by you from the installed-apps list in Settings.      */

#import "Wingman.h"

@implementation WMApps

+ (NSSet<NSString *> *)_chatApps {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"net.whatsapp.WhatsApp",           // WhatsApp
            @"net.whatsapp.WhatsAppSMB",        // WhatsApp Business
            @"ph.telegra.Telegraph",            // Telegram
            @"com.burbn.instagram",             // Instagram
            @"com.facebook.Messenger",          // Messenger
            @"com.facebook.Facebook",           // Facebook
            @"com.toyopagroup.picaboo",         // Snapchat
            @"org.whispersystems.signal",       // Signal
            @"com.hammerandchisel.discord",     // Discord
            @"com.atebits.Tweetie2",            // X / Twitter
            @"com.linkedin.LinkedIn",           // LinkedIn
            @"jp.naver.line",                   // LINE
            @"com.viber",                       // Viber
            @"com.tencent.xin",                 // WeChat
            @"com.tinyspeck.chatlyio",          // Slack
            @"com.microsoft.skype.teams",       // Teams
            @"com.google.Dynamite",             // Google Chat
            @"com.reddit.Reddit",               // Reddit
            @"com.zhiliaoapp.musically",        // TikTok
            @"com.apple.MobileSMS",             // Messages (see note in reply)
        ]];
    });
    return s;
}

+ (NSSet<NSString *> *)_datingApps {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"com.cardify.tinder",              // Tinder
            @"com.moxco.bumble",                // Bumble
            @"co.hinge.app",                    // Hinge
            @"com.okcupid.app",                 // OkCupid
            @"com.badoo.Badoo",                 // Badoo
            @"com.ftw_and_co.happn",            // happn
            @"com.grindrguy.grindrx",           // Grindr
            @"com.pof.mobileapp",               // Plenty of Fish
            @"com.match.match.com",             // Match
            @"com.coffeemeetsbagel.cmb",        // Coffee Meets Bagel
        ]];
    });
    return s;
}

// fallback for dating apps whose bundle IDs vary by region/version
+ (BOOL)_looksLikeDating:(NSString *)bid {
    NSString *b = bid.lowercaseString;
    for (NSString *t in @[@"tinder", @"bumble", @"hinge", @"okcupid", @"badoo", @"happn",
                          @"grindr", @"feeld", @"aisle", @"trulymadly", @"quackquack",
                          @"coffeemeetsbagel", @"hily", @"dating", @"raya", @"tantan"]) {
        if ([b containsString:t]) return YES;
    }
    return NO;
}

// Same idea for chat apps: TrollStore / sideloaded builds (dual installs, tweaked IPAs) often carry a
// changed bundle id, so an exact-id list misses them even though the app's name is right there in it.
+ (BOOL)_looksLikeChat:(NSString *)bid {
    NSString *b = bid.lowercaseString;
    for (NSString *t in @[@"whatsapp", @"telegra", @"instagram", @"messenger", @"snapchat", @"signal",
                          @"discord", @"reddit", @"tiktok", @"musically", @"viber", @"wechat", @"tencent.xin",
                          @"slack", @"chatlyio", @"skype", @"tweetie", @"twitter", @"linkedin", @"facebook",
                          @"naver.line", @"hinge", @"bumble"]) {
        if ([b containsString:t]) return YES;
    }
    return NO;
}

+ (WMAppKind)kindForBundleID:(NSString *)bid {
    if (bid.length == 0) return WMAppKindNone;
    WMSettings *s = [WMSettings shared];
    // Apps you picked yourself are ADDED to the built-in lists. (They used to REPLACE them: tapping Done in
    // the picker switched auto-detection off, so one extra pick silently hid the bubble everywhere else.)
    for (NSString *m in s.manualApps)
        if ([m caseInsensitiveCompare:bid] == NSOrderedSame) return WMAppKindManual;
    if ([[self _datingApps] containsObject:bid] || [self _looksLikeDating:bid]) return WMAppKindDating;
    if ([[self _chatApps] containsObject:bid] || [self _looksLikeChat:bid]) return WMAppKindChat;
    return WMAppKindNone;
}

+ (WMAppKind)currentKind {
    // only real apps, never extensions (keyboards, share sheets, widgets)
    if (![[NSBundle mainBundle].bundlePath hasSuffix:@".app"]) return WMAppKindNone;
    return [self kindForBundleID:[NSBundle mainBundle].bundleIdentifier];
}

+ (NSString *)currentAppName {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSString *n = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
    return n.length ? n : ([NSBundle mainBundle].bundleIdentifier ?: @"this app");
}

@end
