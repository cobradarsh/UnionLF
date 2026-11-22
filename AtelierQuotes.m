/*  AtelierQuotes.m — the live NIFTY and SENSEX numbers above the clock.

    Where they come from: Yahoo Finance's public chart feed, the one its own web pages read:

        https://query1.finance.yahoo.com/v8/finance/chart/%5ENSEI?interval=1m&range=1d      (and %5EBSESN)

    No key, no account, no cookie. chart.result[0].meta has regularMarketPrice, previousClose
    (or chartPreviousClose) and regularMarketTime. query2 is asked when query1 fails. The feed
    can lag the exchange; the band says so on the glass when the newest number is over a minute
    old. The source sits behind a small protocol (AtelierQuoteSource) so that another one, a
    broker's for instance, can take its place later.

    What goes out: two GET requests with a generic User-Agent. An ephemeral session: no cookies
    kept or sent, no cache, no credentials, a four-second timeout. Nothing about the user or the
    phone is in the request.

    When: only between -start and -stop, that is while the bench is on screen.
      - India's session is open (AtelierIndiaSessionOpen: weekdays, 09:15 to 15:30, holidays
        excluded): every 5 seconds.
      - It is closed: one fetch when the bench comes up, for the last close; then nothing but a
        look at the clock every 30 seconds to see whether the session has opened. (If the bench
        was up through the close, one more fetch ten minutes later: the closing figure takes a
        few minutes to settle.)
      - A failure or an HTTP 429: the old numbers stay, dimmed, and the next tries come after
        10, 20, 40 and then 60 seconds.
    -stop cancels whatever is in flight and throws the session away.                           */

#import "Atelier.h"

@implementation AtelierQuote
@end

#pragma mark - Yahoo

@protocol AtelierQuoteSource <NSObject>
- (NSString *)name;
// `done` may be called on any thread: both quotes (NIFTY, SENSEX), or nil and what went wrong
// (status is the HTTP status when there was one).
- (void)fetch:(void (^)(NSArray<AtelierQuote *> *quotes, NSString *problem, NSInteger status, NSString *host))done;
- (void)shutDown;
@end

@interface AtelierYahooSource : NSObject <AtelierQuoteSource>
@end

@implementation AtelierYahooSource {
    NSURLSession *_session;
}

- (NSString *)name { return @"Yahoo Finance"; }

- (NSURLSession *)_openSession {
    if (_session) return _session;
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    c.HTTPCookieStorage = nil;
    c.HTTPShouldSetCookies = NO;
    c.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    c.URLCache = nil;
    c.URLCredentialStorage = nil;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    c.timeoutIntervalForRequest = 4;
    c.timeoutIntervalForResource = 6;
    c.waitsForConnectivity = NO;
    c.HTTPMaximumConnectionsPerHost = 2;
    c.HTTPAdditionalHeaders = @{ @"User-Agent": @"Mozilla/5.0", @"Accept": @"application/json", @"Accept-Language": @"en" };
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    queue.qualityOfService = NSQualityOfServiceUtility;
    _session = [NSURLSession sessionWithConfiguration:c delegate:nil delegateQueue:queue];
    return _session;
}

- (void)shutDown {
    [_session invalidateAndCancel];
    _session = nil;
}

+ (AtelierQuote *)quoteFromData:(NSData *)data symbol:(NSString *)symbol label:(NSString *)label problem:(NSString **)problem {
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id chart = [json isKindOfClass:NSDictionary.class] ? json[@"chart"] : nil;
    id results = [chart isKindOfClass:NSDictionary.class] ? chart[@"result"] : nil;
    id first = ([results isKindOfClass:NSArray.class] && [results count]) ? results[0] : nil;
    NSDictionary *meta = [first isKindOfClass:NSDictionary.class] ? first[@"meta"] : nil;
    if (![meta isKindOfClass:NSDictionary.class]) {
        if (problem) *problem = @"the answer has no chart.result[0].meta";
        return nil;
    }
    id price = meta[@"regularMarketPrice"], previous = meta[@"previousClose"] ?: meta[@"chartPreviousClose"], time = meta[@"regularMarketTime"];
    if (![price isKindOfClass:NSNumber.class] || [price doubleValue] <= 0) {
        if (problem) *problem = @"the answer has no regularMarketPrice";
        return nil;
    }
    AtelierQuote *q = [AtelierQuote new];
    q.symbol = symbol;
    q.label = label;
    q.price = [price doubleValue];
    q.previousClose = [previous isKindOfClass:NSNumber.class] ? [previous doubleValue] : 0;
    q.marketTime = [time isKindOfClass:NSNumber.class] ? [NSDate dateWithTimeIntervalSince1970:[time doubleValue]] : nil;
    return q;
}

- (void)_get:(NSString *)symbol label:(NSString *)label host:(int)host
        done:(void (^)(AtelierQuote *quote, NSString *problem, NSInteger status, NSString *host))done {
    NSString *name = [NSString stringWithFormat:@"query%d.finance.yahoo.com", host];
    NSString *escaped = [symbol stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/v8/finance/chart/%@?interval=1m&range=1d", name, escaped]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPShouldHandleCookies = NO;
    __weak typeof(self) weak = self;
    [[[self _openSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSString *problem = nil;
        AtelierQuote *quote = nil;
        if (error) problem = error.localizedDescription ?: @"no answer";
        else if (status != 200) problem = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        else quote = [AtelierYahooSource quoteFromData:data symbol:symbol label:label problem:&problem];
        if (!quote && host == 1 && error.code != NSURLErrorCancelled && weak) {          // the other host, once
            [weak _get:symbol label:label host:2 done:done];
            return;
        }
        done(quote, problem, status, name);
    }] resume];
}

- (void)fetch:(void (^)(NSArray<AtelierQuote *> *, NSString *, NSInteger, NSString *))done {
    NSArray<NSArray<NSString *> *> *wanted = @[ @[ @"^NSEI", @"NIFTY" ], @[ @"^BSESN", @"SENSEX" ] ];
    NSMutableArray *got = [NSMutableArray arrayWithObjects:[NSNull null], [NSNull null], nil];
    __block NSString *firstProblem = nil;
    __block NSInteger worstStatus = 0;
    __block NSString *usedHost = nil;
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];
    for (NSUInteger i = 0; i < wanted.count; i++) {
        dispatch_group_enter(group);
        [self _get:wanted[i][0] label:wanted[i][1] host:1 done:^(AtelierQuote *quote, NSString *problem, NSInteger status, NSString *host) {
            @synchronized (lock) {
                if (quote) got[i] = quote;
                else { if (!firstProblem) firstProblem = problem ?: @"no quote"; if (status) worstStatus = status; }
                usedHost = host;
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL whole = [got[0] isKindOfClass:AtelierQuote.class] && [got[1] isKindOfClass:AtelierQuote.class];
        done(whole ? [got copy] : nil, whole ? nil : firstProblem, worstStatus, usedHost);
    });
}

@end

#pragma mark - the poller

@implementation AtelierQuotes {
    id<AtelierQuoteSource> _source;
    NSArray<AtelierQuote *> *_quotes;
    NSTimer *_timer;
    BOOL _running, _inFlight, _failing, _fake;
    BOOL _fresh;                         // an answer has come since the bench last came up
    BOOL _sawOpen;                       // the session was open at the last answer
    CFAbsoluteTime _settleAt;            // when to fetch the settled close (0 = not waiting for one)
    NSInteger _failures;                 // in a row
    NSInteger _generation;               // answers to an older start are dropped
    NSUInteger _fetches, _good;
    NSString *_lastProblem;
}

+ (instancetype)shared {
    static AtelierQuotes *q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = [AtelierQuotes new]; });
    return q;
}

- (NSArray<AtelierQuote *> *)quotes { return _quotes ?: @[]; }
- (BOOL)failing { return _failing; }
- (BOOL)running { return _running; }

- (void)_changed {
    if (self.onChange) self.onChange();
}

- (void)start {
    if (_running) return;
    _running = YES;
    _generation++;
    _failures = 0;
    _fresh = NO;                         // what is left from the last time is shown, and fetched again
    _sawOpen = NO;
    _settleAt = 0;
    if (![AtelierSettings shared].showIndices || _fake) return;
    [self _after:0.05];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    _generation++;
    _inFlight = NO;
    [_timer invalidate];
    _timer = nil;
    [_source shutDown];
    _source = nil;
}

- (void)settingsChanged {
    if (!_running) return;
    BOOL want = [AtelierSettings shared].showIndices && !_fake;
    if (want && !_timer && !_inFlight) [self _after:0.05];
    if (!want) { [_timer invalidate]; _timer = nil; [_source shutDown]; _source = nil; _inFlight = NO; _generation++; }
}

- (void)_after:(NSTimeInterval)seconds {
    [_timer invalidate];
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:MAX(0.02, seconds) repeats:NO block:^(NSTimer *t) { [weak _due]; }];
    _timer.tolerance = seconds >= 5 ? 0.5 : 0;
}

- (void)_due {
    _timer = nil;
    if (!_running || _fake || ![AtelierSettings shared].showIndices) return;
    BOOL open = AtelierIndiaSessionOpen(AtelierNow());
    BOOL settle = _settleAt > 0 && CFAbsoluteTimeGetCurrent() >= _settleAt;
    if (!open && _quotes.count && !_failing && _fresh && !settle) {
        // closed, and the close is on the glass: nothing to fetch, just notice the open
        [self _changed];
        [self _after:30];
        return;
    }
    if (settle) _settleAt = 0;
    [self _fetch:NO];
}

- (void)_fetch:(BOOL)once {
    if (_inFlight) return;
    _inFlight = YES;
    _fetches++;
    if (!_source) _source = [AtelierYahooSource new];
    NSInteger generation = _generation;
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    __weak typeof(self) weak = self;
    [_source fetch:^(NSArray<AtelierQuote *> *quotes, NSString *problem, NSInteger status, NSString *host) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weak _got:quotes problem:problem status:status host:host generation:generation took:CFAbsoluteTimeGetCurrent() - began once:once];
        });
    }];
}

- (void)_got:(NSArray<AtelierQuote *> *)quotes problem:(NSString *)problem status:(NSInteger)status host:(NSString *)host
  generation:(NSInteger)generation took:(double)took once:(BOOL)once {
    if (generation != _generation) return;                // the bench has gone since
    _inFlight = NO;
    static const double waits[] = { 10, 20, 40, 60 };
    double next;
    if (quotes.count == 2) {
        BOOL wasFailing = _failing || _good == 0;
        _quotes = quotes;
        _failing = NO;
        _failures = 0;
        _good++;
        _lastProblem = nil;
        BOOL open = AtelierIndiaSessionOpen(AtelierNow());
        if (_sawOpen && !open) _settleAt = CFAbsoluteTimeGetCurrent() + 600;      // it closed while the bench was up
        _sawOpen = open;
        _fresh = YES;
        next = open ? 5 : 30;
        if (wasFailing || once) AtelierLog(@"quotes: %@ from %@ in %.2f s (%@)", [self _numbers], host ?: @"?", took,
                                           open ? @"session open, every 5 s" : @"session closed, this is the close");
    } else {
        _failing = YES;
        _lastProblem = problem ?: @"?";
        next = waits[MIN(_failures, (NSInteger)3)];
        _failures++;
        AtelierLog(@"quotes: no answer (%@%@), try %ld, next in %.0f s", _lastProblem,
                   status ? [NSString stringWithFormat:@", HTTP %ld", (long)status] : @"", (long)_failures, next);
    }
    [self _changed];
    if (once && !_running) { [_source shutDown]; _source = nil; return; }
    if (_running && !_fake) [self _after:next];
}

- (NSString *)_numbers {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"HH:mm:ss";
    f.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Kolkata"];
    for (AtelierQuote *q in _quotes)
        [parts addObject:[NSString stringWithFormat:@"%@ %.2f (previous close %.2f, at %@ IST)", q.label, q.price, q.previousClose,
                          q.marketTime ? [f stringFromDate:q.marketTime] : @"?"]];
    return parts.count ? [parts componentsJoinedByString:@" · "] : @"nothing yet";
}

#pragma mark tests

- (void)fetchOnce {
    AtelierLog(@"quotes: one real fetch");
    _fake = NO;
    if (!_running) _generation++;
    [self _fetch:YES];
}

- (void)inject:(NSString *)kind {
    if ([kind isEqualToString:@"off"]) {
        _fake = NO;
        _failing = NO;
        _quotes = nil;
        [self _changed];
        if (_running) [self _after:0.05];
        return;
    }
    _fake = YES;
    [_timer invalidate];
    _timer = nil;
    NSDate *now = AtelierNow();
    AtelierQuote *(^make)(NSString *, NSString *, double, double, double) = ^AtelierQuote *(NSString *symbol, NSString *label, double price, double previous, double age) {
        AtelierQuote *q = [AtelierQuote new];
        q.symbol = symbol;
        q.label = label;
        q.price = price;
        q.previousClose = previous;
        q.marketTime = [now dateByAddingTimeInterval:-age];
        return q;
    };
    if ([kind isEqualToString:@"rise"]) {
        _quotes = @[ make(@"^NSEI", @"NIFTY", 25800.60, 25227.90, 2), make(@"^BSESN", @"SENSEX", 83919.71, 82031.80, 2) ];
        _failing = NO;
    } else if ([kind isEqualToString:@"fall"]) {
        _quotes = @[ make(@"^NSEI", @"NIFTY", 24986.35, 25227.90, 2), make(@"^BSESN", @"SENSEX", 81204.15, 82031.80, 2) ];
        _failing = NO;
    } else if ([kind isEqualToString:@"mixed"]) {
        _quotes = @[ make(@"^NSEI", @"NIFTY", 25301.10, 25227.90, 2), make(@"^BSESN", @"SENSEX", 100412.05, 100931.80, 2) ];
        _failing = NO;
    } else if ([kind isEqualToString:@"stale"]) {
        _quotes = @[ make(@"^NSEI", @"NIFTY", 25800.60, 25227.90, 150), make(@"^BSESN", @"SENSEX", 83919.71, 82031.80, 930) ];
        _failing = NO;
    } else if ([kind isEqualToString:@"error"]) {
        if (_quotes.count == 0) _quotes = @[ make(@"^NSEI", @"NIFTY", 25800.60, 25227.90, 40), make(@"^BSESN", @"SENSEX", 83919.71, 82031.80, 40) ];
        _failing = YES;
        _lastProblem = @"HTTP 429 (test)";
    } else if ([kind isEqualToString:@"none"]) {
        _quotes = nil;
        _failing = NO;
    } else {
        AtelierLog(@"quotes: no such test \"%@\" (rise fall mixed stale error none off)", kind);
        return;
    }
    AtelierLog(@"quotes: test numbers \"%@\"", kind);
    [self _changed];
}

- (NSString *)debugState {
    return [NSString stringWithFormat:@"quotes %@%@%@ · %@ · %lu fetches, %lu good%@", _running ? @"running" : @"stopped", _fake ? @" (test numbers)" : @"",
            _failing ? @" FAILING" : @"", [self _numbers], (unsigned long)_fetches, (unsigned long)_good,
            _lastProblem ? [NSString stringWithFormat:@" · last problem: %@", _lastProblem] : @""];
}

@end
