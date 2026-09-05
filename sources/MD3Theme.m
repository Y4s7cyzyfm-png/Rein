//
//  MD3Theme.m
//  Rein
//

#import "MD3Theme.h"

static UIColor *MD3Color(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

// Dynamic color provider: light / dark variants.
static UIColor *MD3Dynamic(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *_Nonnull(UITraitCollection *_Nonnull trait) {
        return (trait.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
    }];
}

@implementation MD3Theme

+ (UIColor *)primaryColor {
    return MD3Dynamic(MD3Color(26, 115, 232, 1.0),   // Google Blue 600
                      MD3Color(138, 180, 248, 1.0)); // Blue 300
}

+ (UIColor *)onPrimaryColor {
    return MD3Dynamic(UIColor.whiteColor, MD3Color(16, 28, 52, 1.0));
}

+ (UIColor *)primaryContainerColor {
    return MD3Dynamic(MD3Color(211, 227, 253, 1.0), MD3Color(51, 74, 128, 1.0));
}

+ (UIColor *)onPrimaryContainerColor {
    return MD3Dynamic(MD3Color(23, 78, 166, 1.0), MD3Color(211, 227, 253, 1.0));
}

+ (UIColor *)backgroundColor {
    return MD3Dynamic(MD3Color(248, 249, 250, 1.0), MD3Color(17, 18, 20, 1.0));
}

+ (UIColor *)surfaceColor {
    return MD3Dynamic(UIColor.whiteColor, MD3Color(28, 29, 32, 1.0));
}

+ (UIColor *)surfaceVariantColor {
    return MD3Dynamic(MD3Color(240, 244, 249, 1.0), MD3Color(44, 45, 48, 1.0));
}

+ (UIColor *)onSurfaceColor {
    return MD3Dynamic(MD3Color(31, 31, 31, 1.0), MD3Color(227, 227, 227, 1.0));
}

+ (UIColor *)onSurfaceVariantColor {
    return MD3Dynamic(MD3Color(95, 99, 104, 1.0), MD3Color(154, 160, 166, 1.0));
}

+ (UIColor *)outlineColor {
    return MD3Dynamic(MD3Color(218, 220, 224, 1.0), MD3Color(60, 62, 66, 1.0));
}

+ (UIColor *)errorColor {
    return MD3Dynamic(MD3Color(217, 48, 37, 1.0), MD3Color(242, 139, 130, 1.0));
}

+ (UIColor *)successColor {
    return MD3Dynamic(MD3Color(19, 115, 51, 1.0), MD3Color(129, 199, 132, 1.0));
}

+ (UIFont *)headlineFont {
    if (@available(iOS 16.0, *)) {
        return [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    }
    return [UIFont boldSystemFontOfSize:22];
}

+ (UIFont *)titleFont {
    return [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
}

+ (UIFont *)bodyFont {
    return [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
}

+ (UIFont *)labelFont {
    return [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
}

@end
