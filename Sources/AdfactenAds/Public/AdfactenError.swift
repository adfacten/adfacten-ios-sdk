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

public struct AdfactenError: Error, CustomNSError, LocalizedError, Sendable, Equatable {
    public let code: AdfactenErrorCode
    public let message: String
    /// The server's machine code for `serverRejected` (e.g. `unknown_app`, `app_not_approved`,
    /// `placement_mismatch`, `coppa`, `test_only`, `invalid_request`).
    public let serverCode: String?

    public init(_ code: AdfactenErrorCode, _ message: String, serverCode: String? = nil) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
    }

    public static var errorDomain: String { AdfactenErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let serverCode { info["serverCode"] = serverCode }
        return info
    }
    public var errorDescription: String? { message }
}
