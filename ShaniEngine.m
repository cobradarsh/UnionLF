/*  ShaniEngine.m — which apps are on the list, what is being held, when it comes up, the log.

    Per app on the list (state.plist):
      since      when it went on the list
      passedTo   notifications dated up to here are not Shani's business any more (they were
                 shown, or they are older than the listing). SpringBoard hands every stored
                 notification out again after a respring; this is how those pass untouched.
      until      end of the hold that is open now, 0 when none is
      seen       identifiers of notifications already dealt with (shown, released, tapped)

    Two ways of silencing (Settings → Shani → Silence Starts):
      Every time     the app stays on the list. A new notification opens a hold that lasts the
                     chosen time; everything arriving meanwhile joins it; all come up when it ends.
      Once per tap   a tap on Shani opens one hold from that moment. When it ends the held
                     notifications come up and the app notifies as usual until the next tap.

    The requests that are held live in memory only. After a respring SpringBoard posts them
    again and they are held again, because `until` is on disk.

    State is guarded by @synchronized(self): the dispatcher's methods have always been seen on
    the main thread, but nothing here relies on it. Posting to the system happens outside the lock. */

#import "Shani.h"
#import <notify.h>

@interface NSObject (ShaniPersistentTimer)             // PCPersistentTimer: fires on time even if the phone has to wake for it
- (instancetype)initWithTimeInterval:(double)interval serviceIdentifier:(NSString *)identifier target:(id)target selector:(SEL)selector userInfo:(id)userInfo;
@end

NSString *ShaniBundleOf(id request) {
    return ShaniStr(request, @"sectionIdentifier") ?: @"";
}

NSString *ShaniIdentifierOf(id request) {
    NSString *nid = ShaniStr(request, @"notificationIdentifier");
    if (nid.length) return nid;
    id uuid = ShaniMsg(request, @"uuid");
    if ([uuid isKindOfClass:NSUUID.class]) return [(NSUUID *)uuid UUIDString];
    return [NSString stringWithFormat:@"%p", request];
}

NSString *ShaniAppName(NSString *bundleID) {
    if (bundleID.length == 0) return @"";
    Class cls = NSClassFromString(@"SBApplicationController");
    id ctl = [cls respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")] ? ShaniMsg(cls, @"sharedInstanceIfExists") : ShaniMsg(cls, @"sharedInstance");
    NSString *name = ShaniStr(ShaniMsgObj(ctl, @"applicationWithBundleIdentifier:", bundleID), @"displayName");
    return name.length ? name : bundleID;
}

static double ShaniTimestampOf(id request, double fallback) {
    id date = ShaniMsg(request, @"timestamp");
    return [date isKindOfClass:NSDate.class] ? [(NSDate *)date timeIntervalSince1970] : fallback;
}

static BOOL ShaniSame(id a, id b) {
    if (a == b) return YES;
    SEL s = NSSelectorFromString(@"matchesRequest:");
    if (ShaniShape(a, s, "Bc", 1)) {
        @try { if (((BOOL (*)(id, SEL, id))objc_msgSend)(a, s, b)) return YES; } @catch (__unused id e) {}
    }
    return [ShaniBundleOf(a) isEqualToString:ShaniBundleOf(b)] && [ShaniIdentifierOf(a) isEqualToString:ShaniIdentifierOf(b)];
}

#pragma mark - the notification log (files)

static dispatch_queue_t ShaniStoreQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.adarsh.shani.store", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void ShaniTellSettings(void) {                   // after the files are written
    dispatch_async(ShaniStoreQueue(), ^{ notify_post(SHANI_NOTE_CHANGED); });
}

static NSString *ShaniClip(NSString *text, NSUInteger max) {
    if (![text isKindOfClass:NSString.class]) return @"";
    return text.length > max ? [[text substringToIndex:max] stringByAppendingString:@"…"] : text;
}

static NSMutableDictionary *ShaniEntryFor(id request, ShaniFate fate, double due) {
    id content = ShaniMsg(request, @"content");
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[@"t"] = @(ShaniNow());
    e[@"id"] = ShaniIdentifierOf(request);
    e[@"title"] = ShaniClip(ShaniStr(content, @"title"), 200);
    e[@"sub"] = ShaniClip(ShaniStr(content, @"subtitle"), 200);
    e[@"msg"] = ShaniClip(ShaniStr(content, @"message"), 800);
    e[@"st"] = @(fate);
    if (due > 0) e[@"due"] = @(due);
    return e;
}

static void ShaniNoteAppend(NSString *bundleID, NSDictionary *entry) {
    NSInteger limit = [ShaniSettings shared].logLimit;
    dispatch_async(ShaniStoreQueue(), ^{
        NSMutableArray *all = [ShaniReadNoteLog(bundleID) mutableCopy];
        // SpringBoard hands a held notification out again after a respring: that is the same
        // line in the log, with the time it first came
        NSUInteger again = NSNotFound;
        for (NSUInteger i = all.count; i-- > 0 && all.count - i <= 400;) {
            if ([all[i][@"id"] isEqual:entry[@"id"]]) { again = i; break; }
        }
        if (again != NSNotFound) {
            NSMutableDictionary *m = [entry mutableCopy];
            if (all[again][@"t"]) m[@"t"] = all[again][@"t"];
            all[again] = m;
        } else {
            [all addObject:entry];
        }
        if ((NSInteger)all.count > limit) [all removeObjectsInRange:NSMakeRange(0, all.count - (NSUInteger)limit)];
        [all writeToFile:ShaniNoteLogPath(bundleID) atomically:YES];
    });
    ShaniTellSettings();
}

// Entries with these identifiers get new fields; with `onlyHeld`, only those still marked as held.
static void ShaniNoteUpdate(NSString *bundleID, NSArray<NSString *> *identifiers, NSDictionary *fields, BOOL onlyHeld) {
    if (identifiers.count == 0) return;
    NSSet<NSString *> *ids = [NSSet setWithArray:identifiers];
    dispatch_async(ShaniStoreQueue(), ^{
        NSArray<NSDictionary *> *all = ShaniReadNoteLog(bundleID);
        NSMutableArray *next = [NSMutableArray arrayWithCapacity:all.count];
        BOOL changed = NO;
        for (NSDictionary *e in all) {
            BOOL hit = [e[@"id"] isKindOfClass:NSString.class] && [ids containsObject:e[@"id"]];
            if (hit && onlyHeld && [e[@"st"] integerValue] != ShaniFateHeld) hit = NO;
            if (!hit) { [next addObject:e]; continue; }
            NSMutableDictionary *m = [e mutableCopy];
            [m addEntriesFromDictionary:fields];
            [m removeObjectForKey:@"due"];
            [next addObject:m];
            changed = YES;
        }
        if (changed) {
            [next writeToFile:ShaniNoteLogPath(bundleID) atomically:YES];
            notify_post(SHANI_NOTE_CHANGED);
        }
    });
}

#pragma mark - a quiet copy

// The same notification without banner, sound or screen wake: it goes straight to the list.
static id ShaniQuietCopy(id request) {
    @try {
        if (![request respondsToSelector:@selector(mutableCopyWithZone:)]) return request;
        id quiet = [request mutableCopy];
        if (!ShaniShape(quiet, NSSelectorFromString(@"setRequestDestinations:"), "v", 1)) return request;
        id dest = ShaniMsg(request, @"requestDestinations");
        if ([dest isKindOfClass:NSSet.class]) {
            NSMutableSet *left = [(NSSet *)dest mutableCopy];
            [left removeObject:@"BulletinDestinationBanner"];
            if (left.count == 0) return request;                // a banner-only notification stays as it was
            ShaniSendObj(quiet, @"setRequestDestinations:", left);
        }
        ShaniSendObj(quiet, @"setSound:", nil);
        id options = ShaniMsg(request, @"options");
        if ([options respondsToSelector:@selector(mutableCopyWithZone:)]) {
            id o = [options mutableCopy];
            ShaniSendBool(o, @"setCanPlaySound:", NO);
            ShaniSendBool(o, @"setCanTurnOnDisplay:", NO);
            ShaniSendObj(quiet, @"setOptions:", o);
        }
        return quiet;
    } @catch (NSException *e) {
        ShaniLog(@"quiet copy threw %@", e.reason);
    }
    return request;
}

#pragma mark - engine

@implementation ShaniEngine {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_apps;
    NSMutableDictionary<NSString *, NSMutableArray *> *_held;
    NSMutableDictionary<NSString *, id> *_last;
    id _wakeTimer;                    // PCPersistentTimer
    NSTimer *_plainTimer;
    BOOL _loaded;
    BOOL _threadNoted;
}

+ (instancetype)shared {
    static ShaniEngine *e;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        e = [ShaniEngine new];
        e->_apps = [NSMutableDictionary dictionary];
        e->_held = [NSMutableDictionary dictionary];
        e->_last = [NSMutableDictionary dictionary];
    });
    return e;
}

static NSMutableDictionary *ShaniFreshApp(double now) {
    return [@{ @"since": @(now), @"passedTo": @(now), @"until": @0.0, @"seen": [NSMutableArray array] } mutableCopy];
}

- (void)_loadLocked {
    if (_loaded) return;
    _loaded = YES;
    NSDictionary *saved = ShaniReadState()[@"apps"];
    double now = ShaniNow();
    if ([saved isKindOfClass:NSDictionary.class]) {
        for (NSString *bid in saved) {
            NSDictionary *d = saved[bid];
            if (![bid isKindOfClass:NSString.class] || ![d isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *st = ShaniFreshApp(now);
            for (NSString *key in @[ @"since", @"passedTo", @"until" ]) {
                if ([d[key] respondsToSelector:@selector(doubleValue)]) st[key] = @([d[key] doubleValue]);
            }
            st[@"seen"] = [ShaniCleanList(d[@"seen"]) mutableCopy];
            _apps[bid] = st;
        }
    }
    // the list in Settings is the one that counts
    NSArray<NSString *> *listed = [ShaniSettings shared].apps;
    for (NSString *bid in listed) if (!_apps[bid]) _apps[bid] = ShaniFreshApp(now);
    for (NSString *bid in _apps.allKeys) if (![listed containsObject:bid]) [_apps removeObjectForKey:bid];
}

- (void)_saveLocked {
    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    for (NSString *bid in _apps) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        NSDictionary *st = _apps[bid];
        d[@"since"] = st[@"since"] ?: @0.0;
        d[@"passedTo"] = st[@"passedTo"] ?: @0.0;
        d[@"until"] = st[@"until"] ?: @0.0;
        d[@"seen"] = [st[@"seen"] copy] ?: @[];
        d[@"held"] = @([_held[bid] count]);
        apps[bid] = d;
    }
    NSDictionary *state = @{ @"v": @1, @"saved": @(ShaniNow()), @"apps": apps };
    dispatch_async(ShaniStoreQueue(), ^{ [state writeToFile:ShaniStatePath() atomically:YES]; });
    ShaniTellSettings();
}

static void ShaniRemember(NSMutableDictionary *st, NSString *identifier) {
    NSMutableArray *seen = st[@"seen"];
    if (![seen isKindOfClass:NSMutableArray.class]) { seen = [NSMutableArray array]; st[@"seen"] = seen; }
    if (identifier.length == 0 || [seen containsObject:identifier]) return;
    [seen addObject:identifier];
    if (seen.count > 400) [seen removeObjectsInRange:NSMakeRange(0, seen.count - 400)];
}

- (void)start {
    @synchronized (self) { [self _loadLocked]; [self _saveLocked]; }
    ShaniSettings *s = [ShaniSettings shared];
    ShaniLog(@"engine: %lu app(s) on the list, %@ per hold, %@, release style %ld", (unsigned long)s.apps.count, ShaniPeriodText(s.minutes),
             s.mode == ShaniModeEveryTime ? @"every time" : @"once per tap", (long)s.releaseStyle);
    [self _schedule];
}

- (void)settingsChanged {
    ShaniSettings *s = [ShaniSettings shared];
    NSArray<NSString *> *listed = s.apps;
    NSMutableArray<NSString *> *gone = [NSMutableArray array];
    double now = ShaniNow();
    @synchronized (self) {
        [self _loadLocked];
        for (NSString *bid in listed) {
            if (_apps[bid]) continue;
            _apps[bid] = ShaniFreshApp(now);
            ShaniLog(@"list: + %@", bid);
        }
        for (NSString *bid in _apps.allKeys) if (![listed containsObject:bid]) [gone addObject:bid];
    }
    for (NSString *bid in gone) {
        [self _releaseApp:bid upTo:now why:@"taken off the list"];
        @synchronized (self) { [_apps removeObjectForKey:bid]; }
        ShaniLog(@"list: - %@", bid);
    }
    if (!s.enabled) [self releaseEverything:@"Shani switched off"];
    @synchronized (self) { [self _saveLocked]; }
    [self _schedule];
}

#pragma mark from the hooks

- (BOOL)holdsNewRequest:(id)request {
    ShaniSettings *s = [ShaniSettings shared];
    NSString *bid = ShaniBundleOf(request);
    if (bid.length == 0) return NO;
    if (!_threadNoted) {
        _threadNoted = YES;
        ShaniLog(@"first notification through the hook (%@ thread)", NSThread.isMainThread ? @"main" : @"a background");
    }
    @synchronized (self) {
        [self _loadLocked];
        _last[bid] = request;
        if (!s.enabled || !_apps[bid]) return NO;
    }
    [self releaseDue];

    BOOL hold = NO, opened = NO, critical = NO, stale = NO;
    double now = ShaniNow(), until = 0;
    NSString *nid = ShaniIdentifierOf(request);
    @synchronized (self) {
        NSMutableDictionary *st = _apps[bid];
        if (!st) return NO;
        NSMutableArray *held = _held[bid];
        for (NSUInteger i = 0; i < held.count; i++) {           // the same one again: keep the newer object, say nothing
            if (!ShaniSame(held[i], request)) continue;
            held[i] = request;
            return YES;
        }
        double t = ShaniTimestampOf(request, now);
        until = [st[@"until"] doubleValue];
        if ([st[@"seen"] containsObject:nid] || t <= [st[@"passedTo"] doubleValue]) {
            stale = YES;                                        // dealt with before, or older than the listing
        } else if (ShaniBoolMsg(request, @"isCriticalAlert", NO)) {
            critical = YES;
            ShaniRemember(st, nid);
        } else {
            if (s.mode == ShaniModeEveryTime) {
                if (until <= 0) { until = now + s.minutes * 60.0; st[@"until"] = @(until); opened = YES; }
                hold = YES;
            } else {
                hold = until > now;
            }
            if (hold) {
                if (!held) { held = [NSMutableArray array]; _held[bid] = held; }
                [held addObject:request];
            } else {
                ShaniRemember(st, nid);
            }
        }
        if (!stale) [self _saveLocked];
    }
    if (stale) {
        // one that was held when SpringBoard restarted after its time was up: it is shown now
        ShaniNoteUpdate(bid, @[ nid ], @{ @"st": @(ShaniFateReleased), @"rel": @(now) }, YES);
        return NO;
    }
    ShaniNoteAppend(bid, ShaniEntryFor(request, critical ? ShaniFateCritical : (hold ? ShaniFateHeld : ShaniFateShown), hold ? until : 0));
    if (hold) {
        ShaniLog(@"hold %@ until %@%@", bid, ShaniClockText(until), opened ? @" (new hold)" : @"");
        if (opened) [self _schedule];
    } else {
        ShaniLog(@"pass %@ (%@)", bid, critical ? @"critical alert" : @"no hold open");
    }
    return hold;
}

- (BOOL)holdsModifiedRequest:(id)request {
    NSString *bid = ShaniBundleOf(request);
    if (bid.length == 0) return NO;
    @synchronized (self) {
        NSMutableArray *held = _held[bid];
        for (NSUInteger i = 0; i < held.count; i++) {
            if (!ShaniSame(held[i], request)) continue;
            held[i] = request;
            return YES;
        }
    }
    return NO;
}

- (void)requestWithdrawn:(id)request {
    NSString *bid = ShaniBundleOf(request);
    if (bid.length == 0) return;
    BOOL was = NO;
    @synchronized (self) {
        NSMutableArray *held = _held[bid];
        for (NSUInteger i = 0; i < held.count; i++) {
            if (!ShaniSame(held[i], request)) continue;
            [held removeObjectAtIndex:i];
            was = YES;
            break;
        }
        if (was) {
            ShaniRemember(_apps[bid], ShaniIdentifierOf(request));
            [self _saveLocked];
        }
    }
    if (was) {
        ShaniNoteUpdate(bid, @[ ShaniIdentifierOf(request) ], @{ @"st": @(ShaniFateWithdrawn) }, YES);
        ShaniLog(@"held one of %@ was taken back by the app", bid);
    }
}

#pragma mark the button

- (BOOL)isSilencing:(NSString *)bundleID {
    if (bundleID.length == 0) return NO;
    @synchronized (self) {
        [self _loadLocked];
        NSDictionary *st = _apps[bundleID];
        if (!st) return NO;
        if ([ShaniSettings shared].mode == ShaniModeEveryTime) return YES;
        return [st[@"until"] doubleValue] > ShaniNow();
    }
}

- (NSString *)buttonTitleFor:(NSString *)bundleID {
    return [self isSilencing:bundleID] ? @"Shani Off" : @"Shani";
}

static void ShaniHapticDone(void) {
    if (![ShaniSettings shared].haptic) return;
    @try { [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess]; } @catch (__unused id e) {}
}

- (void)tapOnRequest:(id)request via:(NSString *)where systemClears:(BOOL)systemClears {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tapOnRequest:request via:where systemClears:systemClears]; });
        return;
    }
    ShaniSettings *s = [ShaniSettings shared];
    NSString *bid = ShaniBundleOf(request);
    if (bid.length == 0 || !s.enabled) return;
    NSString *name = ShaniAppName(bid);
    double now = ShaniNow();

    if ([self isSilencing:bid]) {                               // "Shani Off"
        if (s.mode == ShaniModeEveryTime) {
            NSMutableArray<NSString *> *apps = [s.apps mutableCopy];
            [apps removeObject:bid];
            [s setApps:apps];
            [self settingsChanged];                             // shows what was held, forgets the app
        } else {
            [self _releaseApp:bid upTo:now why:@"Shani Off"];
        }
        ShaniLog(@"tap (%@): %@ off", where, bid);
        if (s.toast) ShaniToast(name, @"Shani off · notifies as usual");
        ShaniHapticDone();
        return;
    }

    double until = 0;
    @synchronized (self) {
        [self _loadLocked];
        NSMutableDictionary *st = _apps[bid];
        if (!st) { st = ShaniFreshApp(now); _apps[bid] = st; }
        if (s.mode == ShaniModeOncePerTap) { until = now + s.minutes * 60.0; st[@"until"] = @(until); }
        ShaniRemember(st, ShaniIdentifierOf(request));
        [self _saveLocked];
    }
    if (![s.apps containsObject:bid]) [s setApps:[s.apps arrayByAddingObject:bid]];
    ShaniNoteAppend(bid, ShaniEntryFor(request, ShaniFateTapped, 0));
    ShaniLog(@"tap (%@): %@ on%@", where, bid, until > 0 ? [@", silent until " stringByAppendingString:ShaniClockText(until)] : @"");
    if (!systemClears && s.clearOnTap) [self clearRequests:@[ request ]];
    [self _schedule];
    if (s.toast) {
        ShaniToast(name, until > 0 ? [NSString stringWithFormat:@"Silent until %@", ShaniClockText(until)]
                                   : [NSString stringWithFormat:@"Shani on · held %@ at a time", ShaniPeriodText(s.minutes)]);
    }
    ShaniHapticDone();
}

#pragma mark release

- (id)_liveDispatcher {
    id d = self.dispatcher;
    if (d) return d;
    d = ShaniMsg(ShaniMsg(UIApplication.sharedApplication, @"notificationDispatcher"), @"dispatcher");
    if (d) self.dispatcher = d;
    return d;
}

// Everything held for the app comes up (or goes to the log only), and its hold is over.
- (void)_releaseApp:(NSString *)bid upTo:(double)passedTo why:(NSString *)why {
    ShaniSettings *s = [ShaniSettings shared];
    NSArray *held = nil;
    @synchronized (self) {
        NSMutableDictionary *st = _apps[bid];
        if (!st) return;
        held = [_held[bid] copy];
        [_held removeObjectForKey:bid];
        if ([st[@"until"] doubleValue] <= 0 && held.count == 0) return;
        st[@"until"] = @0.0;
        st[@"passedTo"] = @(MAX(passedTo, [st[@"passedTo"] doubleValue]));
        for (id r in held) ShaniRemember(st, ShaniIdentifierOf(r));
        [self _saveLocked];
    }
    ShaniReleaseStyle style = s.enabled ? s.releaseStyle : ShaniReleaseQuiet;
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id r in held) [ids addObject:ShaniIdentifierOf(r)];
    double now = ShaniNow();
    if (held.count == 0) {
        ShaniLog(@"release %@: nothing was held (%@)", bid, why);
    } else if (style == ShaniReleaseLogOnly) {
        [self clearRequests:held];
        ShaniNoteUpdate(bid, ids, @{ @"st": @(ShaniFateLogOnly), @"rel": @(now) }, YES);
        ShaniLog(@"release %@: %lu kept in the log only (%@)", bid, (unsigned long)held.count, why);
    } else {
        id dispatcher = [self _liveDispatcher];
        void (^post)(id, id) = self.post;
        NSUInteger shown = 0;
        for (NSUInteger i = 0; i < held.count; i++) {
            BOOL loud = style == ShaniReleaseEachAlerts || (style == ShaniReleaseOneAlert && i == held.count - 1);
            id r = loud ? held[i] : ShaniQuietCopy(held[i]);
            if (!dispatcher || !post) break;
            @try { post(dispatcher, r); shown++; } @catch (NSException *e) { ShaniLog(@"posting a held notification threw %@", e.reason); }
        }
        ShaniNoteUpdate(bid, ids, @{ @"st": @(ShaniFateReleased), @"rel": @(now) }, YES);
        ShaniLog(@"release %@: %lu of %lu shown (%@, style %ld)%@", bid, (unsigned long)shown, (unsigned long)held.count, why, (long)style,
                 (dispatcher && post) ? @"" : @" NO DISPATCHER");
    }
    [self _schedule];
}

- (void)releaseApp:(NSString *)bundleID reason:(NSString *)why {
    [self _releaseApp:bundleID upTo:ShaniNow() why:why];
}

- (void)releaseDue {
    double now = ShaniNow();
    NSMutableDictionary<NSString *, NSNumber *> *due = [NSMutableDictionary dictionary];
    @synchronized (self) {
        for (NSString *bid in _apps) {
            double until = [_apps[bid][@"until"] doubleValue];
            if (until > 0 && now >= until) due[bid] = @(until);
        }
    }
    // notifications dated after the hold's end are new ones: they must not pass as "old"
    for (NSString *bid in due) [self _releaseApp:bid upTo:due[bid].doubleValue why:@"time is up"];
}

- (void)releaseEverything:(NSString *)why {
    NSArray<NSString *> *all;
    @synchronized (self) { all = _apps.allKeys; }
    for (NSString *bid in all) [self _releaseApp:bid upTo:ShaniNow() why:why];
}

// What the system's own Clear does: the notification is removed for good.
- (void)clearRequests:(NSArray *)requests {
    if (requests.count == 0) return;
    id dispatcher = [self _liveDispatcher];
    NSMutableSet *stored = [NSMutableSet set];
    for (id r in requests) {
        if (ShaniMsg(r, @"bulletin")) { [stored addObject:r]; continue; }
        // a notification that no app's store knows (a test one): taking it off the screen is all there is
        ShaniSendObj(dispatcher, @"withdrawNotificationWithRequest:", r);
    }
    if (stored.count == 0) return;
    SEL clear = NSSelectorFromString(@"destination:requestsClearingNotificationRequests:");
    if (!ShaniShape(dispatcher, clear, "v", 2)) { ShaniLog(@"clear: the dispatcher cannot (%@)", dispatcher ? @"shape" : @"none"); return; }
    @try { ((void (*)(id, SEL, id, id))objc_msgSend)(dispatcher, clear, nil, stored); }
    @catch (NSException *e) { ShaniLog(@"clear threw %@", e.reason); }
}

#pragma mark the clock

- (void)_timerFired:(id)timer {
    ShaniLog(@"timer");
    [self releaseDue];
    [self _schedule];
}

- (void)_schedule {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self _schedule]; }); return; }
    double next = 0, now = ShaniNow();
    @synchronized (self) {
        for (NSString *bid in _apps) {
            double until = [_apps[bid][@"until"] doubleValue];
            if (until > 0 && (next == 0 || until < next)) next = until;
        }
    }
    if (_wakeTimer) { ShaniSend(_wakeTimer, @"invalidate"); _wakeTimer = nil; }
    [_plainTimer invalidate];
    _plainTimer = nil;
    if (next <= 0) return;
    double delay = MAX(1.0, next - now + 0.5);
    Class pc = NSClassFromString(@"PCPersistentTimer");
    SEL make = NSSelectorFromString(@"initWithTimeInterval:serviceIdentifier:target:selector:userInfo:");
    if (pc && [pc instancesRespondToSelector:make] && [pc instancesRespondToSelector:NSSelectorFromString(@"scheduleInRunLoop:")]) {
        @try {
            id t = [[pc alloc] initWithTimeInterval:delay serviceIdentifier:SHANI_DOMAIN target:self selector:@selector(_timerFired:) userInfo:nil];
            ShaniSendObj(t, @"scheduleInRunLoop:", [NSRunLoop mainRunLoop]);
            _wakeTimer = t;
        } @catch (NSException *e) {
            ShaniLog(@"wake timer threw %@", e.reason);
            _wakeTimer = nil;
        }
    }
    // the plain timer is the second line: it fires as soon as the phone is awake after the time
    _plainTimer = [NSTimer scheduledTimerWithTimeInterval:delay + 1.0 target:self selector:@selector(_timerFired:) userInfo:nil repeats:NO];
    _plainTimer.tolerance = 1.0;
}

#pragma mark tests

- (id)lastRequestFor:(NSString *)bundleID {
    @synchronized (self) { return _last[bundleID]; }
}

- (NSString *)debugState {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    double now = ShaniNow();
    @synchronized (self) {
        for (NSString *bid in [_apps.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *st = _apps[bid];
            double until = [st[@"until"] doubleValue];
            [parts addObject:[NSString stringWithFormat:@"%@ held=%lu until=%@ seen=%lu", bid, (unsigned long)[_held[bid] count],
                              until > 0 ? [NSString stringWithFormat:@"+%.0fs", until - now] : @"-", (unsigned long)[st[@"seen"] count]]];
        }
    }
    ShaniSettings *s = [ShaniSettings shared];
    return [NSString stringWithFormat:@"enabled=%d mode=%ld minutes=%ld style=%ld timer=%@ apps[%lu]: %@", (int)s.enabled, (long)s.mode, (long)s.minutes,
            (long)s.releaseStyle, _wakeTimer ? @"wake" : (_plainTimer ? @"plain" : @"none"), (unsigned long)parts.count, [parts componentsJoinedByString:@" | "]];
}

@end
