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

@property (nonatomic, strong) MD3FilledButton *initKernelButton;
@property (nonatomic, strong) MD3FilledButton *initRemoteCallButton;
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

    self.initKernelButton = [MD3FilledButton buttonWithTitle:@"初始化 DarkSword 内核"
                                                  systemIcon:@"cpu"
                                                       style:0];
    [card addSubview:self.initKernelButton];

    self.initRemoteCallButton = [MD3FilledButton buttonWithTitle:@"初始化 RemoteCall"
                                                      systemIcon:@"antenna.radiowaves.left.and.right"
                                                           style:0];
    [card addSubview:self.initRemoteCallButton];

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.initKernelButton.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
        [self.initKernelButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.initKernelButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.initRemoteCallButton.topAnchor constraintEqualToAnchor:self.initKernelButton.bottomAnchor constant:12],
        [self.initRemoteCallButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.initRemoteCallButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.initRemoteCallButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    __weak typeof(self) weakSelf = self;
    self.initKernelButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf initKernelTapped:button];
    };
    self.initRemoteCallButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf initRemoteCallTapped:button];
    };
}

#pragma mark - Actions

- (void)initKernelTapped:(MD3FilledButton *)sender {
    if (ReinKernelIsReady()) {
        [self reloadState];
        return;
    }
    if (ReinKernelIsRunning()) return;

    [self.progressView setProgress:0 animated:NO];
    ReinInitializeDarkSwordKernel();
    [self reloadState];
}

- (void)initRemoteCallTapped:(MD3FilledButton *)sender {
    if (ReinRemoteCallIsReady()) {
        [self reloadState];
        return;
    }
    if (ReinRemoteCallIsRunning()) return;

    ReinInitializeRemoteCall();
    [self reloadState];
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

    [self.initKernelButton setEnabled:!kernelRunning];
    [self.initKernelButton setTitle:(kernelRunning
                                        ? @"正在初始化内核…"
                                        : (kernelReady ? @"内核已就绪" : @"初始化 DarkSword 内核"))];
    [self.initRemoteCallButton setEnabled:(kernelReady && !remoteRunning)];
}

@end
