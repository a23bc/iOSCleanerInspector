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

- (NSString *)humanBinarySize:(unsigned long long)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double v = (double)bytes / 1024.0;
    NSArray *units = @[@"KiB", @"MiB", @"GiB", @"TiB"];
    NSUInteger i = 0;
    while (v >= 1024.0 && i < units.count - 1) {
        v /= 1024.0;
        i++;
    }
    return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
}

static unsigned long long SumOf(NSArray<NSString *> *paths,
                                NSDictionary<NSString *, NSNumber *> *sizes) {
    unsigned long long total = 0;
    for (NSString *p in paths) total += [sizes[p] unsignedLongLongValue];
    return total;
}

- (NSString *)fullReadOnlyReport {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"iOS Cleaner Inspector 0.2.3\n"];
    [out appendString:@"READ-ONLY MODE - NO FILE DELETION\n"];
    [out appendFormat:@"running as uid=%d euid=%d gid=%d egid=%d\n",
        (int)getuid(), (int)geteuid(), (int)getgid(), (int)getegid()];
    [out appendString:@"================================\n\n"];

    SystemScanner *system = [SystemScanner shared];
    AppScanner *apps = [AppScanner shared];

    [out appendString:[system scanReport]];
    [out appendString:@"\n"];
    [out appendString:[apps scanReport]];

    /* Buckets mirroring how the audited cleaner groups its numbers, so the two
       reports can be compared line by line instead of guessing which paths
       landed in which bucket. */
    NSDictionary<NSString *, NSNumber *> *sizes = system.sizesByPath;
    unsigned long long systemCaches = SumOf(@[@"/var/mobile/Library/Caches"], sizes);
    unsigned long long systemLogs = SumOf(@[@"/var/mobile/Library/Logs"], sizes);
    unsigned long long tempFiles = SumOf(@[@"/tmp", @"/var/mobile/Media/Downloads"], sizes);
    unsigned long long photos =
        SumOf(@[@"/var/mobile/Media/PhotoData/Caches", @"/var/mobile/Media/PhotoData/Thumbnails"], sizes);
    unsigned long long appCachesOnly = apps.libraryCacheTotal;
    unsigned long long appTmpOnly = apps.tmpTotal;
    unsigned long long appleTotal = apps.appleLibraryCacheTotal + apps.appleTmpTotal;
    unsigned long long thirdPartyTotal = apps.thirdPartyLibraryCacheTotal + apps.thirdPartyTmpTotal;

    [out appendString:@"\n================================\n"];
    [out appendString:@"CATEGORY TOTALS (binary units, to compare with iOSCleanerPro)\n"];
    [out appendString:@"------------------------------------------------------------\n\n"];

    [out appendFormat:@"系统缓存 system\n"
                       "  Library/Caches                        %20llu  %@\n"
                       "  Library/Caches + Library/Logs         %20llu  %@\n"
                       "  Library/Caches + com.apple.* 容器      %20llu  %@\n\n",
        systemCaches, [self humanBinarySize:systemCaches],
        systemCaches + systemLogs, [self humanBinarySize:systemCaches + systemLogs],
        systemCaches + appleTotal, [self humanBinarySize:systemCaches + appleTotal]];

    [out appendFormat:@"临时文件 temp\n"
                       "  /tmp + Media/Downloads                %20llu  %@\n\n",
        tempFiles, [self humanBinarySize:tempFiles]];

    [out appendFormat:@"照片缓存 photos\n"
                       "  PhotoData/Caches + Thumbnails         %20llu  %@\n\n",
        photos, [self humanBinarySize:photos]];

    [out appendFormat:@"应用缓存 apps (%lu containers)\n"
                       "  Library/Caches only                   %20llu  %@\n"
                       "  tmp only                              %20llu  %@\n"
                       "  Library/Caches + tmp                  %20llu  %@\n"
                       "  第三方 apps: Library/Caches            %20llu  %@\n"
                       "  第三方 apps: +tmp                      %20llu  %@\n"
                       "  com.apple.* apps (含 tmp)              %20llu  %@\n\n",
        (unsigned long)apps.containerCount,
        appCachesOnly, [self humanBinarySize:appCachesOnly],
        appTmpOnly, [self humanBinarySize:appTmpOnly],
        appCachesOnly + appTmpOnly, [self humanBinarySize:appCachesOnly + appTmpOnly],
        apps.thirdPartyLibraryCacheTotal, [self humanBinarySize:apps.thirdPartyLibraryCacheTotal],
        thirdPartyTotal, [self humanBinarySize:thirdPartyTotal],
        appleTotal, [self humanBinarySize:appleTotal]];

    [out appendFormat:@"整体合计 (去重后, 含容器 tmp)          %20llu  %@\n",
        systemCaches + systemLogs + tempFiles + photos + appCachesOnly + appTmpOnly,
        [self humanBinarySize:systemCaches + systemLogs + tempFiles + photos + appCachesOnly + appTmpOnly]];

    [out appendString:@"\n================================\n"];
    [out appendString:@"Scan complete.\n"];
    return out;
}

@end
