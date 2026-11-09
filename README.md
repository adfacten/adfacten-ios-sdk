# Adfacten Ads SDK for iOS

Banner, interstitial, rewarded, native and app-open ads from the Adfacten network.

- iOS 15+, Swift 5.9+ / Swift 6, Objective-C compatible
- No third-party dependencies (UIKit, WebKit, AVFoundation, StoreKit)
- ~650 KB device binary, privacy manifest included

## Installation

### Swift Package Manager

In Xcode: **File > Add Package Dependencies…** and enter `https://github.com/adfacten/adfacten-ios-sdk`, or in `Package.swift`:

```swift
.package(url: "https://github.com/adfacten/adfacten-ios-sdk.git", from: "1.0.0")
```

and add `"AdfactenAds"` to your target's dependencies.

### CocoaPods

```ruby
pod 'AdfactenAds', :git => 'https://github.com/adfacten/adfacten-ios-sdk.git', :tag => '1.0.0'
```

### Manual

1. Download `https://cdn.adfacten.com/ios/AdfactenAds-1.0.0.xcframework.zip` and unzip it.
2. Drag `AdfactenAds.xcframework` into your project and set it to **Embed & Sign**.

## Initialize

Call once at launch, on the main thread. The app key (`apk_…`) is in the Adfacten panel under your app.

```swift
import AdfactenAds

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let config = AdfactenConfig()
    config.testMode = true          // while developing
    config.userId = currentUser?.id // optional, for rewarded server callbacks
    Adfacten.initialize(appKey: "apk_XXXXXXXX", config: config)
    return true
}
```

```objc
@import AdfactenAds;

ADFConfig *config = [ADFConfig new];
config.testMode = YES;
[ADFAdfacten initializeWithAppKey:@"apk_XXXXXXXX" config:config];
```

| Config | Default | |
|---|---|---|
| `testMode` | `false` | Request test ads (never billed). |
| `logLevel` | `.warning` | Console output, subsystem `com.adfacten.ads`. |
| `childDirected` | `false` | COPPA. Adfacten does not serve child-directed apps; requests are flagged and no device IDs are sent. |
| `userId` | `nil` | Your user id, passed to the rewarded server callback. Change later with `Adfacten.setUserId(_:)`. |

All callbacks run on the main thread. Each loaded ad expires about 55 minutes after loading; load close to when you show it.

## Banner

Sizes: `.banner` 320×50, `.largeBanner` 320×100, `.mediumRectangle` 300×250, `.leaderboard` 728×90 (tablets).

The banner refreshes every 30–120 seconds (placement setting, or `refreshInterval`). Time only counts while the banner is on screen and the app is active.

```swift
let banner = AdfactenBannerView(placementId: "plc_XXXXXXXX", size: .banner)
banner.delegate = self
banner.rootViewController = self
view.addSubview(banner)   // has an intrinsic content size
banner.load()
```

SwiftUI:

```swift
AdfactenBanner(placementId: "plc_XXXXXXXX", size: .banner)
    .frame(width: 320, height: 50)
```

```objc
ADFBannerView *banner = [[ADFBannerView alloc] initWithPlacementId:@"plc_XXXXXXXX" size:ADFBannerSizeBanner];
banner.delegate = self;
banner.rootViewController = self;
[self.view addSubview:banner];
[banner load];
```

Delegate: `bannerViewDidLoad`, `bannerView(_:didFailWithError:)`, `bannerViewDidRecordImpression`, `bannerViewDidClick`.

## Interstitial

```swift
InterstitialAd.load(placementId: "plc_XXXXXXXX") { [weak self] ad, error in
    guard let ad else { return }
    ad.delegate = self
    self?.interstitial = ad
}

// later
if let ad = interstitial, ad.isReady { ad.present(from: self) }
```

With async/await:

```swift
let ad = try await InterstitialAd.load(placementId: "plc_XXXXXXXX")
ad.present(from: self)
```

```objc
[ADFInterstitialAd loadWithPlacementId:@"plc_XXXXXXXX" completion:^(ADFInterstitialAd *ad, NSError *error) {
    self.interstitial = ad;
    ad.delegate = self;
}];
[self.interstitial presentFromViewController:self];
```

`FullScreenAdDelegate`: `adDidPresent`, `ad(_:didFailToPresentWithError:)`, `adDidClick`, `adDidDismiss`. Each ad can be shown once; load the next one in `adDidDismiss`.

## Rewarded

```swift
RewardedAd.load(placementId: "plc_XXXXXXXX", customData: "level=3") { [weak self] ad, error in
    self?.rewarded = ad
}

rewarded?.present(from: self) { reward in
    // UI only, e.g. show "+10 coins". Credit the user from your server callback.
    print("earned \(reward.amount) \(reward.type)")
}
```

```objc
[ADFRewardedAd loadWithPlacementId:@"plc_XXXXXXXX" customData:@"level=3" completion:^(ADFRewardedAd *ad, NSError *error) {
    self.rewarded = ad;
}];
[self.rewarded presentFromViewController:self userDidEarnRewardHandler:^(ADFReward *reward) { }];
```

Video ads play muted and the close button appears after the placement's countdown. Closing early asks for confirmation and gives no reward.

### Server-side verification (SSV)

Only trust the server callback. `onUserEarnedReward` runs on the device and can be faked.

After a completed view, Adfacten calls the reward callback URL set on your app:

```
GET <callback>?user_id=…&custom=…&reward_type=coins&reward_amount=10
    &transaction_id=<id>&placement=plc_…&ts=<unix>[&test=1]&sig=<hex>
```

- `sig` is hex HMAC-SHA256 of the raw query string up to (not including) `&sig=`, keyed with your reward secret (`rws_…`).
- Compare signatures in constant time and reject old `ts` values.
- `transaction_id` is unique. Calls are retried until you return 2xx, so make crediting idempotent.
- `test=1` marks test ads; don't credit real rewards for them.

## Native

Build your own layout in a `NativeAdView` and connect the outlets (in code or Interface Builder): `titleLabel`, `bodyLabel`, `brandLabel`, `callToActionButton`, `mediaView`, `iconView`, `adLabel`.

```swift
NativeAd.load(placementId: "plc_XXXXXXXX") { ad, error in
    nativeAdView.nativeAd = ad   // fills the outlets and starts tracking
}
```

```objc
[ADFNativeAd loadWithPlacementId:@"plc_XXXXXXXX" completion:^(ADFNativeAd *ad, NSError *error) {
    self.nativeAdView.nativeAd = ad;
}];
```

The view records impressions and clicks itself; taps anywhere on it open the ad. Keep the ad label visible; if `adLabel` is not connected, the view adds a small badge. Set `nativeAd = nil` when a cell is reused.

## App open

```swift
AppOpenAd.load(placementId: "plc_XXXXXXXX") { ad, _ in self.appOpen = ad }

// on cold start or when returning to the foreground
appOpen?.present()   // or present(from: viewController)
```

## Errors

Errors use the domain `com.adfacten.ads` and `AdfactenErrorCode`:

| Code | Meaning |
|---|---|
| `notInitialized` | `initialize` was not called, or the app key is invalid. |
| `noFill` | No ad right now. The placement then backs off for at least 30 seconds. |
| `network` | Network error, timeout or server error. |
| `serverRejected` | 400/403. `serverCode` tells why: `unknown_app`, `app_not_approved`, `platform_mismatch`, `bundle_mismatch`, `placement_mismatch`, `invalid_request`. |
| `childDirected` | The app or request is child-directed. |
| `expired`, `notReady` | The ad expired or was already shown. Load a new one. |
| `presentationFailed` | No view controller in a window, or another ad is on screen. |
| `creativeFailed` | The image, HTML or video failed to load. |

## Test mode

- `config.testMode = true` returns test ads labeled "Test ad". They are never billed and their rewards are marked `test=1`.
- Apps under review, apps with test mode on in the panel, and apps whose app-ads.txt is not verified only get test ads.
- The simulator always gets test ads.

Turn test mode off before release.

## Privacy and consent

### App Tracking Transparency

The SDK never shows the ATT prompt. If you request it and the user allows tracking, the SDK uses the IDFA; otherwise it uses the IDFV, or a random per-install id. Add `NSUserTrackingUsageDescription` to your Info.plist if you ask for ATT.

The IDFA is also not sent when GDPR applies, when a GPP string is present, or when the US Privacy string has an opt-out.

### GDPR / US privacy

The SDK reads the standard IAB keys your consent platform (CMP) writes to `UserDefaults`: `IABTCF_gdprApplies`, `IABTCF_TCString`, `IABTCF_PurposeConsents`, `IABGPP_HDR_GppString` and `IABUSPrivacy_String`. Nothing else is needed. Under GDPR without purpose 1 consent, no device identifier other than the SDK's random install id is sent.

### App Store privacy answers

The SDK ships `PrivacyInfo.xcprivacy`. In App Store Connect, declare:

| Data type | Linked to user | Used for tracking | Purposes |
|---|---|---|---|
| Device ID | No | Yes | Third-party advertising, Analytics |
| Advertising Data | No | No | Third-party advertising, Analytics |
| Product Interaction | No | No | Third-party advertising, Analytics |
| User ID (only if you set `userId`) | Yes | No | App functionality |

The SDK uses `UserDefaults` (reason `CA92.1`) and system boot time for elapsed time (reason `35F9.1`). It does not collect location, contacts or other personal data. The ad server sees the IP address for fraud checks and coarse country targeting.

## SKAdNetwork

Not supported yet. You don't need to add Adfacten entries to `SKAdNetworkItems` for now.

## Sample app

`Project/AdfactenAds.xcodeproj` has the `AdfactenSample` scheme: a SwiftUI demo of every format, a UIKit screen with a banner in a table, and an Objective-C file that uses the API.

The sample is preconfigured with Adfacten's public sample app, which always receives test ads (never billed), so it runs as is. To try your own app, put its app key and placement ids from the panel (**Apps › your app**) in `Sample/AdfactenSample/SampleApp.swift`, or pass them as `ADF_APP_KEY`, `ADF_PLC_BANNER`, … environment variables. To work offline, run the bundled mock server:

```sh
python3 scripts/mock_server.py &       # local test server on :8197
scripts/run_sample.sh                  # builds and runs in the simulator
scripts/run_sample.sh http://127.0.0.1:8197 rewarded   # shows a rewarded ad automatically
```

## Development

```sh
# unit and end-to-end tests on the simulator
xcodebuild test -scheme AdfactenAds -destination 'platform=iOS Simulator,name=iPhone 17'

# AdfactenAds.xcframework, the zip and the SwiftPM checksum in dist/
scripts/build_xcframework.sh
```

`scripts/build_xcframework.sh` also writes the version and checksum into `distribution/Package.swift` (the binary SwiftPM manifest) and `distribution/AdfactenAds.podspec`. The version comes from `Adfacten.sdkVersion` and must match `MARKETING_VERSION` in the Xcode project.

## License

Apache License 2.0. See [LICENSE](LICENSE).
