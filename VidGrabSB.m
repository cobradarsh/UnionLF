// VidGrab's part in SpringBoard: the hand-over to GIF Stash.
//
// An app with VidGrab cannot write into GIF Stash's container (the sandbox), SpringBoard can.
// The app puts a finished clip (<id>.gif, .mp4, .jpg, .json) into its own temporary folder under
// vidgrab-outbox/<id>/ and posts a notification; this moves the clip into GIF Stash's library,
// leaves a one-line answer next to the folder, and tells GIF Stash that its library changed.
// Nothing else happens here: no hooks, no timers.
#import <Foundation/Foundation.h>
#include <notify.h>
#include <unistd.h>

static NSString *const kApp = @"com.cobradarsh.gifstash";
static NSString *const kGroup = @"group.com.cobradarsh.gifstash";

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@end

static void SBLog(NSString *line) {
    NSString *path = @"/var/mobile/Library/Logs/VidGrab.log";
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *attributes = [files attributesOfItemAtPath:path error:NULL];
    if (!attributes || [attributes fileSize] > 64 * 1024) [NSData.data writeToFile:path atomically:NO];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    [handle writeData:[[NSString stringWithFormat:@"%@ %@\n", [format stringFromDate:NSDate.date], line] dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

/// GIF Stash's "Stash" folder, or nil while the app is not installed or has never been opened.
static NSString *LibraryFolder(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if ([proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        LSApplicationProxy *proxy = [proxyClass applicationProxyForIdentifier:kApp];
        NSDictionary *groups = [proxy respondsToSelector:@selector(groupContainerURLs)] ? proxy.groupContainerURLs : nil;
        NSURL *url = [groups isKindOfClass:NSDictionary.class] ? groups[kGroup] : nil;
        if ([url isKindOfClass:NSURL.class]) {
            NSString *folder = [url.path stringByAppendingPathComponent:@"Stash"];
            if ([files fileExistsAtPath:folder]) return folder;
        }
    }
    NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
    for (NSString *name in [files contentsOfDirectoryAtPath:base error:NULL] ?: @[]) {
        NSString *container = [base stringByAppendingPathComponent:name];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
                                  [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([metadata[@"MCMMetadataIdentifier"] isEqual:kGroup]) {
            NSString *folder = [container stringByAppendingPathComponent:@"Stash"];
            if ([files fileExistsAtPath:folder]) return folder;
        }
    }
    return nil;
}

static BOOL Bring(NSString *from, NSString *to) {
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtPath:to error:NULL];
    // a second name for the same file: nothing is copied, and the app may delete its own name afterwards
    if (link(from.fileSystemRepresentation, to.fileSystemRepresentation) == 0) return YES;
    return [files copyItemAtPath:from toPath:to error:NULL];
}

static void TakeOutboxes(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSInteger taken = 0;
    for (NSString *app in [files contentsOfDirectoryAtPath:base error:NULL] ?: @[]) {
        NSString *outbox = [[base stringByAppendingPathComponent:app] stringByAppendingPathComponent:@"tmp/vidgrab-outbox"];
        NSArray<NSString *> *clips = [files contentsOfDirectoryAtPath:outbox error:NULL];
        for (NSString *itemID in clips ?: @[]) {
            NSString *folder = [outbox stringByAppendingPathComponent:itemID];
            BOOL isFolder = NO;
            if (![files fileExistsAtPath:folder isDirectory:&isFolder] || !isFolder) continue;
            NSString *json = [folder stringByAppendingPathComponent:[itemID stringByAppendingString:@".json"]];
            NSString *gif = [folder stringByAppendingPathComponent:[itemID stringByAppendingString:@".gif"]];
            if (![files fileExistsAtPath:json] || ![files fileExistsAtPath:gif]) continue;       // still being made
            NSString *answer = [outbox stringByAppendingPathComponent:[itemID stringByAppendingString:@".result"]];
            if ([files fileExistsAtPath:answer]) continue;                                       // already dealt with
            // only names VidGrab makes: nothing else is ever written into GIF Stash's library
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"];
            NSString *result;
            NSString *library = LibraryFolder();
            if (![itemID hasPrefix:@"vg-"] || [itemID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
                result = @"The clip has a name GIF Stash would not know.";
            } else if (!library) {
                result = @"GIF Stash is not installed, or has not been opened yet. Open it once, then try again.";
            } else {
                BOOL ok = YES;
                for (NSString *ending in @[@"gif", @"mp4", @"jpg"]) {
                    NSString *from = [folder stringByAppendingPathComponent:[itemID stringByAppendingPathExtension:ending]];
                    if (![files fileExistsAtPath:from]) continue;
                    if (!Bring(from, [library stringByAppendingPathComponent:[itemID stringByAppendingPathExtension:ending]])) ok = NO;
                }
                // the description last: GIF Stash lists a clip once this file is there
                NSData *description = [NSData dataWithContentsOfFile:json];
                if (ok) ok = [description writeToFile:[library stringByAppendingPathComponent:[itemID stringByAppendingString:@".json"]] atomically:YES];
                result = ok ? @"ok" : @"The clip could not be put into GIF Stash's library.";
                if (ok) taken++;
            }
            [result writeToFile:answer atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            SBLog([NSString stringWithFormat:@"clip %@ from %@: %@", itemID, app, result]);
        }
    }
    if (taken) notify_post("com.cobradarsh.gifstash.changed");      // GIF Stash and its keyboard button re-read the library
}

__attribute__((constructor)) static void VidGrabSBInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        static dispatch_queue_t queue;
        queue = dispatch_queue_create("com.adarsh.vidgrab.stash", DISPATCH_QUEUE_SERIAL);
        int token = 0;
        notify_register_dispatch("com.adarsh.vidgrab/stash", &token, queue, ^(int t) {
            @autoreleasepool {
                @try {
                    TakeOutboxes();
                } @catch (NSException *exception) {
                    SBLog([NSString stringWithFormat:@"hand-over threw %@: %@", exception.name, exception.reason]);
                }
            }
        });
        dispatch_async(queue, ^{ SBLog(@"VidGrab's GIF Stash hand-over is ready in SpringBoard"); });
    }
}
