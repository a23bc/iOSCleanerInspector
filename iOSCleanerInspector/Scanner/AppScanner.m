#import "AppScanner.h"
#import "Scanner.h"

@implementation AppScanner

+ (instancetype)shared {
    static AppScanner *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [AppScanner new]; });
    return s;
}

static unsigned long long SizeOfTreeAtPath(NSString *path, NSUInteger *files, NSUInteger *dirs) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;

    if (!isDir) {
        NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
        return [a[NSFileSize] unsignedLongLongValue];
    }

    if (dirs) (*dirs)++;
    unsigned long long total = 0;

    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    for (NSString *rel in e) {
        @autoreleasepool {
            NSString *full = [path stringByAppendingPathComponent:rel];
            BOOL childDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&childDir]) continue;

            if (childDir) {
                if (dirs) (*dirs)++;
            } else {
                if (files) (*files)++;
                NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
                total += [a[NSFileSize] unsignedLongLongValue];
            }
        }
    }
    return total;
}

/* Every app data container carries its bundle id in a metadata plist written by
   MobileContainerManager. Reading it is what turns a wall of anonymous UUIDs
   into an auditable list - and it needs no API beyond Foundation. */
static NSString *BundleIDForContainer(NSString *container) {
    NSString *metadataPath =
        [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    NSString *identifier = metadata[@"MCMMetadataIdentifier"];
    return [identifier isKindOfClass:NSString.class] && identifier.length ? identifier : nil;
}

- (NSString *)scanReport {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = NSFileManager.defaultManager;

    self.libraryCacheTotal = 0;
    self.tmpTotal = 0;
    self.appleLibraryCacheTotal = 0;
    self.appleTmpTotal = 0;
    self.thirdPartyLibraryCacheTotal = 0;
    self.thirdPartyTmpTotal = 0;
    self.containerCount = 0;
    self.resolvedCount = 0;

    NSMutableString *out =
        [NSMutableString stringWithString:@"\nAPP CONTAINERS\n--------------\n\n"];

    NSString *failure = AccessFailure(root);
    if (failure) {
        [out appendFormat:@"[NO ACCESS] %@\n    cause: %@\n", root, failure];
        return out;
    }

    NSArray *entries = [fm contentsOfDirectoryAtPath:root error:nil];

    if (!entries) {
        [out appendFormat:@"[NO ACCESS] %@\n    cause: contentsOfDirectoryAtPath returned nil\n", root];
        return out;
    }

    for (NSString *uuid in [entries sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        @autoreleasepool {
            NSString *container = [root stringByAppendingPathComponent:uuid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:container isDirectory:&isDir] || !isDir) continue;

            NSString *libraryCaches = [container stringByAppendingPathComponent:@"Library/Caches"];
            NSString *tmp = [container stringByAppendingPathComponent:@"tmp"];

            NSUInteger files = 0, dirs = 0;
            unsigned long long cacheSize = SizeOfTreeAtPath(libraryCaches, &files, &dirs);

            NSUInteger tmpFiles = 0, tmpDirs = 0;
            unsigned long long tmpSize = SizeOfTreeAtPath(tmp, &tmpFiles, &tmpDirs);

            if (cacheSize == 0 && tmpSize == 0) continue;

            NSString *bundleID = BundleIDForContainer(container);
            BOOL isApple = [bundleID hasPrefix:@"com.apple."];

            self.containerCount += 1;
            self.libraryCacheTotal += cacheSize;
            self.tmpTotal += tmpSize;
            if (isApple) {
                self.appleLibraryCacheTotal += cacheSize;
                self.appleTmpTotal += tmpSize;
            } else {
                self.thirdPartyLibraryCacheTotal += cacheSize;
                self.thirdPartyTmpTotal += tmpSize;
            }
            if (bundleID) self.resolvedCount += 1;

            [out appendFormat:
                @"\nContainer: %@\n"
                 "  app:            %@\n"
                 "  Library/Caches: %llu bytes (%lu files)\n"
                 "  tmp:            %llu bytes (%lu files)\n"
                 "  total:          %llu bytes\n",
                 uuid,
                 bundleID ?: @"(unknown - metadata plist unreadable)",
                 cacheSize, (unsigned long)files,
                 tmpSize, (unsigned long)tmpFiles,
                 cacheSize + tmpSize];
        }
    }

    [out appendFormat:@"\nApps with cache/tmp data: %lu (bundle id resolved for %lu)\nTotal: %llu bytes\n",
        (unsigned long)self.containerCount, (unsigned long)self.resolvedCount,
        self.libraryCacheTotal + self.tmpTotal];

    return out;
}

@end
