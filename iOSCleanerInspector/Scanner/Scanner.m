#import "Scanner.h"
#import "AppScanner.h"
#import "SystemScanner.h"

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
    [out appendString:@"iOS Cleaner Inspector 0.1.0\\n"];
    [out appendString:@"READ-ONLY MODE — NO FILE DELETION\\n"];
    [out appendString:@"================================\\n\\n"];

    [out appendString:[[SystemScanner shared] scanReport]];
    [out appendString:@"\\n"];
    [out appendString:[[AppScanner shared] scanReport]];

    [out appendString:@"\\n================================\\n"];
    [out appendString:@"Scan complete.\\n"];
    return out;
}

@end
