#import "SystemScanner.h"

@implementation SystemScanner

+ (instancetype)shared {
    static SystemScanner *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [SystemScanner new]; });
    return s;
}

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

- (NSString *)scanReport {
    NSArray *paths = @[
        @"/tmp",
        @"/var/tmp",
        @"/var/mobile/Library/Caches",
        @"/var/mobile/Library/Logs",
        @"/var/mobile/Library/Preferences/Logs",
        @"/var/mobile/Media/PhotoData/Caches",
        @"/var/mobile/Media/PhotoData/Thumbnails"
    ];

    NSMutableString *out = [NSMutableString stringWithString:@"SYSTEM / GLOBAL PATHS\\n----------------------\\n"];

    for (NSString *path in paths) {
        NSUInteger files = 0, dirs = 0;
        BOOL isDir = NO;
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

        if (!exists) {
            [out appendFormat:@"[NO ACCESS / NOT FOUND] %@\\n", path];
            continue;
        }

        unsigned long long size = SizeOfTree(path, &files, &dirs);
        [out appendFormat:@"\\n%@\\n  size: %llu bytes\\n  files: %lu\\n  dirs: %lu\\n",
            path, size, (unsigned long)files, (unsigned long)dirs];
    }

    return out;
}

@end
