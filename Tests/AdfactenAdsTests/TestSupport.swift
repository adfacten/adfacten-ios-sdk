import Foundation
import UIKit
import XCTest
@testable import AdfactenAds

/// URLProtocol mock: routes by path, records every request (with its body).
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        var fail: Bool = false
    }

    struct Recorded: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?
    }

    nonisolated(unsafe) private static var _routes: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var _recorded: [Recorded] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _routes = [:]
        _recorded = []
    }

    /// Queue replies for a path; the last one repeats.
    static func route(_ path: String, _ replies: Reply...) {
        lock.lock(); defer { lock.unlock() }
        _routes[path] = replies
    }

    static var recorded: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    static func requests(path: String) -> [Recorded] { recorded.filter { $0.url.path == path } }

    private static func next(for path: String) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        guard var list = _routes[path], !list.isEmpty else { return nil }
        let r = list.first!
        if list.count > 1 { list.removeFirst(); _routes[path] = list }
        return r
    }

    private static func record(_ r: Recorded) {
        lock.lock(); defer { lock.unlock() }
        _recorded.append(r)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            buf.deallocate()
            stream.close()
            body = data
        }
        Self.record(Recorded(url: url, method: request.httpMethod ?? "GET",
                             headers: request.allHTTPHeaderFields ?? [:], body: body))
        guard let reply = Self.next(for: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if reply.fail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TestClock: @unchecked Sendable {
    let box = Locked(Date(timeIntervalSince1970: 1_790_000_000))
    var clock: Clock { let b = box; return Clock(now: { b.get() }) }
    func advance(_ s: TimeInterval) { box.mutate { $0 = $0.addingTimeInterval(s) } }
    var now: Date { box.get() }
}

struct FakeIdentity: IdentitySource {
    var status: TrackingStatus = .denied
    var idfa: String? = "00000000-0000-0000-0000-000000000000"
    var idfv: String? = "11111111-2222-3333-4444-555555555555"
    func trackingStatus() -> TrackingStatus { status }
    func advertisingIdentifier() -> String? { idfa }
    func vendorIdentifier() -> String? { idfv }
}

enum Fixtures {
    static func mockSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("adf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @MainActor
    static func environment(clock: TestClock, identity: FakeIdentity = FakeIdentity(),
                            defaults: UserDefaults? = nil, dir: URL? = nil) -> SDKEnvironment {
        let suite = defaults ?? UserDefaults(suiteName: "adf-test-\(UUID().uuidString)")!
        let storage = dir ?? tempDir()
        return SDKEnvironment(
            sessionConfiguration: {
                let c = URLSessionConfiguration.ephemeral
                c.protocolClasses = [MockURLProtocol.self]
                return c
            },
            defaults: suite,
            clock: clock.clock,
            identity: identity,
            storageDirectory: { storage },
            appIsActive: { true },
            jitter: { 0 }
        )
    }

    static let pngData: Data = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        return r.pngData { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }()

    static func adJSON(format: String = "interstitial", kind: String = "image", id: String = "imp-1",
                       extra: String = "", expiresAt: Int = 1_790_003_300) -> Data {
        """
        {"ad":{"id":"\(id)","format":"\(format)","kind":"\(kind)","w":320,"h":480,
        "image":{"url":"https://cdn.test/a.webp","url_2x":"https://cdn.test/a@2x.webp","fallback":"https://cdn.test/a.jpg"},
        "html":"<!doctype html><html><body style='margin:0;background:#0a0'><a href='https://example.com/land'>Go</a></body></html>",
        "native":{"title":"Başlık","body":"Gövde","brand":"Marka","cta":"Yükle","image":{"url":"https://cdn.test/n.jpg","w":1200,"h":628},"icon":{"url":"https://cdn.test/i.png"}},
        "click_url":"https://trk.test/a/click?imp=\(id)",
        "trackers":{"render":"https://trk.test/i?imp=\(id)&e=render","view":"https://trk.test/i?imp=\(id)&e=view",
        "complete":"https://trk.test/i?imp=\(id)&e=complete","close":"https://trk.test/i?imp=\(id)&e=close"},
        "view_rule":{"min_ratio":0.5,"min_ms":1000},"close_after_s":0,"reward":{"type":"coins","amount":10},
        "label":"Reklam","expires_at":\(expiresAt)\(extra)}}
        """.data(using: .utf8)!
    }

    static let httpDate = "Mon, 21 Sep 2026 14:13:20 GMT" // == 1_790_000_000
}

extension XCTestCase {
    /// Polls `condition` on the main actor until it is true or the timeout passes.
    @MainActor
    func waitUntil(_ timeout: TimeInterval = 5, _ message: String = "condition",
                   file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(message)", file: file, line: line)
    }
}
