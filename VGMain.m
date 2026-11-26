// VidGrab 2 — where it starts, in each app it is loaded into.
#import "VidGrabUI.h"

__attribute__((constructor)) static void VidGrabInit(void) {
    @autoreleasepool {
        NSBundle *main = NSBundle.mainBundle;
        NSString *identifier = main.bundleIdentifier;
        if (!identifier) return;
        // Apps only: not their share or notification extensions, not SpringBoard (VidGrabSB is its part there).
        if (![main.bundlePath.pathExtension isEqualToString:@"app"]) return;
        if ([identifier isEqualToString:@"com.apple.springboard"]) return;
        VGCaptureInstall();
        VGGesturesInstall();
        VGDebugStart();
        VGLog(@"VidGrab %@ in %@ (%@): %@, %@", VG_VERSION, identifier, main.executablePath.lastPathComponent,
              VGCaptureHookSummary(), [VGPrefs enabled] ? @"on" : @"switched off for this app");
    }
}
