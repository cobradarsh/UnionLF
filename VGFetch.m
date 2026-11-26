// Downloads: small files into memory, lists of files onto disk a few at a time, with retries.
#import "VidGrab.h"
#include <stdatomic.h>

static const NSUInteger kParallel = 5;
static const NSInteger kAttempts = 3;

@implementation VGFetcher {
    NSURLSession *_session;
    NSDictionary<NSString *, NSString *> *_headers;
    atomic_bool _cancelled;
    atomic_llong _bytes;
}

- (instancetype)initWithHeaders:(NSDictionary<NSString *, NSString *> *)headers {
    if ((self = [super init])) {
        _headers = [headers copy];
        // The default configuration shares the app's cookies, which is what its own player sends too.
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.HTTPMaximumConnectionsPerHost = 6;
        configuration.URLCache = nil;                       // segments do not belong in the app's cache
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 30;       // idle time, not total time
        configuration.timeoutIntervalForResource = 3600;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)dealloc {
    [_session finishTasksAndInvalidate];
}

- (BOOL)cancelled { return atomic_load(&_cancelled); }
- (long long)bytesReceived { return atomic_load(&_bytes); }

- (void)cancel {
    atomic_store(&_cancelled, true);
    [_session invalidateAndCancel];
}

- (NSURLRequest *)requestFor:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [_headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
        if (![field isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class]) return;
        if ([field caseInsensitiveCompare:@"Range"] == NSOrderedSame) return;       // the whole file is wanted
        [request setValue:value forHTTPHeaderField:field];
    }];
    return request;
}

static NSInteger VGStatus(NSURLResponse *response) {
    return [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
}

static BOOL VGWorthRetrying(NSError *error, NSInteger status) {
    if (error) return error.code != NSURLErrorCancelled;
    return status >= 500 || status == 429 || status == 408;
}

static NSError *VGNetworkError(NSError *error, NSInteger status) {
    if (error.code == NSURLErrorCancelled) return VGError(VGErrorCancelled, @"Cancelled.");
    if (error) return VGError(VGErrorNetwork, error.localizedDescription ?: @"The download failed.");
    if (status == 403 || status == 401) return VGError(VGErrorNetwork, @"The server refused the download (the link may have expired).");
    if (status == 404 || status == 410) return VGError(VGErrorNetwork, @"The video is no longer on the server.");
    return VGError(VGErrorNetwork, [NSString stringWithFormat:@"The server answered with error %ld.", (long)status]);
}

- (NSData *)dataAtURL:(NSURL *)url error:(NSError **)error {
    NSError *last = nil;
    for (NSInteger attempt = 0; attempt < kAttempts; attempt++) {
        if (self.cancelled) break;
        if (attempt) [NSThread sleepForTimeInterval:0.6 * attempt];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSData *result = nil;
        __block NSError *problem = nil;
        __block NSInteger status = 0;
        @try {
            [[_session dataTaskWithRequest:[self requestFor:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
                status = e ? 0 : VGStatus(response);
                problem = e;
                if (!e && status >= 200 && status < 300) result = data;
                dispatch_semaphore_signal(done);
            }] resume];
        } @catch (NSException *exception) {                 // the session was cancelled under us
            break;
        }
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (result) {
            atomic_fetch_add(&_bytes, (long long)result.length);
            return result;
        }
        last = VGNetworkError(problem, status);
        if (!VGWorthRetrying(problem, status)) break;
    }
    if (error) *error = self.cancelled ? VGError(VGErrorCancelled, @"Cancelled.") : (last ?: VGError(VGErrorNetwork, @"The download failed."));
    return nil;
}

- (BOOL)downloadURLs:(NSArray<NSURL *> *)urls
             toPaths:(NSArray<NSString *> *)paths
              ranges:(NSArray *)ranges
              starts:(NSMutableArray<NSNumber *> *)starts
            progress:(void (^)(double, long long))progress
               error:(NSError **)error {
    NSUInteger total = urls.count;
    if (total == 0) return YES;
    NSParameterAssert(paths.count == total);
    NSMutableDictionary<NSNumber *, NSNumber *> *firstBytes = [NSMutableDictionary new];
    dispatch_queue_t queue = dispatch_queue_create("com.adarsh.vidgrab.fetch", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    NSMutableDictionary<NSNumber *, NSURLSessionTask *> *active = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, NSNumber *> *tries = [NSMutableDictionary new];
    __block NSUInteger next = 0, completed = 0, waitingToRetry = 0;
    __block long long finishedBytes = 0;
    __block NSError *failure = nil;
    __block BOOL signalled = NO;
    __block void (^startOne)(NSUInteger) = nil;
    __block void (^pump)(void) = nil;
    NSURLSession *session = _session;
    __weak VGFetcher *weakSelf = self;

    void (^finish)(void) = ^{
        if (signalled) return;
        signalled = YES;
        dispatch_semaphore_signal(finished);
    };
    pump = ^{
        VGFetcher *me = weakSelf;
        if (!me || me.cancelled) {
            if (!failure) failure = VGError(VGErrorCancelled, @"Cancelled.");
        }
        while (!failure && active.count < kParallel && next < total) startOne(next++);
        if (failure) {
            if (active.count == 0) finish();
            return;
        }
        if (active.count == 0 && waitingToRetry == 0 && completed == total) finish();
    };
    startOne = ^(NSUInteger index) {
        VGFetcher *me = weakSelf;
        if (!me) return;
        NSURL *destination = [NSURL fileURLWithPath:paths[index]];
        NSURLSessionDownloadTask *task = nil;
        @try {
            NSMutableURLRequest *request = [[me requestFor:urls[index]] mutableCopy];
            NSString *range = index < ranges.count && [ranges[index] isKindOfClass:NSString.class] ? ranges[index] : nil;
            if (range) [request setValue:range forHTTPHeaderField:@"Range"];
            task = [session downloadTaskWithRequest:request
                                  completionHandler:^(NSURL *location, NSURLResponse *response, NSError *e) {
                // the temporary file is gone when this block returns: move it now
                NSInteger status = e ? 0 : VGStatus(response);
                NSError *problem = e;
                long long size = 0;
                long long firstByte = 0;
                if (!e && status == 206 && [response isKindOfClass:NSHTTPURLResponse.class]) {
                    // "bytes 719-1508718/…": where the part we were sent begins in the whole file
                    NSString *content = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Content-Range"];
                    NSScanner *scanner = [NSScanner scannerWithString:content ?: @""];
                    [scanner scanUpToCharactersFromSet:NSCharacterSet.decimalDigitCharacterSet intoString:NULL];
                    [scanner scanLongLong:&firstByte];
                }
                if (!problem && (status < 200 || status >= 300)) problem = VGNetworkError(nil, status);
                if (!problem) {
                    NSFileManager *files = NSFileManager.defaultManager;
                    [files removeItemAtURL:destination error:NULL];
                    NSError *moveError = nil;
                    if (location && [files moveItemAtURL:location toURL:destination error:&moveError]) {
                        size = [[files attributesOfItemAtPath:destination.path error:NULL] fileSize];
                    } else {
                        problem = VGError(VGErrorStorage, moveError.localizedDescription ?: @"A downloaded part could not be stored.");
                        status = -1;
                    }
                }
                dispatch_async(queue, ^{
                    [active removeObjectForKey:@(index)];
                    if (!problem) {
                        completed++;
                        finishedBytes += size;
                        firstBytes[@(index)] = @(firstByte);
                        VGFetcher *strong = weakSelf;
                        if (strong) atomic_fetch_add(&strong->_bytes, size);
                    } else if (!failure) {
                        NSInteger count = tries[@(index)].integerValue + 1;
                        tries[@(index)] = @(count);
                        BOOL again = status >= 0 && count < kAttempts && VGWorthRetrying(e, status) && !weakSelf.cancelled;
                        if (again) {
                            waitingToRetry++;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * count * NSEC_PER_SEC)), queue, ^{
                                waitingToRetry--;
                                if (!failure && !weakSelf.cancelled && startOne) startOne(index);
                                if (pump) pump();
                            });
                            return;
                        }
                        failure = status == -1 ? problem : VGNetworkError(e, status);
                        for (NSURLSessionTask *other in active.allValues) [other cancel];
                    }
                    if (pump) pump();
                });
            }];
        } @catch (NSException *exception) {
            task = nil;
        }
        if (!task) {
            if (!failure) failure = VGError(VGErrorCancelled, @"Cancelled.");
            return;
        }
        active[@(index)] = task;
        [task resume];
    };

    dispatch_source_t timer = nil;
    if (progress) {
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            double units = completed;
            long long bytes = finishedBytes;
            for (NSURLSessionTask *task in active.allValues) {
                long long received = task.countOfBytesReceived, expected = task.countOfBytesExpectedToReceive;
                bytes += received;
                if (expected > 0) units += MIN(1.0, (double)received / (double)expected);
            }
            progress(MIN(1.0, units / (double)total), bytes);
        });
        dispatch_resume(timer);
    }

    dispatch_async(queue, ^{ pump(); });
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    if (timer) dispatch_source_cancel(timer);
    __block NSError *result = nil;
    dispatch_sync(queue, ^{
        result = failure;
        startOne = nil;                                     // the two blocks hold each other
        pump = nil;
    });
    if (result) {
        if (error) *error = result;
        return NO;
    }
    [starts removeAllObjects];
    for (NSUInteger i = 0; i < total; i++) [starts addObject:firstBytes[@(i)] ?: @0];
    if (progress) progress(1.0, finishedBytes);
    return YES;
}

@end
