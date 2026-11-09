import UIKit
import WebKit

/// Common surface of the image / HTML / video creative views.
@MainActor
protocol CreativeView: UIView {
    /// Called once the creative has actually drawn.
    var onReady: (() -> Void)? { get set }
    var onFailure: ((AdfactenError) -> Void)? { get set }
    /// The user tapped the creative (or a link in it). `URL` is the link target for HTML, nil otherwise.
    var onTap: ((URL?) -> Void)? { get set }
    func startLoading()
}

/// Static image creative.
@MainActor
final class ImageCreativeView: UIView, CreativeView {
    var onReady: (() -> Void)?
    var onFailure: ((AdfactenError) -> Void)?
    var onTap: ((URL?) -> Void)?

    private let imageView = UIImageView()
    private let image: AdPayload.Image?
    private var preloaded: UIImage?
    private let loader: ImageLoader?

    init(image: AdPayload.Image?, preloaded: UIImage?, loader: ImageLoader?) {
        self.image = image
        self.preloaded = preloaded
        self.loader = loader
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = [.image, .link]
        imageView.accessibilityLabel = Strings.advertisement
        addSubview(imageView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tapped() { onTap?(nil) }

    func startLoading() {
        if let preloaded {
            show(preloaded)
            return
        }
        guard let loader else { onFailure?(AdfactenError(.creativeFailed, "no image loader")); return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let image = self.image
        Task { [weak self] in
            let img = await loader.load(image, scale: scale)
            guard let self else { return }
            if let img { self.show(img) } else {
                self.onFailure?(AdfactenError(.creativeFailed, "the creative image could not be loaded"))
            }
        }
    }

    private func show(_ img: UIImage) {
        imageView.image = img
        onReady?()
    }
}

/// HTML5 creative in a WKWebView: JavaScript allowed, no message handlers, no persistent storage,
/// and every user-initiated navigation leaves the app.
@MainActor
final class HTMLCreativeView: UIView, CreativeView, WKNavigationDelegate, WKUIDelegate {
    var onReady: (() -> Void)?
    var onFailure: ((AdfactenError) -> Void)?
    var onTap: ((URL?) -> Void)?

    private let html: String
    private var webView: WKWebView?
    private var loaded = false

    init(html: String) {
        self.html = html
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func startLoading() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = .audio
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // Fit the creative to the slot even if it has no viewport tag.
        let viewport = """
        (function(){if(!document.querySelector('meta[name=viewport]')){var m=document.createElement('meta');\
        m.name='viewport';m.content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no';\
        (document.head||document.documentElement).appendChild(m);}})();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: viewport, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let wv = WKWebView(frame: bounds, configuration: cfg)
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.isOpaque = false
        wv.backgroundColor = .clear
        if #available(iOS 16.4, *) { wv.isInspectable = false }
        addSubview(wv)
        webView = wv
        wv.loadHTMLString(html, baseURL: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if !loaded || !isMainFrame {
            // The initial document and its sub-frames load normally.
            if let url = action.request.url, action.navigationType == .linkActivated {
                decisionHandler(.cancel)
                onTap?(url)
                return
            }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // Only user taps leave the app; script-driven redirects (auto-redirect ads) are blocked.
        if action.navigationType == .linkActivated, let url = action.request.url {
            onTap?(url)
        } else {
            Log.warning("blocked a non-user navigation from an HTML creative")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loaded else { return }
        loaded = true
        onReady?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !loaded { onFailure?(AdfactenError(.creativeFailed, "HTML creative failed: \(error.localizedDescription)")) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !loaded { onFailure?(AdfactenError(.creativeFailed, "HTML creative failed: \(error.localizedDescription)")) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: WKUIDelegate — window.open / target=_blank

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let url = action.request.url { onTap?(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        completionHandler() // ads may not show alerts
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        completionHandler(nil)
    }
}

/// The small "Reklam / Ad" disclosure badge shown on every creative.
@MainActor
final class AdBadge: UILabel {
    init(text: String) {
        super.init(frame: .zero)
        self.text = " \(text) "
        font = .systemFont(ofSize: 10, weight: .semibold)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 3
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }
}

enum Strings {
    static var isTurkish: Bool { (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("tr") }
    static var advertisement: String { isTurkish ? "Reklam" : "Ad" }
    static var close: String { isTurkish ? "Kapat" : "Close" }
    static var mute: String { isTurkish ? "Sesi kapat" : "Mute" }
    static var unmute: String { isTurkish ? "Sesi aç" : "Unmute" }
    static var skipTitle: String { isTurkish ? "Ödülü kaybedeceksiniz" : "You will lose your reward" }
    static var skipMessage: String { isTurkish ? "Videoyu şimdi kapatırsanız ödül verilmez." : "If you close the video now, you won't get the reward." }
    static var keepWatching: String { isTurkish ? "İzlemeye devam et" : "Keep watching" }
    static var closeAnyway: String { isTurkish ? "Yine de kapat" : "Close anyway" }

    /// The server label ("Reklam") wins; otherwise a localized default.
    static func label(_ server: String?) -> String {
        if let s = server?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return String(s.prefix(20)) }
        return advertisement
    }
}
