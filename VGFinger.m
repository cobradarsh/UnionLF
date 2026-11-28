// Tests only (VGDebug.m's "finger" command): a real touch inside the app, made the way KIF makes
// them (github.com/kif-framework/KIF, UITouch-KIFAdditions and IOHIDEvent+KIF): a UITouch with its
// private setters, an IOHIDEvent describing the finger, the app's touches event, -[UIApplication
// sendEvent:]. Gesture recognizers then see it exactly as a finger: a test of the real tap and hold.
// Nothing here runs unless a test command asks for it. The IOKit functions are looked up when first
// needed, so the library links nothing more.
#import "VidGrabUI.h"
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;                                   // 64-bit

enum {
    kVGDigitizerTransducerHand = 3,
    kVGDigitizerEventRange = 0x1,
    kVGDigitizerEventTouch = 0x2,
    kVGDigitizerEventPosition = 0x4,
    kVGFieldDigitizerIsDisplayIntegrated = (11 << 16) + 25,  // kIOHIDEventTypeDigitizer, field 25
};

static IOHIDEventRef (*gCreateHand)(CFAllocatorRef, uint64_t, uint32_t type, uint32_t index, uint32_t identity, uint32_t eventMask,
                                    uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure,
                                    IOHIDFloat barrelPressure, Boolean range, Boolean touch, uint32_t options);
static IOHIDEventRef (*gCreateFinger)(CFAllocatorRef, uint64_t, uint32_t index, uint32_t identity, uint32_t eventMask,
                                      IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat twist,
                                      IOHIDFloat minorRadius, IOHIDFloat majorRadius, IOHIDFloat quality, IOHIDFloat density,
                                      IOHIDFloat irregularity, Boolean range, Boolean touch, uint32_t options);
static void (*gAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t options);
static void (*gSetInteger)(IOHIDEventRef, uint32_t field, long value);

static BOOL VGFingerReady(NSString **problem) {
    static BOOL ready, tried;
    if (tried) {
        if (!ready && problem) *problem = @"IOKit's event functions are not there";
        return ready;
    }
    tried = YES;
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    void *where = iokit ?: RTLD_DEFAULT;
    gCreateHand = dlsym(where, "IOHIDEventCreateDigitizerEvent");
    gCreateFinger = dlsym(where, "IOHIDEventCreateDigitizerFingerEventWithQuality");
    gAppend = dlsym(where, "IOHIDEventAppendEvent");
    gSetInteger = dlsym(where, "IOHIDEventSetIntegerValue");
    ready = gCreateHand && gCreateFinger && gAppend && gSetInteger;
    if (!ready && problem) *problem = @"IOKit's event functions are not there";
    return ready;
}

/// The hand-and-finger event for one touch in its current phase.
static IOHIDEventRef VGHIDEvent(CGPoint point, UITouchPhase phase) {
    uint64_t now = mach_absolute_time();
    IOHIDEventRef hand = gCreateHand(kCFAllocatorDefault, now, kVGDigitizerTransducerHand, 0, 0, kVGDigitizerEventTouch, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0);
    gSetInteger(hand, kVGFieldDigitizerIsDisplayIntegrated, 1);
    uint32_t mask = phase == UITouchPhaseMoved ? kVGDigitizerEventPosition : (kVGDigitizerEventRange | kVGDigitizerEventTouch);
    Boolean touching = phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled;
    IOHIDEventRef finger = gCreateFinger(kCFAllocatorDefault, now, 1, 2, mask, point.x, point.y, 0, 0, 0, 5, 5, 1, 1, 1,
                                         touching, touching, 0);
    gSetInteger(finger, kVGFieldDigitizerIsDisplayIntegrated, 1);
    gAppend(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

static BOOL VGHas(id object, SEL selector) { return [object respondsToSelector:selector]; }

static void VGSetObject(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (VGHas(object, selector)) ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}
static void VGSetBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if (VGHas(object, selector)) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}
static void VGSetInteger(id object, NSString *name, NSInteger value) {
    SEL selector = NSSelectorFromString(name);
    if (VGHas(object, selector)) ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, value);
}
static void VGSetTime(id object, NSString *name, NSTimeInterval value) {
    SEL selector = NSSelectorFromString(name);
    if (VGHas(object, selector)) ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(object, selector, value);
}

/// Hands the touch, in this phase, to the app as UIKit would. nil when it was sent.
static NSString *VGSendTouch(UITouch *touch, CGPoint point, UITouchPhase phase) {
    VGSetTime(touch, @"setTimestamp:", NSProcessInfo.processInfo.systemUptime);
    VGSetInteger(touch, @"setPhase:", phase);
    UIApplication *app = UIApplication.sharedApplication;
    SEL touchesEvent = NSSelectorFromString(@"_touchesEvent");
    if (!VGHas(app, touchesEvent)) return @"no -[UIApplication _touchesEvent]";
    UIEvent *event = ((id (*)(id, SEL))objc_msgSend)(app, touchesEvent);
    SEL clear = NSSelectorFromString(@"_clearTouches"), setHID = NSSelectorFromString(@"_setHIDEvent:");
    SEL add = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
    if (!VGHas(event, clear) || !VGHas(event, setHID) || !VGHas(event, add)) return @"the touches event lacks a method KIF uses";
    ((void (*)(id, SEL))objc_msgSend)(event, clear);
    IOHIDEventRef hid = VGHIDEvent(point, phase);
    ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(event, setHID, hid);
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, add, touch, NO);
    [app sendEvent:event];
    CFRelease(hid);
    return nil;
}

/// A finger that is down: every tenth of a second a "still here", as KIF sends, then the lift.
/// (performSelector:afterDelay: keeps it alive until each tick has run.)
@interface VGFinger : NSObject
@property (nonatomic, strong) UITouch *touch;
@property (nonatomic) CGPoint point;
@property (nonatomic) NSTimeInterval seconds, held;
@property (nonatomic, copy) void (^done)(NSString *problem);
@end

@implementation VGFinger
- (void)tick {
    self.held += 0.1;
    if (self.held + 0.001 < self.seconds) {
        NSString *trouble = VGSendTouch(self.touch, self.point, UITouchPhaseStationary);
        if (trouble) {
            self.done(trouble);
            return;
        }
        [self performSelector:@selector(tick) withObject:nil afterDelay:0.1 inModes:@[NSRunLoopCommonModes]];
        return;
    }
    self.done(VGSendTouch(self.touch, self.point, UITouchPhaseEnded));
}
@end

void VGFingerPress(UIWindow *window, CGPoint point, NSTimeInterval seconds, void (^done)(NSString *problem)) {
    NSString *problem = nil;
    if (!window) { done(@"no window"); return; }
    if (!VGFingerReady(&problem)) { done(problem); return; }
    // a new touch, as UITouch-KIFAdditions makes one
    UITouch *touch = [UITouch new];
    VGSetObject(touch, @"setWindow:", window);                       // first: it wipes other values
    VGSetInteger(touch, @"setTapCount:", 1);
    SEL locate = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    if (!VGHas(touch, locate)) { done(@"no -[UITouch _setLocationInWindow:resetPrevious:]"); return; }
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, locate, point, YES);
    UIView *view = [window hitTest:point withEvent:nil];
    VGSetObject(touch, @"setView:", view);
    VGSetInteger(touch, @"setPhase:", UITouchPhaseBegan);
    VGSetBool(touch, @"_setIsTapToClick:", NO);
    VGSetBool(touch, @"_setIsFirstTouchForView:", YES);
    VGSetBool(touch, @"setIsTap:", YES);
    VGSetTime(touch, @"setTimestamp:", NSProcessInfo.processInfo.systemUptime);
    VGSetObject(touch, @"setGestureView:", view);
    SEL touchHID = NSSelectorFromString(@"_setHidEvent:");
    if (VGHas(touch, touchHID)) {
        IOHIDEventRef hid = VGHIDEvent(point, UITouchPhaseBegan);
        ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(touch, touchHID, hid);
        CFRelease(hid);
    }
    problem = VGSendTouch(touch, point, UITouchPhaseBegan);
    if (problem) { done(problem); return; }
    VGFinger *finger = [VGFinger new];
    finger.touch = touch;
    finger.point = point;
    finger.seconds = seconds;
    finger.done = done;
    [finger performSelector:@selector(tick) withObject:nil afterDelay:MIN(0.1, seconds) inModes:@[NSRunLoopCommonModes]];
}
