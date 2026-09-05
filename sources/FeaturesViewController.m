//
//  FeaturesViewController.m
//  Rein
//

#import "FeaturesViewController.h"
#import "MD3Theme.h"
#import "MD3Components.h"
#import "ReinBridge.h"
#import "PeaceESP.h"
#import "SilentKeepAlive.h"

static NSString * const kFeatureKeyPrefix = @"rein.feature.";

@interface FeaturesViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) MD3FilledButton *reinFeatureButton;
@property (nonatomic, strong) UIView *toastView;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) NSTimer *espStateTimer;
@property (nonatomic, strong) MD3Switch *keepAliveSwitch;
@property (nonatomic, copy, nullable) NSString *lastShownESPError;
@property (nonatomic, assign) BOOL espStarting;
@end

@implementation FeaturesViewController

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

    [self buildReinFeatureButton];
    [self buildKeepAliveCard];
    [self buildFeatureSwitches];
    [self buildToast];

    // 轮询 ESP 状态刷新按钮文案 / 展示异步错误
    self.espStateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                          target:self
                                                        selector:@selector(espStateTick)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.espStateTimer invalidate];
    self.espStateTimer = nil;
}

/// 「启动ESP」按钮（SF 图标：restart.circle）
- (void)buildReinFeatureButton {
    self.reinFeatureButton = [MD3FilledButton buttonWithTitle:@"启动ESP"
                                                   systemIcon:@"restart.circle"
                                                        style:0];
    [self.stack addArrangedSubview:self.reinFeatureButton];

    __weak typeof(self) weakSelf = self;
    self.reinFeatureButton.onTap = ^(MD3FilledButton *button) {
        [weakSelf espTapped:button];
    };
}

- (void)espStateTick {
    BOOL running = PeaceESPIsRunning();

    // 异步启动失败时弹一次错误并复位按钮
    NSString *error = PeaceESPLastError();
    if (error.length > 0 && ![error isEqualToString:self.lastShownESPError]) {
        self.lastShownESPError = error;
        self.espStarting = NO;
        [self showToast:error];
    } else if (error.length == 0) {
        self.lastShownESPError = nil;
    }

    if (running) {
        self.espStarting = NO;
        [self.reinFeatureButton setTitle:@"停止ESP"];
    } else if (!self.espStarting) {
        [self.reinFeatureButton setTitle:@"启动ESP"];
    }
}

/// 「后台保活」卡片：静音音频循环，退后台后 App 不被冻结，
/// RemoteCall 异常端口得以继续应答（防 SpringBoard 注销）。
- (void)buildKeepAliveCard {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"后台保活";
    title.font = MD3Theme.titleFont;
    title.textColor = MD3Theme.onSurfaceColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"静音音频循环，退后台保持运行（防注销）";
    subtitle.font = MD3Theme.bodyFont;
    subtitle.textColor = MD3Theme.onSurfaceColor;
    subtitle.numberOfLines = 0;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitle];

    MD3Switch *keepAliveSwitch = [[MD3Switch alloc] init];
    keepAliveSwitch.on = SilentKeepAlivePreferenceEnabled();
    keepAliveSwitch.tag = 100;
    [keepAliveSwitch addTarget:self action:@selector(keepAliveChanged:)
               forControlEvents:UIControlEventValueChanged];
    [card addSubview:keepAliveSwitch];
    self.keepAliveSwitch = keepAliveSwitch;

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:keepAliveSwitch.leadingAnchor constant:-12],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:keepAliveSwitch.leadingAnchor constant:-12],
        [subtitle.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],

        [keepAliveSwitch.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [keepAliveSwitch.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];

    // 偏好已开启时补一次启动（冷启动后自动恢复播放）
    if (SilentKeepAlivePreferenceEnabled()) {
        SilentKeepAliveStart();
    }
}

- (void)keepAliveChanged:(MD3Switch *)sender {
    SilentKeepAliveSetPreference(sender.on);
    [self showToast:sender.on ? @"后台保活已开启" : @"后台保活已关闭"];
}

- (void)buildFeatureSwitches {
    MD3CardView *card = [[MD3CardView alloc] init];
    [self.stack addArrangedSubview:card];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"功能开关";
    cardTitle.font = MD3Theme.titleFont;
    cardTitle.textColor = MD3Theme.onSurfaceColor;
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:cardTitle];

    UIView *previousAnchor = cardTitle;
    for (NSInteger index = 1; index <= 5; index++) {
        NSString *title = [NSString stringWithFormat:@"功能%ld", (long)index];
        UIView *row = [self featureRowWithTitle:title index:index];
        [card addSubview:row];

        [NSLayoutConstraint activateConstraints:@[
            [row.topAnchor constraintEqualToAnchor:previousAnchor.bottomAnchor
                                        constant:(index == 1 ? 12 : 0)],
            [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
            [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        ]];
        previousAnchor = row;
    }

    [NSLayoutConstraint activateConstraints:@[
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cardTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [previousAnchor.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-12],
    ]];
}

- (UIView *)featureRowWithTitle:(NSString *)title index:(NSInteger)index {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = MD3Theme.titleFont;
    label.textColor = MD3Theme.onSurfaceColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];

    MD3Switch *switchView = [[MD3Switch alloc] init];
    NSString *key = [kFeatureKeyPrefix stringByAppendingString:[NSString stringWithFormat:@"%ld", (long)index]];
    switchView.on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
    [row addSubview:switchView];

    [switchView addTarget:self action:@selector(featureChanged:)
     forControlEvents:UIControlEventValueChanged];
    switchView.tag = index;

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:52],

        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

        [switchView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [switchView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

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
    self.toastLabel.text = @"功能暂定，敬请期待";
    self.toastLabel.font = MD3Theme.labelFont;
    self.toastLabel.textColor = MD3Theme.backgroundColor;
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toastView addSubview:self.toastLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.toastView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.toastView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                    constant:-24],
        [self.toastView.heightAnchor constraintEqualToConstant:40],
        [self.toastView.widthAnchor constraintGreaterThanOrEqualToConstant:180],

        [self.toastLabel.topAnchor constraintEqualToAnchor:self.toastView.topAnchor constant:10],
        [self.toastLabel.bottomAnchor constraintEqualToAnchor:self.toastView.bottomAnchor constant:-10],
        [self.toastLabel.leadingAnchor constraintEqualToAnchor:self.toastView.leadingAnchor constant:20],
        [self.toastLabel.trailingAnchor constraintEqualToAnchor:self.toastView.trailingAnchor constant:-20],
    ]];
}

- (void)espTapped:(MD3FilledButton *)sender {
    if (PeaceESPIsRunning()) {
        PeaceESPStop();
        [self.reinFeatureButton setTitle:@"启动ESP"];
        return;
    }

    if (!ReinKernelIsReady()) {
        [self showToast:@"请先在「内核」页面初始化 DarkSword 内核"];
        return;
    }
    if (!ReinRemoteCallIsReady()) {
        [self showToast:@"请先在「内核」页面初始化 RemoteCall"];
        return;
    }

    [self.reinFeatureButton setTitle:@"启动中…"];
    self.espStarting = YES;
    PeaceESPStart();
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

- (void)featureChanged:(MD3Switch *)sender {
    NSString *key = [kFeatureKeyPrefix
        stringByAppendingString:[NSString stringWithFormat:@"%ld", (long)sender.tag]];
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
