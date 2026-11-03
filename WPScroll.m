/*  WPScroll.m — make the app UNDER SpringBoard scroll itself, without touching it.

    We post digitizer (touch) events into the system HID layer via
    IOHIDEventSystemClient. Because SpringBoard is a privileged process, these synthetic
    touches are routed by backboardd to whatever app is frontmost (Hinge) - exactly like
    a real finger - so "hold the bubble" can auto-scroll a long profile and snapshot each
    screen, while nothing is ever injected into the dating app.

    The IOHIDEvent* symbols are private and not in the public IOKit stub, so we resolve
    them at RUNTIME with dlsym (IOKit is already loaded in SpringBoard). That way the
    build never fails to link, and if a symbol is somehow missing the swipe is just a
    no-op - the caller's end-detection then stops after the first frame.               */

#import "WPlus.h"
#import <mach/mach_time.h>
#import <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;

typedef IOHIDEventSystemClientRef (*ClientCreateFn)(CFAllocatorRef);
typedef void (*DispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*DigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
    boolean_t, boolean_t, uint32_t);
typedef IOHIDEventRef (*FingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
typedef void (*AppendFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);

static const uint32_t kHandType     = 2;           // kIOHIDDigitizerTransducerTypeHand
static const uint32_t kMaskRange    = 0x00000001;  // kIOHIDDigitizerEventRange
static const uint32_t kMaskTouch    = 0x00000002;  // kIOHIDDigitizerEventTouch
static const uint32_t kMaskPosition = 0x00000004;  // kIOHIDDigitizerEventPosition

static ClientCreateFn pClientCreate;
static DispatchFn     pDispatch;
static DigitizerFn    pDigitizer;
static FingerFn       pFinger;
static AppendFn       pAppend;
static IOHIDEventSystemClientRef gClient;
static BOOL gResolved;

@implementation WPScroll

+ (BOOL)_resolve {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pClientCreate = (ClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        pDispatch     = (DispatchFn)   dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        pDigitizer    = (DigitizerFn)  dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        pFinger       = (FingerFn)     dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        pAppend       = (AppendFn)     dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        if (pClientCreate && pDispatch && pDigitizer && pFinger && pAppend) {
            @try { gClient = pClientCreate(kCFAllocatorDefault); } @catch (__unused id e) {}
            gResolved = (gClient != NULL);
        }
    });
    return gResolved;
}

// Post one finger sample (down / move / up) at normalized (x,y) in [0,1].
+ (void)_postX:(IOHIDFloat)x y:(IOHIDFloat)y touch:(boolean_t)touch range:(boolean_t)range mask:(uint32_t)mask {
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef parent = pDigitizer(kCFAllocatorDefault, ts, kHandType, 1, 1, mask, 0,
                                      x, y, 0, 0, 0, range, touch, 0);
    if (!parent) return;
    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts, 1, 2, mask,
                                   x, y, 0, 0, 0, range, touch, 0);
    if (finger) { pAppend(parent, finger, 0); CFRelease(finger); }
    @try { pDispatch(gClient, parent); } @catch (__unused id e) {}
    CFRelease(parent);
}

// A swipe UP through the middle of the screen => content scrolls ~one screen DOWN.
// Short, flick-like motion so scroll views actually move. Call OFF the main thread
// (it uses usleep).
+ (void)swipeUp {
    if (![self _resolve]) return;
    const IOHIDFloat x = 0.5, y0 = 0.74, y1 = 0.24;
    const uint32_t downUp = kMaskTouch | kMaskPosition | kMaskRange;
    [self _postX:x y:y0 touch:1 range:1 mask:downUp];            // finger down
    usleep(16000);
    const int steps = 12;
    for (int i = 1; i <= steps; i++) {
        IOHIDFloat y = y0 + (y1 - y0) * ((IOHIDFloat)i / steps);
        [self _postX:x y:y touch:1 range:1 mask:kMaskPosition];  // move
        usleep(9000);
    }
    [self _postX:x y:y1 touch:0 range:0 mask:downUp];            // finger up (lift)
}

@end
