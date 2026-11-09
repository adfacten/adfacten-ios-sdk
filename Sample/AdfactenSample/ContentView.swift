import AdfactenAds
import SwiftUI
import UIKit

/// SwiftUI demo of every format.
struct ContentView: View {
    @EnvironmentObject var log: EventLog
    @StateObject private var ads = FullScreenDemo()
    @State private var showUIKit = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Banner 320×50 (SwiftUI)")) {
                    AdfactenBanner(placementId: DemoConfig.banner, size: .banner) { event in
                        EventLog.shared.add("banner: \(event)")
                    }
                    .frame(width: 320, height: 50)
                    .frame(maxWidth: .infinity)
                }

                Section(header: Text("Interstitial")) {
                    Button("Load") { ads.loadInterstitial() }
                    Button("Show") { ads.showInterstitial() }.disabled(!ads.interstitialReady)
                }

                Section(header: Text("Rewarded — coins: \(ads.coins)")) {
                    Button("Load") { ads.loadRewarded() }
                    Button("Show") { ads.showRewarded() }.disabled(!ads.rewardedReady)
                }

                Section(header: Text("App open")) {
                    Button("Load") { ads.loadAppOpen() }
                    Button("Show") { ads.showAppOpen() }.disabled(!ads.appOpenReady)
                }

                Section(header: Text("Native (NativeAdView)")) {
                    NativeAdCard(placementId: DemoConfig.native).frame(height: 300)
                }

                Section(header: Text("UIKit")) {
                    Button("UIKit demo (banner in a table, Objective-C style API)") { showUIKit = true }
                }

                Section(header: Text("Events")) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationBarTitle("Adfacten Ads \(Adfacten.sdkVersion)", displayMode: .inline)
            .sheet(isPresented: $showUIKit) { UIKitDemo().ignoresSafeArea() }
        }
        .navigationViewStyle(.stack)
        .onAppear { ads.autoDemoIfRequested() }
    }
}

/// Full-screen formats driven from SwiftUI.
@MainActor
final class FullScreenDemo: NSObject, ObservableObject, FullScreenAdDelegate {
    @Published var interstitialReady = false
    @Published var rewardedReady = false
    @Published var appOpenReady = false
    @Published var coins = 0

    private var interstitial: InterstitialAd?
    private var rewarded: RewardedAd?
    private var appOpen: AppOpenAd?
    private var autoStarted = false

    func loadInterstitial(thenShow: Bool = false) {
        EventLog.shared.add("interstitial: loading")
        InterstitialAd.load(placementId: DemoConfig.interstitial) { [weak self] ad, error in
            guard let self else { return }
            if let error { EventLog.shared.add("interstitial: failed — \(error.localizedDescription)"); return }
            ad?.delegate = self
            self.interstitial = ad
            self.interstitialReady = true
            EventLog.shared.add("interstitial: loaded")
            if thenShow { self.showInterstitial() }
        }
    }

    func showInterstitial() {
        guard let ad = interstitial, let vc = UIApplication.topViewController else { return }
        interstitialReady = false
        ad.present(from: vc)
    }

    func loadRewarded(thenShow: Bool = false) {
        EventLog.shared.add("rewarded: loading")
        Task {
            do {
                let ad = try await RewardedAd.load(placementId: DemoConfig.rewarded, customData: "level=3")
                ad.delegate = self
                rewarded = ad
                rewardedReady = true
                EventLog.shared.add("rewarded: loaded, reward \(ad.reward?.description ?? "-")")
                if thenShow { showRewarded() }
            } catch {
                EventLog.shared.add("rewarded: failed — \(error.localizedDescription)")
            }
        }
    }

    func showRewarded() {
        guard let ad = rewarded, let vc = UIApplication.topViewController else { return }
        rewardedReady = false
        ad.present(from: vc) { [weak self] reward in
            // UI only. Credit the user from the server-side reward callback.
            self?.coins += Int(reward.amount)
            EventLog.shared.add("rewarded: user earned \(reward)")
        }
    }

    func loadAppOpen(thenShow: Bool = false) {
        EventLog.shared.add("app open: loading")
        AppOpenAd.load(placementId: DemoConfig.appOpen) { [weak self] ad, error in
            guard let self else { return }
            if let error { EventLog.shared.add("app open: failed — \(error.localizedDescription)"); return }
            ad?.delegate = self
            self.appOpen = ad
            self.appOpenReady = true
            EventLog.shared.add("app open: loaded")
            if thenShow { self.showAppOpen() }
        }
    }

    func showAppOpen() {
        guard let ad = appOpen else { return }
        appOpenReady = false
        ad.present()
    }

    func autoDemoIfRequested() {
        guard !autoStarted, let mode = DemoConfig.autoDemo else { return }
        autoStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            switch mode {
            case "rewarded": self.loadRewarded(thenShow: true)
            case "app_open": self.loadAppOpen(thenShow: true)
            default: self.loadInterstitial(thenShow: true)
            }
        }
    }

    // MARK: FullScreenAdDelegate

    func adDidPresent(_ ad: FullScreenAd) { EventLog.shared.add("\(ad.placementId): shown") }
    func adDidClick(_ ad: FullScreenAd) { EventLog.shared.add("\(ad.placementId): clicked") }
    func adDidDismiss(_ ad: FullScreenAd) { EventLog.shared.add("\(ad.placementId): closed") }
    func ad(_ ad: FullScreenAd, didFailToPresentWithError error: Error) {
        EventLog.shared.add("\(ad.placementId): present failed — \(error.localizedDescription)")
    }
}

/// A native ad laid out in UIKit, wrapped for SwiftUI.
struct NativeAdCard: UIViewRepresentable {
    let placementId: String

    func makeUIView(context: Context) -> DemoNativeAdView {
        let v = DemoNativeAdView()
        NativeAd.load(placementId: placementId) { ad, error in
            if let error { EventLog.shared.add("native: failed — \(error.localizedDescription)"); return }
            ad?.onImpression = { EventLog.shared.add("native: impression") }
            ad?.onClicked = { EventLog.shared.add("native: clicked") }
            v.nativeAd = ad
            EventLog.shared.add("native: loaded")
        }
        return v
    }

    func updateUIView(_ uiView: DemoNativeAdView, context: Context) {}
}

/// Example native layout: icon + brand, title, media, body, CTA, ad label.
final class DemoNativeAdView: NativeAdView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let icon = UIImageView(), brand = UILabel(), label = UILabel(), title = UILabel(), body = UILabel()
        let media = UIImageView(), cta = UIButton(type: .system)
        icon.layer.cornerRadius = 6
        icon.clipsToBounds = true
        brand.font = .preferredFont(forTextStyle: .caption1)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabel
        title.font = .preferredFont(forTextStyle: .headline)
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.numberOfLines = 2
        media.contentMode = .scaleAspectFill
        media.clipsToBounds = true
        cta.titleLabel?.font = .boldSystemFont(ofSize: 15)

        let header = UIStackView(arrangedSubviews: [icon, brand, UIView(), label])
        header.spacing = 8
        header.alignment = .center
        let stack = UIStackView(arrangedSubviews: [header, title, media, body, cta])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            media.heightAnchor.constraint(equalTo: media.widthAnchor, multiplier: 628.0 / 1200.0),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
        iconView = icon
        brandLabel = brand
        adLabel = label
        titleLabel = title
        bodyLabel = body
        mediaView = media
        callToActionButton = cta
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
}
