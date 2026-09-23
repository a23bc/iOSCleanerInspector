#import "CleanupPlanner.h"

/* The whole safety model of this app:
   - a hard allow-list of directory shapes; anything else is refused outright
   - never a directory, never a symlink, never anything written in the last hour
   - every path re-checked immediately before it is removed
   Directories the safety review marked "must not be deleted" are not even in
   the allow-list, so no code path here can reach them. */

static NSString *const kContainerRoot = @"/var/mobile/Containers/Data/Application";
static NSString *const kSystemCaches = @"/var/mobile/Library/Caches";
static NSString *const kTemp = @"/tmp";

/* Anything not matching one of these shapes is refused. Deliberately narrow. */
static BOOL PathIsDeletable(NSString *path) {
    if ([path hasPrefix:[kTemp stringByAppendingString:@"/"]]) return YES;
    if ([path hasPrefix:[kSystemCaches stringByAppendingString:@"/"]]) return YES;

    NSString *prefix = [kContainerRoot stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return NO;

    NSArray<NSString *> *parts = [[path substringFromIndex:prefix.length] componentsSeparatedByString:@"/"];
    if (parts.count < 2) return NO;

    /* parts[0] must look like a container UUID */
    NSRange r = [parts[0] rangeOfString:@"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
                                options:NSRegularExpressionSearch];
    if (r.location == NSNotFound) return NO;

    if (parts.count >= 3 && [parts[1] isEqualToString:@"Library"] && [parts[2] isEqualToString:@"Caches"]) return YES;
    if ([parts[1] isEqualToString:@"tmp"]) return YES;
    return NO;
}

static NSString *HumanBytes(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double v = (double)bytes / 1024.0;
    NSArray *units = @[@"KiB", @"MiB", @"GiB", @"TiB"];
    NSUInteger i = 0;
    while (v >= 1024.0 && i < units.count - 1) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
}

static unsigned long long SizeOfTree(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) {
        NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
        return [a[NSFileSize] unsignedLongLongValue];
    }
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    for (NSString *rel in e) {
        @autoreleasepool {
            NSString *full = [path stringByAppendingPathComponent:rel];
            BOOL childDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&childDir] || childDir) continue;
            NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
            total += [a[NSFileSize] unsignedLongLongValue];
        }
    }
    return total;
}

static NSString *_Nullable BundleIDForContainer(NSString *container) {
    NSString *metadataPath =
        [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    NSString *identifier = metadata[@"MCMMetadataIdentifier"];
    return [identifier isKindOfClass:NSString.class] && identifier.length ? identifier : nil;
}

@implementation CleanItem
@end

@implementation CleanPlan
@end

@implementation CleanupPlanner

+ (instancetype)shared {
    static CleanupPlanner *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [CleanupPlanner new]; });
    return s;
}

- (NSArray<CleanItem *> *)discoverTargets {
    NSMutableArray<CleanItem *> *items = [NSMutableArray array];

    /* Global targets first, so they stay visible at the top. */
    for (NSString *path in @[kTemp, kSystemCaches]) {
        unsigned long long size = SizeOfTree(path);
        if (size == 0) continue;
        CleanItem *item = [CleanItem new];
        item.title = path;
        item.directories = @[path];
        item.directorySizes = @[@(size)];
        item.bytes = size;
        item.selected = YES;
        [items addObject:item];
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *entries = [fm contentsOfDirectoryAtPath:kContainerRoot error:nil];
    for (NSString *uuid in entries) {
        @autoreleasepool {
            NSString *container = [kContainerRoot stringByAppendingPathComponent:uuid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:container isDirectory:&isDir] || !isDir) continue;

            NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
            NSString *tmp = [container stringByAppendingPathComponent:@"tmp"];
            unsigned long long cacheBytes = SizeOfTree(caches);
            unsigned long long tmpBytes = SizeOfTree(tmp);
            if (cacheBytes == 0 && tmpBytes == 0) continue;

            CleanItem *item = [CleanItem new];
            item.title = BundleIDForContainer(container) ?: uuid;
            item.directories = @[caches, tmp];
            item.directorySizes = @[@(cacheBytes), @(tmpBytes)];
            item.bytes = cacheBytes + tmpBytes;
            item.selected = YES;
            [items addObject:item];
        }
    }

    [items sortUsingComparator:^NSComparisonResult(CleanItem *a, CleanItem *b) {
        if (a.bytes == b.bytes) return [a.title compare:b.title];
        return a.bytes > b.bytes ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
}

- (CleanPlan *)planForItems:(NSArray<CleanItem *> *)items {
    CleanPlan *plan = [CleanPlan new];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *biggest = [NSMutableArray array];
    const NSUInteger maxRows = 20;

    unsigned long long total = 0;
    NSUInteger recent = 0, links = 0, denied = 0;
    unsigned long long recentBytes = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    NSFileManager *fm = NSFileManager.defaultManager;
    for (CleanItem *item in items) {
        if (!item.selected) continue;
        for (NSString *dir in item.directories) {
            if (!PathIsDeletable([dir stringByAppendingString:@"/"])) { denied++; continue; }

            NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
            for (NSString *rel in e) {
                @autoreleasepool {
                    NSString *full = [dir stringByAppendingPathComponent:rel];
                    NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
                    NSString *type = a[NSFileType];
                    if (!type) continue;                                            /* gone or unreadable */
                    if ([type isEqualToString:NSFileTypeDirectory]) continue;        /* dirs are never removed */
                    if ([type isEqualToString:NSFileTypeSymbolicLink]) { links++; continue; }
                    if (!PathIsDeletable(full)) { denied++; continue; }

                    unsigned long long size = [a[NSFileSize] unsignedLongLongValue];
                    NSDate *m = a[NSFileModificationDate];
                    NSTimeInterval age = m ? (now - m.timeIntervalSince1970) : 0;
                    if (age < 3600) { recent++; recentBytes += size; continue; }

                    [files addObject:full];
                    total += size;

                    /* Keep only the biggest few - sorting the whole list would
                       cost a stat per comparison on ~200k files. */
                    NSDictionary *row = @{@"path": full, @"size": @(size)};
                    BOOL inserted = NO;
                    if (biggest.count < maxRows) {
                        [biggest addObject:row];
                        inserted = YES;
                    } else if (size > [(NSNumber *)biggest[0][@"size"] unsignedLongLongValue]) {
                        biggest[0] = row;
                        inserted = YES;
                    }
                    if (inserted) {
                        [biggest sortUsingComparator:^NSComparisonResult(NSDictionary *p, NSDictionary *q) {
                            unsigned long long sp = [(NSNumber *)p[@"size"] unsignedLongLongValue];
                            unsigned long long sq = [(NSNumber *)q[@"size"] unsignedLongLongValue];
                            if (sp == sq) return NSOrderedSame;
                            return sp < sq ? NSOrderedAscending : NSOrderedDescending;
                        }];
                    }
                }
            }
        }
    }

    plan.files = files;
    plan.bytes = total;
    plan.skippedRecent = recent;
    plan.skippedRecentBytes = recentBytes;
    plan.skippedLink = links;
    plan.skippedDenied = denied;

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"DRY RUN - 只统计，未删除任何文件\n"];
    [out appendString:@"==============================\n\n"];
    [out appendFormat:@"计划删除: %lu 个文件, %@\n", (unsigned long)files.count, HumanBytes(total)];
    [out appendFormat:@"跳过(1 小时内写入): %lu 个, %@\n", (unsigned long)recent, HumanBytes(recentBytes)];
    [out appendFormat:@"跳过(符号链接): %lu 个\n", (unsigned long)links];
    [out appendFormat:@"拒绝(不在允许清单内): %lu 个\n\n", (unsigned long)denied];
    [out appendString:@"规则: 只删文件不删目录; 不跟随/删除符号链接; 跳过最近 1 小时内被写入的;\n"
                       "日志、下载、Photos 数据、daemon/插件/共享/系统容器不在允许清单内, 无法触及。\n\n"];

    if (biggest.count) {
        [out appendString:@"最大的待删文件:\n"];
        for (NSDictionary *row in [biggest reverseObjectEnumerator]) {
            [out appendFormat:@"    %12@  %@\n", HumanBytes([(NSNumber *)row[@"size"] unsignedLongLongValue]),
                                                  (NSString *)row[@"path"]];
        }
    }
    plan.summary = out;
    return plan;
}

- (NSString *)executePlan:(CleanPlan *)plan {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger ok = 0, failed = 0, skipped = 0;
    unsigned long long freed = 0;
    NSMutableString *errors = [NSMutableString string];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    for (NSString *path in plan.files) {
        @autoreleasepool {
            /* Re-check everything: the plan may be minutes old by now. */
            NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
            NSString *type = a[NSFileType];
            if (!type || ![type isEqualToString:NSFileTypeRegular]) { skipped++; continue; }
            if (!PathIsDeletable(path)) { skipped++; continue; }

            NSDate *m = a[NSFileModificationDate];
            if (m && (now - m.timeIntervalSince1970) < 3600) { skipped++; continue; }

            unsigned long long size = [a[NSFileSize] unsignedLongLongValue];
            NSError *error = nil;
            if ([fm removeItemAtPath:path error:&error]) {
                ok++;
                freed += size;
            } else {
                failed++;
                if (errors.length < 4000) {
                    [errors appendFormat:@"    %@  (%@)\n", path, error.localizedDescription ?: @"unknown"];
                }
            }
        }
    }

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"DELETE RESULT\n==============\n\n"];
    [out appendFormat:@"已删除: %lu 个, 释放 %@\n", (unsigned long)ok, HumanBytes(freed)];
    [out appendFormat:@"跳过(删除前复核未通过): %lu 个\n", (unsigned long)skipped];
    [out appendFormat:@"失败: %lu 个\n", (unsigned long)failed];
    if (errors.length) {
        [out appendString:@"\n失败明细:\n"];
        [out appendString:errors];
    }
    [out appendString:@"\n目录本身一律保留; 允许清单外的路径从未被触及。\n"];
    return out;
}

@end
