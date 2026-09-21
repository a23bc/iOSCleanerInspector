#import <Foundation/Foundation.h>
@interface SystemScanner : NSObject
+ (instancetype)shared;
- (NSString *)scanReport;
@end
