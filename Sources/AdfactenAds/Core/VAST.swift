import Foundation

/// The parts of a VAST 2–4 InLine linear ad the SDK plays.
struct VASTAd: Sendable, Equatable {
    struct MediaFile: Sendable, Equatable {
        var url: URL
        var type: String
        var width: Int
        var height: Int
        var bitrate: Int?
        var delivery: String
        var apiFramework: String?
    }

    struct Tracking: Sendable, Equatable {
        var event: String
        var url: URL
        /// For `progress` events: seconds, or a fraction (0…1) of the duration when `isFraction`.
        var offset: Double?
        var isFraction: Bool = false
    }

    var adId: String?
    var duration: TimeInterval?
    var skipOffset: String?
    var impressions: [URL] = []
    var errors: [String] = []
    var mediaFiles: [MediaFile] = []
    var tracking: [Tracking] = []
    var clickThrough: URL?
    var clickTracking: [URL] = []

    func trackers(for event: String) -> [URL] {
        tracking.filter { $0.event == event }.map(\.url)
    }
}

enum VASTError: Error, Equatable {
    case malformed
    case noAd
    case wrapperUnsupported
    case noLinear
    case noPlayableMedia
}

enum VASTParser {
    static func parse(_ xml: String) throws -> VASTAd {
        guard let data = xml.data(using: .utf8) else { throw VASTError.malformed }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let error = delegate.failure { throw error }
        guard ok, delegate.sawRoot else { throw VASTError.malformed }
        if delegate.sawWrapper && !delegate.sawInline { throw VASTError.wrapperUnsupported }
        guard delegate.sawInline else { throw VASTError.noAd }
        guard delegate.sawLinear else { throw VASTError.noLinear }
        var ad = delegate.ad
        ad.mediaFiles = ad.mediaFiles.filter { MediaSelector.isPlayable($0) }
        guard !ad.mediaFiles.isEmpty else { throw VASTError.noPlayableMedia }
        return ad
    }

    /// `HH:MM:SS(.mmm)` → seconds.
    static func parseTime(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + sec
    }

    /// Offsets are either a time or a percentage ("25%").
    static func parseOffset(_ s: String) -> (Double, Bool)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("%"), let p = Double(t.dropLast()) { return (min(max(p, 0), 100) / 100, true) }
        if let secs = parseTime(t) { return (secs, false) }
        return nil
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var ad = VASTAd()
        var failure: VASTError?
        var sawRoot = false
        var sawInline = false
        var sawWrapper = false
        var sawLinear = false

        private var stack: [String] = []
        private var text = ""
        private var attrs: [[String: String]] = []
        /// Only the first <Ad> that has an <InLine>, and its first Linear creative, are used.
        private var inAd = false
        private var inlineActive = false
        private var locked = false
        private var linearDone = false
        private var inLinear = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(name)
            attrs.append(attributes)
            text = ""
            switch name {
            case "VAST": sawRoot = true
            case "Ad":
                inAd = true
                if !locked { ad = VASTAd(); ad.adId = attributes["id"]; linearDone = false }
            case "InLine":
                if inAd && !locked { sawInline = true; inlineActive = true }
            case "Wrapper": sawWrapper = true
            case "Linear":
                if inlineActive && !linearDone {
                    inLinear = true
                    sawLinear = true
                    ad.skipOffset = attributes["skipoffset"]
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = attrs.last ?? [:]
            defer {
                if !stack.isEmpty { stack.removeLast() }
                if !attrs.isEmpty { attrs.removeLast() }
                text = ""
            }
            if name == "Ad" {
                if inlineActive { locked = true; inlineActive = false }
                inAd = false
                return
            }
            guard inlineActive else { return }
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""

            switch name {
            case "Impression":
                if let u = URL(string: value), !value.isEmpty { ad.impressions.append(u) }
            case "Error":
                if !value.isEmpty { ad.errors.append(value) }
            case "Linear":
                if inLinear { inLinear = false; linearDone = true }
            case "Duration" where inLinear:
                ad.duration = VASTParser.parseTime(value)
            case "MediaFile" where inLinear:
                guard let u = URL(string: value), !value.isEmpty else { break }
                ad.mediaFiles.append(.init(
                    url: u,
                    type: (a["type"] ?? "").lowercased(),
                    width: Int(a["width"] ?? "") ?? 0,
                    height: Int(a["height"] ?? "") ?? 0,
                    bitrate: Int(a["bitrate"] ?? "") ?? Int(a["maxBitrate"] ?? ""),
                    delivery: (a["delivery"] ?? "progressive").lowercased(),
                    apiFramework: a["apiFramework"]
                ))
            case "Tracking" where inLinear && parent == "TrackingEvents":
                guard let event = a["event"], let u = URL(string: value), !value.isEmpty else { break }
                var t = VASTAd.Tracking(event: event, url: u)
                if let off = a["offset"], let parsed = VASTParser.parseOffset(off) {
                    t.offset = parsed.0
                    t.isFraction = parsed.1
                }
                ad.tracking.append(t)
            case "ClickThrough" where inLinear:
                ad.clickThrough = URL(string: value)
            case "ClickTracking" where inLinear:
                if let u = URL(string: value), !value.isEmpty { ad.clickTracking.append(u) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if failure == nil { failure = .malformed }
        }
    }
}

enum MediaSelector {
    static let playableTypes: Set<String> = [
        "video/mp4", "video/quicktime", "video/x-m4v", "video/3gpp",
        "application/x-mpegurl", "application/vnd.apple.mpegurl",
    ]

    static func isPlayable(_ m: VASTAd.MediaFile) -> Bool {
        if let api = m.apiFramework?.lowercased(), api.contains("vpaid") { return false }
        return playableTypes.contains(m.type)
    }

    /// Picks the file closest in size to the screen, within a bitrate cap for the connection
    /// (cellular 2.5 Mbps, otherwise 8 Mbps). HLS is used only when no progressive file fits.
    static func select(_ files: [VASTAd.MediaFile], screenPx: (w: Int, h: Int), connection: String) -> VASTAd.MediaFile? {
        let playable = files.filter(isPlayable)
        guard !playable.isEmpty else { return nil }
        let cap = connection == "cellular" ? 2500 : 8000
        let progressive = playable.filter { $0.delivery == "progressive" }
        let pool0 = progressive.isEmpty ? playable : progressive
        let capped = pool0.filter { ($0.bitrate ?? 0) <= cap }
        let pool = capped.isEmpty ? pool0 : capped
        let target = Double(max(1, screenPx.w) * max(1, screenPx.h))
        return pool.min { score($0, target) < score($1, target) }
    }

    private static func score(_ m: VASTAd.MediaFile, _ target: Double) -> Double {
        let area = Double(max(1, m.width) * max(1, m.height))
        // Distance on a log scale; upscaling is penalised a bit more than downscaling.
        let d = log(area / target)
        return d < 0 ? -d * 1.5 : d
    }
}

enum VASTMacros {
    static func expand(_ url: URL, errorCode: Int? = nil, playhead: TimeInterval? = nil, now: Date = Date()) -> URL {
        var s = url.absoluteString
        guard s.contains("[") || s.contains("%5B") else { return url }
        let iso = ISO8601DateFormatter().string(from: now)
        let ts = iso.addingPercentEncoding(withAllowedCharacters: .adfQueryValue) ?? iso
        let buster = String(Int.random(in: 10_000_000...99_999_999))
        var map: [String: String] = ["TIMESTAMP": ts, "CACHEBUSTING": buster]
        if let errorCode { map["ERRORCODE"] = String(errorCode) }
        if let playhead {
            let h = Int(playhead) / 3600, m = (Int(playhead) % 3600) / 60
            let sec = playhead - Double(h * 3600 + m * 60)
            map["ADPLAYHEAD"] = String(format: "%02d:%02d:%06.3f", h, m, sec)
            map["CONTENTPLAYHEAD"] = map["ADPLAYHEAD"]
        }
        for (k, v) in map {
            s = s.replacingOccurrences(of: "[\(k)]", with: v)
            s = s.replacingOccurrences(of: "%5B\(k)%5D", with: v)
        }
        return URL(string: s) ?? url
    }
}
