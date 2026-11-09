import StoreKit
import UIKit

/// Opens ad clicks outside the app.
///
/// The tracker's `click_url` is requested once without following the redirect. A direct App Store
/// destination opens in an in-app `SKStoreProductViewController`; anything else (landing pages,
/// MMP links) opens with `UIApplication.open`. If the tracker can't be reached quickly, the click URL
/// itself is opened in the system browser. Never an in-app WebView.
@MainActor
final class ClickHandler: NSObject {
    static let shared = ClickHandler()

    private var lastClick: CFTimeInterval = 0
    private var storeController: SKStoreProductViewController?
    private var resolver: URLSession?

    /// Returns false when the click was ignored (double tap within 1 s).
    @discardableResult
    func open(_ url: URL, from presenter: UIViewController?, session: URLSession?) -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastClick > 1.0 else { return false }
        lastClick = now

        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            openExternally(url)
            return true
        }
        if let id = Self.appStoreID(from: url), let presenter {
            presentStore(id: id, fallback: url, from: presenter)
            return true
        }
        resolveRedirect(url) { [weak self] location in
            guard let self else { return }
            guard let location else { self.openExternally(url); return }
            if let id = Self.appStoreID(from: location), let presenter, presenter.view.window != nil {
                self.presentStore(id: id, fallback: location, from: presenter)
            } else {
                self.openExternally(location)
            }
        }
        return true
    }

    /// `https://apps.apple.com/tr/app/name/id123456789` → "123456789".
    nonisolated static func appStoreID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "apps.apple.com" || host == "itunes.apple.com" else { return nil }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let q = comps.queryItems?.first(where: { $0.name == "id" })?.value, q.allSatisfy(\.isNumber), !q.isEmpty {
            return q
        }
        for part in url.pathComponents.reversed() where part.hasPrefix("id") {
            let digits = part.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(digits) }
        }
        return nil
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { Log.warning("could not open click destination \(url.absoluteString)") }
        }
    }

    private func presentStore(id: String, fallback: URL, from presenter: UIViewController) {
        let top = Self.topmost(from: presenter)
        let store = SKStoreProductViewController()
        store.delegate = self
        storeController = store
        top.present(store, animated: true)
        store.loadProduct(withParameters: [SKStoreProductParameterITunesItemIdentifier: id]) { [weak self] ok, _ in
            guard !ok else { return }
            Task { @MainActor in
                store.dismiss(animated: true)
                self?.storeController = nil
                self?.openExternally(fallback)
            }
        }
    }

    private func resolveRedirect(_ url: URL, completion: @escaping @MainActor (URL?) -> Void) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 4
        cfg.httpShouldSetCookies = false
        if let ua = Adfacten.context?.session.configuration.httpAdditionalHeaders {
            cfg.httpAdditionalHeaders = ua
        }
        let s = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        resolver = s
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        s.dataTask(with: req) { _, response, _ in
            var location: URL?
            if let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location") {
                location = URL(string: loc, relativeTo: url)?.absoluteURL
            }
            let reached = response != nil
            Task { @MainActor in
                // Reached the tracker but no redirect: the click is counted; nothing else to open.
                if location == nil && reached {
                    Log.warning("click URL returned no redirect")
                    completion(url)
                } else {
                    completion(location)
                }
            }
            s.finishTasksAndInvalidate()
        }.resume()
    }

    static func topmost(from vc: UIViewController) -> UIViewController {
        var top = vc
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        return top
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

extension ClickHandler: SKStoreProductViewControllerDelegate {
    nonisolated func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.storeController = nil
        }
    }
}

enum ClickTarget {
    /// The tracked `click_url` wins, so every click is counted. A link inside an HTML creative that
    /// already points at the tracker (same host as `click_url`) is used as is.
    static func resolve(clickURL: URL?, tapped: URL?) -> URL? {
        if let tapped, let click = clickURL, tapped.host?.lowercased() == click.host?.lowercased() { return tapped }
        return clickURL ?? tapped
    }
}

extension UIView {
    /// The view controller that owns this view, for presenting the store sheet.
    var adfOwningViewController: UIViewController? {
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc }
            r = next
        }
        return window?.rootViewController
    }
}
