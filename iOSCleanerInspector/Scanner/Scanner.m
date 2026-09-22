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

+ (NSString *)timestampNow {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone systemTimeZone];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    return [f stringFromDate:[NSDate date]];
}

- (NSString *)fullReadOnlyReport {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"iOS Cleaner Inspector 0.3.0\n"];
    [out appendString:@"AUDIT MODE - READ ONLY, NO FILE DELETION\n"];
    [out appendString:@"目标: 审计被审计清理工具\"会删除\"的目录里到底装了什么\n"];
    [out appendFormat:@"running as uid=%d euid=%d gid=%d egid=%d\n",
        (int)getuid(), (int)geteuid(), (int)getgid(), (int)getegid()];
    [out appendFormat:@"scan started:  %@\n", [Scanner timestampNow]];
    [out appendString:@"================================\n\n"];

    [out appendString:[[SystemScanner shared] scanReport]];
    [out appendString:@"\n"];
    [out appendString:[[AppScanner shared] scanReport]];

    /* Transparency: what this build refuses to look at, and why. */
    [out appendString:@"\n================================\n"];
    [out appendString:@"NOT SCANNED (安全评审判定为不可删除, 本工具不枚举)\n"];
    [out appendString:@"------------------------------------------------\n"];
    for (NSString *line in @[
        @"/var/mobile/Library/Logs                      日志, 禁止删除",
        @"/var/mobile/Library/Preferences/Logs           (该路径在 iOS 上不存在)",
        @"/var/mobile/Media/Downloads                   用户下载内容, 禁止删除",
        @"/var/mobile/Media/PhotoData/Caches            Photos 数据, 禁止删除",
        @"/var/mobile/Media/PhotoData/Thumbnails        Photos 缩略图, 禁止删除",
        @"/var/mobile/Containers/Data/InternalDaemon    系统 daemon 数据, 禁止删除",
        @"/var/mobile/Containers/Data/PluginKitPlugin   插件容器, 同上按不可删除处理",
        @"/var/mobile/Containers/Shared/AppGroup        共享容器, 同上按不可删除处理",
        @"/var/containers/Data                          系统容器数据, 禁止删除"]) {
        [out appendFormat:@"  %@\n", line];
    }

    AppScanner *apps = [AppScanner shared];
    [out appendFormat:@"\n审计对象合计: %lu 个 App 容器, Library/Caches %@ + tmp %@\n",
        (unsigned long)apps.containerCount,
        [self humanBinarySize:apps.libraryCacheTotal],
        [self humanBinarySize:apps.tmpTotal]];

    [out appendString:@"\n================================\n"];
    [out appendFormat:@"scan finished: %@\n", [Scanner timestampNow]];
    [out appendString:@"Scan complete.\n"];
    return out;
}

@end
