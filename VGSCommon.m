#import "VGSCommon.h"
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

NSString *const VGSErrorDomain = @"GifStash";
NSString *const VGSAppGroup = @"group.com.cobradarsh.gifstash";
NSString *const VGSChangedDarwinName = @"com.cobradarsh.gifstash.changed";

NSError *VGSMakeError(VGSErrorCode code, NSString *message) {
    return [NSError errorWithDomain:VGSErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Something went wrong."}];
}

double VGSFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / 1048576.0;
}

double VGSAvailableMB(void) {
#if TARGET_OS_IPHONE
    return os_proc_available_memory() / 1048576.0;
#else
    return -1;
#endif
}

NSString *VGSByteString(long long bytes) {
    if (bytes < 1000) return [NSString stringWithFormat:@"%lld B", bytes];
    if (bytes < 1000 * 1000) return [NSString stringWithFormat:@"%.0f KB", bytes / 1000.0];
    if (bytes < 10 * 1000 * 1000) return [NSString stringWithFormat:@"%.1f MB", bytes / 1000000.0];
    if (bytes < 1000LL * 1000 * 1000) return [NSString stringWithFormat:@"%.0f MB", bytes / 1000000.0];
    return [NSString stringWithFormat:@"%.1f GB", bytes / 1000000000.0];
}
