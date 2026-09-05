//
//  KernelViewController.m
//  Rein
//

#import "KernelViewController.h"
#import "MD3Theme.h"
#import "MD3Components.h"
#import "ReinBridge.h"

#pragma mark - Console log viewer（内核页「控制台日志」实时查看器）

@interface ConsoleLogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIButton *logCopyButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, copy) NSString *lastRenderedText;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation ConsoleLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MD3Theme.backgroundColor;

    UIView *header = [[UIView alloc] init];
    header.backgroundColor = MD3Theme.surfaceColor;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"控制台日志";
    titleLabel.font = MD3Theme.titleFont;
    titleLabel.textColor = MD3Theme.onSurfaceColor;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleLabel];

    self.countLabel = [[UILabel alloc] init];
    self.countLabel.font = MD3Theme.labelFont;
    self.countLabel.textColor = MD3Theme.onSurfaceVariantColor;
    self.countLabel.text = @"0 行";
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.countLabel];

    self.logCopyButton = [self headerButtonWithTitle:@"复制"];
    self.clearButton = [self headerButtonWithTitle:@"清空"];
    UIButton *doneButton = [self headerButtonWithTitle:@"完成"];
    [header addSubview:self.logCopyButton];
    [header addSubview:self.clearButton];
    [header addSubview:doneButton];

    self.textView = [[UITextView alloc] init];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1.0];
    self.textView.textColor = [UIColor colorWithRed:0.55 green:0.88 blue:0.62 alpha:1.0];
    self.textView.font = ([UIFont fontWithName:@"Menlo-Regular" size:11]
                          ?: [UIFont fontWithName:@"Courier" size:11]
                          ?: [UIFont systemFontOfSize:11]);
    self.textView.layer.cornerRadius = 12;
    self.textView.layer.masksToBounds = YES;
    self.textView.contentInset = UIEdgeInsetsMake(10, 6, 10, 6);
    self.textView.layoutManager.allowsNonContiguousLayout = NO;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:64],

        [titleLabel.topAnchor constraintEqualToAnchor:header.topAnchor constant:10],
        [titleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],

        [self.countLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [self.countLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.countLabel.bottomAnchor constraintLessThanOrEqualToAnchor:header.bottomAnchor constant:-8],

        [doneButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [doneButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.clearButton.trailingAnchor constraintEqualToAnchor:doneButton.leadingAnchor constant:-18],
        [self.clearButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.logCopyButton.trailingAnchor constraintEqualToAnchor:self.clearButton.leadingAnchor constant:-18],
        [self.logCopyButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.textView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:10],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
    ]];

    [doneButton addTarget:self action:@selector(doneTapped)
         forControlEvents:UIControlEventTouchUpInside];
    [self.logCopyButton addTarget:self action:@selector(copyTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [self.clearButton addTarget:self action:@selector(clearTapped)
               forControlEvents:UIControlEventTouchUpInside];

    [self refreshLog];
}

- (UIButton *)headerButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = MD3Theme.labelFont;
    button.tintColor = MD3Theme.primaryColor;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.refreshTimer) {
        self.refreshTimer = [NSTimer timerWithTimeInterval:0.5
                                                     target:self
                                                   selector:@selector(refreshLog)
                                                   userInfo:nil
                                                    repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

#pragma mark Actions

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyTapped {
    NSArray<NSString *> *lines = ReinConsoleLogLines();
    UIPasteboard.generalPasteboard.string =
        lines.count > 0 ? [lines componentsJoinedByString:@"\n"] : @"";
    [self flashButtonTitle:@"已复制"];
}

- (void)clearTapped {
    // 两段式确认，防误触
    if (![self.clearButton.currentTitle isEqualToString:@"确认清空?"]) {
        [self.clearButton setTitle:@"确认清空?" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.clearButton setTitle:@"清空" forState:UIControlStateNormal];
        });
        return;
    }
    [self.clearButton setTitle:@"清空" forState:UIControlStateNormal];
    ReinClearConsoleLog();
    self.lastRenderedText = nil;
    [self refreshLog];
}

- (void)flashButtonTitle:(NSString *)title {
    [self.logCopyButton setTitle:title forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.logCopyButton setTitle:@"复制" forState:UIControlStateNormal];
    });
}

#pragma mark Refresh

- (void)refreshLog {
    NSArray<NSString *> *lines = ReinConsoleLogLines();
    self.countLabel.text = [NSString stringWithFormat:@"%lu 行", (unsigned long)lines.count];

    NSString *text = lines.count > 0
        ? [lines componentsJoinedByString:@"\n"]
        : @"（暂无日志——初始化内核或启动 ESP 后，日志会实时显示在这里）";
    if ([text isEqualToString:self.lastRenderedText]) return;

    BOOL atBottom = [self isTextViewAtBottom];
    self.textView.text = text;
    self.lastRenderedText = text;
    if (atBottom) [self scrollTextViewToBottom]; // 用户在底部时自动跟随新日志
}

- (BOOL)isTextViewAtBottom {
    CGFloat overflow = self.textView.contentSize.height - self.textView.bounds.size.height;
    if (overflow <= 0) return YES;
    return self.textView.contentOffset.y >= overflow - 60;
}

- (void)scrollTextViewToBottom {
    CGFloat overflow = self.textView.contentSize.height - self.textView.bounds.size.height;
    if (overflow > 0) {
        [self.textView setContentOffset:CGPointMake(0, overflow) animated:NO];
    }
}

@end

@interface KernelViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;

@property (nonatomic, strong) UILabel *kernelStateLabel;
@property (nonatomic, strong) UILabel *remoteStateLabel;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) MD3ProgressView *progressView;

@property (nonatomic, strong) MD3FilledButton *kernelInitButton;
@property (nonatomic, strong) MD3FilledButton *remoteCallInitButton;
@property (nonatomic, strong) MD3FilledButton *consoleLogButton;

@property (nonatomic, strong) UILabel *gameStateLabel;
@property (nonatomic, strong) MD3FilledButton *readGameButton;
@property (nonatomic, strong) MD3FilledButton *dumpSDKButton;

@property (nonatomic, strong) UIView *toastView;
@property (nonatomic, strong) UILabel *toastLabel;
@end

@implementation KernelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MD3Theme.backgroundColor;

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 12;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *content = self.scrollView.contentLayoutGuide;
    UILayoutGuide *frame = self.scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [self.stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
        [self.stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-32],
    ]];

    [self buildStatusCard];
    [self buildActionsCard];
    [self buildGameCard];
    [self buildToast];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(bridgeDidChange:)
                                                 name:ReinBridgeProgressNotification
                                               object:nil];
    [self reloadState];
}

- (void)buildStatusCard {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"状态";
    cardTitle.font = MD3Theme.titleFont;
    cardTitle.textColor = MD3Theme.onSurfaceColor;
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardTitle];

    self.kernelStateLabel = [self stateLabelWithIcon:@"cpu"];
    self.remoteStateLabel = [self stateLabelWithIcon:@"antenna.radiowaves.left.and.right"];
    self.stageLabel = [self stateLabelWithIcon:@"circle.dashed"];
    [card addSubview:self.kernelStateLabel];
    [card addSubview:self.remoteStateLabel];
    [card addSubview:self.stageLabel];

    self.progressView = [[MD3ProgressView alloc] init];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.progressView];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.font = MD3Theme.bodyFont;
    self.errorLabel.textColor = MD3Theme.errorColor;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.hidden = YES;
    [card addSubview:self.errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.kernelStateLabel.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
        [self.kernelStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.kernelStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.remoteStateLabel.topAnchor constraintEqualToAnchor:self.kernelStateLabel.bottomAnchor constant:8],
        [self.remoteStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.remoteStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.progressView.topAnchor constraintEqualToAnchor:self.remoteStateLabel.bottomAnchor constant:12],
        [self.progressView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.progressView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.stageLabel.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:12],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.stageLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.errorLabel.topAnchor constraintEqualToAnchor:self.stageLabel.bottomAnchor constant:8],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.errorLabel.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
}

- (UILabel *)stateLabelWithIcon:(NSString *)iconName {
    UILabel *label = [[UILabel alloc] init];
    label.font = MD3Theme.bodyFont;
    label.textColor = MD3Theme.onSurfaceVariantColor;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextAttachment *icon = [NSTextAttachment new];
    icon.image = [[UIImage systemImageNamed:iconName]
        imageWithTintColor:MD3Theme.onSurfaceVariantColor
         renderingMode:UIImageRenderingModeAlwaysOriginal];
    icon.bounds = CGRectMake(0, -2, 16, 16);
    NSAttributedString *iconText =
        [NSAttributedString attributedStringWithAttachment:icon];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithAttributedString:iconText];
    [text appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"  "
            attributes:@{NSFontAttributeName : MD3Theme.bodyFont}]];
    label.attributedText = text;
    return label;
}

- (void)appendIconString:(NSMutableAttributedString *)target
             systemIcon:(NSString *)iconName
                  color:(UIColor *)color {
    NSTextAttachment *icon = [NSTextAttachment new];
    icon.image = [[UIImage systemImageNamed:iconName]
        imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    icon.bounds = CGRectMake(0, -2, 16, 16);
    [target appendAttributedString:[NSAttributedString attributedStringWithAttachment:icon]];
    [target appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"  " attributes:@{NSFontAttributeName : MD3Theme.bodyFont}]];
}

- (NSMutableAttributedString *)plainAttributes {
    return [[NSMutableAttributedString alloc]
        initWithString:@""
          attributes:@{NSFontAttributeName : MD3Theme.bodyFont,
                       NSForegroundColorAttributeName : MD3Theme.onSurfaceVariantColor}];
}

- (void)buildActionsCard {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"初始化";
    cardTitle.font = MD3Theme.titleFont;
    cardTitle.textColor = MD3Theme.onSurfaceColor;
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardTitle];

    self.kernelInitButton = [MD3FilledButton buttonWithTitle:@"初始化 DarkSword 内核"
                                                  systemIcon:@"cpu"
                                                       style:0];
    [card addSubview:self.kernelInitButton];

    self.remoteCallInitButton = [MD3FilledButton buttonWithTitle:@"初始化 RemoteCall"
                                                      systemIcon:@"antenna.radiowaves.left.and.right"
                                                           style:0];
    [card addSubview:self.remoteCallInitButton];

    self.consoleLogButton = [MD3FilledButton buttonWithTitle:@"控制台日志"
                                                  systemIcon:@"terminal"
                                                       style:1];
    [card addSubview:self.consoleLogButton];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.kernelInitButton.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
        [self.kernelInitButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.kernelInitButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.remoteCallInitButton.topAnchor constraintEqualToAnchor:self.kernelInitButton.bottomAnchor constant:12],
        [self.remoteCallInitButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.remoteCallInitButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.consoleLogButton.topAnchor constraintEqualToAnchor:self.remoteCallInitButton.bottomAnchor constant:12],
        [self.consoleLogButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.consoleLogButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.consoleLogButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    __weak typeof(self) weakSelf = self;
    self.kernelInitButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf kernelInitTapped:button];
    };
    self.remoteCallInitButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf remoteCallInitTapped:button];
    };
    self.consoleLogButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf consoleLogTapped:button];
    };
}

- (void)buildGameCard {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"游戏";
    cardTitle.font = MD3Theme.titleFont;
    cardTitle.textColor = MD3Theme.onSurfaceColor;
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardTitle];

    self.gameStateLabel = [[UILabel alloc] init];
    self.gameStateLabel.font = MD3Theme.bodyFont;
    self.gameStateLabel.textColor = MD3Theme.onSurfaceVariantColor;
    self.gameStateLabel.numberOfLines = 0;
    self.gameStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.gameStateLabel];

    self.readGameButton = [MD3FilledButton buttonWithTitle:@"读取游戏进程"
                                               systemIcon:@"gamecontroller"
                                                    style:0];
    [card addSubview:self.readGameButton];

    self.dumpSDKButton = [MD3FilledButton buttonWithTitle:@"Dump UE4 SDK"
                                             systemIcon:@"doc.text.magnifyingglass"
                                                  style:1];
    [card addSubview:self.dumpSDKButton];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.gameStateLabel.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
        [self.gameStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.gameStateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.readGameButton.topAnchor constraintEqualToAnchor:self.gameStateLabel.bottomAnchor constant:12],
        [self.readGameButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.readGameButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.dumpSDKButton.topAnchor constraintEqualToAnchor:self.readGameButton.bottomAnchor constant:12],
        [self.dumpSDKButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.dumpSDKButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.dumpSDKButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    __weak typeof(self) weakSelf = self;
    self.readGameButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf readGameTapped:button];
    };
    self.dumpSDKButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf dumpSDKTapped:button];
    };

    [self reloadGameState:@"未读取"];
}

- (void)reloadGameState:(NSString *)state {
    self.gameStateLabel.text = [NSString stringWithFormat:@"游戏进程：%@", state];
}

#pragma mark - Actions

- (void)kernelInitTapped:(MD3FilledButton *)sender {
    if (ReinKernelIsReady()) {
        [self reloadState];
        return;
    }
    if (ReinKernelIsRunning()) return;

    [self.progressView setProgress:0 animated:NO];
    ReinInitializeDarkSwordKernel();
    [self reloadState];
}

- (void)remoteCallInitTapped:(MD3FilledButton *)sender {
    if (ReinRemoteCallIsReady()) {
        [self reloadState];
        return;
    }
    if (ReinRemoteCallIsRunning()) return;

    ReinInitializeRemoteCall();
    [self reloadState];
}

- (void)readGameTapped:(MD3FilledButton *)sender {
    if (!ReinKernelIsReady()) {
        [self showToast:@"请先初始化 DarkSword 内核"];
        return;
    }

    [self.readGameButton setEnabled:NO];
    [self.readGameButton setTitle:@"正在读取…"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int pid = 0;
        BOOL found = ReinReadGameProcess(&pid);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.readGameButton setEnabled:YES];
            [strongSelf.readGameButton setTitle:@"读取游戏进程"];
            if (found) {
                [strongSelf reloadGameState:[NSString
                    stringWithFormat:@"ShadowTrackerExtra（pid %d）", pid]];
                [strongSelf showToast:@"游戏进程已找到"];
            } else {
                [strongSelf reloadGameState:@"未找到"];
                [strongSelf showToast:ReinBridgeLastError().length > 0
                    ? ReinBridgeLastError() : @"未找到游戏进程"];
            }
        });
    });
}

- (void)dumpSDKTapped:(MD3FilledButton *)sender {
    // 占位：后续接入实际的 UE4 SDK Dump 功能。
    [self showToast:@"Dump UE4 SDK 功能开发中，敬请期待"];
}

- (void)consoleLogTapped:(MD3FilledButton *)sender {
    ConsoleLogViewController *viewer = [[ConsoleLogViewController alloc] init];
    viewer.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:viewer animated:YES completion:nil];
}

#pragma mark - Toast

- (void)buildToast {
    self.toastView = [[UIView alloc] init];
    self.toastView.backgroundColor = [MD3Theme.onSurfaceColor colorWithAlphaComponent:0.92];
    self.toastView.layer.cornerRadius = 20;
    self.toastView.layer.cornerCurve = kCACornerCurveContinuous;
    self.toastView.userInteractionEnabled = NO;
    self.toastView.hidden = YES;
    self.toastView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.toastView];

    self.toastLabel = [[UILabel alloc] init];
    self.toastLabel.font = MD3Theme.labelFont;
    self.toastLabel.textColor = MD3Theme.backgroundColor;
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.numberOfLines = 0;
    self.toastLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toastView addSubview:self.toastLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.toastView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.toastView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                    constant:-24],
        [self.toastView.heightAnchor constraintGreaterThanOrEqualToConstant:40],
        [self.toastView.widthAnchor constraintGreaterThanOrEqualToConstant:180],

        [self.toastLabel.topAnchor constraintEqualToAnchor:self.toastView.topAnchor constant:10],
        [self.toastLabel.bottomAnchor constraintEqualToAnchor:self.toastView.bottomAnchor constant:-10],
        [self.toastLabel.leadingAnchor constraintEqualToAnchor:self.toastView.leadingAnchor constant:20],
        [self.toastLabel.trailingAnchor constraintEqualToAnchor:self.toastView.trailingAnchor constant:-20],
    ]];
}

- (void)showToast:(NSString *)message {
    self.toastLabel.text = message;
    self.toastView.alpha = 0;
    self.toastView.hidden = NO;
    [UIView animateWithDuration:0.2
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.toastView.alpha = 1;
                     }
                     completion:^(BOOL finished) {
                         dispatch_after(
                             dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{
                                 [UIView animateWithDuration:0.25
                                                       animations:^{
                                                           self.toastView.alpha = 0;
                                                       }
                                                       completion:^(BOOL done) {
                                                           self.toastView.hidden = YES;
                                                       }];
                             });
                     }];
}

#pragma mark - State

- (void)bridgeDidChange:(NSNotification *)note {
    [self reloadState];
}

- (void)reloadState {
    BOOL kernelReady = ReinKernelIsReady();
    BOOL kernelRunning = ReinKernelIsRunning();
    BOOL remoteReady = ReinRemoteCallIsReady();
    BOOL remoteRunning = ReinRemoteCallIsRunning();

    NSString *kernelState = kernelReady ? @"已就绪" : (kernelRunning ? @"初始化中…" : @"未初始化");
    NSString *remoteState;
    if (remoteReady) {
        remoteState = [NSString stringWithFormat:@"已连接（SpringBoard pid %d）", ReinRemoteCallPID()];
    } else {
        remoteState = remoteRunning ? @"连接中…" : @"未连接";
    }

    UIColor *kernelColor = kernelReady ? MD3Theme.successColor : MD3Theme.onSurfaceVariantColor;
    UIColor *remoteColor = remoteReady ? MD3Theme.successColor : MD3Theme.onSurfaceVariantColor;

    NSMutableAttributedString *kernelText = [self plainAttributes];
    [self appendIconString:kernelText systemIcon:@"cpu" color:kernelColor];
    [kernelText appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"DarkSword 内核：%@", kernelState]
            attributes:@{NSFontAttributeName : MD3Theme.bodyFont,
                         NSForegroundColorAttributeName : kernelColor}]];
    self.kernelStateLabel.attributedText = kernelText;

    NSMutableAttributedString *remoteText = [self plainAttributes];
    [self appendIconString:remoteText systemIcon:@"antenna.radiowaves.left.and.right" color:remoteColor];
    [remoteText appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"RemoteCall：%@", remoteState]
            attributes:@{NSFontAttributeName : MD3Theme.bodyFont,
                         NSForegroundColorAttributeName : remoteColor}]];
    self.remoteStateLabel.attributedText = remoteText;

    NSString *stage = ReinBridgeStage();
    NSMutableAttributedString *stageText = [self plainAttributes];
    [self appendIconString:stageText systemIcon:@"circle.dashed" color:MD3Theme.onSurfaceVariantColor];
    [stageText appendAttributedString:[[NSAttributedString alloc]
        initWithString:(stage.length > 0 ? stage : @"等待开始")
            attributes:@{NSFontAttributeName : MD3Theme.bodyFont,
                         NSForegroundColorAttributeName : MD3Theme.onSurfaceVariantColor}]];
    self.stageLabel.attributedText = stageText;

    NSString *error = ReinBridgeLastError();
    self.errorLabel.hidden = (error.length == 0);
    self.errorLabel.text = error;

    double progress = ReinBridgeProgress();
    [self.progressView setProgress:kernelRunning ? progress : (kernelReady ? 1.0 : 0.0)
                          animated:YES];

    [self.kernelInitButton setEnabled:!kernelRunning];
    [self.kernelInitButton setTitle:(kernelRunning
                                        ? @"正在初始化内核…"
                                        : (kernelReady ? @"内核已就绪" : @"初始化 DarkSword 内核"))];
    [self.remoteCallInitButton setEnabled:(kernelReady && !remoteRunning)];
}

@end
