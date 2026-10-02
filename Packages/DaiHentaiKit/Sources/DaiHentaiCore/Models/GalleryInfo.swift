import Foundation

/// Plain, sendable description of a gallery. This is what crosses actor boundaries;
/// the SwiftData `StoredGallery` is only ever touched on the main actor.
public struct GalleryInfo: Hashable, Codable, Sendable, Identifiable {
    public var gid: String
    public var token: String
    public var thumb: String
    public var title: String
    public var titleJpn: String
    public var categoryName: String
    public var uploader: String
    public var fileCount: Int
    public var fileSize: String
    public var rating: Double
    public var posted: String
    public var tags: [String]

    public init(
        gid: String,
        token: String,
        thumb: String = "",
        title: String = "",
        titleJpn: String = "",
        categoryName: String = "",
        uploader: String = "",
        fileCount: Int = 0,
        fileSize: String = "",
        rating: Double = 0,
        posted: String = "",
        tags: [String] = []
    ) {
        self.gid = gid
        self.token = token
        self.thumb = thumb
        self.title = title
        self.titleJpn = titleJpn
        self.categoryName = categoryName
        self.uploader = uploader
        self.fileCount = fileCount
        self.fileSize = fileSize
        self.rating = rating
        self.posted = posted
        self.tags = tags
    }

    /// `gid-token`, the identity used everywhere (history, downloads, download center).
    public var id: String { Self.key(gid: gid, token: token) }

    public static func key(gid: String, token: String) -> String { "\(gid)-\(token)" }

    public var category: GalleryCategory? { GalleryCategory(apiName: categoryName) }

    /// The Japanese title when there is one, otherwise the romanised title.
    public var bestTitle: String { titleJpn.isEmpty ? title : titleJpn }

    /// Folder under Documents holding this gallery's images. Must stay identical to 3.x
    /// (`bestTitle` with `/` replaced by `-`) so existing downloads are found again.
    public var folderName: String {
        let legacy = bestTitle.components(separatedBy: "/").joined(separator: "-")
        guard !legacy.isEmpty else { return gid }
        // File names are capped at 255 bytes; 3.x silently failed to save such galleries,
        // so shortening only these can't orphan existing downloads.
        guard legacy.utf8.count > 240 else { return legacy }
        var prefix = ""
        for character in legacy {
            guard prefix.utf8.count + String(character).utf8.count <= 200 else { break }
            prefix.append(character)
        }
        return "\(prefix)-\(gid)"
    }

    /// The cover thumbnail. ExHentai's own `/t/` path (what its API used to hand out, and what 3.x saved)
    /// answers 404 now; the same files are on `ehgt.org`.
    public var thumbURL: URL? {
        guard let url = URL(string: thumb) else { return nil }
        guard let host = url.host(), host == "exhentai.org" || host.hasSuffix(".exhentai.org"), url.path().hasPrefix("/t/") else { return url }
        return URL(string: "https://ehgt.org\(url.path(percentEncoded: true))")
    }

    public var engTitleWords: [String] { Self.splitTitle(title) }
    public var jpnTitleWords: [String] { Self.splitTitle(titleJpn) }

    /// Same splitting rules as 3.x: cut on punctuation and spaces, drop pieces containing `-`.
    static func splitTitle(_ title: String) -> [String] {
        let separators = CharacterSet(charactersIn: "=♥~【】&/!#,.;:|{}[]() ")
        return title.components(separatedBy: separators).filter { !$0.isEmpty && !$0.contains("-") }
    }

    /// Tags grouped by namespace, keeping the site's order.
    public var groupedTags: [(namespace: String, tags: [String])] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for tag in tags {
            let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
            let (namespace, value) = parts.count == 2 ? (parts[0], parts[1]) : ("misc", tag)
            if groups[namespace] == nil { order.append(namespace) }
            groups[namespace, default: []].append(value)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    public func galleryURL(on site: Site) -> URL {
        site.baseURL.appending(path: "g/\(gid)/\(token)/")
    }
}
