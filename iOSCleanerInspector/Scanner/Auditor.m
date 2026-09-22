#import "Auditor.h"

#include <sys/stat.h>

static NSString *HumanBytes(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double v = (double)bytes / 1024.0;
    NSArray *units = @[@"KiB", @"MiB", @"GiB", @"TiB"];
    NSUInteger i = 0;
    while (v >= 1024.0 && i < units.count - 1) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
}

static NSString *HumanAge(NSTimeInterval seconds) {
    if (seconds < 60) return [NSString stringWithFormat:@"%.0fs", seconds];
    if (seconds < 3600) return [NSString stringWithFormat:@"%.0fm", seconds / 60.0];
    if (seconds < 86400) return [NSString stringWithFormat:@"%.1fh", seconds / 3600.0];
    if (seconds < 86400 * 30) return [NSString stringWithFormat:@"%.1fd", seconds / 86400.0];
    return [NSString stringWithFormat:@"%.1fmo", seconds / (86400.0 * 30.0)];
}

/* Application state vs throwaway bytes. Deliberately narrow: only extensions
   that are unambiguous. */
static BOOL IsStateFile(NSString *name) {
    NSString *lower = name.lowercaseString;
    for (NSString *ext in @[@".sqlite", @".sqlite3", @".db", @".realm", @".realm.lock",
                            @"-wal", @"-shm", @".storedata", @".plist"]) {
        if ([lower hasSuffix:ext]) return YES;
    }
    return NO;
}

static BOOL IsMediaFile(NSString *name) {
    NSString *lower = name.lowercaseString;
    for (NSString *ext in @[@".mp4", @".mov", @".m4a", @".mp3", @".aac", @".caf",
                            @".jpg", @".jpeg", @".png", @".heic", @".gif", @".webp"]) {
        if ([lower hasSuffix:ext]) return YES;
    }
    return NO;
}

@implementation Auditor {
    /* accumulators for the current audit */
    unsigned long long _total;
    unsigned long long _stateBytes;
    unsigned long long _mediaBytes;
    unsigned long long _freshBytes;   // touched within the last hour
    NSUInteger _files;
    NSUInteger _dirs;
    NSUInteger _stateCount;
    NSUInteger _mediaCount;
    NSUInteger _freshCount;
    unsigned long long _age[5];       // <1h, <24h, <7d, <30d, older
    NSMutableArray<NSDictionary *> *_biggest;
    NSUInteger _maxRows;
}

+ (instancetype)shared {
    static Auditor *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [Auditor new]; });
    return s;
}

- (void)reset:(NSUInteger)maxRows {
    _total = _stateBytes = _mediaBytes = _freshBytes = 0;
    _files = _dirs = _stateCount = _mediaCount = _freshCount = 0;
    for (int i = 0; i < 5; i++) _age[i] = 0;
    _maxRows = maxRows;
    _biggest = [NSMutableArray array];
}

- (void)accountFile:(NSString *)full size:(unsigned long long)size mtime:(NSTimeInterval)mtime {
    _files++;
    _total += size;

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - mtime;
    if (age < 3600) { _age[0] += size; _freshBytes += size; _freshCount++; }
    else if (age < 86400) _age[1] += size;
    else if (age < 86400 * 7) _age[2] += size;
    else if (age < 86400 * 30) _age[3] += size;
    else _age[4] += size;

    BOOL isState = IsStateFile(full.lastPathComponent);
    BOOL isMedia = IsMediaFile(full.lastPathComponent);
    if (isState) { _stateBytes += size; _stateCount++; }
    if (isMedia) { _mediaBytes += size; _mediaCount++; }

    /* keep only the biggest few, so memory stays flat on huge trees */
    NSDictionary *row = @{@"path": full, @"size": @(size), @"age": @(age)};
    if (_biggest.count < _maxRows) {
        [_biggest addObject:row];
    } else if (size > [(NSNumber *)_biggest.firstObject[@"size"] unsignedLongLongValue]) {
        _biggest[0] = row;
    }
    [_biggest sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        unsigned long long sa = [(NSNumber *)a[@"size"] unsignedLongLongValue];
        unsigned long long sb = [(NSNumber *)b[@"size"] unsignedLongLongValue];
        return sa < sb ? NSOrderedAscending : (sa > sb ? NSOrderedDescending : NSOrderedSame);
    }];
}

- (void)walk:(NSString *)root {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir]) return;

    if (!isDir) {
        NSDictionary *a = [fm attributesOfItemAtPath:root error:nil];
        NSDate *m = a[NSFileModificationDate];
        [self accountFile:root
                     size:[a[NSFileSize] unsignedLongLongValue]
                    mtime:m ? m.timeIntervalSince1970 : 0];
        return;
    }

    _dirs++;
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
    for (NSString *relative in e) {
        @autoreleasepool {
            NSString *full = [root stringByAppendingPathComponent:relative];
            BOOL childDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&childDir]) continue;
            if (childDir) { _dirs++; continue; }
            NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
            NSDate *m = a[NSFileModificationDate];
            [self accountFile:full
                         size:[a[NSFileSize] unsignedLongLongValue]
                        mtime:m ? m.timeIntervalSince1970 : 0];
        }
    }
}

- (NSString *)render:(NSString *)title {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"%@\n", title];
    [out appendFormat:@"  size:  %llu bytes (%@)\n", _total, HumanBytes(_total)];
    [out appendFormat:@"  files: %lu    dirs: %lu\n", (unsigned long)_files, (unsigned long)_dirs];

    if (_files == 0) {
        [out appendString:@"  (empty)\n"];
        return out;
    }

    [out appendFormat:@"  修改时间分布:  <1h %@ | <24h %@ | <7d %@ | <30d %@ | 更早 %@\n",
        HumanBytes(_age[0]), HumanBytes(_age[1]), HumanBytes(_age[2]),
        HumanBytes(_age[3]), HumanBytes(_age[4])];
    [out appendFormat:@"  内容构成:  状态类(sqlite/realm/plist) %lu 个 %@ | 媒体类 %lu 个 %@ | 其余 %@\n",
        (unsigned long)_stateCount, HumanBytes(_stateBytes),
        (unsigned long)_mediaCount, HumanBytes(_mediaBytes),
        HumanBytes(_total - _stateBytes - _mediaBytes)];

    /* Risk flags - each one is a measured fact, not an opinion. */
    if (_stateCount) {
        [out appendFormat:@"  [风险] 含 %lu 个状态类文件 %@：应用状态/草稿可能放在 Caches 里，删除后无法恢复\n",
            (unsigned long)_stateCount, HumanBytes(_stateBytes)];
    }
    if (_freshCount) {
        [out appendFormat:@"  [风险] %lu 个文件在最近 1 小时内被写入（%@）：正在使用中的文件，清理工具应当跳过\n",
            (unsigned long)_freshCount, HumanBytes(_freshBytes)];
    }
    if (_mediaCount) {
        [out appendFormat:@"  [风险] 含 %lu 个媒体文件 %@：可能是用户主动离线保存的内容，不是缓存\n",
            (unsigned long)_mediaCount, HumanBytes(_mediaBytes)];
    }
    if (!_stateCount && !_freshCount && !_mediaCount) {
        [out appendString:@"  未见状态类/媒体类/近期写入文件\n"];
    }

    if (_biggest.count) {
        [out appendFormat:@"  最大的 %lu 个文件:\n", (unsigned long)_biggest.count];
        for (NSDictionary *row in [_biggest reverseObjectEnumerator]) {
            [out appendFormat:@"      %14llu  %-8@  %@\n",
                [(NSNumber *)row[@"size"] unsignedLongLongValue],
                HumanAge([(NSNumber *)row[@"age"] doubleValue]),
                (NSString *)row[@"path"]];
        }
    }
    return out;
}

- (NSString *)auditReportFor:(NSString *)path title:(NSString *)title {
    [self reset:15];
    [self walk:path];
    return [self render:title];
}

- (NSString *)auditReportForPaths:(NSArray<NSString *> *)paths
                            title:(NSString *)title
                          maxRows:(NSUInteger)maxRows {
    [self reset:maxRows];
    for (NSString *p in paths) {
        @autoreleasepool { [self walk:p]; }
    }
    return [self render:title];
}

@end
