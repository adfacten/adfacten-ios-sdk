#import "ObjCExample.h"
@import AdfactenAds;

@interface ADFObjCExample () <ADFFullScreenAdDelegate, ADFBannerViewDelegate>
@property (nonatomic, strong, nullable) ADFInterstitialAd *interstitial;
@property (nonatomic, strong, nullable) ADFRewardedAd *rewarded;
@end

@implementation ADFObjCExample

+ (void)initializeSDK {
    ADFConfig *config = [ADFConfig new];
    config.testMode = YES;
    config.logLevel = ADFLogLevelDebug;
    config.childDirected = NO;
    config.userId = @"user-123";
    [ADFAdfacten initializeWithAppKey:@"apk_XXXXXXXX" config:config];
}

- (void)loadInterstitialFrom:(UIViewController *)viewController {
    [ADFInterstitialAd loadWithPlacementId:@"plc_XXXXXXXX" completion:^(ADFInterstitialAd *ad, NSError *error) {
        if (error) { NSLog(@"no ad: %@ (code %ld)", error.localizedDescription, (long)error.code); return; }
        self.interstitial = ad;
        ad.delegate = self;
        if (ad.isReady) { [ad presentFromViewController:viewController]; }
    }];
}

- (void)loadRewardedFrom:(UIViewController *)viewController {
    [ADFRewardedAd loadWithPlacementId:@"plc_XXXXXXXX" customData:@"level=3" completion:^(ADFRewardedAd *ad, NSError *error) {
        if (!ad) { return; }
        self.rewarded = ad;
        [ad presentFromViewController:viewController userDidEarnRewardHandler:^(ADFReward *reward) {
            NSLog(@"UI only — credit from the server callback: %f %@", reward.amount, reward.type);
        }];
    }];
}

- (UIView *)makeBannerIn:(UIViewController *)viewController {
    ADFBannerView *banner = [[ADFBannerView alloc] initWithPlacementId:@"plc_XXXXXXXX" size:ADFBannerSizeBanner];
    banner.delegate = self;
    banner.rootViewController = viewController;
    [banner load];
    return banner;
}

- (void)adDidDismiss:(ADFFullScreenAd *)ad { NSLog(@"closed %@", ad.placementId); }
- (void)bannerViewDidClick:(ADFBannerView *)bannerView { NSLog(@"banner click"); }

@end
