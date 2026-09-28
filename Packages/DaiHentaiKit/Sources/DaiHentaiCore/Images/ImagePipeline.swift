import Foundation
import ImageIO
import UIKit

/// Loads cover thumbnails (with the shared cookie jar, so ExHentai covers work) and decodes
/// downloaded pages, downsampled to the size they're shown at. Decoded images are memory-cached.
public actor ImagePipeline {
    public static let shared = ImagePipeline()

    private let session: URLSession
    private let memory = ImageMemoryCache()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 256 << 20, directory: URL.cachesDirectory.appending(path: "Thumbnails"))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    /// Synchronous memory-cache peek, so cells can render a cached image on their first frame.
    public nonisolated func cachedImage(for key: String) -> UIImage? {
        memory.image(for: key)
    }

    /// A cover thumbnail, downsampled so its longest side is at most `maxPixelSize`.
    public func thumbnail(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = "thumb|\(url.absoluteString)|\(Int(maxPixelSize))"
        if let cached = memory.image(for: key) { return cached }
        if let running = inFlight[key] { return await running.value }

        let session = session
        let task = Task<UIImage?, Never> {
            if url.scheme == "fixture" {
                return FixtureArt.cover(gid: url.lastPathComponent)
            }
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return await Self.downsample(data: data, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.set(image, for: key) }
        return image
    }

    /// A downloaded page from disk, downsampled to `maxPixelSize` on its longest side.
    public func page(at fileURL: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = Self.pageKey(fileURL, maxPixelSize: maxPixelSize)
        if let cached = memory.image(for: key) { return cached }
        let image = await Self.downsample(fileURL: fileURL, maxPixelSize: maxPixelSize)
        if let image { memory.set(image, for: key) }
        return image
    }

    public nonisolated static func pageKey(_ fileURL: URL, maxPixelSize: CGFloat) -> String {
        "page|\(fileURL.path(percentEncoded: false))|\(Int(maxPixelSize))"
    }

    public func removePages(inFolder folder: URL) {
        memory.removeAll()
    }

    @concurrent
    static func downsample(data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize)
    }

    @concurrent
    static func downsample(fileURL: URL, maxPixelSize: CGFloat) async -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize)
    }

    private static func downsample(source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// `NSCache` is documented as thread-safe; this wrapper only exposes it with Sendable types.
final class ImageMemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 160 << 20
        return cache
    }()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
