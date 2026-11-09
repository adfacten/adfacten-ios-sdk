import Foundation

/// Error codes reported by the SDK. Objective-C sees them as `NSError` in the `AdfactenErrorDomain` domain.
@objc(ADFErrorCode)
public enum AdfactenErrorCode: Int, Sendable {
    /// `Adfacten.initialize(appKey:config:)` was not called (or the app key is malformed).
    case notInitialized = 1
    /// No ad is available right now (HTTP 204), or the placement is backing off after a no-fill.
    case noFill = 2
    /// Network failure or timeout.
    case network = 3
    /// The server rejected the request (400/403). See `serverCode`.
    case serverRejected = 4
    /// The server sent a response the SDK could not use.
    case invalidResponse = 5
    /// The ad expired before it was shown. Load a new one.
    case expired = 6
    /// The ad is not ready, or was already shown (full-screen ads are single use).
    case notReady = 7
    /// The ad could not be presented (no view controller in a window, or another ad is on screen).
    case presentationFailed = 8
    /// The creative failed to render (image download, video playback, HTML load).
    case creativeFailed = 9
    /// The app is marked child-directed; ads are not served (COPPA).
    case childDirected = 10
}

public let AdfactenErrorDomain = "com.adfacten.ads"

/// `NSError.userInfo` key holding the stable error name (see `AdfactenError.name`).
public let AdfactenErrorNameKey = "AdfactenErrorName"

public struct AdfactenError: Error, CustomNSError, LocalizedError, Sendable, Equatable {
    public let code: AdfactenErrorCode
    public let message: String
    /// The server's machine code for `serverRejected` (e.g. `unknown_app`, `app_not_approved`,
    /// `placement_mismatch`, `coppa`, `test_only`, `invalid_request`).
    public let serverCode: String?
    /// Stable, platform-neutral name of the error, shared with the Android SDK:
    /// `internal_error`, `not_initialized`, `invalid_request`, `network_error`, `no_fill`,
    /// `server_error`, `invalid_response`, `rejected`, `ad_expired`, `already_shown`, `not_ready`,
    /// `show_failed`, `video_not_supported`, `load_in_progress`, `child_directed`, `creative_failed`.
    /// It is a bit finer than `code` (for example `network` splits into `network_error` and
    /// `server_error`), and a server COPPA refusal is `rejected` with `serverCode` "coppa".
    /// Objective-C reads it from `userInfo[AdfactenErrorNameKey]`.
    public let name: String

    public init(_ code: AdfactenErrorCode, _ message: String, serverCode: String? = nil) {
        self.init(code, message, serverCode: serverCode, name: nil)
    }

    init(_ code: AdfactenErrorCode, _ message: String, serverCode: String? = nil, name: AdfactenErrorName?) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
        self.name = (name ?? AdfactenErrorName.default(for: code, serverCode: serverCode)).rawValue
    }

    public static var errorDomain: String { AdfactenErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message, AdfactenErrorNameKey: name]
        if let serverCode { info["serverCode"] = serverCode }
        return info
    }
    public var errorDescription: String? { message }
}

/// The shared error vocabulary. Raw values are what `AdfactenError.name` returns.
enum AdfactenErrorName: String, CaseIterable, Sendable {
    case internalError = "internal_error"
    case notInitialized = "not_initialized"
    case invalidRequest = "invalid_request"
    case networkError = "network_error"
    case noFill = "no_fill"
    case serverError = "server_error"
    case invalidResponse = "invalid_response"
    case rejected = "rejected"
    case adExpired = "ad_expired"
    case alreadyShown = "already_shown"
    case notReady = "not_ready"
    case showFailed = "show_failed"
    case videoNotSupported = "video_not_supported"
    case loadInProgress = "load_in_progress"
    case childDirected = "child_directed"
    case creativeFailed = "creative_failed"

    static func `default`(for code: AdfactenErrorCode, serverCode: String?) -> AdfactenErrorName {
        switch code {
        case .notInitialized: return .notInitialized
        case .noFill: return .noFill
        case .network: return .networkError
        case .serverRejected: return serverCode == "invalid_request" ? .invalidRequest : .rejected
        case .invalidResponse: return .invalidResponse
        case .expired: return .adExpired
        case .notReady: return .notReady
        case .presentationFailed: return .showFailed
        case .creativeFailed: return .creativeFailed
        case .childDirected: return serverCode == "coppa" ? .rejected : .childDirected
        }
    }
}
