import XCTest
@testable import AdfactenAds

final class VASTTests: XCTestCase {
    static let inline = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.1">
      <Ad id="wrap-1"><Wrapper><VASTAdTagURI><![CDATA[https://other/vast]]></VASTAdTagURI></Wrapper></Ad>
      <Ad id="ad-42">
        <InLine>
          <AdSystem>Adfacten</AdSystem>
          <Impression><![CDATA[https://trk.test/vast/imp?c=[CACHEBUSTING]]]></Impression>
          <Impression>https://third.test/imp</Impression>
          <Error><![CDATA[https://trk.test/vast/err?code=[ERRORCODE]]]></Error>
          <Creatives>
            <Creative>
              <Linear skipoffset="00:00:05">
                <Duration>00:00:15.500</Duration>
                <TrackingEvents>
                  <Tracking event="start"><![CDATA[https://trk.test/v?e=start]]></Tracking>
                  <Tracking event="firstQuartile">https://trk.test/v?e=q1</Tracking>
                  <Tracking event="midpoint">https://trk.test/v?e=mid</Tracking>
                  <Tracking event="thirdQuartile">https://trk.test/v?e=q3</Tracking>
                  <Tracking event="complete">https://trk.test/v?e=complete</Tracking>
                  <Tracking event="progress" offset="00:00:10">https://trk.test/v?e=p10</Tracking>
                  <Tracking event="progress" offset="50%">https://trk.test/v?e=p50</Tracking>
                  <Tracking event="close">https://trk.test/v?e=close</Tracking>
                </TrackingEvents>
                <VideoClicks>
                  <ClickThrough><![CDATA[https://landing.test/]]></ClickThrough>
                  <ClickTracking>https://trk.test/v?e=click</ClickTracking>
                </VideoClicks>
                <MediaFiles>
                  <MediaFile delivery="progressive" type="video/mp4" width="1920" height="1080" bitrate="6000"><![CDATA[https://cdn.test/1080.mp4]]></MediaFile>
                  <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000"><![CDATA[https://cdn.test/720.mp4]]></MediaFile>
                  <MediaFile delivery="progressive" type="video/mp4" width="640" height="360" bitrate="700"><![CDATA[https://cdn.test/360.mp4]]></MediaFile>
                  <MediaFile delivery="streaming" type="application/x-mpegURL" width="1920" height="1080"><![CDATA[https://cdn.test/master.m3u8]]></MediaFile>
                  <MediaFile delivery="progressive" type="application/javascript" apiFramework="VPAID" width="640" height="360"><![CDATA[https://cdn.test/vpaid.js]]></MediaFile>
                  <MediaFile delivery="progressive" type="video/webm" width="1280" height="720"><![CDATA[https://cdn.test/720.webm]]></MediaFile>
                </MediaFiles>
              </Linear>
            </Creative>
            <Creative>
              <Linear><Duration>00:00:30</Duration><MediaFiles><MediaFile type="video/mp4" width="1" height="1">https://cdn.test/second.mp4</MediaFile></MediaFiles></Linear>
            </Creative>
            <Creative><CompanionAds><Companion><TrackingEvents><Tracking event="creativeView">https://trk.test/companion</Tracking></TrackingEvents></Companion></CompanionAds></Creative>
          </Creatives>
        </InLine>
      </Ad>
    </VAST>
    """

    func testParsesInlineLinear() throws {
        let ad = try VASTParser.parse(Self.inline)
        XCTAssertEqual(ad.adId, "ad-42")
        XCTAssertEqual(ad.duration, 15.5)
        XCTAssertEqual(ad.skipOffset, "00:00:05")
        XCTAssertEqual(ad.impressions.count, 2)
        XCTAssertEqual(ad.impressions.last?.absoluteString, "https://third.test/imp")
        XCTAssertEqual(ad.errors, ["https://trk.test/vast/err?code=[ERRORCODE]"])
        XCTAssertEqual(ad.trackers(for: "start").map(\.absoluteString), ["https://trk.test/v?e=start"])
        XCTAssertEqual(ad.trackers(for: "complete").count, 1)
        XCTAssertEqual(ad.trackers(for: "creativeView").count, 0, "companion tracking is not linear tracking")
        let progress = ad.tracking.filter { $0.event == "progress" }
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(progress[0].offset, 10)
        XCTAssertFalse(progress[0].isFraction)
        XCTAssertEqual(progress[1].offset, 0.5)
        XCTAssertTrue(progress[1].isFraction)
        XCTAssertEqual(ad.clickThrough?.absoluteString, "https://landing.test/")
        XCTAssertEqual(ad.clickTracking.map(\.absoluteString), ["https://trk.test/v?e=click"])
        // VPAID and webm dropped; only the first Linear creative is used.
        XCTAssertEqual(ad.mediaFiles.count, 4)
        XCTAssertFalse(ad.mediaFiles.contains { $0.url.absoluteString.contains("second") })
    }

    func testURLWithBracketMacrosParses() throws {
        // Brackets aren't valid URL characters; Foundation must still give us a URL.
        let ad = try VASTParser.parse(Self.inline)
        let first = try XCTUnwrap(ad.impressions.first)
        let expanded = VASTMacros.expand(first).absoluteString
        XCTAssertTrue(expanded.hasPrefix("https://trk.test/vast/imp?c="), expanded)
        XCTAssertFalse(expanded.contains("CACHEBUSTING"), expanded)
    }

    func testErrorsForUnusableDocuments() {
        XCTAssertThrowsError(try VASTParser.parse("not xml at all <")) { XCTAssertEqual($0 as? VASTError, .malformed) }
        XCTAssertThrowsError(try VASTParser.parse(#"<VAST version="4.0"><Error>https://e</Error></VAST>"#)) {
            XCTAssertEqual($0 as? VASTError, .noAd)
        }
        XCTAssertThrowsError(try VASTParser.parse(#"<VAST><Ad><Wrapper><VASTAdTagURI>https://x</VASTAdTagURI></Wrapper></Ad></VAST>"#)) {
            XCTAssertEqual($0 as? VASTError, .wrapperUnsupported)
        }
        XCTAssertThrowsError(try VASTParser.parse(#"<VAST><Ad><InLine><Creatives><Creative><NonLinearAds/></Creative></Creatives></InLine></Ad></VAST>"#)) {
            XCTAssertEqual($0 as? VASTError, .noLinear)
        }
        let onlyVPAID = #"<VAST><Ad><InLine><Creatives><Creative><Linear><MediaFiles><MediaFile type="application/javascript" apiFramework="VPAID">https://x.js</MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>"#
        XCTAssertThrowsError(try VASTParser.parse(onlyVPAID)) { XCTAssertEqual($0 as? VASTError, .noPlayableMedia) }
    }

    func testTimeParsing() {
        XCTAssertEqual(VASTParser.parseTime("00:00:15"), 15)
        XCTAssertEqual(VASTParser.parseTime("01:02:03.250"), 3723.25)
        XCTAssertNil(VASTParser.parseTime("15"))
        XCTAssertEqual(VASTParser.parseOffset("25%")?.0, 0.25)
        XCTAssertEqual(VASTParser.parseOffset("00:00:05")?.0, 5)
        XCTAssertNil(VASTParser.parseOffset("soon"))
    }

    func testMediaSelection() throws {
        let files = try VASTParser.parse(Self.inline).mediaFiles
        // iPhone portrait 1179x2556 on wifi → 1080p progressive (within 8 Mbps).
        XCTAssertEqual(MediaSelector.select(files, screenPx: (1179, 2556), connection: "wifi")?.url.lastPathComponent, "1080.mp4")
        // Cellular caps at 2.5 Mbps → 720p.
        XCTAssertEqual(MediaSelector.select(files, screenPx: (1179, 2556), connection: "cellular")?.url.lastPathComponent, "720.mp4")
        // A small screen prefers the small file.
        XCTAssertEqual(MediaSelector.select(files, screenPx: (640, 360), connection: "wifi")?.url.lastPathComponent, "360.mp4")
        // Only HLS available → HLS.
        let hls = files.filter { $0.delivery == "streaming" }
        XCTAssertEqual(MediaSelector.select(hls, screenPx: (1179, 2556), connection: "wifi")?.url.pathExtension, "m3u8")
        XCTAssertNil(MediaSelector.select([], screenPx: (1, 1), connection: "wifi"))
    }

    func testMacroExpansion() {
        let u = URL(string: "https://trk.test/err?code=[ERRORCODE]&t=[TIMESTAMP]&cb=[CACHEBUSTING]&p=[ADPLAYHEAD]")!
        let out = VASTMacros.expand(u, errorCode: 405, playhead: 75.5, now: Date(timeIntervalSince1970: 0)).absoluteString
        XCTAssertTrue(out.contains("code=405"), out)
        XCTAssertTrue(out.contains("t=1970-01-01T00"), out)
        XCTAssertTrue(out.contains("p=00:01:15.500"), out)
        XCTAssertFalse(out.contains("["), out)
    }
}
