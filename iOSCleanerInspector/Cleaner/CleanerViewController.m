#import "CleanerViewController.h"
#import "CleanupPlanner.h"
#import "AppIconIndex.h"

/* Filza URL scheme, documented by the vendor's user guide:
     filza://view/path/to/file   (also filza://path/to/file)
   https://www.tigisoftware.com/default/?page_id=177
   Both forms are tried, and the attempt is logged so a failure can be diagnosed
   instead of guessed at. */
static NSArray<NSString *> *FilzaURLsForPath(NSString *path) {
    NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]] ?: path;
    return @[[@"filza://view" stringByAppendingString:escaped],
             [@"filza://" stringByAppendingString:escaped]];
}

static NSString *HumanBytes(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double v = (double)bytes / 1024.0;
    NSArray *units = @[@"KiB", @"MiB", @"GiB", @"TiB"];
    NSUInteger i = 0;
    while (v >= 1024.0 && i < units.count - 1) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
}

typedef NS_ENUM(NSUInteger, RowKind) {
    RowKindGroup,      /* "全局目标" / "App 容器" - tap to expand */
    RowKindItem,       /* one global directory, or one app container */
    RowKindDirectory   /* a directory inside an item - tap to open in Filza */
};

@interface Row : NSObject
@property (nonatomic, assign) RowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, weak) CleanItem *item;
@property (nonatomic, assign) NSUInteger indent;
@end

@implementation Row
@end

@interface CleanerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextView *log;
@property (nonatomic, strong) UIButton *dryRunButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIButton *exportButton;

@property (nonatomic, strong) NSArray<CleanItem *> *globalItems;
@property (nonatomic, strong) NSArray<CleanItem *> *appItems;
@property (nonatomic, strong) NSArray<Row *> *rows;
@property (nonatomic, assign) BOOL groupGlobalOpen;
@property (nonatomic, assign) BOOL groupAppsOpen;
@property (nonatomic, strong) NSMutableSet<NSString *> *openItems;
@property (nonatomic, strong) CleanPlan *plan;
@property (nonatomic, assign) BOOL busy;
@end

@implementation CleanerViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Safe Cleaner";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.status = [[UILabel alloc] init];
    self.status.font = [UIFont systemFontOfSize:13];
    self.status.text = @"准备中…";
    self.status.numberOfLines = 2;

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 0, 0) style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 56;

    self.log = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    self.log.editable = NO;
    self.log.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.log.text = @"Ready.\n";

    self.dryRunButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dryRunButton setTitle:@"Dry run" forState:UIControlStateNormal];
    [self.dryRunButton addTarget:self action:@selector(dryRun:) forControlEvents:UIControlEventTouchUpInside];

    self.deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.deleteButton setTitle:@"删除" forState:UIControlStateNormal];
    [self.deleteButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [self.deleteButton addTarget:self action:@selector(confirmDelete:) forControlEvents:UIControlEventTouchUpInside];
    self.deleteButton.enabled = NO;

    self.exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.exportButton setTitle:@"导出" forState:UIControlStateNormal];
    [self.exportButton addTarget:self action:@selector(exportLog:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.dryRunButton, self.deleteButton, self.exportButton
    ]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[self.status, self.progress, self.table]];
    top.axis = UILayoutConstraintAxisVertical;
    top.spacing = 8;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, buttons, self.log]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.status.heightAnchor constraintEqualToConstant:36],
        [buttons.heightAnchor constraintEqualToConstant:44],
        [self.log.heightAnchor constraintEqualToConstant:160]
    ]];

    self.openItems = [NSMutableSet set];
    self.groupGlobalOpen = YES;
    self.groupAppsOpen = NO;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.appItems) [self reload];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dryRunButton.enabled = !busy;
        self.deleteButton.enabled = (!busy && self.plan && self.plan.files.count);
    });
}

- (void)setProgress:(float)value status:(NSString *)text {
    self.progress.progress = value;
    self.status.text = text;
}

- (void)reload {
    self.busy = YES;
    self.rows = @[];
    [self.table reloadData];
    [self setProgress:0 status:@"正在枚举目标…"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CleanupPlanner *planner = [CleanupPlanner shared];
        NSArray<CleanItem *> *items = [planner discoverTargetsWithProgress:^(NSUInteger done, NSUInteger total, NSString *what) {
            if (done % 5 == 0 || done == total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setProgress:(total ? (float)done / (float)total : 0)
                               status:[NSString stringWithFormat:@"枚举目标 %lu / %lu\n%@",
                                       (unsigned long)done, (unsigned long)total, what]];
                });
            }
        }];

        NSMutableArray<CleanItem *> *global = [NSMutableArray array];
        NSMutableArray<CleanItem *> *apps = [NSMutableArray array];
        for (CleanItem *item in items) {
            if ([item.title hasPrefix:@"/"]) [global addObject:item]; else [apps addObject:item];
        }

        /* Icons and display names come from the installed bundles. */
        [[AppIconIndex shared] buildWithProgress:^(NSUInteger done, NSUInteger total) {
            if (done % 10 == 0 || done == total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setProgress:(total ? (float)done / (float)total : 0)
                               status:[NSString stringWithFormat:@"读取 App 图标 %lu / %lu",
                                       (unsigned long)done, (unsigned long)total]];
                });
            }
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.globalItems = global;
            self.appItems = apps;
            self.groupAppsOpen = YES;
            [self rebuildRows];
            [self.table reloadData];
            [self setProgress:1 status:[NSString stringWithFormat:@"完成: 全局 %lu 项, App %lu 个",
                                        (unsigned long)global.count, (unsigned long)apps.count]];
            self.log.text = [NSString stringWithFormat:@"%@\n发现全局目标 %lu 项, App 容器 %lu 个。\n"
                                                        "默认全选; 点大项展开; 点目录行跳转 Filza。\n",
                             planner.diagnostic ?: @"", (unsigned long)global.count, (unsigned long)apps.count];
            self.busy = NO;
        });
    });
}

- (void)rebuildRows {
    NSMutableArray<Row *> *rows = [NSMutableArray array];
    AppIconIndex *icons = [AppIconIndex shared];

    Row *globalGroup = [Row new];
    globalGroup.kind = RowKindGroup;
    globalGroup.title = @"全局目标";
    globalGroup.subtitle = [NSString stringWithFormat:@"%lu 项", (unsigned long)self.globalItems.count];
    globalGroup.expanded = self.groupGlobalOpen;
    [rows addObject:globalGroup];

    if (self.groupGlobalOpen) {
        for (CleanItem *item in self.globalItems) {
            Row *row = [Row new];
            row.kind = RowKindItem;
            row.title = item.title;
            row.subtitle = HumanBytes(item.bytes);
            row.path = item.directories.firstObject;
            row.item = item;
            row.indent = 1;
            [rows addObject:row];
            [self appendDirectoriesOf:item toRows:rows];
        }
    }

    Row *appGroup = [Row new];
    appGroup.kind = RowKindGroup;
    appGroup.title = @"App 容器";
    appGroup.subtitle = [NSString stringWithFormat:@"%lu 个", (unsigned long)self.appItems.count];
    appGroup.expanded = self.groupAppsOpen;
    [rows addObject:appGroup];

    if (self.groupAppsOpen) {
        for (CleanItem *item in self.appItems) {
            Row *row = [Row new];
            row.kind = RowKindItem;
            NSString *name = [icons displayNameForBundleID:item.title];
            row.title = name ? [NSString stringWithFormat:@"%@  (%@)", name, item.title] : item.title;
            row.subtitle = HumanBytes(item.bytes);
            row.icon = [icons iconForBundleID:item.title];
            row.item = item;
            row.indent = 1;
            [rows addObject:row];
            [self appendDirectoriesOf:item toRows:rows];
        }
    }

    self.rows = rows;
}

- (void)appendDirectoriesOf:(CleanItem *)item toRows:(NSMutableArray<Row *> *)rows {
    if (![self.openItems containsObject:item.title]) return;
    for (NSUInteger i = 0; i < item.directories.count; i++) {
        NSString *dir = item.directories[i];
        Row *row = [Row new];
        row.kind = RowKindDirectory;
        NSArray<NSString *> *parts = [dir componentsSeparatedByString:@"/"];
        NSString *tail = parts.count >= 3
            ? [NSString stringWithFormat:@"%@/%@", parts[parts.count - 3], parts[parts.count - 1]]
            : dir.lastPathComponent;
        row.title = [@"↳ " stringByAppendingString:tail];
        row.subtitle = i < item.directorySizes.count
            ? HumanBytes([item.directorySizes[i] unsignedLongLongValue]) : @"-";
        row.path = dir;
        row.indent = 2;
        [rows addObject:row];
    }
}

#pragma mark - table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"row";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];

    Row *row = self.rows[indexPath.row];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.subtitle;
    cell.imageView.image = row.icon;
    cell.indentationLevel = row.indent;

    if (row.kind == RowKindGroup) {
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.accessoryView = nil;
        cell.accessoryType = row.expanded ? UITableViewCellAccessoryCheckmark
                                          : UITableViewCellAccessoryDisclosureIndicator;
    } else if (row.kind == RowKindItem) {
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
        sw.on = row.item.selected;
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(toggleItem:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    Row *row = self.rows[indexPath.row];

    if (row.kind == RowKindGroup) {
        if ([row.title isEqualToString:@"全局目标"]) self.groupGlobalOpen = !self.groupGlobalOpen;
        else self.groupAppsOpen = !self.groupAppsOpen;
        [self rebuildRows];
        [self.table reloadData];
        return;
    }

    if (row.kind == RowKindItem) {
        NSString *key = row.item.title;
        if ([self.openItems containsObject:key]) [self.openItems removeObject:key];
        else [self.openItems addObject:key];
        [self rebuildRows];
        [self.table reloadData];
        return;
    }

    [self openInFilza:row.path];
}

- (void)toggleItem:(UISwitch *)sender {
    if (sender.tag < (NSInteger)self.rows.count) {
        Row *row = self.rows[sender.tag];
        row.item.selected = sender.on;
    }
}

- (void)openInFilza:(NSString *)path {
    if (!path) return;
    UIApplication *app = UIApplication.sharedApplication;
    [self note:[NSString stringWithFormat:@"跳转 Filza: %@", path]];

    for (NSString *urlString in FilzaURLsForPath(path)) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            [self note:[NSString stringWithFormat:@"  URL 无效: %@", urlString]];
            continue;
        }
        BOOL can = [app canOpenURL:url];
        [self note:[NSString stringWithFormat:@"  %@  canOpenURL=%@", urlString, can ? @"YES" : @"NO"]];
        if (!can) continue;
        [app openURL:url options:@{} completionHandler:^(BOOL success) {
            [self note:[NSString stringWithFormat:@"  openURL=%@", success ? @"YES" : @"NO"]];
        }];
        return;
    }
    [self note:@"  没有可用的 Filza URL; 路径已复制到剪贴板, 可手动粘进 Filza。"];
    [UIPasteboard generalPasteboard].string = path;
}

#pragma mark - actions

- (void)dryRun:(id)sender {
    if (!self.appItems || self.busy) return;
    self.busy = YES;
    self.log.text = @"Dry run 中…\n";

    NSMutableArray<CleanItem *> *selected = [NSMutableArray array];
    for (CleanItem *item in self.globalItems) if (item.selected) [selected addObject:item];
    for (CleanItem *item in self.appItems) if (item.selected) [selected addObject:item];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CleanPlan *plan = [[CleanupPlanner shared] planForItems:selected];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.plan = plan;
            self.log.text = plan.summary;
            self.busy = NO;
            if (!plan.files.count) [self note:@"没有符合规则的待删文件。"];
        });
    });
}

- (void)confirmDelete:(id)sender {
    if (!self.plan || !self.plan.files.count || self.busy) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"确认删除"
                                            message:[NSString stringWithFormat:@"将删除 %lu 个文件, 约 %@。\n"
                                                     "目录本身保留; 允许清单外的路径不会触及。",
                                                     (unsigned long)self.plan.files.count, HumanBytes(self.plan.bytes)]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { [self runDelete]; }]];
    alert.popoverPresentationController.sourceView = self.deleteButton;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runDelete {
    self.busy = YES;
    self.log.text = @"删除中…\n";
    CleanPlan *plan = self.plan;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *report = [[CleanupPlanner shared] executePlan:plan];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.log.text = report;
            self.plan = nil;
            self.busy = NO;
            [self reload];
        });
    });
}

- (void)exportLog:(id)sender {
    NSString *text = self.log.text;
    if (!text.length) return;
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    activity.modalPresentationStyle = UIModalPresentationPopover;
    activity.popoverPresentationController.sourceView = self.exportButton;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)note:(NSString *)line {
    self.log.text = [self.log.text stringByAppendingFormat:@"%@\n", line];
}

@end
