/*  WPScroll.m — make the app UNDER SpringBoard scroll itself, without touching it.

    We synthesize a finger swipe as a digitizer HID event and dispatch it through
    IOHIDEventSystemClient. SpringBoard is privileged, so backboardd routes the
    synthetic touch to whatever app is frontmost (Hinge) - exactly like a real finger -
    which lets "hold the bubble" auto-scroll a long profile. Nothing is injected into
    the dating app.

    Modeled on libSimulateTouch (iolate): the two things a synthetic touch MUST carry
    or the system drops it are a non-zero senderID and the display-integrated flag.
    Coordinates ride the finger sub-event (normalized 0..1); the hand event is zeroed.

    All private API, resolved with dlsym (IOKit is already loaded in SpringBoard) so the
    build never depends on the stub. A one-line status is written to
    /var/mobile/wingman_scroll.txt so we can tell resolution from routing failures.   */

#import "WPlus.h"
#import <mach/mach_time.h>
#import <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;

typedef IOHIDEventSystemClientRef (*ClientCreateFn)(CFAllocatorRef);
typedef void          (*DispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*DigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
    boolean_t, boolean_t, uint32_t);
typedef IOHIDEventRef (*FingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
typedef void (*AppendFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*SetSenderFn)(IOHIDEventRef, uint64_t);
typedef void (*SetIntFn)(IOHIDEventRef, uint32_t, int);

// digitizer event-mask bits
static const uint32_t MRange = 1, MTouch = 2, MPosition = 4, MIdentity = 32;
static const uint32_t kHandType              = 2;         // kIOHIDDigitizerTransducerTypeHand
static const uint32_t kFieldDisplayIntegrated = 0xB0019;  // kIOHIDEventFieldDigitizerIsDisplayIntegrated
static const uint64_t kSenderID              = 0x000000010000027FULL;  // any non-zero digitizer sender

static ClientCreateFn pClientCreate; static DispatchFn pDispatch;
static DigitizerFn pDigitizer; static FingerFn pFinger; static AppendFn pAppend;
static SetSenderFn pSetSender; static SetIntFn pSetInt;
static IOHIDEventSystemClientRef gClient; static BOOL gOK;

@implementation WPScroll

+ (void)_diag:(NSString *)s {
    @try { [s writeToFile:@"/var/mobile/wingman_scroll.txt" atomically:YES
                 encoding:NSUTF8StringEncoding error:nil]; } @catch (__unused id e) {}
}

+ (BOOL)_resolve {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pClientCreate = (ClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        pDispatch     = (DispatchFn)    dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        pDigitizer    = (DigitizerFn)   dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        pFinger       = (FingerFn)      dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        pAppend       = (AppendFn)      dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        pSetSender    = (SetSenderFn)   dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        pSetInt       = (SetIntFn)      dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        BOOL haveFns = pClientCreate && pDispatch && pDigitizer && pFinger && pAppend;
        if (haveFns) { @try { gClient = pClientCreate(kCFAllocatorDefault); } @catch (__unused id e) {} }
        gOK = haveFns && gClient;
        [self _diag:[NSString stringWithFormat:@"resolve fns=%d client=%d setSender=%d setInt=%d",
                     haveFns, (gClient != NULL), (pSetSender != NULL), (pSetInt != NULL)]];
    });
    return gOK;
}

// One finger sample: coords on the finger sub-event, flags on the hand event.
+ (void)_sendX:(IOHIDFloat)x y:(IOHIDFloat)y handMask:(uint32_t)hm fingerMask:(uint32_t)fm
         range:(boolean_t)range touch:(boolean_t)touch {
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, ts, kHandType, 0, 1, hm, 0,
                                    0, 0, 0, 0, 0, range, touch, 0);
    if (!hand) return;
    if (pSetSender) pSetSender(hand, kSenderID);
    if (pSetInt)    pSetInt(hand, kFieldDisplayIntegrated, 1);   // <- real touchscreen touch
    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts, 1, 2, fm, x, y, 0, 0, 0, range, touch, 0);
    if (finger) { pAppend(hand, finger, 0); CFRelease(finger); }
    @try { pDispatch(gClient, hand); } @catch (__unused id e) {}
    CFRelease(hand);
}

// Swipe UP through the middle => content scrolls ~one screen DOWN. Flick-like so scroll
// views actually fling. Call OFF the main thread (it uses usleep).
+ (void)swipeUp {
    if (![self _resolve]) return;
    const IOHIDFloat x = 0.5, y0 = 0.80, y1 = 0.18;
    [self _sendX:x y:y0 handMask:(MRange|MTouch|MIdentity) fingerMask:(MRange|MTouch) range:1 touch:1];  // down
    usleep(12000);
    const int steps = 14;
    for (int i = 1; i <= steps; i++) {
        IOHIDFloat y = y0 + (y1 - y0) * ((IOHIDFloat)i / steps);
        [self _sendX:x y:y handMask:MPosition fingerMask:MPosition range:1 touch:1];                     // move
        usleep(8000);
    }
    [self _sendX:x y:y1 handMask:(MRange|MTouch|MPosition) fingerMask:(MRange|MTouch) range:0 touch:0];  // up
    [self _diag:@"swipeUp dispatched (sender+displayIntegrated set)"];
}

@end
