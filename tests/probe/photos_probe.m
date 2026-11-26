// Loaded into the test app ("Clips") in the simulator: writes what Photos says about the app's
// access, and with PROBE_ASK=1 asks for full access (a picture of the screen then shows whether
// iOS put up its question). For tools/photos_probe.sh.
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>

static void ProbeWrite(NSString *line) {
    NSString *dir = NSProcessInfo.processInfo.environment[@"PROBE_DIR"] ?: NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:@"probe.log"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [NSData.data writeToFile:path atomically:NO];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

__attribute__((constructor)) static void ProbeStart(void) {
    NSString *variant = NSProcessInfo.processInfo.environment[@"PROBE_VARIANT"] ?: @"?";
    PHAuthorizationStatus full = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    PHAuthorizationStatus add = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    ProbeWrite([NSString stringWithFormat:@"%@: full %ld, add-only %ld (0 not asked, 2 allowed, 3 limited)", variant, (long)full, (long)add]);
    if ([NSProcessInfo.processInfo.environment[@"PROBE_ASK"] isEqualToString:@"1"]) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
            ProbeWrite([NSString stringWithFormat:@"%@: asked, answer %ld", variant, (long)status]);
        }];
    }
}
