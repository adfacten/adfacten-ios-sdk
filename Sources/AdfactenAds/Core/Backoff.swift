import Foundation

/// Per-placement backoff after a no-fill or a failed request (at least 30 s, with jitter).
/// While a placement backs off, loads fail fast with `.noFill` and nothing goes on the network.
actor PlacementBackoff {
    private var failures: [String: Int] = [:]
    private var until: [String: Date] = [:]
    private let clock: Clock
    private let jitter: @Sendable () -> Double

    init(clock: Clock, jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.clock = clock
        self.jitter = jitter
    }

    /// 30 s, 60 s, 120 s, 240 s, then 300 s; each +0–25 % jitter so devices don't sync up.
    static func delay(failures: Int, jitter: Double) -> TimeInterval {
        let n = max(1, failures)
        let base = min(30 * pow(2, Double(n - 1)), 300)
        return base * (1 + 0.25 * min(max(jitter, 0), 1))
    }

    /// Seconds left before the placement may hit the network again, or nil.
    func remaining(_ placement: String) -> TimeInterval? {
        guard let end = until[placement] else { return nil }
        let left = end.timeIntervalSince(clock.now())
        return left > 0 ? left : nil
    }

    func recordFailure(_ placement: String) {
        let n = (failures[placement] ?? 0) + 1
        failures[placement] = n
        until[placement] = clock.now().addingTimeInterval(Self.delay(failures: n, jitter: jitter()))
    }

    func recordSuccess(_ placement: String) {
        failures[placement] = nil
        until[placement] = nil
    }
}

enum Expiry {
    static let defaultTTL: TimeInterval = 55 * 60
    static let maxTTL: TimeInterval = 2 * 3600

    /// Converts the server's `expires_at` into a device-clock deadline. The server's `Date` header
    /// removes device clock skew; without it a non-positive TTL is treated as skew, not as expired.
    static func localDeadline(expiresAt: Double?, serverDate: Date?, now: Date) -> Date {
        guard let expiresAt, expiresAt > 0 else { return now.addingTimeInterval(defaultTTL) }
        let reference = serverDate ?? now
        var ttl = expiresAt - reference.timeIntervalSince1970
        if ttl <= 0 {
            ttl = serverDate == nil ? defaultTTL - 5 * 60 : 0
        }
        return now.addingTimeInterval(min(ttl, maxTTL))
    }

    static func parseHTTPDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return fmt.date(from: value)
    }
}
