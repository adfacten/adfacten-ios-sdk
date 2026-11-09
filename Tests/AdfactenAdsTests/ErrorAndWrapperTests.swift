import XCTest
@testable import AdfactenAds

final class ErrorNameTests: XCTestCase {
    func testVocabularyMatchesAndroid() {
        let shared: Set<String> = [
            "internal_error", "not_initialized", "invalid_request", "network_error", "no_fill", "server_error",
            "invalid_response", "rejected", "ad_expired", "already_shown", "not_ready", "show_failed",
            "video_not_supported", "load_in_progress", "child_directed", "creative_failed",
        ]
        XCTAssertEqual(Set(AdfactenErrorName.allCases.map(\.rawValue)), shared)
    }

    func testDefaultNamePerCode() {
        let expected: [AdfactenErrorCode: String] = [
            .notInitialized: "not_initialized", .noFill: "no_fill", .network: "network_error",
            .serverRejected: "rejected", .invalidResponse: "invalid_response", .expired: "ad_expired",
            .notReady: "not_ready", .presentationFailed: "show_failed", .creativeFailed: "creative_failed",
            .childDirected: "child_directed",
        ]
        XCTAssertEqual(AdfactenError(.childDirected, "x", serverCode: "coppa").name, "rejected")
        for (code, name) in expected {
            XCTAssertEqual(AdfactenError(code, "x").name, name, "\(code)")
        }
        XCTAssertEqual(AdfactenError(.serverRejected, "x", serverCode: "invalid_request").name, "invalid_request")
        XCTAssertEqual(AdfactenError(.serverRejected, "x", serverCode: "bundle_mismatch").name, "rejected")
    }

    func testServerResponsesMapToNames() {
        func name(_ s: Int, _ body: String = "") -> String? {
            if case .failure(let e) = AdClient.interpret(status: s, data: Data(body.utf8), dateHeader: nil) { return e.name }
            return nil
        }
        XCTAssertEqual(name(204), "no_fill")
        XCTAssertEqual(name(500), "server_error")
        XCTAssertEqual(name(503), "server_error")
        XCTAssertEqual(name(400), "invalid_request")
        XCTAssertEqual(name(403, #"{"code":"app_not_approved"}"#), "rejected")
        XCTAssertEqual(name(403, #"{"code":"coppa"}"#), "rejected", "same as Android; serverCode stays coppa")
        XCTAssertEqual(name(200, "{"), "invalid_response")
    }

    func testNSErrorCarriesNameAndKeepsCode() {
        let e = AdfactenError(.network, "boom", name: .serverError) as NSError
        XCTAssertEqual(e.domain, "com.adfacten.ads")
        XCTAssertEqual(e.code, 3)
        XCTAssertEqual(e.userInfo["AdfactenErrorName"] as? String, "server_error")
        XCTAssertEqual(Adfacten.errorNameKey, "AdfactenErrorName")
        let rejected = AdfactenError(.serverRejected, "no", serverCode: "placement_mismatch") as NSError
        XCTAssertEqual(rejected.userInfo[AdfactenErrorNameKey] as? String, "rejected")
        XCTAssertEqual(rejected.userInfo["serverCode"] as? String, "placement_mismatch")
    }
}

final class WrapperTests: XCTestCase {
    let device = DeviceSnapshot(osVersion: "18.2", model: "iPhone16,1", language: "tr", widthPx: 1179, heightPx: 2556,
                                scale: 3, connection: "wifi", tzOffsetMin: 180, bundleId: "com.example.app", appVersion: "1.2.3")

    func testNamesAndVersionsAreNormalized() {
        XCTAssertEqual(WrapperInfo(name: "flutter", version: "1.0.1"), WrapperInfo(name: " Flutter ", version: "1.0.1"))
        XCTAssertEqual(WrapperInfo(name: "react_native", version: "1.0.0").name, "react_native")
        XCTAssertEqual(WrapperInfo(name: "unity", version: "1").name, "unity")
        XCTAssertEqual(WrapperInfo(name: "cordova", version: "1").name, "other")
        XCTAssertEqual(WrapperInfo(name: "react-native", version: "1").name, "other")
        XCTAssertEqual(WrapperInfo(name: "flutter", version: "1.0.1+build-7").version, "1.0.1+build-7")
        XCTAssertEqual(WrapperInfo(name: "flutter", version: " 1.0.1 ").version, "1.0.1", "trimmed")
        XCTAssertEqual(WrapperInfo(name: "flutter", version: "1.0 (beta)").version, "unknown")
        XCTAssertEqual(WrapperInfo(name: "flutter", version: "1.0é").version, "unknown")
        XCTAssertEqual(WrapperInfo(name: "flutter", version: String(repeating: "9", count: 20)).version.count, 20)
        XCTAssertEqual(WrapperInfo(name: "flutter", version: String(repeating: "9", count: 21)).version, "unknown")
        XCTAssertEqual(WrapperInfo(name: "flutter", version: "  ").version, "unknown")
        XCTAssertEqual(WrapperInfo(name: "OTHER", version: "1").name, "other")
    }

    func testUserAgentSuffix() {
        XCTAssertEqual(UserAgent.make(sdkVersion: "1.0.2", device: device, wrapper: WrapperInfo(name: "flutter", version: "1.0.1")),
                       "AdfactenSDK/1.0.2 (ios 18.2; iPhone16,1) com.example.app/1.2.3 Wrapper/flutter-1.0.1")
        XCTAssertFalse(UserAgent.make(sdkVersion: "1.0.2", device: device).contains("Wrapper"))
    }

    func testRequestFieldOnlyWhenSet() throws {
        let id = ResolvedIdentity(ifa: nil, ifaType: "sdk", lmt: true)
        let consent = ConsentSnapshot(gdprApplies: 0, tcString: "", gppString: "", usPrivacy: "", purpose1Consent: false)
        let config = ConfigSnapshot(testMode: false, childDirected: false, serverURL: URL(string: "https://trk.test")!)
        func app(_ w: WrapperInfo?) throws -> [String: Any] {
            let r = AdRequestBuilder.build(appKey: "apk_x", placement: "plc_1", format: .banner, sizes: [], device: device,
                                           identity: id, sdkId: "s", consent: consent, config: config,
                                           userId: nil, custom: nil, wrapper: w)
            let j = try XCTUnwrap(JSONSerialization.jsonObject(with: AdRequest.encoder().encode(r)) as? [String: Any])
            return try XCTUnwrap(j["app"] as? [String: Any])
        }
        XCTAssertNil(try app(nil)["wrapper"], "plain native apps send no wrapper")
        let w = try XCTUnwrap(try app(WrapperInfo(name: "react_native", version: "1.0.0"))["wrapper"] as? [String: String])
        XCTAssertEqual(w, ["name": "react_native", "version": "1.0.0"])
    }
}

final class RefreshPrecedenceTests: XCTestCase {
    func testAppSettingWins() {
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: 0, server: 45), 0, "app turned refresh off; server can't turn it on")
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: 90, server: 45), 90)
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: 10, server: 45), 30, "clamped to 30")
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: 600, server: nil), 120, "clamped to 120")
    }

    func testServerUsedWhenAppDidNotSet() {
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: nil, server: 45), 45)
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: nil, server: 0), 0, "refresh_s 0 means off")
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: nil, server: 500), 120)
        XCTAssertEqual(AdfactenBannerView.refreshInterval(app: nil, server: nil), 60)
    }

    @MainActor
    func testPropertyKeepsItsDefault() {
        let b = AdfactenBannerView(placementId: "plc", size: .banner)
        XCTAssertEqual(b.refreshInterval, 60)
        XCTAssertEqual(b.effectiveRefresh, 60)
        b.refreshInterval = 0
        XCTAssertEqual(b.effectiveRefresh, 0)
    }
}
