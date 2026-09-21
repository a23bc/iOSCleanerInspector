#import "ViewController.h"
#import "Scanner/Scanner.h"

@interface ViewController ()
@property(nonatomic, strong) UITextView *output;
@property(nonatomic, strong) UIButton *scanButton;
@property(nonatomic, strong) UIButton *exportButton;
/* The report exactly as produced by the scanner. Export this rather than
   output.text so the exported bytes cannot be affected by text kit layout. */
@property(nonatomic, copy) NSString *report;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"iOS Cleaner Inspector";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.scanButton setTitle:@"Scan (READ ONLY)" forState:UIControlStateNormal];
    self.scanButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.scanButton addTarget:self
                        action:@selector(scan:)
              forControlEvents:UIControlEventTouchUpInside];

    self.exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.exportButton setTitle:@"Export…" forState:UIControlStateNormal];
    self.exportButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.exportButton addTarget:self
                          action:@selector(export:)
                forControlEvents:UIControlEventTouchUpInside];
    self.exportButton.enabled = NO;

    UIStackView *buttons =
        [[UIStackView alloc] initWithArrangedSubviews:@[self.scanButton, self.exportButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 12;
    buttons.distribution = UIStackViewDistributionFillEqually;

    self.output = [[UITextView alloc] init];
    self.output.editable = NO;
    self.output.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.output.text = @"Ready.\n\nThis app never deletes files.\n"
                        "Tap Scan, then Export to hand the report to the system.\n";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        buttons, self.output
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [buttons.heightAnchor constraintEqualToConstant:52]
    ]];
}

- (void)scan:(id)sender {
    self.scanButton.enabled = NO;
    self.exportButton.enabled = NO;
    self.report = nil;
    self.output.text = @"Scanning...\n";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *report = [[Scanner shared] fullReadOnlyReport];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.report = report;
            self.output.text = report;
            self.scanButton.enabled = YES;
            self.exportButton.enabled = (report.length > 0);
        });
    });
}

/* Hand the RAW report string to UIActivityViewController. No file is written
   up front and no file URL is handed over, so this must not open the Files
   browser to "really save" anything - the system only materialises a file if
   the user picks a destination inside the sheet. */
- (void)export:(id)sender {
    NSString *report = self.report.length ? self.report : self.output.text;
    if (report.length == 0) return;

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[report]
                                          applicationActivities:nil];
    activity.completionWithItemsHandler =
        ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *error) {
            if (error) {
                self.output.text =
                    [self.output.text stringByAppendingFormat:
                        @"\n[EXPORT FAILED] %@\n    %@\n",
                        activityType ?: @"(unknown activity)",
                        error.localizedDescription];
            }
        };

    /* Required on iPad: presenting a popover without a source crashes.
       Harmless on iPhone. */
    activity.modalPresentationStyle = UIModalPresentationPopover;
    activity.popoverPresentationController.sourceView = self.exportButton;
    activity.popoverPresentationController.sourceRect = self.exportButton.bounds;
    activity.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionUp;

    [self presentViewController:activity animated:YES completion:nil];
}

@end
