import UIKit

/// Native ad events. Always called on the main thread.
@objc(ADFNativeAdDelegate)
@MainActor
public protocol NativeAdDelegate: AnyObject {
    /// The ad's view is on screen (the billable impression).
    @objc optional func nativeAdDidRecordImpression(_ nativeAd: NativeAd)
    @objc optional func nativeAdDidClick(_ nativeAd: NativeAd)
}

/// A native ad: assets you lay out yourself inside a `NativeAdView`.
@objc(ADFNativeAd)
@MainActor
public final class NativeAd: NSObject {
    @objc public let placementId: String
    @objc public weak var delegate: NativeAdDelegate?
    public var onImpression: (() -> Void)?
    public var onClicked: (() -> Void)?

    @objc public var title: String? { loaded.payload.native?.title.nonEmpty }
    @objc public var body: String? { loaded.payload.native?.body.nonEmpty }
    @objc public var brand: String? { loaded.payload.native?.brand.nonEmpty }
    @objc public var callToAction: String? { loaded.payload.native?.cta.nonEmpty }
    /// The disclosure label to display (e.g. "Reklam"). Always show it.
    @objc public var adLabel: String { Strings.label(loaded.payload.label) }
    @objc public var imageURL: URL? { loaded.payload.native?.image?.url.flatMap(URL.init(string:)) }
    @objc public var iconURL: URL? { loaded.payload.native?.icon?.url.flatMap(URL.init(string:)) }
    /// Main image size (pixels) as sent by the server, when known.
    @objc public var imageSize: CGSize {
        CGSize(width: loaded.payload.native?.image?.w ?? 0, height: loaded.payload.native?.image?.h ?? 0)
    }
    /// Pre-downloaded images (nil if the download failed).
    @objc public private(set) var image: UIImage?
    @objc public private(set) var icon: UIImage?
    @objc public var expirationDate: Date { loaded.expiresAt }

    let loaded: LoadedAd
    let context: SDKContext
    /// The view showing this ad. An ad lives in one view at a time.
    weak var boundView: NativeAdView?
    /// Impression state is kept on the ad, not the view, so re-binding never counts twice.
    var impressionRecorded = false
    var viewableRecorded = false

    init(loaded: LoadedAd, context: SDKContext, image: UIImage?, icon: UIImage?) {
        self.placementId = loaded.placementId
        self.loaded = loaded
        self.context = context
        self.image = image
        self.icon = icon
        super.init()
    }

    /// Loads a native ad (images are downloaded before the completion runs).
    @objc(loadWithPlacementId:completion:)
    public static func load(placementId: String, completion: @escaping @MainActor (NativeAd?, Error?) -> Void) {
        Task { @MainActor in
            do { completion(try await load(placementId: placementId), nil) } catch { completion(nil, error) }
        }
    }

    public static func load(placementId: String) async throws -> NativeAd {
        guard let ctx = Adfacten.context else {
            throw AdfactenError(.notInitialized, "call Adfacten.initialize(appKey:config:) first")
        }
        switch await ctx.load(placementId: placementId, format: .native, sizes: []) {
        case .failure(let e): throw e
        case .success(let ad):
            let scale = UIScreen.main.scale
            async let img = ctx.images.load(ad.payload.native?.image, scale: scale)
            async let ico = ctx.images.load(ad.payload.native?.icon, scale: scale)
            let (i, c) = await (img, ico)
            return NativeAd(loaded: ad, context: ctx, image: i, icon: c)
        }
    }
}

/// Container for a native ad. Connect the outlets (in code or Interface Builder), then set `nativeAd`.
/// The view fills the outlets, adds an "Ad" badge if you have no `adLabel`, and records the
/// impression, the viewable impression and clicks (taps anywhere on the view or the CTA).
/// An ad is shown in one view at a time: binding it to another view detaches it from the first.
/// Each ad records one impression, however often it is bound.
@objc(ADFNativeAdView)
@MainActor
open class NativeAdView: UIView {
    @IBOutlet public weak var titleLabel: UILabel?
    @IBOutlet public weak var bodyLabel: UILabel?
    @IBOutlet public weak var brandLabel: UILabel?
    @IBOutlet public weak var callToActionButton: UIButton?
    @IBOutlet public weak var mediaView: UIImageView?
    @IBOutlet public weak var iconView: UIImageView?
    @IBOutlet public weak var adLabel: UILabel?

    private var tracker: ViewabilityTracker?
    private var autoBadge: AdBadge?
    private var tap: UITapGestureRecognizer?

    /// Binding a native ad starts tracking; set nil to unbind (e.g. on cell reuse).
    @objc open var nativeAd: NativeAd? {
        didSet {
            guard oldValue !== nativeAd else { return }
            unbind(oldValue)
            if let nativeAd { bind(nativeAd) }
        }
    }

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { tracker?.stop() } else { tracker?.start() }
    }

    private func bind(_ ad: NativeAd) {
        if let previous = ad.boundView, previous !== self { previous.detach() }
        ad.boundView = self
        titleLabel?.text = ad.title
        bodyLabel?.text = ad.body
        brandLabel?.text = ad.brand
        if let cta = callToActionButton {
            cta.setTitle(ad.callToAction, for: .normal)
            cta.isHidden = ad.callToAction == nil
            cta.addTarget(self, action: #selector(clicked), for: .touchUpInside)
        }
        mediaView?.image = ad.image
        iconView?.image = ad.icon
        if let label = adLabel {
            label.text = ad.adLabel
            label.isHidden = false
        } else {
            let b = AdBadge(text: ad.adLabel)
            addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                b.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            ])
            autoBadge = b
        }
        let g = UITapGestureRecognizer(target: self, action: #selector(clicked))
        g.cancelsTouchesInView = false
        addGestureRecognizer(g)
        tap = g

        let ctx = ad.context
        let loaded = ad.loaded
        let t = ViewabilityTracker(view: self, rule: loaded.viewRule, isActive: ctx.env.appIsActive)
        t.contentReady = true
        t.onRender = { [weak ad] in
            guard let ad, !ad.impressionRecorded else { return }
            ad.impressionRecorded = true
            ctx.fire(.render, for: loaded)
            ad.delegate?.nativeAdDidRecordImpression?(ad)
            ad.onImpression?()
        }
        t.onViewable = { [weak ad] in
            guard let ad, !ad.viewableRecorded else { return }
            ad.viewableRecorded = true
            ctx.fire(.view, for: loaded)
        }
        tracker = t
        if window != nil { t.start() }
    }

    /// The ad moved to another view: stop tracking here and clear what `bind` filled in, so this
    /// view doesn't keep showing an ad it no longer counts.
    private func detach() {
        nativeAd = nil
        titleLabel?.text = nil
        bodyLabel?.text = nil
        brandLabel?.text = nil
        callToActionButton?.setTitle(nil, for: .normal)
        mediaView?.image = nil
        iconView?.image = nil
        adLabel?.text = nil
    }

    private func unbind(_ ad: NativeAd?) {
        if let ad, ad.boundView === self { ad.boundView = nil }
        tracker?.stop()
        tracker = nil
        autoBadge?.removeFromSuperview()
        autoBadge = nil
        if let tap { removeGestureRecognizer(tap) }
        tap = nil
        callToActionButton?.removeTarget(self, action: #selector(clicked), for: .touchUpInside)
    }

    @objc private func clicked() {
        guard let ad = nativeAd, let url = ad.loaded.clickURL else { return }
        let presenter = adfOwningViewController
        if ClickHandler.shared.open(url, from: presenter, session: ad.context.session) {
            ad.delegate?.nativeAdDidClick?(ad)
            ad.onClicked?()
        }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
