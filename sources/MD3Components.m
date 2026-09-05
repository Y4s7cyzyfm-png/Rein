//
//  MD3Components.m
//  Rein
//

#import "MD3Components.h"

#pragma mark - MD3FilledButton

@interface MD3FilledButton ()
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, assign) NSUInteger style;
@end

@implementation MD3FilledButton

+ (instancetype)buttonWithTitle:(NSString *)title
                      systemIcon:(nullable NSString *)systemIconName
                           style:(NSUInteger)style {
    MD3FilledButton *button = [[MD3FilledButton alloc] init];
    button.style = style;
    button.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    stack.userInteractionEnabled = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [button addSubview:stack];
    button.contentStack = stack;

    if (systemIconName.length > 0) {
        UIImageView *icon = [[UIImageView alloc] init];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.preferredSymbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
        icon.image = [UIImage systemImageNamed:systemIconName];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:icon];
        button.iconView = icon;
        [icon.widthAnchor constraintEqualToConstant:24].active = YES;
        [icon.heightAnchor constraintEqualToConstant:24].active = YES;
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontForContentSizeCategory = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:label];
    button.titleLabel = label;

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:button.leadingAnchor constant:20],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:button.trailingAnchor constant:-20],
        [button.heightAnchor constraintEqualToConstant:52],
    ]];

    [button addTarget:button action:@selector(handleTap)
     forControlEvents:UIControlEventTouchUpInside];
    [button applyStyle];
    return button;
}

- (void)applyStyle {
    UIColor *fill;
    UIColor *content;
    switch (self.style) {
        case 1: // tonal
            fill = MD3Theme.primaryContainerColor;
            content = MD3Theme.onPrimaryContainerColor;
            break;
        case 2: // outlined
            fill = UIColor.clearColor;
            content = MD3Theme.primaryColor;
            break;
        default: // filled
            fill = MD3Theme.primaryColor;
            content = MD3Theme.onPrimaryColor;
            break;
    }
    self.backgroundColor = fill;
    self.iconView.tintColor = content;
    self.titleLabel.textColor = content;
    self.layer.cornerRadius = 26;
    if (self.style == 2) {
        self.layer.borderWidth = 1;
        self.layer.borderColor = MD3Theme.outlineColor.CGColor;
    }
    [self setNeedsDisplay];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyStyle];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1.0 : 0.45;
}

- (void)setTitle:(NSString *)title {
    self.titleLabel.text = title;
}

- (void)handleTap {
    if (self.onTap) self.onTap(self);
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.transform = CGAffineTransformMakeScale(0.97, 0.97); }
                     completion:nil];
    return [super beginTrackingWithTouch:touch withEvent:event];
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [UIView animateWithDuration:0.12 delay:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.transform = CGAffineTransformIdentity; }
                     completion:nil];
    [super endTrackingWithTouch:touch withEvent:event];
}

@end

#pragma mark - MD3Switch

@interface MD3Switch ()
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *thumbView;
@property (nonatomic, strong) NSLayoutConstraint *thumbCenterX;
@end

@implementation MD3Switch {
    UIImpactFeedbackGenerator *_hapticGenerator;
    BOOL _dragged;
    CGFloat _touchStartLocationX;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        _hapticGenerator = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleLight];

        // 轨道
        UIView *track = [[UIView alloc] init];
        track.translatesAutoresizingMaskIntoConstraints = NO;
        track.layer.cornerRadius = 16;
        track.layer.cornerCurve = kCACornerCurveContinuous;
        track.userInteractionEnabled = NO;
        [self addSubview:track];
        self.trackView = track;

        // 滑块
        UIView *thumb = [[UIView alloc] init];
        thumb.translatesAutoresizingMaskIntoConstraints = NO;
        thumb.layer.cornerRadius = 12;
        thumb.layer.cornerCurve = kCACornerCurveContinuous;
        thumb.userInteractionEnabled = NO;
        [self addSubview:thumb];
        self.thumbView = thumb;

        [NSLayoutConstraint activateConstraints:@[
            [track.topAnchor constraintEqualToAnchor:self.topAnchor],
            [track.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [thumb.widthAnchor constraintEqualToConstant:24],
            [thumb.heightAnchor constraintEqualToConstant:24],
            [thumb.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        _thumbCenterX = [thumb.centerXAnchor
            constraintEqualToAnchor:self.leadingAnchor constant:16];
        _thumbCenterX.active = YES;

        [self.widthAnchor constraintEqualToConstant:52].active = YES;
        [self.heightAnchor constraintEqualToConstant:32].active = YES;

        [self applyColorsAnimated:NO];
    }
    return self;
}

// 扩大点击热区到至少 44x44（HIG 最小可点按尺寸）
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect bounds = self.bounds;
    CGFloat dx = MAX(0, (44.0 - bounds.size.width) / 2.0);
    CGFloat dy = MAX(0, (44.0 - bounds.size.height) / 2.0);
    CGRect hitArea = CGRectInset(bounds, -dx, -dy);
    return CGRectContainsPoint(hitArea, point);
}

#pragma mark 触摸跟踪：单击切换 + 左右拖拽切换

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _touchStartLocationX = [touch locationInView:self].x;
    _dragged = NO;
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat locationX = [touch locationInView:self].x;
    CGFloat deltaX = locationX - _touchStartLocationX;
    if (ABS(deltaX) >= 10.0) {
        _dragged = YES;
        BOOL on = deltaX > 0;
        if (on != self.on) {
            [self toggleTo:on];
        }
    }
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [super endTrackingWithTouch:touch withEvent:event];
    if (_dragged) return;
    [self toggleTo:!self.on];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [super cancelTrackingWithEvent:event];
    _dragged = NO;
}

- (void)toggleTo:(BOOL)on {
    [self setOn:on animated:YES];
    [_hapticGenerator impactOccurred];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)setOn:(BOOL)on {
    [self setOn:on animated:NO];
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    _on = on;
    [self applyColorsAnimated:animated];
    self.accessibilityValue = on ? @"1" : @"0";
}

- (void)applyColorsAnimated:(BOOL)animated {
    UIColor *trackColor = self.on ? MD3Theme.primaryColor : MD3Theme.surfaceVariantColor;
    UIColor *thumbColor = self.on ? MD3Theme.onPrimaryColor : MD3Theme.outlineColor;
    CGFloat targetX = self.on ? 36 : 16;

    void (^changes)(void) = ^{
        self.trackView.backgroundColor = trackColor;
        self.thumbView.backgroundColor = thumbColor;
        self.thumbCenterX.constant = targetX;
        [self layoutIfNeeded];
    };

    if (animated) {
        [UIView animateWithDuration:0.18
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyColorsAnimated:NO];
}

@end

#pragma mark - MD3CardView

@implementation MD3CardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = 16;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundColor = MD3Theme.surfaceColor;
        self.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;
        self.layer.shadowOpacity = 1;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 1);
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.backgroundColor = MD3Theme.surfaceColor;
}

@end

#pragma mark - MD3ProgressView

@interface MD3ProgressView ()
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) NSLayoutConstraint *fillWidth;
@end

@implementation MD3ProgressView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = UIColor.clearColor;

        UIView *track = [[UIView alloc] init];
        track.translatesAutoresizingMaskIntoConstraints = NO;
        track.layer.cornerRadius = 2;
        track.layer.cornerCurve = kCACornerCurveContinuous;
        track.backgroundColor = MD3Theme.surfaceVariantColor;
        [self addSubview:track];
        self.trackView = track;

        UIView *fill = [[UIView alloc] init];
        fill.translatesAutoresizingMaskIntoConstraints = NO;
        fill.layer.cornerRadius = 2;
        fill.layer.cornerCurve = kCACornerCurveContinuous;
        fill.backgroundColor = MD3Theme.primaryColor;
        [self addSubview:fill];
        self.fillView = fill;

        [NSLayoutConstraint activateConstraints:@[
            [track.topAnchor constraintEqualToAnchor:self.topAnchor],
            [track.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [track.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [fill.topAnchor constraintEqualToAnchor:self.topAnchor],
            [fill.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [fill.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [fill.widthAnchor constraintLessThanOrEqualToAnchor:track.widthAnchor],
        ]];
        _fillWidth = [fill.widthAnchor constraintEqualToConstant:0];
        _fillWidth.active = YES;

        [self.heightAnchor constraintEqualToConstant:4].active = YES;
    }
    return self;
}

- (void)setProgress:(double)progress {
    [self setProgress:progress animated:NO];
}

- (void)setProgress:(double)progress animated:(BOOL)animated {
    _progress = MIN(MAX(progress, 0.0), 1.0);
    CGFloat width = self.bounds.size.width * _progress;
    if (width <= 0) width = 1;

    void (^changes)(void) = ^{
        self.fillWidth.constant = width;
        [self layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes];
    } else {
        changes();
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.fillWidth.constant = self.bounds.size.width * _progress;
    if (self.fillWidth.constant <= 0) self.fillWidth.constant = 1;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.trackView.backgroundColor = MD3Theme.surfaceVariantColor;
    self.fillView.backgroundColor = MD3Theme.primaryColor;
}

@end
