#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Compile-time check of the Objective-C API surface (also the README's Objective-C examples).
@interface ADFObjCExample : NSObject
+ (void)initializeSDK;
- (void)loadInterstitialFrom:(UIViewController *)viewController;
- (void)loadRewardedFrom:(UIViewController *)viewController;
- (UIView *)makeBannerIn:(UIViewController *)viewController;
@end

NS_ASSUME_NONNULL_END
