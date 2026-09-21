#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Scanner : NSObject
+ (instancetype)shared;
- (NSString *)fullReadOnlyReport;
- (NSString *)humanSize:(unsigned long long)bytes;
@end

NS_ASSUME_NONNULL_END
