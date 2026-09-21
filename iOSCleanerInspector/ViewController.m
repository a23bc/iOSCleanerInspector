#import "ViewController.h"
#import "Scanner/Scanner.h"

@interface ViewController ()
@property(nonatomic, strong) UITextView *output;
@property(nonatomic, strong) UIButton *scanButton;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"iOS Cleaner Inspector";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.scanButton setTitle:@"Scan (READ ONLY)" forState:UIControlStateNormal];
    self.scanButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.scanButton addTarget:self
                        action:@selector(scan:)
              forControlEvents:UIControlEventTouchUpInside];

    self.output = [[UITextView alloc] init];
    self.output.editable = NO;
    self.output.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.output.text = @"Ready.\n\nThis app never deletes files.\n";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.scanButton, self.output
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
        [self.scanButton.heightAnchor constraintEqualToConstant:52]
    ]];
}

- (void)scan:(id)sender {
    self.scanButton.enabled = NO;
    self.output.text = @"Scanning...\n";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *report = [[Scanner shared] fullReadOnlyReport];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.output.text = report;
            self.scanButton.enabled = YES;
        });
    });
}

@end
