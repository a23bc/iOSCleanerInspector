#import <Foundation/Foundation.h>

@interface AppScanner : NSObject
+ (instancetype)shared;
- (NSString *)scanReport;

/* Totals filled by the last scanReport call. Kept split so the report can
   reproduce other tools' bucket boundaries instead of forcing one opinion:
   library caches vs tmp, and Apple apps vs third party. */
@property (nonatomic, assign) unsigned long long libraryCacheTotal;
@property (nonatomic, assign) unsigned long long tmpTotal;
@property (nonatomic, assign) unsigned long long appleLibraryCacheTotal;
@property (nonatomic, assign) unsigned long long appleTmpTotal;
@property (nonatomic, assign) unsigned long long thirdPartyLibraryCacheTotal;
@property (nonatomic, assign) unsigned long long thirdPartyTmpTotal;
@property (nonatomic, assign) NSUInteger containerCount;
@property (nonatomic, assign) NSUInteger resolvedCount;
@end
