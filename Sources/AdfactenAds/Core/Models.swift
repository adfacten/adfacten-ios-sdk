import Foundation

/// Ad formats of the `/m/v1` API. Values this SDK version doesn't know decode as `.unknown`.
enum AdFormat: String, Codable, Sendable {
    case banner, interstitial, rewarded, native
    case appOpen = "app_open"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AdFormat(rawValue: raw) ?? .unknown
    }
}

// MARK: - Request

struct AdRequest: Encodable, Sendable, Equatable {
    var v: Int = 1
    var appKey: String
    var placement: String
    var format: AdFormat
    var sizes: [String]
    var device: Device
    var app: App
    var regs: Regs
    var user: User?
    var test: Bool

    struct Device: Encodable, Sendable, Equatable {
        var os: String = "ios"
        var osv: String
        var make: String = "Apple"
        var model: String
        var ifa: String?
        var ifaType: String
        var lmt: Bool
        var sdkId: String
        var lang: String
        var w: Int
        var h: Int
        var pxratio: Double
        var connection: String
        var carrier: String = ""
        var tzOffsetMin: Int
    }

    struct App: Encodable, Sendable, Equatable {
        var bundle: String
        var version: String
        var sdkVersion: String
    }

    struct Regs: Encodable, Sendable, Equatable {
        var coppa: Bool
        var gdpr: Int
        var tcf: String
        var gpp: String
        var usPrivacy: String
    }

    struct User: Encodable, Sendable, Equatable {
        var id: String?
        var custom: String?
    }

    enum CodingKeys: String, CodingKey {
        case v, appKey, placement, format, sizes, device, app, regs, user, test
    }

    static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        return enc
    }
}

// MARK: - Response

struct AdEnvelope: Decodable, Sendable {
    var ad: AdPayload
}

struct AdPayload: Decodable, Sendable, Equatable {
    var id: String
    var format: AdFormat
    var kind: Kind
    var w: Int?
    var h: Int?
    var image: Image?
    var html: String?
    var vast: String?
    var native: Native?
    var clickUrl: String?
    var trackers: Trackers
    var viewRule: ViewRule?
    var closeAfterS: Double?
    var reward: Reward?
    var label: String?
    var expiresAt: Double?
    /// Optional, additive: banner refresh seconds from the placement setting.
    var refreshS: Double?
    /// True for test ads (never billed).
    var test: Bool?

    enum CodingKeys: String, CodingKey {
        case id, format, kind, w, h, image, html, vast, native, trackers, reward, label, test
        case clickUrl = "click_url"
        case viewRule = "view_rule"
        case closeAfterS = "close_after_s"
        case expiresAt = "expires_at"
        case refreshS = "refresh_s"
    }

    enum Kind: String, Decodable, Sendable {
        case image, html, video, native, unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    struct Image: Decodable, Sendable, Equatable {
        var url: String?
        var url2x: String?
        var fallback: String?
        var w: Int?
        var h: Int?

        enum CodingKeys: String, CodingKey {
            case url, fallback, w, h
            case url2x = "url_2x"
        }
    }

    struct Native: Decodable, Sendable, Equatable {
        var title: String?
        var body: String?
        var brand: String?
        var cta: String?
        var image: Image?
        var icon: Image?
    }

    struct Trackers: Decodable, Sendable, Equatable {
        var render: String?
        var view: String?
        var complete: String?
        var close: String?
    }

    struct ViewRule: Decodable, Sendable, Equatable {
        var minRatio: Double
        var minMs: Double

        enum CodingKeys: String, CodingKey {
            case minRatio = "min_ratio"
            case minMs = "min_ms"
        }
        static let display = ViewRule(minRatio: 0.5, minMs: 1000)
        static let video = ViewRule(minRatio: 0.5, minMs: 2000)
    }

    struct Reward: Decodable, Sendable, Equatable {
        var type: String
        var amount: Double
    }

    static func decoder() -> JSONDecoder { JSONDecoder() }
}

struct ServerErrorBody: Decodable, Sendable {
    var code: String?
    var message: String?
}

/// A decoded ad plus everything the SDK derived from it at load time.
struct LoadedAd: Sendable {
    let payload: AdPayload
    let vast: VASTAd?
    /// Local (device clock) expiry, corrected for clock skew using the HTTP `Date` header.
    let expiresAt: Date
    let placementId: String

    func isExpired(now: Date) -> Bool { now >= expiresAt }

    var viewRule: AdPayload.ViewRule {
        if let r = payload.viewRule, r.minRatio > 0, r.minMs >= 0 { return r }
        return payload.kind == .video ? .video : .display
    }

    var clickURL: URL? { payload.clickUrl.flatMap(URL.init(string:)) }
}
