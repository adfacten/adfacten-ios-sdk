import Foundation
import UIKit
import AdSupport
import AppTrackingTransparency

/// IAB consent strings as written into `UserDefaults.standard` by the app's CMP.
struct ConsentSnapshot: Sendable, Equatable {
    var gdprApplies: Int        // 0 = no / unknown, 1 = yes
    var tcString: String
    var gppString: String
    var usPrivacy: String
    /// TCF purpose 1 ("store and/or access information on a device").
    var purpose1Consent: Bool

    static func read(from defaults: UserDefaults) -> ConsentSnapshot {
        let applies: Int
        switch defaults.object(forKey: "IABTCF_gdprApplies") {
        case let n as NSNumber: applies = n.intValue == 1 ? 1 : 0
        case let s as String: applies = s == "1" ? 1 : 0
        default: applies = 0
        }
        let tc = defaults.string(forKey: "IABTCF_TCString") ?? ""
        let purposes = defaults.string(forKey: "IABTCF_PurposeConsents") ?? ""
        return ConsentSnapshot(
            gdprApplies: applies,
            tcString: tc,
            gppString: defaults.string(forKey: "IABGPP_HDR_GppString") ?? "",
            usPrivacy: defaults.string(forKey: "IABUSPrivacy_String") ?? "",
            purpose1Consent: purposes.first == "1"
        )
    }

    /// GDPR applies and the user did not grant purpose 1: no device identifier beyond the SDK id.
    var forbidsDeviceIdentifiers: Bool { gdprApplies == 1 && !purpose1Consent }

    /// The server ignores the IDFA under GDPR, with a GPP string, or with a US-privacy opt-out
    /// (3rd char `Y`), so it is not sent in those cases.
    var forbidsIDFA: Bool {
        if gdprApplies == 1 || !gppString.isEmpty { return true }
        let chars = Array(usPrivacy.uppercased())
        return chars.count >= 3 && chars[2] == "Y"
    }
}

/// ATT status as the SDK sees it. The SDK never requests ATT; the app does.
enum TrackingStatus: Sendable, Equatable {
    case authorized, denied, restricted, notDetermined
}

protocol IdentitySource: Sendable {
    func trackingStatus() -> TrackingStatus
    func advertisingIdentifier() -> String?
    @MainActor func vendorIdentifier() -> String?
}

struct SystemIdentitySource: IdentitySource {
    func trackingStatus() -> TrackingStatus {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func advertisingIdentifier() -> String? {
        ASIdentifierManager.shared().advertisingIdentifier.uuidString
    }

    @MainActor func vendorIdentifier() -> String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
}

struct ResolvedIdentity: Sendable, Equatable {
    var ifa: String?
    var ifaType: String
    var lmt: Bool
}

enum IdentityResolver {
    static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    /// Preference: IDFA (authorized, non-zero) → IDFV → SDK install id.
    /// Child-directed apps and GDPR without purpose-1 consent never send IDFA/IDFV.
    static func resolve(status: TrackingStatus, idfa: String?, idfv: String?, sdkId: String,
                        childDirected: Bool, consent: ConsentSnapshot) -> ResolvedIdentity {
        let limited = status != .authorized
        if childDirected || consent.forbidsDeviceIdentifiers {
            return ResolvedIdentity(ifa: sdkId, ifaType: "sdk", lmt: true)
        }
        if !limited, !consent.forbidsIDFA, let idfa, !idfa.isEmpty, idfa != zeroUUID {
            return ResolvedIdentity(ifa: idfa, ifaType: "idfa", lmt: false)
        }
        if let idfv, !idfv.isEmpty, idfv != zeroUUID {
            return ResolvedIdentity(ifa: idfv, ifaType: "idfv", lmt: limited)
        }
        return ResolvedIdentity(ifa: sdkId, ifaType: "sdk", lmt: limited)
    }
}

/// Per-install random id, kept in the app's own UserDefaults (removed with the app, not shared).
enum InstallID {
    static let key = "com.adfacten.ads.sdk_id"

    static func get(_ defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return id
    }
}
