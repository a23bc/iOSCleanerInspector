#import <Foundation/Foundation.h>
@interface AppScanner : NSObject
+ (instancetype)shared;
- (NSString *)scanReport;
@end
