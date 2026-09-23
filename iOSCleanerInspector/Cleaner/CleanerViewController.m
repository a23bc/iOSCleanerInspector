#import "CleanerViewController.h"
#import "CleanupPlanner.h"

/* Filza URL scheme, documented by the vendor:
     filza://view/path/to/file   (also filza://path/to/file)
   https://www.tigisoftware.com/default/?page_id=177 */
static NSString *FilzaURLForPath(NSString *path) {
    NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]];
    return [@"filza://view" stringByAppendingString:escaped ?: @""];
}

static NSString *HumanBytes(unsigned long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%llu B", bytes];
    double v = (double)bytes / 1024.0;
    NSArray *units = @[@"KiB", @"MiB", @"GiB", @"TiB"];
    NSUInteger i = 0;
    while (v >= 1024.0 && i < units.count - 1) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.2f %@", v, units[i]];
}

@interface CleanerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextView *log;
@property (nonatomic, strong) UIButton *dryRunButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) NSArray<CleanItem *> *globalItems;
@property (nonatomic, strong) NSArray<CleanItem *> *appItems;
@property (nonatomic, strong) CleanPlan *plan;
@property (nonatomic, assign) BOOL busy;
@end

@implementation CleanerViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Safe Cleaner";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, 0, 0) style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 44;

    self.log = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    self.log.editable = NO;
    self.log.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.log.text = @"Ready.\n\n"
                     "全选默认打开; 关掉的不参与清理。\n"
                     "点目录行可以在 Filza 里打开它自己看。\n"
                     "先 Dry run 出清单, 确认后才允许删除。\n";

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

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.spinner, self.table, buttons, self.log
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [buttons.heightAnchor constraintEqualToConstant:44],
        [self.log.heightAnchor constraintEqualToConstant:190],
        [self.spinner.heightAnchor constraintEqualToConstant:20]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.appItems) [self reload];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
        self.dryRunButton.enabled = !busy;
        self.deleteButton.enabled = (!busy && self.plan && self.plan.files.count);
    });
}

- (void)reload {
    self.busy = YES;
    self.log.text = @"正在枚举目标(约需几分钟)...\n";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<CleanItem *> *items = [[CleanupPlanner shared] discoverTargets];
        NSMutableArray<CleanItem *> *global = [NSMutableArray array];
        NSMutableArray<CleanItem *> *apps = [NSMutableArray array];
        for (CleanItem *item in items) {
            if ([item.title hasPrefix:@"/"]) [global addObject:item]; else [apps addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.globalItems = global;
            self.appItems = apps;
            [self.table reloadData];
            self.log.text = [NSString stringWithFormat:@"发现 %lu 个全局目标, %lu 个 App 容器。\n"
                                                        "默认全选; 关掉的不参与。先 Dry run。\n",
                             (unsigned long)global.count, (unsigned long)apps.count];
            self.busy = NO;
        });
    });
}

- (CleanItem *)itemForSection:(NSInteger)section {
    if (section == 0) return nil;
    return self.appItems[section - 1];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (!self.appItems) return 0;
    return 1 + (NSInteger)self.appItems.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)self.globalItems.count;
    return (NSInteger)[self itemForSection:section].directories.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"全局目标" : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 28 : 52;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    CGFloat width = tableView.bounds.size.width;
    if (section == 0) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, width - 24, 28)];
        label.text = @"全局目标";
        label.font = [UIFont boldSystemFontOfSize:13];
        return label;
    }

    CleanItem *item = [self itemForSection:section];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 52)];
    header.backgroundColor = UIColor.secondarySystemBackgroundColor;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, width - 100, 52)];
    label.text = [NSString stringWithFormat:@"%@\n%@", item.title, HumanBytes(item.bytes)];
    label.font = [UIFont systemFontOfSize:13];
    label.numberOfLines = 2;

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(width - 63, 10, 0, 0)];
    sw.on = item.selected;
    sw.tag = section;
    [sw addTarget:self action:@selector(toggleItem:) forControlEvents:UIControlEventValueChanged];

    [header addSubview:label];
    [header addSubview:sw];
    return header;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"dir";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];

    NSString *path;
    if (indexPath.section == 0) {
        CleanItem *item = self.globalItems[indexPath.row];
        path = item.directories.firstObject;
        cell.textLabel.text = path;
        cell.detailTextLabel.text = HumanBytes(item.bytes);
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        path = [self itemForSection:indexPath.section].directories[indexPath.row];
        NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
        NSString *tail = parts.count >= 3
            ? [NSString stringWithFormat:@"%@/%@", parts[parts.count - 3], parts[parts.count - 1]]
            : path.lastPathComponent;
        cell.textLabel.text = tail;
        CleanItem *item = [self itemForSection:indexPath.section];
        if (indexPath.row < (NSInteger)item.directorySizes.count) {
            cell.detailTextLabel.text = HumanBytes([item.directorySizes[indexPath.row] unsignedLongLongValue]);
        } else {
            cell.detailTextLabel.text = @"-";
        }
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    return cell;
}

/* Tapping a directory opens it in Filza, so the user can look before deleting. */
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *path;
    if (indexPath.section == 0) path = self.globalItems[indexPath.row].directories.firstObject;
    else path = [self itemForSection:indexPath.section].directories[indexPath.row];

    NSURL *url = [NSURL URLWithString:FilzaURLForPath(path)];
    if (!url) return;
    UIApplication *app = UIApplication.sharedApplication;
    if ([app canOpenURL:url]) {
        [app openURL:url options:@{} completionHandler:^(BOOL success) {
            if (!success) [self note:[NSString stringWithFormat:@"Filza 打开失败: %@", path]];
        }];
    } else {
        [self note:@"未安装 Filza, 无法跳转。"];
    }
}

- (void)toggleItem:(UISwitch *)sender {
    NSInteger section = sender.tag;
    if (section == 0) {
        CleanItem *item = self.globalItems[0];
        item.selected = sender.on;
        return;
    }
    [self itemForSection:section].selected = sender.on;
}

#pragma mark - actions

- (void)dryRun:(id)sender {
    if (!self.appItems || self.busy) return;
    self.busy = YES;
    self.log.text = @"Dry run 中...\n";

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
                                                     (unsigned long)self.plan.files.count,
                                                     HumanBytes(self.plan.bytes)]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { [self runDelete]; }]];
    alert.popoverPresentationController.sourceView = self.deleteButton;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runDelete {
    self.busy = YES;
    self.log.text = @"删除中...\n";
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
