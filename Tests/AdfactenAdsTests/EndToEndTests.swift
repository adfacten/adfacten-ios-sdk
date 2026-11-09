import UIKit
import XCTest
@testable import AdfactenAds

/// load → present → beacons, with every HTTP call answered by MockURLProtocol.
@MainActor
final class EndToEndTests: XCTestCase {
    var window: UIWindow!
    var clock: TestClock!

    override func setUp() async throws {
        MockURLProtocol.reset()
        FullScreenAd.presenting = false
        clock = TestClock()
        Adfacten.environment = Fixtures.environment(clock: clock)
        Adfacten.initialize(appKey: "apk_test", config: AdfactenConfig(testMode: true, logLevel: .debug, userId: "user-9"))
        window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        // The SPM test runner has no app scene, so UIKit never completes a modal presentation here.
        // Host the ad controller as a child instead; the sample app's hosted run covers real modals.
        FullScreenAd.presentOverride = { host, vc in
            host.addChild(vc)
            vc.view.frame = host.view.bounds
            host.view.addSubview(vc.view)
            vc.didMove(toParent: host)
        }
        MockURLProtocol.route("/a.webp", .init(status: 200, body: Fixtures.pngData))
        MockURLProtocol.route("/a@2x.webp", .init(status: 200, body: Fixtures.pngData))
        MockURLProtocol.route("/n.jpg", .init(status: 200, body: Fixtures.pngData))
        MockURLProtocol.route("/i.png", .init(status: 200, body: Fixtures.pngData))
        MockURLProtocol.route("/i", .init(status: 204))
    }

    override func tearDown() async throws {
        FullScreenAd.presentOverride = nil
        window.isHidden = true
        window = nil
        Adfacten.context?.stop()
        Adfacten.context = nil
        Adfacten.environment = .live
    }

    private func beacons(_ event: String) -> [MockURLProtocol.Recorded] {
        MockURLProtocol.requests(path: "/i").filter { $0.url.query?.contains("e=\(event)") == true }
    }

    func testInitializeRejectsBadKey() {
        Adfacten.initialize(appKey: "not-a-key")
        XCTAssertFalse(Adfacten.isInitialized)
    }

    func testInterstitialLoadPresentAndBeacons() async throws {
        MockURLProtocol.route("/m/v1/ad", .init(status: 200, headers: ["Date": Fixtures.httpDate],
                                                body: Fixtures.adJSON(format: "interstitial", kind: "image")))
        let ad = try await InterstitialAd.load(placementId: "plc_int")
        XCTAssertTrue(ad.isReady)

        // The request on the wire.
        let req = try XCTUnwrap(MockURLProtocol.requests(path: "/m/v1/ad").first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertTrue(req.headers["User-Agent"]?.hasPrefix("AdfactenSDK/\(Adfacten.sdkVersion) (ios ") == true, req.headers["User-Agent"] ?? "")
        XCTAssertEqual(req.headers["X-Adfacten-SDK"], "ios/\(Adfacten.sdkVersion)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["format"] as? String, "interstitial")
        XCTAssertEqual(body["test"] as? Bool, true)
        XCTAssertNil(body["user"], "user id only goes with rewarded")
        let sdkId = try XCTUnwrap((body["device"] as? [String: Any])?["sdk_id"] as? String)
        XCTAssertEqual((body["device"] as? [String: Any])?["model"] as? String, "Simulator")

        var presented = 0, dismissed = 0
        ad.onPresented = { presented += 1 }
        ad.onDismissed = { dismissed += 1 }
        ad.present(from: window.rootViewController!)
        await waitUntil(5, "presented") { presented == 1 }
        await waitUntil(5, "render beacon") { !self.beacons("render").isEmpty }
        let render = try XCTUnwrap(beacons("render").first?.url)
        XCTAssertTrue(render.query?.contains("sid=\(sdkId)") == true, render.absoluteString)
        XCTAssertTrue(render.query?.contains("ts=1790000000000") == true, render.absoluteString)
        XCTAssertTrue(beacons("view").isEmpty, "view needs 1 s on screen")
        await waitUntil(5, "view beacon") { !self.beacons("view").isEmpty }
        XCTAssertFalse(ad.isReady, "single use")

        // Showing it twice is refused.
        var failed: Error?
        let probe = DelegateProbe()
        probe.onFail = { failed = $0 }
        ad.delegate = probe
        ad.present(from: window.rootViewController!)
        XCTAssertEqual((failed as? AdfactenError)?.code, .notReady)

        let vc = try XCTUnwrap(window.rootViewController?.children.first as? FullScreenAdViewController)
        vc.finish()
        await waitUntil(5, "dismissed") { dismissed == 1 }
        await waitUntil(5, "close beacon") { !self.beacons("close").isEmpty }
        XCTAssertEqual(beacons("render").count, 1)
        XCTAssertEqual(beacons("view").count, 1)
        XCTAssertTrue(beacons("complete").isEmpty, "interstitial image has no completion")
        XCTAssertFalse(FullScreenAd.presenting)
    }

    func testRewardedImageCompletesAndRewards() async throws {
        let json = Fixtures.adJSON(format: "rewarded", kind: "image", id: "imp-r").replacingCloseAfter(2)
        MockURLProtocol.route("/m/v1/ad", .init(status: 200, body: json))
        let ad = try await RewardedAd.load(placementId: "plc_rw", customData: "level-3")
        XCTAssertEqual(ad.reward?.type, "coins")
        XCTAssertEqual(ad.reward?.amount, 10)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.requests(path: "/m/v1/ad").first?.body ?? Data()) as? [String: Any])
        XCTAssertEqual((body["user"] as? [String: Any])?["id"] as? String, "user-9")
        XCTAssertEqual((body["user"] as? [String: Any])?["custom"] as? String, "level-3")

        var earned: [AdReward] = []
        ad.present(from: window.rootViewController!) { earned.append($0) }
        await waitUntil(8, "reward") { earned.count == 1 }
        await waitUntil(5, "complete beacon") { !self.beacons("complete").isEmpty }
        XCTAssertEqual(earned.first?.amount, 10)
        let vc = try XCTUnwrap(window.rootViewController?.children.first as? FullScreenAdViewController)
        vc.finish()
        await waitUntil(5, "close beacon") { !self.beacons("close").isEmpty }
        XCTAssertEqual(earned.count, 1)
    }

    func testFirstPartyVASTURLsCarrySid() async throws {
        let vast = #"<VAST><Ad><InLine><Impression>https://trk.test/i?imp=v1&amp;e=vast_imp</Impression><Impression>https://third.example/imp</Impression><Creatives><Creative><Linear><MediaFiles><MediaFile type=\"video/mp4\" width=\"640\" height=\"360\">https://cdn.test/v.mp4</MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>"#
        let json = Fixtures.adJSON(format: "rewarded", kind: "video", id: "v1", extra: ",\"vast\":\"\(vast)\"")
        MockURLProtocol.route("/m/v1/ad", .init(status: 200, body: json))
        MockURLProtocol.route("/imp", .init(status: 204))
        let ad = try await RewardedAd.load(placementId: "plc_v")
        let ctx = try XCTUnwrap(Adfacten.context)
        ctx.fireExternal(try XCTUnwrap(ad.loaded.vast?.impressions), key: "impression", for: ad.loaded)
        await waitUntil(5, "vast beacons") { MockURLProtocol.requests(path: "/imp").count == 1 && !self.beacons("vast_imp").isEmpty }
        XCTAssertTrue(beacons("vast_imp").first?.url.query?.contains("sid=\(ctx.sdkId)") == true)
        XCTAssertFalse(MockURLProtocol.requests(path: "/imp").first?.url.query?.contains("sid=") == true, "third-party URL untouched")
    }

    func testNoFillBacksOffWithoutNetwork() async {
        MockURLProtocol.route("/m/v1/ad", .init(status: 204))
        do { _ = try await InterstitialAd.load(placementId: "plc_nf"); XCTFail("expected no fill") } catch {
            XCTAssertEqual((error as? AdfactenError)?.code, .noFill)
        }
        do { _ = try await InterstitialAd.load(placementId: "plc_nf"); XCTFail("expected no fill") } catch {
            XCTAssertEqual((error as? AdfactenError)?.code, .noFill)
            XCTAssertTrue((error as? AdfactenError)?.message.contains("backing off") == true)
        }
        XCTAssertEqual(MockURLProtocol.requests(path: "/m/v1/ad").count, 1, "second load must not hit the network")
        clock.advance(31)
        MockURLProtocol.route("/m/v1/ad", .init(status: 200, body: Fixtures.adJSON(format: "interstitial")))
        let ad = try? await InterstitialAd.load(placementId: "plc_nf")
        XCTAssertNotNil(ad)
    }

    func testExpiredAdIsNotPresented() async throws {
        MockURLProtocol.route("/m/v1/ad", .init(status: 200, headers: ["Date": Fixtures.httpDate],
                                                body: Fixtures.adJSON(format: "app_open", kind: "html")))
        let ad = try await AppOpenAd.load(placementId: "plc_open")
        clock.advance(3301)
        XCTAssertFalse(ad.isReady)
        let probe = DelegateProbe()
        var failed: Error?
        probe.onFail = { failed = $0 }
        ad.delegate = probe
        ad.present(from: window.rootViewController!)
        XCTAssertEqual((failed as? AdfactenError)?.code, .expired)
        XCTAssertTrue(window.rootViewController?.children.isEmpty == true)
    }

    func testServerRejectionSurfacesCodeWithoutBackoff() async {
        MockURLProtocol.route("/m/v1/ad", .init(status: 400, body: Data(#"{"code":"placement_mismatch","message":"wrong format"}"#.utf8)))
        for _ in 0..<2 {
            do { _ = try await NativeAd.load(placementId: "plc_x"); XCTFail("expected error") } catch {
                XCTAssertEqual((error as? AdfactenError)?.code, .serverRejected)
                XCTAssertEqual((error as? AdfactenError)?.serverCode, "placement_mismatch")
            }
        }
        XCTAssertEqual(MockURLProtocol.requests(path: "/m/v1/ad").count, 2, "4xx is not a backoff case")
    }

    func testBannerRendersAndCountsView() async throws {
        MockURLProtocol.route("/m/v1/ad", .init(status: 200, body: Fixtures.adJSON(format: "banner", kind: "image", id: "imp-b")))
        let banner = AdfactenBannerView(placementId: "plc_ban", size: .banner)
        var loaded = 0, impressions = 0
        banner.onLoaded = { loaded += 1 }
        banner.onImpression = { impressions += 1 }
        banner.load()
        await waitUntil(5, "banner loaded") { loaded == 1 }
        XCTAssertTrue(beacons("render").isEmpty, "not on screen yet → no render")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.requests(path: "/m/v1/ad").first?.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["sizes"] as? [String], ["320x50"])

        banner.frame.origin = CGPoint(x: 10, y: 100)
        window.rootViewController!.view.addSubview(banner)
        await waitUntil(5, "render") { impressions == 1 }
        await waitUntil(5, "view beacon") { !self.beacons("view").isEmpty }
        XCTAssertEqual(beacons("render").count, 1)
        banner.removeFromSuperview()
        banner.destroy()
    }

    func testNativeAdViewBindsAndTracks() async throws {
        MockURLProtocol.route("/m/v1/ad", .init(status: 200, body: Fixtures.adJSON(format: "native", kind: "native", id: "imp-n")))
        let ad = try await NativeAd.load(placementId: "plc_nat")
        XCTAssertEqual(ad.title, "Başlık")
        XCTAssertEqual(ad.callToAction, "Yükle")
        XCTAssertNotNil(ad.image)
        XCTAssertNotNil(ad.icon)

        let v = NativeAdView(frame: CGRect(x: 0, y: 200, width: 360, height: 300))
        let title = UILabel(), cta = UIButton(type: .system), media = UIImageView()
        [title, cta, media].forEach(v.addSubview)
        v.titleLabel = title
        v.callToActionButton = cta
        v.mediaView = media
        v.nativeAd = ad
        XCTAssertEqual(title.text, "Başlık")
        XCTAssertEqual(cta.title(for: .normal), "Yükle")
        XCTAssertNotNil(media.image)
        XCTAssertTrue(v.subviews.contains { ($0 as? UILabel)?.text?.contains("Reklam") == true }, "auto ad badge")

        var impressions = 0
        ad.onImpression = { impressions += 1 }
        window.rootViewController!.view.addSubview(v)
        await waitUntil(5, "impression") { impressions == 1 }
        await waitUntil(5, "view beacon") { !self.beacons("view").isEmpty }
        v.nativeAd = nil
    }
}

@MainActor
private final class DelegateProbe: NSObject, FullScreenAdDelegate {
    var onFail: ((Error) -> Void)?
    func ad(_ ad: FullScreenAd, didFailToPresentWithError error: Error) { onFail?(error) }
}

private extension Data {
    func replacingCloseAfter(_ s: Int) -> Data {
        let str = String(decoding: self, as: UTF8.self).replacingOccurrences(of: #""close_after_s":0"#, with: #""close_after_s":\#(s)"#)
        return Data(str.utf8)
    }
}
