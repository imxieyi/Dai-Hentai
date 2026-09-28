import Foundation

public enum SiteError: Error, Sendable, Equatable {
    case network
    case parse
    case galleryNotFound
}

/// Everything the app needs from the site. `LiveGalleryService` talks to e-/exhentai;
/// `FixtureGalleryService` serves generated content for previews, demo mode and UI tests.
public protocol GalleryService: Sendable {
    var site: Site { get }

    /// One page of the gallery list. `next` is the gid of the last gallery already shown.
    @concurrent func galleries(filter: SearchFilter, next: String?) async throws(SiteError) -> [GalleryInfo]

    /// Image page links on thumbnail page `index` (0-based) of a gallery.
    @concurrent func imagePageLinks(gid: String, token: String, index: Int) async throws(SiteError) -> [String]

    /// Resolves an image page (`/s/{imgkey}/{gid}-{page}`) to the real image URL.
    @concurrent func imageURL(forImagePage pageURL: String) async throws(SiteError) -> URL

    /// Downloads image bytes.
    @concurrent func imageData(from url: URL) async throws(SiteError) -> Data

    /// Fetches metadata for specific galleries (used by the API diagnostic).
    @concurrent func metadata(for references: [SiteParser.GalleryReference]) async throws(SiteError) -> [GalleryInfo]
}

public struct LiveGalleryService: GalleryService {
    public let site: Site
    private let session: URLSession
    private let imageSession: URLSession

    public init(site: Site) {
        self.site = site
        self.session = .shared
        self.imageSession = Self.sharedImageSession
    }

    private static let sharedImageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    @concurrent public func galleries(filter: SearchFilter, next: String?) async throws(SiteError) -> [GalleryInfo] {
        let html = try await text(from: filter.listURL(on: site, next: next))
        let references: [SiteParser.GalleryReference]
        do {
            references = try SiteParser.galleryReferences(inListPage: html)
        } catch {
            throw .parse
        }
        guard !references.isEmpty else {
            // An empty result page is a valid answer; anything else without links is a parse failure.
            if html.contains("No hits found") || html.contains("No unfiltered results") { return [] }
            throw .parse
        }
        return try await metadata(for: references)
    }

    @concurrent public func metadata(for references: [SiteParser.GalleryReference]) async throws(SiteError) -> [GalleryInfo] {
        let gidList: [[Any]] = references.map { [Int($0.gid) ?? 0, $0.token] }
        let data = try await postJSON(["method": "gdata", "gidlist": gidList, "namespace": 1])
        do {
            return try SiteParser.galleries(inGDataResponse: data, order: references)
        } catch {
            throw .parse
        }
    }

    @concurrent public func imagePageLinks(gid: String, token: String, index: Int) async throws(SiteError) -> [String] {
        var items = [URLQueryItem(name: "inline_set", value: "ts_m")]
        if index > 0 { items.insert(URLQueryItem(name: "p", value: String(index)), at: 0) }
        let url = site.baseURL.appending(path: "g/\(gid)/\(token)/").appending(queryItems: items)
        let html = try await text(from: url)
        if SiteParser.isGalleryUnavailable(html) { throw .galleryNotFound }
        do {
            let links = try SiteParser.imagePageLinks(inGalleryPage: html)
            if links.isEmpty { throw SiteError.parse }
            return links
        } catch {
            throw .parse
        }
    }

    @concurrent public func imageURL(forImagePage pageURL: String) async throws(SiteError) -> URL {
        guard let page = ImagePage(pageURL) else { throw .parse }

        if let showKey = await ShowKeyCache.shared.key(for: page.gid) {
            let body: [String: Any] = ["method": "showpage", "gid": Int(page.gid) ?? 0, "page": page.page, "imgkey": page.imageKey, "showkey": showKey]
            if let data = try? await postJSON(body),
               let source = try? SiteParser.imageURL(inShowPageResponse: data),
               let url = URL(string: source) {
                return url
            }
            // The key may have expired; fall back to the page itself below.
            await ShowKeyCache.shared.remove(for: page.gid)
        }

        guard let url = URL(string: pageURL) else { throw .parse }
        let html = try await text(from: url, referer: pageURL)
        if let showKey = SiteParser.showKey(inImagePage: html) {
            await ShowKeyCache.shared.set(showKey, for: page.gid)
        }
        guard let source = try? SiteParser.imageURL(inImagePage: html), let imageURL = URL(string: source) else { throw .parse }
        return imageURL
    }

    @concurrent public func imageData(from url: URL) async throws(SiteError) -> Data {
        do {
            let (data, response) = try await imageSession.data(from: url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, !data.isEmpty else { throw SiteError.network }
            return data
        } catch {
            throw .network
        }
    }

    // MARK: - Transport

    private func text(from url: URL, referer: String? = nil) async throws(SiteError) -> String {
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        do {
            let (data, _) = try await session.data(for: request)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw .network
        }
    }

    private func postJSON(_ body: [String: Any]) async throws(SiteError) -> Data {
        var request = URLRequest(url: site.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            throw .network
        }
    }
}

/// `https://e-hentai.org/s/{imgkey}/{gid}-{page}` broken into parts.
public struct ImagePage: Hashable, Sendable {
    public let imageKey: String
    public let gid: String
    public let page: Int

    public init?(_ urlString: String) {
        let parts = urlString.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let tail = parts[parts.count - 1].split(separator: "-")
        guard tail.count == 2, let page = Int(tail[1]) else { return nil }
        self.imageKey = String(parts[parts.count - 2])
        self.gid = String(tail[0])
        self.page = page
    }

    /// File name used on disk by every app version: `{gid}-{page}`.
    public static func fileName(for urlString: String) -> String {
        URL(string: urlString)?.lastPathComponent ?? urlString.split(separator: "/").last.map(String.init) ?? urlString
    }
}

/// Show keys are per gallery and reused for every page of it.
actor ShowKeyCache {
    static let shared = ShowKeyCache()
    private var keys: [String: String] = [:]

    func key(for gid: String) -> String? { keys[gid] }
    func set(_ key: String, for gid: String) { keys[gid] = key }
    func remove(for gid: String) { keys[gid] = nil }
}
