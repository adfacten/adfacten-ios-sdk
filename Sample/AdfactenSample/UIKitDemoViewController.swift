import AdfactenAds
import SwiftUI
import UIKit

/// UIKit integration: a banner inside a scrolling table (refresh pauses when scrolled away) and an
/// interstitial driven by the delegate API.
final class UIKitDemoViewController: UITableViewController, AdfactenBannerViewDelegate, FullScreenAdDelegate {
    private let banner = AdfactenBannerView(placementId: DemoConfig.banner, size: .mediumRectangle)
    private var interstitial: InterstitialAd?
    private let bannerRow = 12

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Interstitial", style: .plain, target: self,
                                                            action: #selector(showInterstitial))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        banner.delegate = self
        banner.rootViewController = self
        banner.refreshInterval = 30
        banner.load()
    }

    @objc private func close() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 40 }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.row == bannerRow ? 270 : 44
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        cell.contentView.subviews.filter { $0 === banner }.forEach { $0.removeFromSuperview() }
        if indexPath.row == bannerRow {
            cell.textLabel?.text = nil
            banner.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(banner)
            NSLayoutConstraint.activate([
                banner.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                banner.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            ])
        } else {
            cell.textLabel?.text = "Row \(indexPath.row)"
        }
        return cell
    }

    @objc private func showInterstitial() {
        InterstitialAd.load(placementId: DemoConfig.interstitial) { [weak self] ad, error in
            guard let self else { return }
            if let error { EventLog.shared.add("uikit interstitial failed — \(error.localizedDescription)"); return }
            self.interstitial = ad
            ad?.delegate = self
            ad?.present(from: self)
        }
    }

    // MARK: AdfactenBannerViewDelegate

    func bannerViewDidLoad(_ bannerView: AdfactenBannerView) { EventLog.shared.add("uikit banner: loaded") }
    func bannerView(_ bannerView: AdfactenBannerView, didFailWithError error: Error) {
        EventLog.shared.add("uikit banner: failed — \(error.localizedDescription)")
    }
    func bannerViewDidRecordImpression(_ bannerView: AdfactenBannerView) { EventLog.shared.add("uikit banner: impression") }
    func bannerViewDidClick(_ bannerView: AdfactenBannerView) { EventLog.shared.add("uikit banner: clicked") }

    // MARK: FullScreenAdDelegate

    func adDidPresent(_ ad: FullScreenAd) { EventLog.shared.add("uikit interstitial: shown") }
    func adDidDismiss(_ ad: FullScreenAd) { EventLog.shared.add("uikit interstitial: closed") }
}

struct UIKitDemo: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UIKitDemoViewController(style: .plain))
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
