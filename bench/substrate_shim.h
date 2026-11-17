/*
 * Stands in for CydiaSubstrate when the original tweak (upstream/Tweak.m) is built for the iOS
 * simulator, where there is no hooking library. Only MSHookMessageEx is needed, and for
 * Objective-C methods it is nothing more than the runtime calls below (see substrate_shim.m).
 * The upstream source is compiled as it is: tools/sim_bench.sh only swaps its
 * "@import CydiaSubstrate;" line for an include of this header.
 */
#import <objc/runtime.h>

void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);
