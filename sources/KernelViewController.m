//
//  KernelViewController.m
//  Rein
//

#import "KernelViewController.h"
#import "MD3Theme.h"
#import "MD3Components.h"
#import "ReinBridge.h"

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
        [self.remoteCallInitButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    __weak typeof(self) weakSelf = self;
    self.kernelInitButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf kernelInitTapped:button];
    };
    self.remoteCallInitButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf remoteCallInitTapped:button];
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
