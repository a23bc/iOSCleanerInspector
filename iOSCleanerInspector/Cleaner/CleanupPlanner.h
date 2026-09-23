#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* One row the user can switch on or off: either a global directory or one app
   container. `directories` are the only paths that may ever be touched. */
@interface CleanItem : NSObject
@property (nonatomic, copy) NSString *title;                 // bundle id, or the path
@property (nonatomic, strong) NSArray<NSString *> *directories;
/* Recursive byte count per directory, same order as `directories`. */
@property (nonatomic, strong) NSArray<NSNumber *> *directorySizes;
@property (nonatomic, assign) unsigned long long bytes;
@property (nonatomic, assign) BOOL selected;
@end

/* Result of a dry run. `files` are only regular files that passed every rule at
   plan time; the delete pass re-checks each one because time moves on. */
@interface CleanPlan : NSObject
@property (nonatomic, strong) NSArray<NSString *> *files;
@property (nonatomic, assign) unsigned long long bytes;
@property (nonatomic, assign) NSUInteger skippedRecent;
@property (nonatomic, assign) unsigned long long skippedRecentBytes;
@property (nonatomic, assign) NSUInteger skippedLink;
@property (nonatomic, assign) NSUInteger skippedDenied;
@property (nonatomic, copy) NSString *summary;
@end

@interface CleanupPlanner : NSObject
+ (instancetype)shared;

/* Long running: walks the container root. Call off the main thread. */
- (NSArray<CleanItem *> *)discoverTargets;

/* Dry run: what would go, and what is deliberately left alone. */
- (CleanPlan *)planForItems:(NSArray<CleanItem *> *)items;

/* The only place in this app that deletes anything. Returns a report. */
- (NSString *)executePlan:(CleanPlan *)plan;
@end

NS_ASSUME_NONNULL_END
