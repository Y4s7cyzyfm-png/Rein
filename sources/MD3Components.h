//
//  MD3Components.h
//  Rein
//
//  Material Design 3 style UIKit controls: filled button, switch, card.
//

#import <UIKit/UIKit.h>
#import "MD3Theme.h"

NS_ASSUME_NONNULL_BEGIN

/// MD3 filled button: full pill shape (28pt radius), 52pt height.
@interface MD3FilledButton : UIControl

@property (nonatomic, copy, nullable) void (^onTap)(MD3FilledButton *button);

+ (instancetype)buttonWithTitle:(NSString *)title
                      systemIcon:(nullable NSString *)systemIconName
                           style:(NSUInteger)style; // 0 = filled, 1 = tonal, 2 = outlined

- (void)setEnabled:(BOOL)enabled;
- (void)setTitle:(NSString *)title;

@end

/// MD3 switch: 52x32 track, 16pt thumb expanding to 24pt when on.
@interface MD3Switch : UIControl

@property (nonatomic, assign, getter=isOn) BOOL on;

- (void)setOn:(BOOL)on animated:(BOOL)animated;

@end

/// MD3 elevated card: surface color, 16pt corners, soft shadow.
@interface MD3CardView : UIView
@end

/// MD3 linear progress indicator (4pt height, rounded, primary on track).
@interface MD3ProgressView : UIView

@property (nonatomic, assign) double progress;

- (void)setProgress:(double)progress animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
