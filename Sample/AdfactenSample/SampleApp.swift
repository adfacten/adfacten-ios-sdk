import AdfactenAds
import SwiftUI
import UIKit

/// Sample settings. The defaults are Adfacten's public sample app: it always receives test ads, which are
/// never billed. To try your own app, use the app key and placement ids from the Adfacten panel
/// (Apps › your app), or pass them as environment variables (simulator: `SIMCTL_CHILD_ADF_*`).
enum DemoConfig {
    static let env = ProcessInfo.processInfo.environment
    static var appKey: String { env["ADF_APP_KEY"] ?? "apk_r2FjVF7YUGb3ITZZUt6ENHH1" }
    static var server: URL? { env["ADF_SERVER"].flatMap(URL.init(string:)) }
    static var banner: String { env["ADF_PLC_BANNER"] ?? "plc_034uZ7K268zGmUPhbl0LgL" }
    static var interstitial: String { env["ADF_PLC_INTERSTITIAL"] ?? "plc_034uZ7K26J5FvjnFBJjThJ" }
    static var rewarded: String { env["ADF_PLC_REWARDED"] ?? "plc_034uZ7K2CBEP9L6EQszuIk" }
    static var native: String { env["ADF_PLC_NATIVE"] ?? "plc_034uZ7K2I1fWOEzDnkJpwt" }
    static var appOpen: String { env["ADF_PLC_APP_OPEN"] ?? "plc_034uZ7K2IBiNmiy9FGrHNe" }
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
