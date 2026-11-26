#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const VGSErrorDomain;
extern NSString *const VGSAppGroup;                  // shared by the app and its share extension
extern NSString *const VGSChangedDarwinName;         // posted across processes when the library changes

typedef NS_ENUM(NSInteger, VGSErrorCode) {
    VGSErrorNoLink = 1,
    VGSErrorNetwork,
    VGSErrorNoMedia,
    VGSErrorRestricted,
    VGSErrorVideo,
    VGSErrorStorage,
    VGSErrorCancelled,
};

/// An error whose description is a sentence that can be shown as it is.
NSError *VGSMakeError(VGSErrorCode code, NSString *message);

/// Memory this process is charged for, and how much more it may take before the system ends it (-1 when unknown).
double VGSFootprintMB(void);
double VGSAvailableMB(void);

/// "1.4 MB", "820 KB".
NSString *VGSByteString(long long bytes);

NS_ASSUME_NONNULL_END
