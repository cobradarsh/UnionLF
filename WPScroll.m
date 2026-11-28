/*  WPScroll.m — auto-scroll: the app under SpringBoard scrolls itself; nothing is injected into it.

    A finger swipe is built as IOHIDEvents and dispatched through an IOHIDEventSystemClient. SpringBoard holds
    com.apple.private.hid.client.event-dispatch, so backboardd routes the touch to whatever is under the finger,
    like a real one.

    1.0.13 / 1.0.14 tried this and the swipes never moved anything. 1.0.39 follows the recipe of a touch
    injector known to work (ZXTouch / IOS13-SimulateTouch), which differed from ours in four ways:
      - the parent event is a HAND transducer (3; we sent 2, a finger) with index 99, identity 1 and no mask,
        and it carries IsDisplayIntegrated (0xB0019) and IsBuiltIn (0x4);
      - its event mask, range and touch (0xB0007 / 8 / 9 = 0x23, 1, 1) are set AFTER the finger is appended,
        and the finger has identity 3 and radii of 0.04;
      - the sender ID is the REAL touchscreen's (we used a made-up constant): read from the touchscreen
        service's registry ID, or caught from the next real touch;
      - integer fields are passed as CFIndex (64 bit; an int left the upper half of the register undefined).
    Every private function is resolved with dlsym, so a missing one only turns auto-scroll off.
    WPSelfTest can run a swipe on demand and log whether the screen moved.                                  */

#import "WPlus.h"
#import <mach/mach_time.h>
#import <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef double IOHIDFloat;
typedef void (*WPEventCallback)(void *target, void *refcon, void *service, IOHIDEventRef event);

typedef IOHIDEventSystemClientRef (*WPClientCreateFn)(CFAllocatorRef);
typedef void          (*WPDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef CFArrayRef    (*WPCopyServicesFn)(IOHIDEventSystemClientRef);
typedef CFTypeRef     (*WPServicePropertyFn)(IOHIDServiceClientRef, CFStringRef);
typedef CFTypeRef     (*WPServiceRegistryFn)(IOHIDServiceClientRef);
typedef IOHIDEventRef (*WPDigitizerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                       IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                       Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*WPFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                    Boolean, Boolean, uint32_t);
typedef void          (*WPAppendFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void          (*WPSetSenderFn)(IOHIDEventRef, uint64_t);
typedef void          (*WPSetIntFn)(IOHIDEventRef, uint32_t, CFIndex);
typedef void          (*WPSetFloatFn)(IOHIDEventRef, uint32_t, IOHIDFloat);
typedef uint32_t      (*WPGetTypeFn)(IOHIDEventRef);
typedef uint64_t      (*WPGetSenderFn)(IOHIDEventRef);
typedef void          (*WPScheduleFn)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
typedef void          (*WPRegisterFn)(IOHIDEventSystemClientRef, WPEventCallback, void *, void *);

static WPClientCreateFn pClientCreate; static WPDispatchFn pDispatch; static WPCopyServicesFn pCopyServices;
static WPServicePropertyFn pServiceProperty; static WPServiceRegistryFn pServiceRegistry;
static WPDigitizerFn pDigitizer; static WPFingerFn pFinger; static WPAppendFn pAppend;
static WPSetSenderFn pSetSender; static WPSetIntFn pSetInt; static WPSetFloatFn pSetFloat;
static WPGetTypeFn pGetType; static WPGetSenderFn pGetSender;
static WPScheduleFn pSchedule, pUnschedule; static WPRegisterFn pRegister, pUnregister;

static IOHIDEventSystemClientRef gClient;     // dispatches our events
static IOHIDEventSystemClientRef gWatcher;    // briefly sees real touches, for the touchscreen's sender ID
static uint64_t gSender;                      // the touchscreen's sender ID (0 = not found yet)
static NSString *gSenderSource = @"none";
static NSString *gServices = @"not listed yet";

static const uint64_t kWPFallbackSender  = 0x000000010000027FULL;   // what 1.0.14 used; only if nothing better
static const uint32_t kWPDigitizerEvents = 11;                      // kIOHIDEventTypeDigitizer

@interface WPScroll ()
+ (void)_senderFromServices;
+ (void)_stopWatching;
@end

@implementation WPScroll

+ (BOOL)_resolve {
    static BOOL ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pClientCreate    = (WPClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        pDispatch        = (WPDispatchFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        pCopyServices    = (WPCopyServicesFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
        pServiceProperty = (WPServicePropertyFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
        pServiceRegistry = (WPServiceRegistryFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
        pDigitizer       = (WPDigitizerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        pFinger          = (WPFingerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        pAppend          = (WPAppendFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        pSetSender       = (WPSetSenderFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        pSetInt          = (WPSetIntFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        pSetFloat        = (WPSetFloatFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        pGetType         = (WPGetTypeFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        pGetSender       = (WPGetSenderFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
        pSchedule        = (WPScheduleFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientScheduleWithRunLoop");
        pUnschedule      = (WPScheduleFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientUnscheduleWithRunLoop");
        pRegister        = (WPRegisterFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientRegisterEventCallback");
        pUnregister      = (WPRegisterFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientUnregisterEventCallback");
        BOOL fns = pClientCreate && pDispatch && pDigitizer && pFinger && pAppend && pSetSender && pSetInt;
        if (fns) gClient = pClientCreate(kCFAllocatorDefault);
        ok = fns && gClient != NULL;
        if (ok) [self _senderFromServices];
    });
    return ok;
}

// The touchscreen's events carry its service's registry ID as their sender ID.
+ (void)_senderFromServices {
    if (!pCopyServices || !pServiceProperty || !pServiceRegistry) { gServices = @"service functions missing"; return; }
    CFArrayRef services = pCopyServices(gClient);
    if (!services) { gServices = @"no services visible"; return; }
    NSMutableString *list = [NSMutableString string];
    uint64_t touch = 0, integrated = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!svc) continue;
        id page = CFBridgingRelease(pServiceProperty(svc, CFSTR("PrimaryUsagePage")));
        if (![page isKindOfClass:[NSNumber class]] || [page integerValue] != 0x0D) continue;   // digitizers only
        id usage = CFBridgingRelease(pServiceProperty(svc, CFSTR("PrimaryUsage")));
        id disp  = CFBridgingRelease(pServiceProperty(svc, CFSTR("DisplayIntegrated")));
        id name  = CFBridgingRelease(pServiceProperty(svc, CFSTR("Product")));
        uint64_t reg = 0;
        CFTypeRef rid = pServiceRegistry(svc);                       // a Get: not ours to release
        if (rid && CFGetTypeID(rid) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)rid, kCFNumberSInt64Type, &reg);
        NSInteger u = [usage isKindOfClass:[NSNumber class]] ? [usage integerValue] : -1;
        BOOL onScreen = [disp isKindOfClass:[NSNumber class]] && [disp boolValue];
        [list appendFormat:@"[%@ usage=%ld integrated=%d id=0x%llx] ",
                           [name isKindOfClass:[NSString class]] ? name : @"?", (long)u, onScreen, reg];
        if (u == 0x04 && reg && !touch) touch = reg;                 // usage 4 = touch screen
        if (onScreen && reg && !integrated) integrated = reg;
    }
    CFRelease(services);
    gServices = list.length ? [list copy] : @"no digitizer services";
    uint64_t pick = touch ?: integrated;
    if (pick && !gSender) {
        gSender = pick;
        gSenderSource = touch ? @"touchscreen service" : @"display-integrated service";
    }
}

static void WPRealTouch(void *target, void *refcon, void *service, IOHIDEventRef event) {
    if (!event || !pGetType || !pGetSender || pGetType(event) != kWPDigitizerEvents) return;
    uint64_t s = pGetSender(event);
    if (!s || [gSenderSource isEqualToString:@"real touch"]) return;
    gSender = s;
    gSenderSource = @"real touch";
    dispatch_async(dispatch_get_main_queue(), ^{ [WPScroll _stopWatching]; });
}

+ (void)watchForRealTouch {
    if (![self _resolve] || gWatcher || !pSchedule || !pRegister) return;
    if (gSender) return;            // the touchscreen service already gave it (it does on the iPhone 14 Pro Max)
    gWatcher = pClientCreate(kCFAllocatorDefault);
    if (!gWatcher) return;
    pSchedule(gWatcher, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    pRegister(gWatcher, WPRealTouch, NULL, NULL);
    // Never left listening: the finger that is on the bubble right now is all it needs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [WPScroll _stopWatching];
    });
}

+ (void)_stopWatching {
    if (!gWatcher) return;
    if (pUnregister) pUnregister(gWatcher, WPRealTouch, NULL, NULL);
    if (pUnschedule) pUnschedule(gWatcher, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRelease(gWatcher);
    gWatcher = NULL;
}

// One finger sample: a hand event with the finger appended, as the real touchscreen sends them.
static void WPSend(IOHIDFloat x, IOHIDFloat y, uint32_t mask, Boolean range, Boolean touch) {
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, ts, 3, 99, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return;
    pSetInt(hand, 0xB0019, 1);        // IsDisplayIntegrated: a touch on the screen itself
    pSetInt(hand, 0x4, 1);            // IsBuiltIn
    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts, 1, 3, mask, x, y, 0, 0, 0, range, touch, 0);
    if (finger) {
        if (pSetFloat) { pSetFloat(finger, 0xB0014, 0.04); pSetFloat(finger, 0xB0015, 0.04); }   // major / minor radius
        pAppend(hand, finger, 0);
        CFRelease(finger);
    }
    pSetInt(hand, 0xB0007, 0x23);     // event mask: range | touch | identity
    pSetInt(hand, 0xB0008, 1);        // range
    pSetInt(hand, 0xB0009, 1);        // touch
    pSetSender(hand, gSender ? gSender : kWPFallbackSender);
    pDispatch(gClient, hand);
    CFRelease(hand);
}

+ (BOOL)available { return [self _resolve]; }

+ (BOOL)swipeFrom:(CGPoint)a to:(CGPoint)b duration:(NSTimeInterval)duration hold:(NSTimeInterval)hold {
    if (![self _resolve]) return NO;
    WPSend(a.x, a.y, 3, 1, 1);                                        // down: range + touch
    int steps = MAX(8, (int)(duration / 0.012));
    useconds_t gap = (useconds_t)(duration / steps * 1e6);
    for (int i = 1; i <= steps; i++) {
        usleep(gap);
        double t = (double)i / steps;
        double e = t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);   // ease in and out: slows to a stop
        WPSend(a.x + (b.x - a.x) * e, a.y + (b.y - a.y) * e, 4, 1, 1); // move: position
    }
    // Hold still before lifting, so the scroll view stops with the finger instead of flinging on.
    for (NSTimeInterval held = 0; held < hold; held += 0.03) { usleep(30000); WPSend(b.x, b.y, 4, 1, 1); }
    WPSend(b.x, b.y, 2, 0, 0);                                        // up: touch changed, out of range
    return YES;
}

+ (NSString *)diagnostics {
    BOOL ok = [self _resolve];
    return [NSString stringWithFormat:@"resolved=%d sender=0x%llx (%@) digitizers: %@", ok,
            gSender ? gSender : kWPFallbackSender, gSender ? gSenderSource : @"fallback constant", gServices];
}

@end
