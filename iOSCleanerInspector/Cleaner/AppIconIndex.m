#import "AppIconIndex.h"

static NSString *const kBundleRoot = @"/var/containers/Bundle/Application";

@interface AppIconIndex ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *byBundleID;
@property (nonatomic, assign) BOOL builtFlag;
@end

@implementation AppIconIndex

+ (instancetype)shared {
    static AppIconIndex *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [AppIconIndex new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) _byBundleID = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)built { return self.builtFlag; }
- (NSUInteger)count { return self.byBundleID.count; }

/* Icon candidates, most specific first. */
static NSArray<NSString *> *IconCandidates(NSDictionary *info) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];

    NSDictionary *primary = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
    NSArray *files = primary[@"CFBundleIconFiles"];
    if ([files isKindOfClass:NSArray.class]) {
        for (NSString *base in files) {
            if (![base isKindOfClass:NSString.class]) continue;
            [names addObject:[base stringByAppendingString:@"@3x.png"]];
            [names addObject:[base stringByAppendingString:@"@2x.png"]];
            [names addObject:[base stringByAppendingString:@".png"]];
        }
    }
    [names addObjectsFromArray:@[@"AppIcon60x60@3x.png", @"AppIcon60x60@2x.png",
                                 @"AppIcon76x76@2x.png", @"AppIcon40x40@3x.png",
                                 @"AppIcon40x40@2x.png", @"AppIcon.png", @"Icon.png"]];
    return names;
}

- (void)buildWithProgress:(void (^)(NSUInteger, NSUInteger))progress {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    NSArray *uuids = [fm contentsOfDirectoryAtPath:kBundleRoot error:&error];
    if (!uuids) return;    /* no permission: lookups simply return nil */

    NSUInteger index = 0;
    for (NSString *uuid in uuids) {
        @autoreleasepool {
            index++;
            if (progress) progress(index, uuids.count);

            NSString *container = [kBundleRoot stringByAppendingPathComponent:uuid];
            NSArray *inner = [fm contentsOfDirectoryAtPath:container error:nil];
            for (NSString *name in inner) {
                if (![name hasSuffix:@".app"]) continue;
                NSString *appPath = [container stringByAppendingPathComponent:name];
                NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                NSString *bundleID = info[@"CFBundleIdentifier"];
                if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) continue;

                NSString *display = info[@"CFBundleDisplayName"];
                if (![display isKindOfClass:NSString.class] || display.length == 0) display = info[@"CFBundleName"];
                if (![display isKindOfClass:NSString.class]) display = nil;

                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[@"path"] = appPath;
                if (display) entry[@"name"] = display;
                self.byBundleID[bundleID] = entry;
            }
        }
    }
    self.builtFlag = YES;
}

- (NSString *)displayNameForBundleID:(NSString *)bundleID {
    return self.byBundleID[bundleID][@"name"];
}

- (UIImage *)iconForBundleID:(NSString *)bundleID {
    NSString *appPath = self.byBundleID[bundleID][@"path"];
    if (!appPath) return nil;

    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *file in IconCandidates(info ?: @{})) {
        NSString *candidate = [appPath stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:candidate]) {
            UIImage *image = [UIImage imageWithContentsOfFile:candidate];
            if (image) return image;
        }
    }
    return nil;
}

@end
