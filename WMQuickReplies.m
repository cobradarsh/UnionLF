/*  WMQuickReplies.m — 5 ready replies per app, editable in the sheet.
    Stored in each app's own NSUserDefaults, so every app keeps its own set
    (WhatsApp, Tinder, Hopr ... each separately). Edit the defaults below.  */

#import "Wingman.h"

static NSString *const kWMQRKey = @"com.adarsh.wingman.quickReplies";

@implementation WMQuickReplies

+ (NSArray<NSString *> *)_defaultsForKind:(WMAppKind)kind {
    if (kind == WMAppKindDating) {
        return @[
            @"Okay your profile actually made me smile 😄 What's the story behind your last pic?",
            @"Coffee or cocktails, what's your go-to for a first date?",
            @"Tell me something about you that isn't on your profile",
            @"I'm enjoying this chat. Free for a quick call this week?",
            @"Okay I'm intrigued. Your turn to ask me something",
        ];
    }
    return @[
        @"Hey, just saw this! Give me a few mins, I'll get back to you",
        @"Can I call you in a bit?",
        @"Haha fair enough 😂",
        @"Sounds good 👍",
        @"Not feeling great today, resting. Will catch up soon",
    ];
}

+ (NSArray<NSString *> *)repliesForCurrentApp {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kWMQRKey];
    NSArray *defs = [self _defaultsForKind:[WMApps currentKind]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < kWMQuickReplyCount; i++) {
        NSString *v = (i < (NSInteger)saved.count && [saved[i] isKindOfClass:[NSString class]]
                       && [saved[i] length]) ? saved[i] : defs[i];
        [out addObject:v];
    }
    return out;
}

+ (void)setReply:(NSString *)text atIndex:(NSInteger)idx {
    if (idx < 0 || idx >= kWMQuickReplyCount) return;
    NSMutableArray *cur = [[self repliesForCurrentApp] mutableCopy];
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return;
    cur[idx] = t;
    [[NSUserDefaults standardUserDefaults] setObject:cur forKey:kWMQRKey];
}

+ (void)resetCurrentApp {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kWMQRKey];
}

@end
