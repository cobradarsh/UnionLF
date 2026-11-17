/*
 * MSHookMessageEx for the simulator build of the original tweak. Same contract as the real one:
 * replace the class's implementation of a method (adding it when the class only inherits it) and
 * hand back the implementation that was in effect before. A missing class or method is skipped,
 * as ElleKit does on the phone.
 */
#import "substrate_shim.h"

void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old) {
    if (!_class) return;
    Method method = class_getInstanceMethod(_class, message);
    if (!method) return;
    IMP inherited = method_getImplementation(method);
    IMP replaced = class_replaceMethod(_class, message, hook, method_getTypeEncoding(method));
    if (old) *old = replaced ? replaced : inherited;
}
