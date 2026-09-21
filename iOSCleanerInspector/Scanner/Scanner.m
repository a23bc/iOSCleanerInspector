#import "Scanner.h"
#import "AppScanner.h"
#import "SystemScanner.h"

#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *_Nullable AccessFailure(NSString *path) {
    const char *p = path.fileSystemRepresentation;

    struct stat st;
    if (stat(p, &st) != 0) {
        int e = errno;
        return [NSString stringWithFormat:@"stat() failed errno=%d (%s)", e, strerror(e)];
    }

    if (S_ISDIR(st.st_mode)) {
        DIR *dir = opendir(p);
        if (dir == NULL) {
            int e = errno;
            return [NSString stringWithFormat:@"opendir() failed errno=%d (%s)", e, strerror(e)];
        }
        closedir(dir);
    }
    return nil;
}

@implementation Scanner

+ (instancetype)shared {
    static Scanner *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [Scanner new];
    });
    return s;
}

- (NSString *)humanSize:(unsigned long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double v = bytes;
    NSArray *units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    NSUInteger i = 0;
    while (v >= 1024.0 && i < units.count - 1) {
        v /= 1024.0;
        i++;
    }
    return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
}

- (NSString *)fullReadOnlyReport {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"iOS Cleaner Inspector 0.2.2\n"];
    [out appendString:@"READ-ONLY MODE - NO FILE DELETION\n"];
    [out appendFormat:@"running as uid=%d euid=%d gid=%d egid=%d\n",
        (int)getuid(), (int)geteuid(), (int)getgid(), (int)getegid()];
    [out appendString:@"================================\n\n"];

    [out appendString:[[SystemScanner shared] scanReport]];
    [out appendString:@"\n"];
    [out appendString:[[AppScanner shared] scanReport]];

    [out appendString:@"\n================================\n"];
    [out appendString:@"Scan complete.\n"];
    return out;
}

@end
