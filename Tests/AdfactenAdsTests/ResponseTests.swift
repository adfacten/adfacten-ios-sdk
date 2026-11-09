import XCTest
@testable import AdfactenAds

final class ResponseTests: XCTestCase {
    func testDecodesContractExample() throws {
        let data = Fixtures.adJSON(format: "banner", kind: "image", extra: #","refresh_s":45"#)
        guard case .success(let f) = AdClient.interpret(status: 200, data: data, dateHeader: Fixtures.httpDate) else {
            return XCTFail("decode failed")
        }
        let p = f.payload
        XCTAssertEqual(p.id, "imp-1")
        XCTAssertEqual(p.format, .banner)
        XCTAssertEqual(p.kind, .image)
        XCTAssertEqual(p.image?.url2x, "https://cdn.test/a@2x.webp")
        XCTAssertEqual(p.image?.fallback, "https://cdn.test/a.jpg")
        XCTAssertEqual(p.clickUrl, "https://trk.test/a/click?imp=imp-1")
        XCTAssertEqual(p.trackers.view, "https://trk.test/i?imp=imp-1&e=view")
        XCTAssertEqual(p.viewRule, .init(minRatio: 0.5, minMs: 1000))
        XCTAssertEqual(p.closeAfterS, 0)
        XCTAssertEqual(p.reward, .init(type: "coins", amount: 10))
        XCTAssertEqual(p.native?.image?.w, 1200)
        XCTAssertEqual(p.label, "Reklam")
        XCTAssertEqual(p.expiresAt, 1_790_003_300)
        XCTAssertEqual(p.refreshS, 45)
        XCTAssertEqual(f.serverDate, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testToleratesMissingOptionalFieldsAndUnknownKeys() throws {
        let json = #"{"ad":{"id":"x","format":"native","kind":"native","native":{"title":"T"},"trackers":{},"new_field":{"a":1}}}"#
        guard case .success(let f) = AdClient.interpret(status: 200, data: Data(json.utf8), dateHeader: nil) else {
            return XCTFail("decode failed")
        }
        XCTAssertNil(f.payload.trackers.render)
        XCTAssertNil(f.payload.viewRule)
    }

    func testUnknownFormatAndKindDecodeButAreRejected() throws {
        // Future formats (e.g. "chat") and extra fields must not break decoding.
        let json = #"{"ad":{"id":"x","format":"chat","kind":"cards","trackers":{},"cards":[{"a":1}],"context":{"q":"x"}}}"#
        guard case .success(let f) = AdClient.interpret(status: 200, data: Data(json.utf8), dateHeader: nil) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(f.payload.format, .unknown)
        XCTAssertEqual(f.payload.kind, .unknown)
        guard case .failure(let e) = AdValidator.validate(f.payload, requested: .banner) else { return XCTFail("accepted") }
        XCTAssertEqual(e.code, .invalidResponse)
    }

    func testStatusMapping() {
        func err(_ s: Int, _ body: String = "") -> AdfactenError? {
            if case .failure(let e) = AdClient.interpret(status: s, data: Data(body.utf8), dateHeader: nil) { return e }
            return nil
        }
        XCTAssertEqual(err(204)?.code, .noFill)
        XCTAssertEqual(err(403, #"{"code":"app_not_approved","message":"App not approved"}"#),
                       AdfactenError(.serverRejected, "App not approved", serverCode: "app_not_approved"))
        XCTAssertEqual(err(403, #"{"code":"coppa","message":"child"}"#)?.code, .childDirected)
        XCTAssertEqual(err(400)?.serverCode, "invalid_request")
        XCTAssertEqual(err(500)?.code, .network)
        XCTAssertEqual(err(200, "{not json")?.code, .invalidResponse)
    }

    func testValidatorRejectsMismatches() throws {
        let banner = try decode(Fixtures.adJSON(format: "banner", kind: "image"))
        XCTAssertEqual(try? AdValidator.validate(banner, requested: .banner).get(), .some(nil))
        guard case .failure = AdValidator.validate(banner, requested: .interstitial) else { return XCTFail("format mismatch passed") }
        let video = try decode(Fixtures.adJSON(format: "banner", kind: "video"))
        guard case .failure = AdValidator.validate(video, requested: .banner) else { return XCTFail("video banner passed") }
        let badVast = try decode(Fixtures.adJSON(format: "rewarded", kind: "video", extra: #","vast":"<VAST><Ad><Wrapper/></Ad></VAST>""#))
        guard case .failure(let e) = AdValidator.validate(badVast, requested: .rewarded) else { return XCTFail("wrapper passed") }
        XCTAssertEqual(e.code, .invalidResponse)
    }

    func testExpiryUsesServerDateToCancelClockSkew() {
        let server = Date(timeIntervalSince1970: 1_790_000_000)
        let deviceAhead = server.addingTimeInterval(7200) // device clock 2 h fast
        let d = Expiry.localDeadline(expiresAt: 1_790_003_300, serverDate: server, now: deviceAhead)
        XCTAssertEqual(d.timeIntervalSince(deviceAhead), 3300, accuracy: 0.01)
        // Without a Date header a non-positive TTL is skew, not expiry.
        let noHeader = Expiry.localDeadline(expiresAt: 1_790_003_300, serverDate: nil, now: deviceAhead)
        XCTAssertEqual(noHeader.timeIntervalSince(deviceAhead), 50 * 60, accuracy: 0.01)
        // With a Date header an already-expired ad is expired.
        let expired = Expiry.localDeadline(expiresAt: 1_789_999_000, serverDate: server, now: server)
        XCTAssertEqual(expired, server)
        // Missing expires_at → 55 min; absurd TTLs are capped at 2 h.
        XCTAssertEqual(Expiry.localDeadline(expiresAt: nil, serverDate: nil, now: server).timeIntervalSince(server), 3300)
        XCTAssertEqual(Expiry.localDeadline(expiresAt: 1_900_000_000, serverDate: server, now: server).timeIntervalSince(server), 7200)
    }

    func testImageCandidates() {
        let img = AdPayload.Image(url: "https://c/a.webp", url2x: "https://c/a2.webp", fallback: "https://c/a.jpg")
        XCTAssertEqual(ImageLoader.candidates(img, scale: 3, webpSupported: true).map(\.absoluteString),
                       ["https://c/a2.webp", "https://c/a.webp", "https://c/a.jpg"])
        XCTAssertEqual(ImageLoader.candidates(img, scale: 1, webpSupported: true).map(\.absoluteString),
                       ["https://c/a.webp", "https://c/a.jpg"])
        XCTAssertEqual(ImageLoader.candidates(img, scale: 2, webpSupported: false).map(\.absoluteString), ["https://c/a.jpg"])
    }

    func testClickTargetPrefersTrackedURL() {
        let click = URL(string: "https://trk.adfacten.com/a/click?imp=1")!
        XCTAssertEqual(ClickTarget.resolve(clickURL: click, tapped: nil), click)
        XCTAssertEqual(ClickTarget.resolve(clickURL: click, tapped: URL(string: "https://landing.example/x")), click)
        let own = URL(string: "https://trk.adfacten.com/a/click?imp=1&pos=2")!
        XCTAssertEqual(ClickTarget.resolve(clickURL: click, tapped: own), own)
        XCTAssertEqual(ClickTarget.resolve(clickURL: nil, tapped: own), own)
    }

    func testAppStoreIDExtraction() {
        XCTAssertEqual(ClickHandler.appStoreID(from: URL(string: "https://apps.apple.com/tr/app/foo-bar/id1234567890")!), "1234567890")
        XCTAssertEqual(ClickHandler.appStoreID(from: URL(string: "https://itunes.apple.com/app/id42?mt=8")!), "42")
        XCTAssertEqual(ClickHandler.appStoreID(from: URL(string: "https://apps.apple.com/app/x?id=77")!), "77")
        XCTAssertNil(ClickHandler.appStoreID(from: URL(string: "https://example.com/app/id123")!))
        XCTAssertNil(ClickHandler.appStoreID(from: URL(string: "https://apps.apple.com/developer/idabc")!))
    }

    private func decode(_ d: Data) throws -> AdPayload { try JSONDecoder().decode(AdEnvelope.self, from: d).ad }
}

final class BackoffTests: XCTestCase {
    func testDelaySchedule() {
        XCTAssertEqual(PlacementBackoff.delay(failures: 1, jitter: 0), 30)
        XCTAssertEqual(PlacementBackoff.delay(failures: 2, jitter: 0), 60)
        XCTAssertEqual(PlacementBackoff.delay(failures: 4, jitter: 0), 240)
        XCTAssertEqual(PlacementBackoff.delay(failures: 9, jitter: 0), 300)
        XCTAssertEqual(PlacementBackoff.delay(failures: 1, jitter: 1), 37.5)
        XCTAssertGreaterThanOrEqual(PlacementBackoff.delay(failures: 0, jitter: 0), 30, "never below the 30 s minimum")
    }

    func testPerPlacementWindow() async {
        let clock = TestClock()
        let b = PlacementBackoff(clock: clock.clock, jitter: { 0 })
        let none = await b.remaining("plc_a")
        XCTAssertNil(none)
        await b.recordFailure("plc_a")
        let left = await b.remaining("plc_a")
        XCTAssertEqual(left ?? 0, 30, accuracy: 0.001)
        let other = await b.remaining("plc_b")
        XCTAssertNil(other, "backoff is per placement")
        clock.advance(31)
        let after = await b.remaining("plc_a")
        XCTAssertNil(after)
        await b.recordFailure("plc_a")
        let second = await b.remaining("plc_a")
        XCTAssertEqual(second ?? 0, 60, accuracy: 0.001)
        await b.recordSuccess("plc_a")
        let reset = await b.remaining("plc_a")
        XCTAssertNil(reset)
    }
}
