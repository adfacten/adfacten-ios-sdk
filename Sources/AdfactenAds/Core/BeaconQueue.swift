import Foundation

/// Fires tracking URLs at most once each, persists unsent ones to a small file and retries them
/// with exponential backoff for up to 24 hours.
actor BeaconQueue {
    struct Item: Codable, Equatable, Sendable {
        var key: String
        var url: String
        var created: Double
        var attempts: Int
        var next: Double
    }

    private struct State: Codable {
        var items: [Item] = []
        /// Dedupe keys → time first fired. Kept 48 h, so a beacon can never fire twice.
        var fired: [String: Double] = [:]
    }

    static let maxAge: TimeInterval = 24 * 3600
    static let dedupeAge: TimeInterval = 48 * 3600
    static let maxItems = 500
    static let maxFiredKeys = 5000

    private var state = State()
    private var inFlight = Set<String>()
    private var wakeTask: Task<Void, Never>?
    private let fileURL: URL?
    private let session: URLSession
    private let clock: Clock
    private let jitter: @Sendable () -> Double

    init(fileURL: URL?, session: URLSession, clock: Clock, jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.fileURL = fileURL
        self.session = session
        self.clock = clock
        self.jitter = jitter
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    /// Retry delay after `attempts` failed sends: 10 s, 20 s, 40 s … capped at 1 h, +0–20 % jitter.
    static func retryDelay(attempts: Int, jitter: Double) -> TimeInterval {
        let base = min(10 * pow(2, Double(max(0, attempts - 1))), 3600)
        return base * (1 + 0.2 * min(max(jitter, 0), 1))
    }

    /// Queues `url` under `key` and tries to send it immediately. Returns false for a duplicate.
    @discardableResult
    func enqueue(key: String, url: URL) async -> Bool {
        let now = clock.now().timeIntervalSince1970
        prune(now: now)
        guard state.fired[key] == nil else {
            Log.debug("beacon \(key) already fired; skipped")
            return false
        }
        state.fired[key] = now
        state.items.append(Item(key: key, url: url.absoluteString, created: now, attempts: 0, next: now))
        if state.items.count > Self.maxItems {
            state.items.removeFirst(state.items.count - Self.maxItems)
        }
        persist()
        await flush()
        return true
    }

    func hasFired(_ key: String) -> Bool { state.fired[key] != nil }
    func pending() -> [Item] { state.items }

    /// Sends every due item. Safe to call often (app became active, network back, timers).
    func flush() async {
        let now = clock.now().timeIntervalSince1970
        prune(now: now)
        let due = state.items.filter { $0.next <= now && !inFlight.contains($0.key) }
        guard !due.isEmpty else { scheduleWake(); return }
        for item in due { inFlight.insert(item.key) }

        let session = self.session
        let results = await withTaskGroup(of: (String, Outcome).self) { group -> [(String, Outcome)] in
            for item in due {
                group.addTask { (item.key, await Self.send(item, session: session)) }
            }
            var out: [(String, Outcome)] = []
            for await r in group { out.append(r) }
            return out
        }

        let after = clock.now().timeIntervalSince1970
        for (key, outcome) in results {
            inFlight.remove(key)
            guard let idx = state.items.firstIndex(where: { $0.key == key }) else { continue }
            switch outcome {
            case .done:
                state.items.remove(at: idx)
            case .drop(let status):
                Log.warning("beacon \(key) rejected with HTTP \(status); dropped")
                state.items.remove(at: idx)
            case .retry:
                state.items[idx].attempts += 1
                state.items[idx].next = after + Self.retryDelay(attempts: state.items[idx].attempts, jitter: jitter())
            }
        }
        persist()
        scheduleWake()
    }

    enum Outcome: Sendable, Equatable { case done, drop(Int), retry }

    private static func send(_ item: Item, session: URLSession) async -> Outcome {
        guard let url = URL(string: item.url) else { return .drop(0) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        do {
            let (_, http) = try await session.adfData(for: req)
            return classify(status: http.statusCode)
        } catch {
            return .retry
        }
    }

    static func classify(status: Int) -> Outcome {
        switch status {
        case 200..<400: return .done
        case 408, 425, 429: return .retry
        case 400..<500: return .drop(status)
        default: return .retry
        }
    }

    private func prune(now: Double) {
        let before = state.items.count
        state.items.removeAll { now - $0.created > Self.maxAge }
        if state.items.count != before {
            Log.warning("dropped \(before - state.items.count) beacon(s) older than 24 h")
        }
        if state.fired.count > 64 || state.fired.values.contains(where: { now - $0 > Self.dedupeAge }) {
            state.fired = state.fired.filter { now - $0.value <= Self.dedupeAge }
            if state.fired.count > Self.maxFiredKeys {
                let sorted = state.fired.sorted { $0.value > $1.value }.prefix(Self.maxFiredKeys)
                state.fired = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
            }
        }
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        guard let next = state.items.filter({ !inFlight.contains($0.key) }).map(\.next).min() else { return }
        let delay = max(1, next - clock.now().timeIntervalSince1970)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableDir = dir
                try? mutableDir.setResourceValues(values)
            }
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.warning("could not persist beacon queue: \(error.localizedDescription)")
        }
    }
}
