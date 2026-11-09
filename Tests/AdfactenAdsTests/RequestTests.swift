import XCTest
@testable import AdfactenAds

final class RequestTests: XCTestCase {
    let device = DeviceSnapshot(osVersion: "18.2", model: "iPhone16,1", language: "tr", widthPx: 1179, heightPx: 2556,
                                scale: 3, connection: "wifi", tzOffsetMin: 180, bundleId: "com.example.app", appVersion: "1.2.3")
    let config = ConfigSnapshot(testMode: true, childDirected: false, serverURL: URL(string: "https://trk.adfacten.com")!)
    let consent = ConsentSnapshot(gdprApplies: 1, tcString: "CPXxRfAPXxRfAAfKABENB-CgAP_AAH_AAAqIHWtf", gppString: "DBABMA~CPX",
                                  usPrivacy: "1YNN", purpose1Consent: true)

    private func json(_ r: AdRequest) throws -> [String: Any] {
        let data = try AdRequest.encoder().encode(r)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBannerRequestMatchesContractShape() throws {
        let id = ResolvedIdentity(ifa: "11111111-2222-3333-4444-555555555555", ifaType: "idfv", lmt: true)
        let r = AdRequestBuilder.build(appKey: "apk_x", placement: "plc_1", format: .banner, sizes: ["320x50"],
                                       device: device, identity: id, sdkId: "sdk-uuid", consent: consent, config: config,
                                       userId: "user-7", custom: "c")
        let j = try json(r)
        XCTAssertEqual(j["v"] as? Int, 1)
        XCTAssertEqual(j["app_key"] as? String, "apk_x")
        XCTAssertEqual(j["placement"] as? String, "plc_1")
        XCTAssertEqual(j["format"] as? String, "banner")
        XCTAssertEqual(j["sizes"] as? [String], ["320x50"])
        XCTAssertEqual(j["test"] as? Bool, true)
        XCTAssertNil(j["user"], "user id must only be sent for rewarded")

        let d = try XCTUnwrap(j["device"] as? [String: Any])
        XCTAssertEqual(d["os"] as? String, "ios")
        XCTAssertEqual(d["osv"] as? String, "18.2")
        XCTAssertEqual(d["make"] as? String, "Apple")
        XCTAssertEqual(d["model"] as? String, "iPhone16,1")
        XCTAssertEqual(d["ifa"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(d["ifa_type"] as? String, "idfv")
        XCTAssertEqual(d["lmt"] as? Bool, true)
        XCTAssertEqual(d["sdk_id"] as? String, "sdk-uuid")
        XCTAssertEqual(d["lang"] as? String, "tr")
        XCTAssertEqual(d["w"] as? Int, 1179)
        XCTAssertEqual(d["h"] as? Int, 2556)
        XCTAssertEqual(d["pxratio"] as? Double, 3)
        XCTAssertEqual(d["connection"] as? String, "wifi")
        XCTAssertEqual(d["carrier"] as? String, "")
        XCTAssertEqual(d["tz_offset_min"] as? Int, 180)

        let app = try XCTUnwrap(j["app"] as? [String: Any])
        XCTAssertEqual(app["bundle"] as? String, "com.example.app")
        XCTAssertEqual(app["version"] as? String, "1.2.3")
        XCTAssertEqual(app["sdk_version"] as? String, Adfacten.sdkVersion)

        let regs = try XCTUnwrap(j["regs"] as? [String: Any])
        XCTAssertEqual(regs["coppa"] as? Bool, false)
        XCTAssertEqual(regs["gdpr"] as? Int, 1)
        XCTAssertEqual(regs["tcf"] as? String, consent.tcString)
        XCTAssertEqual(regs["gpp"] as? String, "DBABMA~CPX")
        XCTAssertEqual(regs["us_privacy"] as? String, "1YNN")
    }

    func testRewardedRequestCarriesUserAndTruncatesCustom() throws {
        let id = ResolvedIdentity(ifa: "sdk-uuid", ifaType: "sdk", lmt: true)
        let long = String(repeating: "x", count: 400)
        let r = AdRequestBuilder.build(appKey: "apk_x", placement: "plc_r", format: .rewarded, sizes: [],
                                       device: device, identity: id, sdkId: "sdk-uuid", consent: consent, config: config,
                                       userId: "user-7", custom: long)
        let user = try XCTUnwrap(try json(r)["user"] as? [String: Any])
        XCTAssertEqual(user["id"] as? String, "user-7")
        XCTAssertEqual((user["custom"] as? String)?.count, 256)
    }

    func testAppOpenFormatEncodesSnakeCase() throws {
        let id = ResolvedIdentity(ifa: nil, ifaType: "sdk", lmt: true)
        let r = AdRequestBuilder.build(appKey: "apk_x", placement: "p", format: .appOpen, sizes: [], device: device,
                                       identity: id, sdkId: "s", consent: consent, config: config, userId: nil, custom: nil)
        XCTAssertEqual(try json(r)["format"] as? String, "app_open")
    }

    func testChildDirectedSetsCoppa() throws {
        var cfg = config
        cfg.childDirected = true
        let id = IdentityResolver.resolve(status: .authorized, idfa: "AAAAAAAA-1111-2222-3333-444444444444", idfv: "v",
                                          sdkId: "sdk-1", childDirected: true, consent: consent)
        let r = AdRequestBuilder.build(appKey: "apk_x", placement: "p", format: .banner, sizes: [], device: device,
                                       identity: id, sdkId: "sdk-1", consent: consent, config: cfg, userId: nil, custom: nil)
        let j = try json(r)
        XCTAssertEqual((j["regs"] as? [String: Any])?["coppa"] as? Bool, true)
        XCTAssertEqual((j["device"] as? [String: Any])?["ifa_type"] as? String, "sdk")
        XCTAssertEqual((j["device"] as? [String: Any])?["ifa"] as? String, "sdk-1")
    }

    func testUserAgentFormat() {
        let ua = UserAgent.make(sdkVersion: "1.0.0", device: device)
        XCTAssertEqual(ua, "AdfactenSDK/1.0.0 (ios 18.2; iPhone16,1) com.example.app/1.2.3")
        var odd = device
        odd.appVersion = "2.0 (beta; 7)"
        XCTAssertEqual(UserAgent.make(sdkVersion: "1.0.0", device: odd),
                       "AdfactenSDK/1.0.0 (ios 18.2; iPhone16,1) com.example.app/2.0_beta_7")
    }

    // MARK: Identity

    func testIdentityPreferenceOrder() {
        let c = ConsentSnapshot(gdprApplies: 0, tcString: "", gppString: "", usPrivacy: "", purpose1Consent: false)
        let idfa = "AAAAAAAA-1111-2222-3333-444444444444"
        XCTAssertEqual(IdentityResolver.resolve(status: .authorized, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false, consent: c),
                       ResolvedIdentity(ifa: idfa, ifaType: "idfa", lmt: false))
        XCTAssertEqual(IdentityResolver.resolve(status: .denied, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false, consent: c),
                       ResolvedIdentity(ifa: "V", ifaType: "idfv", lmt: true))
        XCTAssertEqual(IdentityResolver.resolve(status: .notDetermined, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false, consent: c),
                       ResolvedIdentity(ifa: "V", ifaType: "idfv", lmt: true))
        // Authorized but zeroed IDFA → IDFV.
        XCTAssertEqual(IdentityResolver.resolve(status: .authorized, idfa: IdentityResolver.zeroUUID, idfv: "V", sdkId: "S",
                                                childDirected: false, consent: c).ifaType, "idfv")
        XCTAssertEqual(IdentityResolver.resolve(status: .denied, idfa: nil, idfv: nil, sdkId: "S", childDirected: false, consent: c),
                       ResolvedIdentity(ifa: "S", ifaType: "sdk", lmt: true))
        // GDPR (even with consent), a GPP string or a US opt-out → no IDFA.
        let gdpr = ConsentSnapshot(gdprApplies: 1, tcString: "x", gppString: "", usPrivacy: "", purpose1Consent: true)
        XCTAssertEqual(IdentityResolver.resolve(status: .authorized, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false, consent: gdpr).ifaType, "idfv")
        let gpp = ConsentSnapshot(gdprApplies: 0, tcString: "", gppString: "DBA", usPrivacy: "", purpose1Consent: false)
        XCTAssertEqual(IdentityResolver.resolve(status: .authorized, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false, consent: gpp).ifaType, "idfv")
        let optOut = ConsentSnapshot(gdprApplies: 0, tcString: "", gppString: "", usPrivacy: "1YYN", purpose1Consent: false)
        XCTAssertEqual(IdentityResolver.resolve(status: .authorized, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false, consent: optOut).ifaType, "idfv")
        let noOptOut = ConsentSnapshot(gdprApplies: 0, tcString: "", gppString: "", usPrivacy: "1YNN", purpose1Consent: false)
        XCTAssertEqual(IdentityResolver.resolve(status: .authorized, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false, consent: noOptOut).ifaType, "idfa")
        // GDPR applies without purpose-1 consent → only the SDK id.
        let noConsent = ConsentSnapshot(gdprApplies: 1, tcString: "x", gppString: "", usPrivacy: "", purpose1Consent: false)
        XCTAssertEqual(IdentityResolver.resolve(status: .authorized, idfa: idfa, idfv: "V", sdkId: "S", childDirected: false,
                                                consent: noConsent).ifaType, "sdk")
    }

    func testConsentReadFromUserDefaults() {
        let d = UserDefaults(suiteName: "adf-consent-\(UUID().uuidString)")!
        XCTAssertEqual(ConsentSnapshot.read(from: d),
                       ConsentSnapshot(gdprApplies: 0, tcString: "", gppString: "", usPrivacy: "", purpose1Consent: false))
        d.set(1, forKey: "IABTCF_gdprApplies")
        d.set("TCSTR", forKey: "IABTCF_TCString")
        d.set("1011", forKey: "IABTCF_PurposeConsents")
        d.set("GPPSTR", forKey: "IABGPP_HDR_GppString")
        d.set("1YYN", forKey: "IABUSPrivacy_String")
        let c = ConsentSnapshot.read(from: d)
        XCTAssertEqual(c, ConsentSnapshot(gdprApplies: 1, tcString: "TCSTR", gppString: "GPPSTR", usPrivacy: "1YYN", purpose1Consent: true))
        XCTAssertFalse(c.forbidsDeviceIdentifiers)
        d.set("0111", forKey: "IABTCF_PurposeConsents")
        XCTAssertTrue(ConsentSnapshot.read(from: d).forbidsDeviceIdentifiers)
        d.set("1", forKey: "IABTCF_gdprApplies") // some CMPs write strings
        XCTAssertEqual(ConsentSnapshot.read(from: d).gdprApplies, 1)
    }

    func testInstallIDIsStable() {
        let d = UserDefaults(suiteName: "adf-id-\(UUID().uuidString)")!
        let a = InstallID.get(d)
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertEqual(InstallID.get(d), a)
        d.set("garbage", forKey: InstallID.key)
        XCTAssertNotEqual(InstallID.get(d), "garbage")
    }

    func testBeaconDecorationKeepsExistingQuery() {
        let u = URL(string: "https://trk.adfacten.com/i?imp=abc%2B1&e=render")!
        let d = u.appendingQuery([("sid", "s-1"), ("ts", "1700000000000")])
        XCTAssertEqual(d.absoluteString, "https://trk.adfacten.com/i?imp=abc%2B1&e=render&sid=s-1&ts=1700000000000")
    }
}
