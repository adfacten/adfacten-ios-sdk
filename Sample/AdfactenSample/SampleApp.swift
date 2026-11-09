import AdfactenAds
import SwiftUI
import UIKit

/// Sample settings. Replace the placeholders with the app key and placement ids from your Adfacten
/// panel (Apps › your app), or pass them as environment variables (simulator: `SIMCTL_CHILD_ADF_*`).
/// A new app stays in test mode until it is reviewed, so it only receives test ads.
enum DemoConfig {
    static let env = ProcessInfo.processInfo.environment
    static var appKey: String { env["ADF_APP_KEY"] ?? "apk_YOUR_APP_KEY" }
    static var server: URL? { env["ADF_SERVER"].flatMap(URL.init(string:)) }
    static var banner: String { env["ADF_PLC_BANNER"] ?? "plc_YOUR_BANNER" }
    static var interstitial: String { env["ADF_PLC_INTERSTITIAL"] ?? "plc_YOUR_INTERSTITIAL" }
    static var rewarded: String { env["ADF_PLC_REWARDED"] ?? "plc_YOUR_REWARDED" }
    static var native: String { env["ADF_PLC_NATIVE"] ?? "plc_YOUR_NATIVE" }
    static var appOpen: String { env["ADF_PLC_APP_OPEN"] ?? "plc_YOUR_APP_OPEN" }
    /// "interstitial", "rewarded", "app_open" — loads and shows that format automatically.
    static var autoDemo: String? { env["ADF_AUTODEMO"] }
}

@main
struct AdfactenSampleApp: App {
    @StateObject private var log = EventLog.shared

    init() {
        let config = AdfactenConfig(testMode: true, logLevel: .debug, userId: "demo-user-1")
        if let server = DemoConfig.server { config.serverURL = server }
        Adfacten.initialize(appKey: DemoConfig.appKey, config: config)
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(log)
        }
    }
}

/// On-screen event log (also printed to the console with the "DEMO" prefix).
@MainActor
final class EventLog: ObservableObject {
    static let shared = EventLog()
    @Published private(set) var lines: [String] = []

    func add(_ s: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.insert("\(ts)  \(s)", at: 0)
        if lines.count > 60 { lines.removeLast() }
        print("DEMO \(s)")
    }
}

extension UIApplication {
    /// The top-most view controller, for presenting full-screen ads from SwiftUI.
    @MainActor static var topViewController: UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
