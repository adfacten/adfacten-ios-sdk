import SwiftUI
import UIKit

/// Standard banner sizes (points).
@objc(ADFBannerSize)
public enum AdfactenBannerSize: Int, Sendable, CaseIterable {
    /// 320×50
    case banner = 0
    /// 320×100
    case largeBanner = 1
    /// 300×250
    case mediumRectangle = 2
    /// 728×90 (tablets)
    case leaderboard = 3

    public var size: CGSize {
        switch self {
        case .banner: return CGSize(width: 320, height: 50)
        case .largeBanner: return CGSize(width: 320, height: 100)
        case .mediumRectangle: return CGSize(width: 300, height: 250)
        case .leaderboard: return CGSize(width: 728, height: 90)
        }
    }

    var token: String { "\(Int(size.width))x\(Int(size.height))" }
}

/// Banner events. Always called on the main thread.
@objc(ADFBannerViewDelegate)
@MainActor
public protocol AdfactenBannerViewDelegate: AnyObject {
    /// A creative was loaded (also after each refresh).
    @objc optional func bannerViewDidLoad(_ bannerView: AdfactenBannerView)
    @objc optional func bannerView(_ bannerView: AdfactenBannerView, didFailWithError error: Error)
    /// The creative is on screen (the billable impression).
    @objc optional func bannerViewDidRecordImpression(_ bannerView: AdfactenBannerView)
    @objc optional func bannerViewDidClick(_ bannerView: AdfactenBannerView)
}

/// A banner ad view. Add it to your layout (it has an intrinsic content size) and call `load()`.
/// It refreshes itself every `refreshInterval` seconds of on-screen time, only while visible and
/// while the app is active. After a failed load (no fill, network or server error) it tries again
/// on the same timer; a rejected request (app or placement not approved, COPPA) stops it until the
/// next `load()`.
@objc(ADFBannerView)
@MainActor
public final class AdfactenBannerView: UIView {
    @objc public var placementId: String
    @objc public var adSize: AdfactenBannerSize {
        didSet { invalidateIntrinsicContentSize() }
    }
    @objc public weak var delegate: AdfactenBannerViewDelegate?
    /// The controller used to present the App Store sheet on click. Defaults to the owning controller.
    @objc public weak var rootViewController: UIViewController?
    /// Seconds of visible time between refreshes; clamped to 30…120. 0 disables refresh.
    /// If you set it, it wins over the placement's setting from the server. If you don't, the
    /// placement's setting is used (60 s when it has none).
    @objc public var refreshInterval: TimeInterval {
        get { appRefresh ?? 60 }
        set { appRefresh = newValue }
    }

    public var onLoaded: (() -> Void)?
    public var onFailed: ((Error) -> Void)?
    public var onClicked: (() -> Void)?
    public var onImpression: (() -> Void)?

    /// The interval the app set, if any.
    private var appRefresh: TimeInterval?
    /// `refresh_s` of the last ad the server sent (nil: not sent).
    private var serverRefresh: TimeInterval?
    private var current: LoadedAd?
    private var creative: CreativeView?
    private var tracker: ViewabilityTracker?
    private var badge: AdBadge?
    private var loading = false
    private var wantsAd = false
    private var visibleSinceLoad: TimeInterval = 0
    private(set) var retryAfterFailure: TimeInterval?
    private var poll: Timer?

    @objc public init(placementId: String, size: AdfactenBannerSize) {
        self.placementId = placementId
        self.adSize = size
        super.init(frame: CGRect(origin: .zero, size: size.size))
        commonInit()
    }

    /// Interface Builder: set `placementId` (and `adSize`) before calling `load()`.
    public required init?(coder: NSCoder) {
        self.placementId = ""
        self.adSize = .banner
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        clipsToBounds = true
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    public override var intrinsicContentSize: CGSize { adSize.size }

    /// Requests an ad. Calling it again replaces the creative with a new one.
    @objc public func load() {
        wantsAd = true
        startPolling()
        fetch()
    }

    /// Stops refreshing and removes the creative.
    @objc public func destroy() {
        wantsAd = false
        poll?.invalidate()
        poll = nil
        tracker?.stop()
        tracker = nil
        (creative as UIView?)?.removeFromSuperview()
        creative = nil
        current = nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            poll?.invalidate()
            poll = nil
            tracker?.stop()
        } else if wantsAd {
            startPolling()
            tracker?.start()
            // An unrendered ad may have expired while off screen.
            if let current, tracker?.hasRendered != true,
               current.isExpired(now: Adfacten.context?.env.clock.now() ?? Date()) {
                fetch()
            }
        }
    }

    // MARK: Loading

    private func fetch() {
        guard !loading else { return }
        guard let ctx = Adfacten.context else {
            report(AdfactenError(.notInitialized, "call Adfacten.initialize(appKey:config:) first"))
            return
        }
        loading = true
        let placement = placementId
        let size = adSize
        Task { [weak self] in
            let result = await ctx.load(placementId: placement, format: .banner, sizes: [size.token])
            guard let self else { return }
            self.loading = false
            switch result {
            case .success(let ad):
                self.retryAfterFailure = nil
                self.show(ad, context: ctx)
            case .failure(let err) where err.code == .serverRejected || err.code == .childDirected:
                // Configuration errors: a retry won't fix them, so stop until the next load().
                self.wantsAd = false
                self.retryAfterFailure = nil
                self.report(err)
            case .failure(let err):
                // Keep the current creative (if any) and try again later, but never before the
                // placement's backoff ends (a request then would fail without reaching the server).
                let wait = await ctx.backoff.remaining(placement) ?? 0
                self.scheduleRetry(minimum: wait)
                self.report(err)
            }
        }
    }

    /// Next attempt after a failure: one refresh interval of on-screen time (60 s when refresh is
    /// off), or longer while the placement backs off.
    private func scheduleRetry(minimum: TimeInterval = 0) {
        let interval = effectiveRefresh > 0 ? effectiveRefresh : 60
        retryAfterFailure = max(interval, minimum)
        visibleSinceLoad = 0
    }

    private func show(_ ad: LoadedAd, context ctx: SDKContext) {
        tracker?.stop()
        (creative as UIView?)?.removeFromSuperview()
        badge?.removeFromSuperview()

        let view: CreativeView
        if ad.payload.kind == .html {
            view = HTMLCreativeView(html: ad.payload.html ?? "")
        } else {
            view = ImageCreativeView(image: ad.payload.image, preloaded: nil, loader: ctx.images)
        }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        let b = AdBadge(text: Strings.label(ad.payload.label))
        addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            b.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        ])
        badge = b
        creative = view
        current = ad
        serverRefresh = ad.payload.refreshS
        visibleSinceLoad = 0

        let t = ViewabilityTracker(view: view, rule: ad.viewRule, isActive: ctx.env.appIsActive)
        t.onRender = { [weak self] in
            guard let self else { return }
            ctx.fire(.render, for: ad)
            self.delegate?.bannerViewDidRecordImpression?(self)
            self.onImpression?()
        }
        t.onViewable = { ctx.fire(.view, for: ad) }
        t.onVisibleTime = { [weak self] dt in self?.visibleSinceLoad += dt }
        tracker = t

        view.onReady = { [weak self, weak t] in
            t?.contentReady = true
            guard let self else { return }
            self.delegate?.bannerViewDidLoad?(self)
            self.onLoaded?()
        }
        view.onFailure = { [weak self] err in
            guard let self, self.current?.payload.id == ad.payload.id else { return }
            // The creative never rendered, so the refresh timer would not run; retry instead.
            if self.tracker?.hasRendered != true { self.scheduleRetry() }
            self.report(err)
        }
        view.onTap = { [weak self] url in self?.clicked(ad, linkURL: url, context: ctx) }
        if window != nil { t.start() }
        view.startLoading()
    }

    private func clicked(_ ad: LoadedAd, linkURL: URL?, context ctx: SDKContext) {
        guard let target = ClickTarget.resolve(clickURL: ad.clickURL, tapped: linkURL) else { return }
        let presenter = rootViewController ?? adfOwningViewController
        if ClickHandler.shared.open(target, from: presenter, session: ctx.session) {
            delegate?.bannerViewDidClick?(self)
            onClicked?()
        }
    }

    private func report(_ err: AdfactenError) {
        delegate?.bannerView?(self, didFailWithError: err)
        onFailed?(err)
    }

    // MARK: Refresh

    /// The app's setting wins, then the placement's `refresh_s` (0 = off), then 60 s.
    var effectiveRefresh: TimeInterval {
        Self.refreshInterval(app: appRefresh, server: serverRefresh)
    }

    nonisolated static func refreshInterval(app: TimeInterval?, server: TimeInterval?) -> TimeInterval {
        let base = app ?? server ?? 60
        guard base > 0, base.isFinite else { return 0 }
        return min(max(base, 30), 120)
    }

    private func startPolling() {
        guard poll == nil, window != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func refreshTick() {
        guard wantsAd, !loading, window != nil else { return }
        guard let ctx = Adfacten.context, ctx.env.appIsActive() else { return }
        // Nothing is requested while the banner is off screen (scrolled away, hidden, covered).
        let onScreen = Visibility.measure(self) > 0
        if let retry = retryAfterFailure ?? (current == nil ? 60 : nil) {
            // Waiting to retry after a failure: count on-screen time only. A rendered creative's
            // tracker already counts it.
            if onScreen && tracker?.hasRendered != true { visibleSinceLoad += 1 }
            if onScreen, visibleSinceLoad >= retry { fetch() }
            return
        }
        // Refresh only after the current creative has rendered and was on screen long enough.
        let interval = effectiveRefresh
        if interval > 0, onScreen, tracker?.hasRendered == true, visibleSinceLoad >= interval {
            fetch()
        }
    }
}

/// SwiftUI wrapper of `AdfactenBannerView`.
///
/// ```swift
/// AdfactenBanner(placementId: "plc_…", size: .banner)
/// ```
public struct AdfactenBanner: UIViewRepresentable {
    public let placementId: String
    public let size: AdfactenBannerSize
    public var onEvent: ((Event) -> Void)?

    public enum Event { case loaded, failed(Error), impression, clicked }

    public init(placementId: String, size: AdfactenBannerSize = .banner, onEvent: ((Event) -> Void)? = nil) {
        self.placementId = placementId
        self.size = size
        self.onEvent = onEvent
    }

    public func makeUIView(context: Context) -> AdfactenBannerView {
        let v = AdfactenBannerView(placementId: placementId, size: size)
        let cb = onEvent
        v.onLoaded = { cb?(.loaded) }
        v.onFailed = { cb?(.failed($0)) }
        v.onImpression = { cb?(.impression) }
        v.onClicked = { cb?(.clicked) }
        v.load()
        return v
    }

    public func updateUIView(_ uiView: AdfactenBannerView, context: Context) {
        if uiView.placementId != placementId || uiView.adSize != size {
            uiView.placementId = placementId
            uiView.adSize = size
            uiView.load()
        }
    }

    public static func dismantleUIView(_ uiView: AdfactenBannerView, coordinator: ()) {
        uiView.destroy()
    }
}
