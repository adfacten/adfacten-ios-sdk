import Foundation
import Network
import UIKit

/// Device/app facts captured on the main thread right before an ad request.
struct DeviceSnapshot: Sendable, Equatable {
    var osVersion: String
    var model: String
    var language: String
    var widthPx: Int
    var heightPx: Int
    var scale: Double
    var connection: String
    var tzOffsetMin: Int
    var bundleId: String
    var appVersion: String

    @MainActor
    static func capture(connection: String) -> DeviceSnapshot {
        let screen = UIScreen.main
        let native = screen.nativeBounds.size
        let info = Bundle.main.infoDictionary ?? [:]
        let lang = (Locale.preferredLanguages.first ?? "en")
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return DeviceSnapshot(
            osVersion: UIDevice.current.systemVersion,
            model: hardwareModel(),
            language: lang.lowercased(),
            widthPx: Int(native.width.rounded()),
            heightPx: Int(native.height.rounded()),
            scale: Double(screen.nativeScale),
            connection: connection,
            tzOffsetMin: TimeZone.current.secondsFromGMT() / 60,
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: (info["CFBundleShortVersionString"] as? String) ?? "0"
        )
    }

    /// `iPhone16,1` on devices. On the simulator we report "Simulator" so the server applies its
    /// emulator rule (test ads only).
    static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "iPhone" : machine
        #endif
    }
}

enum UserAgent {
    /// `AdfactenSDK/<sdk_version> (ios <osv>; <model>) <bundle>/<app_version>`
    /// A wrapper (Flutter, React Native, …) adds ` Wrapper/<name>-<version>`.
    static func make(sdkVersion: String, device: DeviceSnapshot, wrapper: WrapperInfo? = nil) -> String {
        "AdfactenSDK/\(sdkVersion) (ios \(device.osVersion); \(sanitize(device.model))) "
            + "\(sanitize(device.bundleId))/\(sanitize(device.appVersion))"
            + (wrapper?.userAgentSuffix ?? "")
    }

    private static func sanitize(_ s: String) -> String {
        let cleaned = s.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0 != "(" && $0 != ")" && $0 != ";" }
        let out = String(String.UnicodeScalarView(cleaned)).replacingOccurrences(of: " ", with: "_")
        return out.isEmpty ? "unknown" : out
    }
}

/// Current connection type via NWPathMonitor (no permission needed).
final class ConnectionMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let state = Locked<String>("unknown")
    private let queue = DispatchQueue(label: "com.adfacten.ads.path")
    var onBecameReachable: (@Sendable () -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type: String
            if path.status != .satisfied {
                type = "unknown"
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else {
                type = "unknown"
            }
            let wasOffline = self.state.get() == "unknown"
            self.state.set(type)
            if path.status == .satisfied, wasOffline { self.onBecameReachable?() }
        }
        monitor.start(queue: queue)
    }

    var current: String { state.get() }
}
