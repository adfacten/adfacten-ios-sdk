import Foundation
import os.log

/// A tiny lock-protected box. Used for the few values that are read from several threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Log verbosity of the SDK. The default is `.warning`.
@objc(ADFLogLevel)
public enum AdfactenLogLevel: Int, Sendable {
    case none = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
}

enum Log {
    static let level = Locked<AdfactenLogLevel>(.warning)
    private static let osLog = OSLog(subsystem: "com.adfacten.ads", category: "AdfactenAds")

    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }
    static func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }

    private static func write(_ lvl: AdfactenLogLevel, _ message: @autoclosure () -> String) {
        guard lvl.rawValue <= level.get().rawValue, lvl != .none else { return }
        let type: OSLogType
        switch lvl {
        case .error: type = .error
        case .warning: type = .default
        case .info: type = .info
        default: type = .debug
        }
        os_log("%{public}@", log: osLog, type: type, "[Adfacten] " + message())
    }
}

/// Injectable time source so tests can move the clock.
struct Clock: Sendable {
    var now: @Sendable () -> Date
    static let system = Clock(now: { Date() })
}

extension URLSession {
    /// Callback-based `dataTask` wrapper returning the HTTP response.
    /// Requests without their own User-Agent get the session's one plus the current wrapper, so
    /// `Adfacten.setWrapper` also applies after `initialize`.
    func adfData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil, let wrapper = Adfacten.wrapper,
           let base = configuration.httpAdditionalHeaders?["User-Agent"] as? String {
            request.setValue(base + wrapper.userAgentSuffix, forHTTPHeaderField: "User-Agent")
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    cont.resume(returning: (data ?? Data(), http))
                } else {
                    cont.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}

extension URL {
    /// Appends query items without touching (or re-encoding) the existing query.
    func appendingQuery(_ items: [(String, String)]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var existing = comps.percentEncodedQueryItems ?? []
        for (name, value) in items {
            let enc = value.addingPercentEncoding(withAllowedCharacters: .adfQueryValue) ?? value
            existing.append(URLQueryItem(name: name, value: enc))
        }
        comps.percentEncodedQueryItems = existing
        return comps.url ?? self
    }
}

extension CharacterSet {
    static let adfQueryValue: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}
