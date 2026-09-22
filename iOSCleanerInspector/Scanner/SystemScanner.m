#import "SystemScanner.h"
#import "Scanner.h"

#include <sys/stat.h>

@implementation SystemScanner

+ (instancetype)shared {
    static SystemScanner *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [SystemScanner new]; });
    return s;
}

/* AccessFailure() comes from Scanner.h / Scanner.m. */

static unsigned long long SizeOfTree(NSString *path, NSUInteger *files, NSUInteger *dirs) {
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
    for (NSString *relative in e) {
        @autoreleasepool {
            NSString *full = [path stringByAppendingPathComponent:relative];
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

/* Immediate children of a directory with their recursive sizes, biggest first.
   Needed when a total disagrees with another tool: the only way to tell
   "different measurement time" from "different definition" is to see which
   subset of the children adds up to the other tool's number. */
static NSString *ChildBreakdown(NSString *path, NSUInteger limit) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *entries = [fm contentsOfDirectoryAtPath:path error:nil];
    if (!entries) return @"    (unreadable)\n";

    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *name in entries) {
        NSString *full = [path stringByAppendingPathComponent:name];
        NSUInteger files = 0, dirs = 0;
        unsigned long long size = SizeOfTree(full, &files, &dirs);
        [rows addObject:@{@"name": name, @"size": @(size)}];
    }
    [rows sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"size" ascending:NO]]];

    NSMutableString *out = [NSMutableString string];
    NSUInteger shown = MIN(limit, rows.count);
    unsigned long long shownTotal = 0;
    for (NSUInteger i = 0; i < shown; i++) {
        NSDictionary *row = rows[i];
        unsigned long long size = [row[@"size"] unsignedLongLongValue];
        shownTotal += size;
        [out appendFormat:@"    %-52@ %14llu\n", row[@"name"], size];
    }
    if (rows.count > shown) {
        unsigned long long rest = 0;
        for (NSUInteger i = shown; i < rows.count; i++) rest += [rows[i][@"size"] unsignedLongLongValue];
        [out appendFormat:@"    %-52@ %14llu\n",
            [NSString stringWithFormat:@"(...and %lu more)", (unsigned long)(rows.count - shown)], rest];
        shownTotal += rest;
    }
    [out appendFormat:@"    %-52@ %14llu\n", @"TOTAL (children)", shownTotal];
    return out;
}

- (NSString *)scanReport {
    NSArray *paths = @[
        @"/tmp",
        @"/var/tmp",
        @"/var/mobile/Library/Caches",
        @"/var/mobile/Library/Logs",
        @"/var/mobile/Library/Preferences/Logs",
        @"/var/mobile/Media/Downloads",
        @"/var/mobile/Media/PhotoData/Caches",
        @"/var/mobile/Media/PhotoData/Thumbnails",
        // Not scanned before 0.2.4: candidates for the 0.72 GiB that
        // iOSCleanerPro's "system" bucket shows on top of Library/Caches.
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Containers/Data/TempDir",
        @"/var/mobile/Containers/Data/InternalDaemon",
        @"/var/mobile/Containers/Data/PluginKitPlugin",
        @"/var/containers/Data"
    ];

    NSMutableString *out = [NSMutableString stringWithString:@"SYSTEM / GLOBAL PATHS\n----------------------\n\n"];
    self.sizesByPath = [NSMutableDictionary dictionary];

    /* On iOS /var is a symlink to /private/var and /tmp is a symlink to
       /private/var/tmp, so "/tmp" and "/var/tmp" are the SAME directory.
       Walking both silently inflates the total - exactly the kind of thing
       this tool exists to catch. Track dev:inode and count each object once. */
    NSMutableDictionary<NSString *, NSString *> *counted = [NSMutableDictionary dictionary];

    for (NSString *path in paths) {
        NSString *failure = AccessFailure(path);
        if (failure) {
            [out appendFormat:@"[NO ACCESS] %@\n    cause: %@\n\n", path, failure];
            continue;
        }

        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) != 0) { /* AccessFailure already passed */ continue; }
        NSString *identity =
            [NSString stringWithFormat:@"%llu:%llu",
                (unsigned long long)st.st_dev, (unsigned long long)st.st_ino];

        NSString *alreadyCountedAs = counted[identity];
        if (alreadyCountedAs) {
            NSString *link = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:path error:nil];
            [out appendFormat:
                @"[DUPLICATE] %@%@\n"
                 "    same filesystem object as %@\n"
                 "    dev:inode %@ - counted once, NOT added again\n\n",
                path,
                link ? [@"  -> " stringByAppendingString:link] : @"",
                alreadyCountedAs,
                identity];
            continue;
        }
        counted[identity] = path;

        NSUInteger files = 0, dirs = 0;
        unsigned long long size = SizeOfTree(path, &files, &dirs);
        self.sizesByPath[path] = @(size);
        [out appendFormat:@"%@\n  size: %llu bytes\n  files: %lu\n  dirs: %lu\n\n",
            path, size, (unsigned long)files, (unsigned long)dirs];
    }

    /* iOSCleanerPro's "system" bucket is the one number we cannot reproduce, so
       expose the composition of the only path that could be split differently. */
    [out appendString:@"\nTOP-LEVEL OF /var/mobile/Library/Caches (biggest first)\n"];
    [out appendString:@"------------------------------------------------------\n"];
    [out appendString:ChildBreakdown(@"/var/mobile/Library/Caches", 20)];
    [out appendString:@"\n"];

    return out;
}

@end
