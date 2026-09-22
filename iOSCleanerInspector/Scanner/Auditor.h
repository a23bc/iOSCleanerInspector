#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* What a deletion target actually contains. The point of the audit is not the
   total - it is whether the things inside are really throwaway caches.

   Everything reported here is measured, never guessed:
     - age:      file modification date (a file written seconds ago is not
                 something a cleaner should touch)
     - kind:     sqlite/realm family holds application state, media is usually
                 content the user chose to keep offline
     - biggest:  the actual paths, so a number can be checked by hand */
@interface Auditor : NSObject
+ (instancetype)shared;

/* One directory. */
- (NSString *)auditReportFor:(NSString *)path title:(NSString *)title;

/* Many directories at once (e.g. every app container's Library/Caches),
   reported as one target with a shared top-files table. */
- (NSString *)auditReportForPaths:(NSArray<NSString *> *)paths
                            title:(NSString *)title
                          maxRows:(NSUInteger)maxRows;
@end

NS_ASSUME_NONNULL_END
