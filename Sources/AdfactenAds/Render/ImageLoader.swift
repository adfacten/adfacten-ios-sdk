import UIKit

/// Downloads and decodes creative images, with a small in-memory cache.
final class ImageLoader: @unchecked Sendable {
    private let session: URLSession
    private let cache = NSCache<NSURL, UIImage>()

    init(session: URLSession) {
        self.session = session
        cache.countLimit = 24
    }

    /// Candidate URLs, best first: 2x on retina, then 1x, then the JPEG fallback.
    static func candidates(_ image: AdPayload.Image?, scale: CGFloat, webpSupported: Bool) -> [URL] {
        guard let image else { return [] }
        var list: [String?] = []
        if scale >= 2 { list.append(image.url2x) }
        list.append(image.url)
        list.append(image.fallback)
        var seen = Set<String>()
        return list.compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .filter { webpSupported || !$0.lowercased().contains(".webp") }
            .compactMap(URL.init(string:))
    }

    func load(_ image: AdPayload.Image?, scale: CGFloat) async -> UIImage? {
        for url in Self.candidates(image, scale: scale, webpSupported: true) {
            if let img = await load(url) { return img }
        }
        return nil
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        req.httpMethod = "GET"
        guard let (data, http) = try? await session.adfData(for: req), (200..<300).contains(http.statusCode),
              let img = UIImage(data: data) else {
            Log.warning("image download failed: \(url.absoluteString)")
            return nil
        }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}
