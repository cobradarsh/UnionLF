/*  tools/click.c — a mouse click or drag at a point of the Mac's screen (for the simulator touch test).

    The simulator turns a click on its window into a finger on the phone's screen, which is the
    only way to put a real touch through the window server of a simulated iPhone from a script.

    usage: click <x> <y> [hold seconds]            a click
           click drag <x1> <y1> <x2> <y2> [s] [h]  press at the first point, slide to the second in s seconds,
                                                   and keep the finger down there for h seconds
           (global display points, origin at the top left)
    build: clang -o click tools/click.c -framework ApplicationServices                        */

#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void post(CGEventType type, CGPoint p) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, kCGMouseButtonLeft);
    if (!e) return;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

int main(int argc, char **argv) {
    if (argc >= 6 && strcmp(argv[1], "drag") == 0) {
        CGPoint a = CGPointMake(atof(argv[2]), atof(argv[3])), b = CGPointMake(atof(argv[4]), atof(argv[5]));
        double seconds = argc > 6 ? atof(argv[6]) : 0.4;
        double hold = argc > 7 ? atof(argv[7]) : 0.0;
        int steps = 24;
        post(kCGEventMouseMoved, a);
        usleep(200000);
        post(kCGEventLeftMouseDown, a);
        usleep(60000);
        for (int i = 1; i <= steps; i++) {
            CGPoint p = CGPointMake(a.x + (b.x - a.x) * i / steps, a.y + (b.y - a.y) * i / steps);
            post(kCGEventLeftMouseDragged, p);
            usleep((useconds_t)(seconds * 1000000 / steps));
        }
        usleep(60000 + (useconds_t)(hold * 1000000));
        post(kCGEventLeftMouseUp, b);
        usleep(100000);
        return 0;
    }
    if (argc < 3) return 2;
    CGPoint p = CGPointMake(atof(argv[1]), atof(argv[2]));
    double hold = argc > 3 ? atof(argv[3]) : 0.08;
    post(kCGEventMouseMoved, p);
    usleep(200000);
    post(kCGEventLeftMouseDown, p);
    usleep((useconds_t)(hold * 1000000));
    post(kCGEventLeftMouseUp, p);
    usleep(100000);
    return 0;
}
