# Adfacten Ads SDK for iOS

Banner, interstitial, rewarded, native and app-open ads from the Adfacten network.

- iOS 15+, Swift 5.9+ / Swift 6, Objective-C compatible
- No third-party dependencies (UIKit, WebKit, AVFoundation, StoreKit)
- ~650 KB device binary, privacy manifest included

## Installation

### Swift Package Manager

In Xcode: **File > Add Package Dependencies…** and enter `https://github.com/adfacten/adfacten-ios-sdk`, or in `Package.swift`:

```swift
.package(url: "https://github.com/adfacten/adfacten-ios-sdk.git", from: "1.0.2")
```

and add `"AdfactenAds"` to your target's dependencies.

### CocoaPods

```ruby
pod 'AdfactenAds', :git => 'https://github.com/adfacten/adfacten-ios-sdk.git', :tag => '1.0.2'
```

### Manual

1. Download `https://cdn.adfacten.com/ios/AdfactenAds-1.0.2.xcframework.zip` and unzip it.
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

The banner refreshes every 30–120 seconds of on-screen time. Time only counts while the banner is on screen and the app is active.

- If you set `refreshInterval`, it wins: `0` turns refresh off, even when the placement has an interval in the panel.
- If you don't set it, the placement's interval from the panel is used (off if the placement says 0), otherwise 60 seconds.
- After a failed load (no fill, network or server error) the banner tries again by itself after one refresh interval of on-screen time (60 seconds when refresh is off), and never before the placement's backoff ends. It doesn't retry while it is off screen or the app is in the background.
- A rejected request (`rejected`, `invalid_request`: app or placement not approved, wrong bundle, COPPA) stops the banner until you call `load()` again.

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

An ad is shown in one view at a time. Setting the same ad on another view moves it there: the first view stops tracking and its outlets are cleared. Each ad records one impression, however often it is bound.

## App open

```swift
AppOpenAd.load(placementId: "plc_XXXXXXXX") { ad, _ in self.appOpen = ad }

// on cold start or when returning to the foreground
appOpen?.present()   // or present(from: viewController)
```

## Errors

Errors use the domain `com.adfacten.ads` and `AdfactenErrorCode`. Each error also has a stable `name`, the same on iOS and Android (`AdfactenError.name` in Swift, `error.userInfo[ADFAdfacten.errorNameKey]` (`"AdfactenErrorName"`) in Objective-C). Prefer the name in logs and cross-platform code.

```swift
} catch let error as AdfactenError {
    print(error.name)   // "no_fill", "rejected", …
}
```

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

| Code | `name` |
|---|---|
| `notInitialized` | `not_initialized` |
| `noFill` | `no_fill` |
| `network` | `network_error`, or `server_error` for HTTP 5xx |
| `serverRejected` | `rejected`, or `invalid_request` when `serverCode` is `invalid_request` |
| `invalidResponse` | `invalid_response` (`internal_error` if the request could not be built) |
| `expired` | `ad_expired` |
| `notReady` | `not_ready`, or `already_shown` for a full-screen ad that was already presented |
| `presentationFailed` | `show_failed` |
| `creativeFailed` | `creative_failed` |
| `childDirected` | `rejected` with `serverCode` `coppa` (same as Android) |

`video_not_supported`, `load_in_progress` and `child_directed` belong to the shared list but are not used by the iOS SDK.

After a no-fill or a server error, a placement backs off: 30 seconds, doubling up to 15 minutes (plus some random spread). Loads during that time fail at once with `no_fill`. Being offline does not start a backoff.

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

## Framework plugins

The Flutter and React Native plugins report themselves with `Adfacten.setWrapper(name:version:)` (Objective-C `+[ADFAdfacten setWrapperName:version:]`) before `initialize`. Apps don't call it. Names are `flutter`, `react_native`, `unity`, or `other`; the version is 1–20 characters of `[0-9A-Za-z.+-]` (surrounding spaces are trimmed). A version that doesn't fit is sent as `unknown`. It is sent as `app.wrapper` with each ad request and appended to the User-Agent of every request as ` Wrapper/<name>-<version>` (a call after `initialize` applies to later requests). Native apps send neither.

## Changelog

### 1.0.2

- Banner: the app's `refreshInterval` now wins over the placement's interval, so `0` really turns refresh off. Without an app setting, the placement's `refresh_s` is used (0 = off), else 60 s.
- Banner: a failed load retries on the refresh timer only while the banner is on screen and the app is active, and waits for the placement's backoff. A creative that fails to render also retries. Rejections stop until the next `load()`.
- Backoff: 30 s doubling up to 15 min (was 5 min). Network errors (offline) no longer start a backoff; HTTP 5xx still does.
- Native: binding an ad to a new view detaches it from the previous one, and each ad records one impression and one viewable impression however often it is bound.
- Errors: stable `AdfactenError.name` (and `userInfo["AdfactenErrorName"]`), shared with Android. Codes are unchanged. A server COPPA refusal keeps code `childDirected` but is named `rejected` (`serverCode` `coppa`).
- `Adfacten.setWrapper(name:version:)` for framework plugins (`app.wrapper` request field, User-Agent suffix).
- Reward amounts: `AdReward.amount` stays a `Double` and carries the server value exactly; the server sends whole numbers.

### 1.0.0

- First release: banner, interstitial, rewarded, native and app-open ads.

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
