#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Returns nil when path can be stat'ed and (if a directory) opened for reading.
   Otherwise returns a human readable reason including the POSIX errno, so a
   failure can be told apart: EPERM(1) sandbox denial vs ENOENT(2) missing path
   vs EACCES(13) unix permission. */
NSString *_Nullable AccessFailure(NSString *path);

@interface Scanner : NSObject
+ (instancetype)shared;
- (NSString *)fullReadOnlyReport;
- (NSString *)humanSize:(unsigned long long)bytes;
/* Binary units (KiB/MiB/GiB). iOSCleanerPro displays sizes this way - its
   "990.71M" matched /tmp + Downloads in MiB to two decimals - so the category
   summary below is printed in the same unit to make comparison direct. */
- (NSString *)humanBinarySize:(unsigned long long)bytes;
@end

NS_ASSUME_NONNULL_END
