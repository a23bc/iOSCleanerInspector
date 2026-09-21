#import <Foundation/Foundation.h>

@interface SystemScanner : NSObject
+ (instancetype)shared;
- (NSString *)scanReport;

/* Bytes per scanned path, filled by the last scanReport call. Duplicate
   paths (same dev:inode) are excluded, so a total built from this dictionary
   never counts the same tree twice. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *sizesByPath;
@end
