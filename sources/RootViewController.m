//
//  RootViewController.m
//  Rein
//
//  Gmail-style shell: top app bar + two primary tabs (内核 / 功能).
//

#import "RootViewController.h"
#import "MD3Theme.h"
#import "KernelViewController.h"
#import "FeaturesViewController.h"

@interface RootViewController ()
@property (nonatomic, strong) UIView *appBarView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *tabBarView;
@property (nonatomic, strong) NSArray<UIButton *> *tabButtons;
@property (nonatomic, strong) UIView *tabIndicatorView;
@property (nonatomic, strong) NSLayoutConstraint *indicatorCenterX;
@property (nonatomic, strong) NSArray<UIViewController *> *pageControllers;
@property (nonatomic, assign) NSUInteger selectedIndex;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MD3Theme.backgroundColor;

    [self buildAppBar];
    [self buildTabBar];
    [self buildPages];
}

- (void)buildAppBar {
    UIView *appBar = [[UIView alloc] init];
    appBar.translatesAutoresizingMaskIntoConstraints = NO;
    appBar.backgroundColor = MD3Theme.backgroundColor;
    [self.view addSubview:appBar];
    self.appBarView = appBar;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Rein";
    title.font = MD3Theme.headlineFont;
    title.textColor = MD3Theme.onSurfaceColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [appBar addSubview:title];
    self.titleLabel = title;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"内核 · 功能";
    subtitle.font = MD3Theme.bodyFont;
    subtitle.textColor = MD3Theme.onSurfaceVariantColor;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [appBar addSubview:subtitle];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [appBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [appBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [appBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [appBar.heightAnchor constraintEqualToConstant:64],

        [title.leadingAnchor constraintEqualToAnchor:appBar.leadingAnchor constant:20],
        [title.bottomAnchor constraintEqualToAnchor:appBar.centerYAnchor constant:-2],

        [subtitle.leadingAnchor constraintEqualToAnchor:appBar.leadingAnchor constant:20],
        [subtitle.topAnchor constraintEqualToAnchor:appBar.centerYAnchor constant:2],
    ]];
}

- (void)buildTabBar {
    UIView *tabBar = [[UIView alloc] init];
    tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    tabBar.backgroundColor = MD3Theme.backgroundColor;
    [self.view addSubview:tabBar];
    self.tabBarView = tabBar;

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    NSArray<NSString *> *titles = @[@"内核", @"功能"];
    for (NSString *tabTitle in titles) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.titleLabel.font = MD3Theme.labelFont;
        [button setTitle:tabTitle forState:UIControlStateNormal];
        [button addTarget:self action:@selector(tabTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [tabBar addSubview:button];
        [buttons addObject:button];
    }
    self.tabButtons = buttons;

    UIView *indicator = [[UIView alloc] init];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    indicator.backgroundColor = MD3Theme.primaryColor;
    indicator.layer.cornerRadius = 2;
    indicator.layer.cornerCurve = kCACornerCurveContinuous;
    [tabBar addSubview:indicator];
    self.tabIndicatorView = indicator;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [tabBar.topAnchor constraintEqualToAnchor:self.appBarView.bottomAnchor],
        [tabBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tabBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tabBar.heightAnchor constraintEqualToConstant:48],

        [buttons[0].widthAnchor constraintEqualToAnchor:tabBar.widthAnchor
                                              multiplier:0.5],
        [buttons[1].widthAnchor constraintEqualToAnchor:tabBar.widthAnchor
                                              multiplier:0.5],
        [buttons[0].topAnchor constraintEqualToAnchor:tabBar.topAnchor],
        [buttons[0].bottomAnchor constraintEqualToAnchor:tabBar.bottomAnchor],
        [buttons[1].topAnchor constraintEqualToAnchor:tabBar.topAnchor],
        [buttons[1].bottomAnchor constraintEqualToAnchor:tabBar.bottomAnchor],
        [buttons[0].leadingAnchor constraintEqualToAnchor:tabBar.leadingAnchor],
        [buttons[1].leadingAnchor constraintEqualToAnchor:buttons[0].trailingAnchor],
        [buttons[1].trailingAnchor constraintEqualToAnchor:tabBar.trailingAnchor],

        [indicator.widthAnchor constraintEqualToConstant:40],
        [indicator.heightAnchor constraintEqualToConstant:4],
        [indicator.bottomAnchor constraintEqualToAnchor:tabBar.bottomAnchor],
    ]];
    _indicatorCenterX = [indicator.centerXAnchor
        constraintEqualToAnchor:buttons[0].centerXAnchor];
    _indicatorCenterX.active = YES;
}

- (void)buildPages {
    KernelViewController *kernel = [[KernelViewController alloc] init];
    FeaturesViewController *features = [[FeaturesViewController alloc] init];
    self.pageControllers = @[kernel, features];

    for (UIViewController *page in self.pageControllers) {
        [self addChildViewController:page];
        page.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:page.view];
        [NSLayoutConstraint activateConstraints:@[
            [page.view.topAnchor constraintEqualToAnchor:self.tabBarView.bottomAnchor],
            [page.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [page.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [page.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
        [page didMoveToParentViewController:self];
    }

    [self selectTabIndex:0 animated:NO];
}

- (void)tabTapped:(UIButton *)sender {
    NSUInteger index = [self.tabButtons indexOfObject:sender];
    if (index != NSNotFound && index != self.selectedIndex) {
        [self selectTabIndex:index animated:YES];
    }
}

- (void)selectTabIndex:(NSUInteger)index animated:(BOOL)animated {
    self.selectedIndex = index;

    for (NSUInteger i = 0; i < self.tabButtons.count; i++) {
        UIButton *button = self.tabButtons[i];
        BOOL selected = (i == index);
        [button setTitleColor:(selected ? MD3Theme.primaryColor
                                        : MD3Theme.onSurfaceVariantColor)
                     forState:UIControlStateNormal];
        button.titleLabel.font = selected
            ? [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]
            : [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    }

    void (^changes)(void) = ^{
        self.indicatorCenterX.active = NO;
        self.indicatorCenterX = [self.tabIndicatorView.centerXAnchor
            constraintEqualToAnchor:self.tabButtons[index].centerXAnchor];
        self.indicatorCenterX.active = YES;
        [self.view layoutIfNeeded];
    };

    if (animated) {
        [UIView animateWithDuration:0.22 delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }

    for (NSUInteger i = 0; i < self.pageControllers.count; i++) {
        self.pageControllers[i].view.hidden = (i != index);
    }
}

- (void)themeDidChange {
    self.view.backgroundColor = MD3Theme.backgroundColor;
    self.appBarView.backgroundColor = MD3Theme.backgroundColor;
    self.tabBarView.backgroundColor = MD3Theme.backgroundColor;
    self.titleLabel.textColor = MD3Theme.onSurfaceColor;
    self.tabIndicatorView.backgroundColor = MD3Theme.primaryColor;
    [self selectTabIndex:self.selectedIndex animated:NO];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle !=
        self.traitCollection.userInterfaceStyle) {
        [self themeDidChange];
    }
}

@end
