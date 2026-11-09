import UIKit

/// Events of interstitial, rewarded and app-open ads. Always called on the main thread.
@objc(ADFFullScreenAdDelegate)
@MainActor
public protocol FullScreenAdDelegate: AnyObject {
    /// The ad is on screen (`onShown`).
    @objc optional func adDidPresent(_ ad: FullScreenAd)
    /// `present(from:)` could not show the ad (`onFailed`).
    @objc optional func ad(_ ad: FullScreenAd, didFailToPresentWithError error: Error)
    /// The user tapped the ad (`onClicked`).
    @objc optional func adDidClick(_ ad: FullScreenAd)
    /// The ad was closed and dismissed (`onClosed`). Load the next ad here.
    @objc optional func adDidDismiss(_ ad: FullScreenAd)
}

/// The reward configured for a rewarded placement.
@objc(ADFReward)
public final class AdReward: NSObject, Sendable {
    @objc public let type: String
    @objc public let amount: Double

    init(type: String, amount: Double) {
        self.type = type
        self.amount = amount
    }

    public override var description: String { "\(amount) \(type)" }
}

/// Base class of `InterstitialAd`, `RewardedAd` and `AppOpenAd`. Each instance is shown at most once.
@objc(ADFFullScreenAd)
@MainActor
public class FullScreenAd: NSObject {
    @objc public let placementId: String
    @objc public weak var delegate: FullScreenAdDelegate?

    /// Closure alternatives to the delegate (both are called).
    public var onPresented: (() -> Void)?
    public var onClicked: (() -> Void)?
    public var onDismissed: (() -> Void)?

    let loaded: LoadedAd
    let context: SDKContext
    let preloadedImage: UIImage?
    private var used = false
    var rewardHandler: ((AdReward) -> Void)?

    static var presenting = false
    /// Test seam: hosts without a real scene (SPM test runner) can't run modal transitions.
    static var presentOverride: ((UIViewController, UIViewController) -> Void)?

    init(loaded: LoadedAd, context: SDKContext, preloadedImage: UIImage?) {
        self.placementId = loaded.placementId
        self.loaded = loaded
        self.context = context
        self.preloadedImage = preloadedImage
        super.init()
    }

    /// True while the ad can be presented (loaded, not shown yet, not expired).
    @objc public var isReady: Bool { !used && !loaded.isExpired(now: context.env.clock.now()) }

    /// When the loaded ad expires (≈ 55 minutes after loading).
    @objc public var expirationDate: Date { loaded.expiresAt }

    var isRewarded: Bool { false }

    /// Presents the ad full screen from `viewController` (the top-most presented controller is used).
    @objc(presentFromViewController:)
    public func present(from viewController: UIViewController) {
        if let err = presentationError(viewController) {
            Log.warning("present failed: \(err.message)")
            delegate?.ad?(self, didFailToPresentWithError: err)
            return
        }
        used = true
        FullScreenAd.presenting = true
        let top = ClickHandler.topmost(from: viewController)
        let p = loaded.payload
        let closeAfter = max(0, min(p.closeAfterS ?? 0, 60))
        // Non-video rewarded ads complete after close_after_s seconds on screen.
        let rewardAfter = closeAfter
        let vc = FullScreenAdViewController(
            ad: loaded, context: context,
            options: .init(rewarded: isRewarded, closeAfter: closeAfter, rewardAfter: rewardAfter),
            preloadedImage: preloadedImage
        )
        vc.onShown = { [weak self] in
            guard let self else { return }
            self.delegate?.adDidPresent?(self)
            self.onPresented?()
        }
        vc.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.adDidClick?(self)
            self.onClicked?()
        }
        vc.onReward = { [weak self] in
            guard let self, let r = self.loaded.payload.reward else { return }
            self.rewardHandler?(AdReward(type: r.type, amount: r.amount))
        }
        vc.onClosed = { [weak self] in
            FullScreenAd.presenting = false
            guard let self else { return }
            self.delegate?.adDidDismiss?(self)
            self.onDismissed?()
            self.rewardHandler = nil
        }
        if let presentOverride = FullScreenAd.presentOverride {
            presentOverride(top, vc)
        } else {
            top.present(vc, animated: true)
        }
        // UIKit silently refuses a presentation while another one is running; don't stay "presenting".
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak vc] in
            MainActor.assumeIsolated {
                guard let self, let vc, vc.presentingViewController == nil, vc.view.window == nil else { return }
                FullScreenAd.presenting = false
                let err = AdfactenError(.presentationFailed, "UIKit did not present the ad")
                self.delegate?.ad?(self, didFailToPresentWithError: err)
            }
        }
    }

    private func presentationError(_ vc: UIViewController) -> AdfactenError? {
        if used { return AdfactenError(.notReady, "this ad was already shown; load a new one") }
        if loaded.isExpired(now: context.env.clock.now()) {
            return AdfactenError(.expired, "the ad expired; load a new one")
        }
        if FullScreenAd.presenting { return AdfactenError(.presentationFailed, "another Adfacten ad is on screen") }
        let top = ClickHandler.topmost(from: vc)
        if top.view.window == nil { return AdfactenError(.presentationFailed, "the view controller is not in a window") }
        if top.isBeingDismissed || top.isBeingPresented {
            return AdfactenError(.presentationFailed, "the view controller is in a transition")
        }
        return nil
    }

    /// Shared load path of all full-screen formats.
    static func loadCore(placementId: String, format: AdFormat, custom: String?) async -> Result<(LoadedAd, SDKContext, UIImage?), AdfactenError> {
        guard let ctx = Adfacten.context else {
            return .failure(AdfactenError(.notInitialized, "call Adfacten.initialize(appKey:config:) first"))
        }
        let size = UIScreen.main.bounds.size
        let sizes = ["\(Int(size.width))x\(Int(size.height))"]
        switch await ctx.load(placementId: placementId, format: format, sizes: sizes, custom: custom) {
        case .failure(let e):
            return .failure(e)
        case .success(let ad):
            var image: UIImage?
            if ad.payload.kind == .image {
                image = await ctx.images.load(ad.payload.image, scale: UIScreen.main.scale)
                if image == nil { return .failure(AdfactenError(.creativeFailed, "the creative image could not be loaded")) }
            }
            return .success((ad, ctx, image))
        }
    }
}

/// A full-screen interstitial ad.
///
/// ```swift
/// InterstitialAd.load(placementId: "plc_…") { ad, error in
///     self.interstitial = ad
/// }
/// interstitial?.present(from: self)
/// ```
@objc(ADFInterstitialAd)
@MainActor
public final class InterstitialAd: FullScreenAd {
    /// Loads an interstitial. The completion runs on the main thread with an ad or an error.
    @objc(loadWithPlacementId:completion:)
    public static func load(placementId: String, completion: @escaping @MainActor (InterstitialAd?, Error?) -> Void) {
        Task { @MainActor in
            switch await loadCore(placementId: placementId, format: .interstitial, custom: nil) {
            case .success(let (ad, ctx, img)): completion(InterstitialAd(loaded: ad, context: ctx, preloadedImage: img), nil)
            case .failure(let e): completion(nil, e)
            }
        }
    }

    /// Async variant of `load(placementId:completion:)`.
    public static func load(placementId: String) async throws -> InterstitialAd {
        switch await loadCore(placementId: placementId, format: .interstitial, custom: nil) {
        case .success(let (ad, ctx, img)): return InterstitialAd(loaded: ad, context: ctx, preloadedImage: img)
        case .failure(let e): throw e
        }
    }
}

/// A full-screen app-open ad, for cold starts and returns from the background.
@objc(ADFAppOpenAd)
@MainActor
public final class AppOpenAd: FullScreenAd {
    @objc(loadWithPlacementId:completion:)
    public static func load(placementId: String, completion: @escaping @MainActor (AppOpenAd?, Error?) -> Void) {
        Task { @MainActor in
            switch await loadCore(placementId: placementId, format: .appOpen, custom: nil) {
            case .success(let (ad, ctx, img)): completion(AppOpenAd(loaded: ad, context: ctx, preloadedImage: img), nil)
            case .failure(let e): completion(nil, e)
            }
        }
    }

    public static func load(placementId: String) async throws -> AppOpenAd {
        switch await loadCore(placementId: placementId, format: .appOpen, custom: nil) {
        case .success(let (ad, ctx, img)): return AppOpenAd(loaded: ad, context: ctx, preloadedImage: img)
        case .failure(let e): throw e
        }
    }

    /// Presents from the key window's top-most view controller.
    @objc public func present() {
        guard let root = UIApplication.adfKeyWindow?.rootViewController else {
            delegate?.ad?(self, didFailToPresentWithError: AdfactenError(.presentationFailed, "no key window"))
            return
        }
        present(from: root)
    }
}

/// A full-screen rewarded ad. The reward is granted by Adfacten's **server-side** callback to your
/// backend; `onUserEarnedReward` is for UI only — never credit the user from it alone.
@objc(ADFRewardedAd)
@MainActor
public final class RewardedAd: FullScreenAd {
    override var isRewarded: Bool { true }

    /// The reward configured on the placement.
    @objc public var reward: AdReward? {
        loaded.payload.reward.map { AdReward(type: $0.type, amount: $0.amount) }
    }

    /// Loads a rewarded ad.
    /// - Parameter customData: Optional string (≤ 256 chars) echoed in the server-side reward callback.
    @objc(loadWithPlacementId:customData:completion:)
    public static func load(placementId: String, customData: String? = nil,
                            completion: @escaping @MainActor (RewardedAd?, Error?) -> Void) {
        Task { @MainActor in
            switch await loadCore(placementId: placementId, format: .rewarded, custom: customData) {
            case .success(let (ad, ctx, img)): completion(RewardedAd(loaded: ad, context: ctx, preloadedImage: img), nil)
            case .failure(let e): completion(nil, e)
            }
        }
    }

    public static func load(placementId: String, customData: String? = nil) async throws -> RewardedAd {
        switch await loadCore(placementId: placementId, format: .rewarded, custom: customData) {
        case .success(let (ad, ctx, img)): return RewardedAd(loaded: ad, context: ctx, preloadedImage: img)
        case .failure(let e): throw e
        }
    }

    /// Presents the ad. `onUserEarnedReward` runs once, on the main thread, when the user completed it.
    @objc(presentFromViewController:userDidEarnRewardHandler:)
    public func present(from viewController: UIViewController, onUserEarnedReward: @escaping @MainActor (AdReward) -> Void) {
        rewardHandler = onUserEarnedReward
        present(from: viewController)
    }
}

extension UIApplication {
    @MainActor static var adfKeyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
