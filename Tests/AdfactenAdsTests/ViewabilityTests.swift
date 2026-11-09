import UIKit
import XCTest
@testable import AdfactenAds

final class VisibilityMathTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 390, height: 844)

    func testGeometricRatio() {
        XCTAssertEqual(Visibility.geometricRatio(rect: CGRect(x: 35, y: 100, width: 320, height: 50), clips: [], bounds: screen), 1)
        // Half below the bottom edge.
        XCTAssertEqual(Visibility.geometricRatio(rect: CGRect(x: 35, y: 819, width: 320, height: 50), clips: [], bounds: screen), 0.5, accuracy: 0.0001)
        // Fully off screen.
        XCTAssertEqual(Visibility.geometricRatio(rect: CGRect(x: 35, y: 900, width: 320, height: 50), clips: [], bounds: screen), 0)
        // Clipped by a scroll view that shows only its top 20 pt.
        let scroll = CGRect(x: 0, y: 0, width: 390, height: 120)
        XCTAssertEqual(Visibility.geometricRatio(rect: CGRect(x: 35, y: 100, width: 320, height: 50), clips: [scroll], bounds: screen), 0.4, accuracy: 0.0001)
        // Zero-size view.
        XCTAssertEqual(Visibility.geometricRatio(rect: CGRect(x: 0, y: 0, width: 0, height: 50), clips: [], bounds: screen), 0)
    }

    func testOcclusionCombination() {
        XCTAssertEqual(Visibility.combined(geometric: 1, unoccludedSamples: 9, totalSamples: 9), 1)
        XCTAssertEqual(Visibility.combined(geometric: 1, unoccludedSamples: 3, totalSamples: 9), 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(Visibility.combined(geometric: 0.8, unoccludedSamples: 0, totalSamples: 9), 0)
        XCTAssertEqual(Visibility.samplePoints(in: CGRect(x: 0, y: 0, width: 100, height: 100)).count, 9)
    }

    func testViewRuleNeedsContinuousTime() {
        var r = ViewRuleState(minRatio: 0.5, minMs: 1000)
        for _ in 0..<9 { XCTAssertFalse(r.tick(ratio: 0.6, deltaMs: 100, active: true)) }
        // Dropping below 50 % resets the clock.
        XCTAssertFalse(r.tick(ratio: 0.49, deltaMs: 100, active: true))
        XCTAssertEqual(r.accumulatedMs, 0)
        for _ in 0..<9 { XCTAssertFalse(r.tick(ratio: 1, deltaMs: 100, active: true)) }
        XCTAssertTrue(r.tick(ratio: 1, deltaMs: 100, active: true), "fires at 1000 ms")
        XCTAssertFalse(r.tick(ratio: 1, deltaMs: 100, active: true), "fires once")
    }

    func testViewRuleIgnoresInactiveAppAndClockJumps() {
        var r = ViewRuleState(minRatio: 0.5, minMs: 1000)
        XCTAssertFalse(r.tick(ratio: 1, deltaMs: 5000, active: true), "one stalled tick can't satisfy the rule")
        XCTAssertEqual(r.accumulatedMs, 250)
        XCTAssertFalse(r.tick(ratio: 1, deltaMs: 100, active: false))
        XCTAssertEqual(r.accumulatedMs, 0, "backgrounded app resets")
    }
}

@MainActor
final class VisibilityMeasureTests: XCTestCase {
    var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.isHidden = false
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    func testMeasureOnScreenHiddenAndDetached() {
        let root = window.rootViewController!.view!
        let v = UIView(frame: CGRect(x: 35, y: 100, width: 320, height: 50))
        XCTAssertEqual(Visibility.measure(v), 0, "not in a window")
        root.addSubview(v)
        XCTAssertEqual(Visibility.measure(v), 1, accuracy: 0.001)
        v.isHidden = true
        XCTAssertEqual(Visibility.measure(v), 0)
        v.isHidden = false
        root.alpha = 0
        XCTAssertEqual(Visibility.measure(v), 0, "transparent ancestor")
        root.alpha = 1
        v.frame.origin.y = 819
        XCTAssertEqual(Visibility.measure(v), 0.5, accuracy: 0.001)
    }

    func testMeasureClippedByScrollView() {
        let root = window.rootViewController!.view!
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        scroll.contentSize = CGSize(width: 390, height: 2000)
        scroll.contentInsetAdjustmentBehavior = .never
        root.addSubview(scroll)
        let v = UIView(frame: CGRect(x: 35, y: 250, width: 320, height: 100))
        scroll.addSubview(v)
        XCTAssertEqual(Visibility.measure(v), 0.5, accuracy: 0.001)
        scroll.contentOffset = CGPoint(x: 0, y: 400)
        XCTAssertEqual(Visibility.measure(v), 0)
    }

    func testMeasureOccludedByOverlay() {
        let root = window.rootViewController!.view!
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        root.addSubview(v)
        let cover = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        root.addSubview(cover)
        XCTAssertEqual(Visibility.measure(v), 0, "a view on top hides the ad")
        cover.frame = CGRect(x: 0, y: 0, width: 300, height: 100) // covers the top row of samples
        XCTAssertEqual(Visibility.measure(v), 6.0 / 9, accuracy: 0.001)
    }
}
