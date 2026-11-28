// Face ID (or Touch ID), with the passcode as the way in when the face is not recognised.
#import "GuestMode.h"
#import <LocalAuthentication/LocalAuthentication.h>

#ifdef GM_TEST
static NSString *gTestAnswer;                               // nil or "real": the real check
void GMAuthSetTestAnswer(NSString *answer) {
    gTestAnswer = [answer isEqualToString:@"real"] ? nil : [answer copy];
}
#endif

static BOOL gAsking;

void GMAuthenticate(NSString *reason, void (^done)(BOOL ok, NSString *detail)) {
    if (gAsking) {                                          // a second tap while the Face ID sheet is up
        done(NO, @"already asking");
        return;
    }
#ifdef GM_TEST
    if (gTestAnswer) {
        BOOL pass = [gTestAnswer isEqualToString:@"pass"];
        dispatch_async(dispatch_get_main_queue(), ^{ done(pass, pass ? @"test answer: pass" : @"test answer: fail"); });
        return;
    }
#endif
    gAsking = YES;
    LAContext *context = [LAContext new];
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *detail) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gAsking = NO;
            done(ok, detail);
        });
    };
    NSError *why = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&why]) {
        if (why.code == LAErrorPasscodeNotSet) {
            // A phone without a passcode has nothing to check against; refusing would lock its owner in.
            finish(YES, @"no passcode on this iPhone: nothing to check");
        } else {
            finish(NO, [NSString stringWithFormat:@"cannot check: %@ (%ld)", why.localizedDescription, (long)why.code]);
        }
        return;
    }
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:reason reply:^(BOOL success, NSError *error) {
        if (success) {
            finish(YES, @"authenticated");
        } else if (error.code == LAErrorPasscodeNotSet) {
            finish(YES, @"no passcode on this iPhone: nothing to check");
        } else {
            finish(NO, [NSString stringWithFormat:@"not authenticated: %@ (%ld)", error.localizedDescription, (long)error.code]);
        }
    }];
}
