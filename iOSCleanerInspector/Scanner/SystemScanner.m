#import "SystemScanner.h"
#import "Scanner.h"
#import "Auditor.h"

#include <sys/stat.h>

/* AccessFailure() comes from Scanner.h / Scanner.m. */

@implementation SystemScanner

+ (instancetype)shared {
    static SystemScanner *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [SystemScanner new]; });
    return s;
}

- (NSString *)scanReport {
    /* Only the global directories the audited cleaner actually wipes.
       Everything the safety review ruled out (logs, downloads, Photos data,
       system/daemon containers, shared AppGroup) is deliberately NOT touched -
       we do not even enumerate them. */
    NSArray<NSString *> *targets = @[
        @"/tmp",
        @"/var/mobile/Library/Caches"
    ];

    NSMutableString *out = [NSMutableString stringWithString:@"GLOBAL TARGETS\n--------------\n\n"];

    /* /var -> /private/var and /tmp -> /private/var/tmp, so /var/tmp is the
       same directory as /tmp. Say so instead of counting it twice. */
    struct stat tmpStat, varTmpStat;
    if (stat("/tmp", &tmpStat) == 0 && stat("/var/tmp", &varTmpStat) == 0
        && tmpStat.st_dev == varTmpStat.st_dev && tmpStat.st_ino == varTmpStat.st_ino) {
        [out appendString:@"note: /var/tmp is the same directory as /tmp "
                          "(dev:inode matches) - audited once\n\n"];
    }

    Auditor *auditor = [Auditor shared];
    for (NSString *path in targets) {
        NSString *failure = AccessFailure(path);
        if (failure) {
            [out appendFormat:@"[NO ACCESS] %@\n    cause: %@\n\n", path, failure];
            continue;
        }
        [out appendString:[auditor auditReportFor:path title:path]];
        [out appendString:@"\n"];
    }

    return out;
}

@end
