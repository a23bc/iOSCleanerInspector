#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/* Maps bundle id -> display name and icon by reading the installed app bundles
   themselves under /var/containers/Bundle/Application. No private API: it is
   just Info.plist + the png files already sitting in the bundle.

   Needs com.apple.private.security.storage.AppBundles plus a read exception
   for /var/containers/Bundle/Application/. If either is missing, every lookup
   returns nil and the UI falls back to the bundle id - never a crash. */
@interface AppIconIndex : NSObject
+ (instancetype)shared;

/* Enumerates the bundle root. Call off the main thread. */
- (void)buildWithProgress:(void (^_Nullable)(NSUInteger done, NSUInteger total))progress;
@property (nonatomic, readonly) BOOL built;
@property (nonatomic, readonly) NSUInteger count;

- (NSString *_Nullable)displayNameForBundleID:(NSString *)bundleID;
- (UIImage *_Nullable)iconForBundleID:(NSString *)bundleID;
@end

NS_ASSUME_NONNULL_END
