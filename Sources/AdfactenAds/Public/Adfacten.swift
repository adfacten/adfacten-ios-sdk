import Foundation
import UIKit

/// SDK configuration passed to `Adfacten.initialize(appKey:config:)`.
@objc(ADFConfig)
public final class AdfactenConfig: NSObject, @unchecked Sendable {
    /// Request test ads. Test ads are never billed. Use it during development.
    @objc public var testMode: Bool = false
    /// Log verbosity (Console.app, subsystem `com.adfacten.ads`).
    @objc public var logLevel: AdfactenLogLevel = .warning
    /// The app is directed at children (COPPA). Adfacten does not serve child-directed apps; requests
    /// are flagged and identifiers (IDFA/IDFV) are never sent.
    @objc public var childDirected: Bool = false
    /// Your own user id, sent with rewarded requests and echoed in the server-side reward callback.
    @objc public var userId: String?
    /// Ad server base URL. Leave the default; override only for a staging/local tracker.
    @objc public var serverURL: URL = URL(string: "https://trk.adfacten.com")!

    @objc public override init() { super.init() }

    public convenience init(testMode: Bool = false, logLevel: AdfactenLogLevel = .warning,
                            childDirected: Bool = false, userId: String? = nil) {
        self.init()
        self.testMode = testMode
        self.logLevel = logLevel
        self.childDirected = childDirected
        self.userId = userId
    }

    var snapshot: ConfigSnapshot {
        ConfigSnapshot(testMode: testMode, childDirected: childDirected, serverURL: serverURL)
    }
}

struct ConfigSnapshot: Sendable, Equatable {
    var testMode: Bool
    var childDirected: Bool
    var serverURL: URL
}

/// Entry point of the Adfacten Ads SDK.
@objc(ADFAdfacten)
public final class Adfacten: NSObject {
    /// SDK version (semantic).
    @objc public static let sdkVersion = "1.0.2"

    /// `NSError.userInfo` key of the stable error name (`no_fill`, `rejected`, …).
    @objc public static let errorNameKey = AdfactenErrorNameKey

    static let wrapperBox = Locked<WrapperInfo?>(nil)
    static var wrapper: WrapperInfo? { wrapperBox.get() }

    /// For framework plugins (Flutter, React Native, Unity) only; apps don't need it.
    /// Reports the plugin with each ad request (`app.wrapper`) and in the User-Agent. Call it
    /// before `initialize` (later calls apply to later requests). Names other than `flutter`,
    /// `react_native` and `unity` are sent as `other`; a version that isn't 1–20 characters of
    /// `[0-9A-Za-z.+-]` is sent as `unknown`.
    @objc(setWrapperName:version:)
    public static func setWrapper(name: String, version: String) {
        wrapperBox.set(WrapperInfo(name: name, version: version))
    }

    @MainActor static var context: SDKContext?
    @MainActor static var environment = SDKEnvironment.live

    /// Initializes the SDK. Call once, on the main thread, early in app launch. Safe to call again
    /// (for example to switch `testMode`); the latest call wins.
    ///
    /// - Parameters:
    ///   - appKey: The public app key from the Adfacten panel (`apk_…`).
    ///   - config: Optional settings.
    @MainActor
    @objc(initializeWithAppKey:config:)
    public static func initialize(appKey: String, config: AdfactenConfig = AdfactenConfig()) {
        Log.level.set(config.logLevel)
        let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("apk_"), key.count > 4 else {
            Log.error("invalid app key \"\(appKey)\"; it must start with apk_. Ads will not load.")
            context = nil
            return
        }
        if let old = context { old.stop() }
        let ctx = SDKContext(appKey: key, config: config.snapshot, userId: config.userId, env: environment)
        context = ctx
        ctx.start()
        Log.info("initialized \(sdkVersion) app=\(key) test=\(config.testMode)")
        if config.testMode == false {
            #if targetEnvironment(simulator)
            Log.warning("running on the simulator: the server only returns test ads here")
            #endif
        }
    }

    /// Whether `initialize` succeeded.
    @MainActor @objc public static var isInitialized: Bool { context != nil }

    /// Updates the user id used for rewarded server-side verification (e.g. after login).
    @MainActor
    @objc public static func setUserId(_ userId: String?) {
        context?.userId = userId
    }
}

/// Hooks the tests replace; production uses `.live`.
struct SDKEnvironment: @unchecked Sendable {
    var sessionConfiguration: () -> URLSessionConfiguration
    var defaults: UserDefaults
    var clock: Clock
    var identity: IdentitySource
    var storageDirectory: () -> URL?
    var appIsActive: @MainActor () -> Bool
    var jitter: @Sendable () -> Double

    static var live: SDKEnvironment {
        SDKEnvironment(
            sessionConfiguration: {
                let c = URLSessionConfiguration.ephemeral
                c.timeoutIntervalForRequest = 10
                c.timeoutIntervalForResource = 30
                c.httpShouldSetCookies = false
                c.httpCookieAcceptPolicy = .never
                c.urlCache = nil
                c.waitsForConnectivity = false
                return c
            },
            defaults: .standard,
            clock: .system,
            identity: SystemIdentitySource(),
            storageDirectory: {
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("com.adfacten.ads", isDirectory: true)
            },
            appIsActive: { UIApplication.shared.applicationState == .active },
            jitter: { Double.random(in: 0...1) }
        )
    }
}

/// Everything the SDK needs after initialization. Created on the main thread.
final class SDKContext: @unchecked Sendable {
    let appKey: String
    let config: ConfigSnapshot
    let env: SDKEnvironment
    let session: URLSession
    let client: AdClient
    let beacons: BeaconQueue
    let backoff: PlacementBackoff
    let images: ImageLoader
    let connection = ConnectionMonitor()
    let sdkId: String
    private let userIdBox: Locked<String?>
    private var observers: [NSObjectProtocol] = []

    var userId: String? {
        get { userIdBox.get() }
        set { userIdBox.set(newValue) }
    }

    @MainActor
    init(appKey: String, config: ConfigSnapshot, userId: String?, env: SDKEnvironment) {
        self.appKey = appKey
        self.config = config
        self.env = env
        self.userIdBox = Locked(userId)
        let sessionConfig = env.sessionConfiguration()
        // Beacons and VAST trackers carry the SDK user agent too, so the server never sees a bare
        // CFNetwork UA (which bot filters may drop).
        // The wrapper suffix is added per request (see `adfData`), not here.
        let ua = UserAgent.make(sdkVersion: Adfacten.sdkVersion, device: DeviceSnapshot.capture(connection: "unknown"))
        var headers = sessionConfig.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = ua
        headers["X-Adfacten-SDK"] = "ios/\(Adfacten.sdkVersion)"
        sessionConfig.httpAdditionalHeaders = headers
        self.session = URLSession(configuration: sessionConfig)
        self.client = AdClient(session: session, baseURL: config.serverURL)
        let file = env.storageDirectory()?.appendingPathComponent("beacons.json")
        self.beacons = BeaconQueue(fileURL: file, session: session, clock: env.clock, jitter: env.jitter)
        self.backoff = PlacementBackoff(clock: env.clock, jitter: env.jitter)
        self.images = ImageLoader(session: session)
        self.sdkId = InstallID.get(env.defaults)
    }

    @MainActor
    func start() {
        let beacons = self.beacons
        connection.onBecameReachable = { Task { await beacons.flush() } }
        connection.start()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { await beacons.flush() }
        })
        Task { await beacons.flush() }
    }

    @MainActor
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: Loading

    /// Requests an ad. Call on the main thread (device facts are read from UIKit).
    @MainActor
    func load(placementId: String, format: AdFormat, sizes: [String], custom: String? = nil) async -> Result<LoadedAd, AdfactenError> {
        let placement = placementId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !placement.isEmpty else {
            return .failure(AdfactenError(.serverRejected, "empty placement id", serverCode: "invalid_request"))
        }
        if let left = await backoff.remaining(placement) {
            return .failure(AdfactenError(.noFill, "no fill; placement backing off for \(Int(left.rounded(.up))) s"))
        }
        let device = DeviceSnapshot.capture(connection: connection.current)
        let consent = ConsentSnapshot.read(from: env.defaults)
        let identity = IdentityResolver.resolve(
            status: env.identity.trackingStatus(),
            idfa: env.identity.advertisingIdentifier(),
            idfv: env.identity.vendorIdentifier(),
            sdkId: sdkId,
            childDirected: config.childDirected,
            consent: consent
        )
        let body = AdRequestBuilder.build(appKey: appKey, placement: placement, format: format, sizes: sizes,
                                          device: device, identity: identity, sdkId: sdkId, consent: consent,
                                          config: config, userId: userId, custom: custom, wrapper: Adfacten.wrapper)
        let ua = UserAgent.make(sdkVersion: Adfacten.sdkVersion, device: device, wrapper: Adfacten.wrapper)
        Log.debug("requesting \(format.rawValue) for \(placement)")

        let fetched = await client.fetch(body, userAgent: ua)
        switch fetched {
        case .failure(let err):
            // Back off after no-fill and 5xx. Being offline is not the placement's fault, and
            // 400/403 are configuration errors that a retry won't fix.
            if err.name == AdfactenErrorName.noFill.rawValue || err.name == AdfactenErrorName.serverError.rawValue {
                await backoff.recordFailure(placement)
            }
            Log.info("load failed for \(placement): \(err.message)")
            return .failure(err)
        case .success(let f):
            switch AdValidator.validate(f.payload, requested: format) {
            case .failure(let err):
                await backoff.recordFailure(placement)
                return .failure(err)
            case .success(let vast):
                await backoff.recordSuccess(placement)
                let now = env.clock.now()
                let deadline = Expiry.localDeadline(expiresAt: f.payload.expiresAt, serverDate: f.serverDate, now: now)
                return .success(LoadedAd(payload: f.payload, vast: vast, expiresAt: deadline, placementId: placement))
            }
        }
    }

    // MARK: Beacons

    enum Event: String, Sendable { case render, view, complete, close }

    /// Fires one of the ad's own trackers once (adds `sid` and `ts`).
    func fire(_ event: Event, for ad: LoadedAd) {
        let raw: String?
        switch event {
        case .render: raw = ad.payload.trackers.render
        case .view: raw = ad.payload.trackers.view
        case .complete: raw = ad.payload.trackers.complete
        case .close: raw = ad.payload.trackers.close
        }
        guard let raw, let url = URL(string: raw) else { return }
        let ts = Int64(env.clock.now().timeIntervalSince1970 * 1000)
        let decorated = url.appendingQuery([("sid", sdkId), ("ts", String(ts))])
        let key = "\(ad.payload.id)|\(event.rawValue)"
        let beacons = self.beacons
        Log.debug("beacon \(event.rawValue) for \(ad.placementId)")
        Task { await beacons.enqueue(key: key, url: decorated) }
    }

    /// Fires third-party URLs (VAST impression/tracking events) once each, as given.
    func fireExternal(_ urls: [URL], key: String, for ad: LoadedAd, playhead: TimeInterval? = nil, errorCode: Int? = nil) {
        guard !urls.isEmpty else { return }
        let beacons = self.beacons
        let now = env.clock.now()
        let ownHosts = Set([ad.payload.trackers.render, ad.payload.trackers.view, ad.payload.clickUrl]
            .compactMap { $0.flatMap(URL.init(string:))?.host?.lowercased() })
        let ts = String(Int64(now.timeIntervalSince1970 * 1000))
        let sid = sdkId
        let list = urls.map { raw -> URL in
            let u = VASTMacros.expand(raw, errorCode: errorCode, playhead: playhead, now: now)
            // VAST events on Adfacten's own /i endpoint need the sid too, or the server
            // can't bind them to this device. Third-party URLs are sent untouched.
            guard let host = u.host?.lowercased(), ownHosts.contains(host) else { return u }
            return u.appendingQuery([("sid", sid), ("ts", ts)])
        }
        let base = "\(ad.payload.id)|x|\(key)"
        Task {
            for (i, u) in list.enumerated() { await beacons.enqueue(key: "\(base)|\(i)", url: u) }
        }
    }
}
