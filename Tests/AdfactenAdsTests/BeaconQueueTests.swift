import XCTest
@testable import AdfactenAds

final class BeaconQueueTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    private func url(_ e: String) -> URL { URL(string: "https://trk.test/i?imp=abc&e=\(e)")! }

    func testRetryDelaySchedule() {
        XCTAssertEqual(BeaconQueue.retryDelay(attempts: 1, jitter: 0), 10)
        XCTAssertEqual(BeaconQueue.retryDelay(attempts: 2, jitter: 0), 20)
        XCTAssertEqual(BeaconQueue.retryDelay(attempts: 20, jitter: 0), 3600)
        XCTAssertEqual(BeaconQueue.retryDelay(attempts: 1, jitter: 1), 12)
    }

    func testStatusClassification() {
        XCTAssertEqual(BeaconQueue.classify(status: 204), .done)
        XCTAssertEqual(BeaconQueue.classify(status: 302), .done)
        XCTAssertEqual(BeaconQueue.classify(status: 400), .drop(400))
        XCTAssertEqual(BeaconQueue.classify(status: 429), .retry)
        XCTAssertEqual(BeaconQueue.classify(status: 503), .retry)
    }

    func testFiresOnceAndDedupes() async {
        MockURLProtocol.route("/i", .init(status: 204))
        let q = BeaconQueue(fileURL: nil, session: Fixtures.mockSession(), clock: TestClock().clock, jitter: { 0 })
        let first = await q.enqueue(key: "abc|render", url: url("render"))
        let dup = await q.enqueue(key: "abc|render", url: url("render"))
        XCTAssertTrue(first)
        XCTAssertFalse(dup)
        XCTAssertEqual(MockURLProtocol.requests(path: "/i").count, 1)
        let pending = await q.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testRetriesThenSucceeds() async {
        MockURLProtocol.route("/i", .init(status: 503), .init(status: 0, fail: true), .init(status: 204))
        let clock = TestClock()
        let q = BeaconQueue(fileURL: nil, session: Fixtures.mockSession(), clock: clock.clock, jitter: { 0 })
        await q.enqueue(key: "abc|view", url: url("view"))
        var pending = await q.pending()
        XCTAssertEqual(pending.first?.attempts, 1)
        XCTAssertEqual(pending.first?.next ?? 0, clock.now.timeIntervalSince1970 + 10, accuracy: 0.01)

        await q.flush() // not due yet
        XCTAssertEqual(MockURLProtocol.requests(path: "/i").count, 1)

        clock.advance(10)
        await q.flush() // network error → retry in 20 s
        pending = await q.pending()
        XCTAssertEqual(pending.first?.attempts, 2)

        clock.advance(20)
        await q.flush()
        pending = await q.pending()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(MockURLProtocol.requests(path: "/i").count, 3)
    }

    func testClientErrorDrops() async {
        MockURLProtocol.route("/i", .init(status: 400))
        let q = BeaconQueue(fileURL: nil, session: Fixtures.mockSession(), clock: TestClock().clock, jitter: { 0 })
        await q.enqueue(key: "abc|close", url: url("close"))
        let pending = await q.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testGivesUpAfter24Hours() async {
        MockURLProtocol.route("/i", .init(status: 500))
        let clock = TestClock()
        let q = BeaconQueue(fileURL: nil, session: Fixtures.mockSession(), clock: clock.clock, jitter: { 0 })
        await q.enqueue(key: "abc|render", url: url("render"))
        clock.advance(23 * 3600)
        await q.flush()
        var pending = await q.pending()
        XCTAssertEqual(pending.count, 1, "still retrying inside 24 h")
        clock.advance(2 * 3600)
        await q.flush()
        pending = await q.pending()
        XCTAssertTrue(pending.isEmpty, "dropped after 24 h")
        let fired = await q.hasFired("abc|render")
        XCTAssertTrue(fired, "still deduped so it can't be re-sent")
    }

    func testPersistsAcrossLaunches() async throws {
        MockURLProtocol.route("/i", .init(status: 0, fail: true))
        let file = Fixtures.tempDir().appendingPathComponent("q/beacons.json")
        let clock = TestClock()
        do {
            let q = BeaconQueue(fileURL: file, session: Fixtures.mockSession(), clock: clock.clock, jitter: { 0 })
            await q.enqueue(key: "abc|render", url: url("render"))
            await q.enqueue(key: "abc|view", url: url("view"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let excluded = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)

        // "Relaunch": a new queue reads the file and delivers once the network is back.
        MockURLProtocol.route("/i", .init(status: 204))
        let q2 = BeaconQueue(fileURL: file, session: Fixtures.mockSession(), clock: clock.clock, jitter: { 0 })
        var pending = await q2.pending()
        XCTAssertEqual(Set(pending.map(\.key)), ["abc|render", "abc|view"])
        let dup = await q2.enqueue(key: "abc|render", url: url("render"))
        XCTAssertFalse(dup, "dedupe survives relaunch")
        clock.advance(30)
        await q2.flush()
        pending = await q2.pending()
        XCTAssertTrue(pending.isEmpty)
    }
}
