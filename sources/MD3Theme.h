//
//  MD3Theme.h
//  Rein
//
//  Material Design 3 (Google / Gmail style) design tokens for UIKit.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MD3Theme : NSObject

// Primary palette (Google Blue, Gmail style)
+ (UIColor *)primaryColor;
+ (UIColor *)onPrimaryColor;
+ (UIColor *)primaryContainerColor;
+ (UIColor *)onPrimaryContainerColor;

// Surfaces
+ (UIColor *)backgroundColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)surfaceVariantColor;
+ (UIColor *)onSurfaceColor;
+ (UIColor *)onSurfaceVariantColor;
+ (UIColor *)outlineColor;

// State colors
+ (UIColor *)errorColor;
+ (UIColor *)successColor;

// Typography helpers (system font stands in for Google Sans / Roboto)
+ (UIFont *)headlineFont;
+ (UIFont *)titleFont;
+ (UIFont *)bodyFont;
+ (UIFont *)labelFont;

@end

NS_ASSUME_NONNULL_END
