import Foundation
import SwiftSoup

/// Pure parsing of the site's HTML and JSON. No networking, no state, safe on any thread.
public enum SiteParser {
    public struct GalleryReference: Hashable, Sendable {
        public let gid: String
        public let token: String
    }

    /// Galleries linked from a list page (`https://e-hentai.org/g/{gid}/{token}/`), in page order.
    public static func galleryReferences(inListPage html: String) throws -> [GalleryReference] {
        let document = try SwiftSoup.parse(html)
        var anchors = try document.select("td.gl3c.glname a[href]").array()
        if anchors.isEmpty {
            // Other display modes (thumbnail / extended) keep the links elsewhere in the table.
            anchors = try document.select(".itg a[href*=/g/]").array()
        }
        var seen = Set<GalleryReference>()
        var references: [GalleryReference] = []
        for anchor in anchors {
            guard let reference = galleryReference(from: try anchor.attr("href")), seen.insert(reference).inserted else { continue }
            references.append(reference)
        }
        return references
    }

    static func galleryReference(from href: String) -> GalleryReference? {
        guard let match = href.firstMatch(of: /\/g\/(\d+)\/([0-9a-f]+)/) else { return nil }
        return GalleryReference(gid: String(match.1), token: String(match.2))
    }

    /// Image page links (`https://e-hentai.org/s/{imgkey}/{gid}-{page}`) on one thumbnail page of a gallery.
    public static func imagePageLinks(inGalleryPage html: String) throws -> [String] {
        let document = try SwiftSoup.parse(html)
        var anchors = try document.select("#gdt a[href]").array()
        if anchors.isEmpty {
            anchors = try document.select("a[href*=/s/]").array()
        }
        var seen = Set<String>()
        return try anchors.compactMap { anchor in
            let href = try anchor.attr("href")
            guard href.contains("/s/"), seen.insert(href).inserted else { return nil }
            return href
        }
    }

    /// Whether a gallery page says the gallery was removed or is unavailable.
    public static func isGalleryUnavailable(_ html: String) -> Bool {
        html.contains("Gallery Not Available") || html.contains("This gallery has been removed") || html.contains("Key missing, or incorrect key provided")
    }

    /// `var showkey="..."` from an image page's inline script.
    public static func showKey(inImagePage html: String) -> String? {
        html.firstMatch(of: /showkey\s*=\s*"([^"]+)"/).map { String($0.1) }
    }

    /// What an image page shows, and where its original file is when that isn't it.
    public struct ImageSources: Equatable, Sendable {
        /// `<img id="img">`: resampled when the original is large, and usually recompressed.
        public var image: String
        /// 「Download original」 (`/fullimg/...`), only there when `image` isn't the original.
        public var original: String?
    }

    /// The image (`<img id="img" src="...">`) and the original's link (in `#i6`) on an image page.
    public static func imageSources(inImagePage html: String) throws -> ImageSources? {
        let document = try SwiftSoup.parse(html)
        guard let image = try nonEmpty(document.select("img#img").first()?.attr("src")) else { return nil }
        return ImageSources(image: image, original: try originalLink(in: document))
    }

    /// The same from a `showpage` API response, whose `i3` (image) and `i6` (links) fields are HTML fragments.
    public static func imageSources(inShowPageResponse data: Data) throws -> ImageSources? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["error"] != nil { return nil }
        guard let fragment = object["i3"] as? String else { return nil }
        let document = try SwiftSoup.parseBodyFragment(fragment)
        guard let image = try nonEmpty((document.select("img#img").first() ?? document.select("a img").first())?.attr("src")) else { return nil }
        let links = try (object["i6"] as? String).map { try SwiftSoup.parseBodyFragment($0) }
        return ImageSources(image: image, original: try links.flatMap(originalLink(in:)))
    }

    /// Whether an image URL is the placeholder the site shows once the image limits run out.
    public static func isRateLimitImage(_ url: String) -> Bool {
        let path = URL(string: url)?.path() ?? url
        return path.hasSuffix("/509.gif") || path.hasSuffix("/509s.gif")
    }

    /// What a short text answer to an image request (usually an original's link) means:
    /// "You have reached the image limit, and do not have sufficient GP to buy a download quota." is the
    /// whole account, "Downloading original files of this gallery [during peak hours] requires GP, and you do
    /// not have enough." is this gallery only.
    public static func imageRefusal(in text: String) -> SiteError? {
        if text.contains("reached the image limit") { return .rateLimited }
        if text.contains("requires GP") { return .originalsNeedGP }
        return nil
    }

    /// `/fullimg/{gid}/{page}/{key}/{name}` (older pages: `fullimg.php?...`).
    private static func originalLink(in document: Document) throws -> String? {
        try nonEmpty(document.select("a[href*=fullimg]").first()?.attr("href"))
    }

    private static func nonEmpty(_ string: String?) -> String? {
        string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Galleries from a `gdata` API response, keeping the order of `order` when given.
    public static func galleries(inGDataResponse data: Data, order: [GalleryReference] = []) throws -> [GalleryInfo] {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let metadata = object["gmetadata"] as? [[String: Any]]
        else { throw SiteError.parse }

        let galleries = metadata.compactMap { entry -> GalleryInfo? in
            guard entry["error"] == nil, let gid = LenientJSON.string(entry["gid"]), let token = LenientJSON.string(entry["token"]) else { return nil }
            let posted = LenientJSON.double(entry["posted"]).map(formatPosted) ?? ""
            let bytes = LenientJSON.double(entry["filesize"]) ?? 0
            return GalleryInfo(
                gid: gid,
                token: token,
                thumb: LenientJSON.string(entry["thumb"]) ?? "",
                title: decodeEntities(LenientJSON.string(entry["title"]) ?? ""),
                titleJpn: decodeEntities(LenientJSON.string(entry["title_jpn"]) ?? ""),
                categoryName: LenientJSON.string(entry["category"]) ?? "",
                uploader: LenientJSON.string(entry["uploader"]) ?? "",
                fileCount: LenientJSON.int(entry["filecount"]) ?? 0,
                fileSize: Int64(bytes).formatted(.byteCount(style: .file)),
                rating: LenientJSON.double(entry["rating"]) ?? 0,
                posted: posted,
                tags: (entry["tags"] as? [Any])?.compactMap { LenientJSON.string($0) } ?? []
            )
        }
        guard !order.isEmpty else { return galleries }
        let rank = Dictionary(order.enumerated().map { ($1.gid, $0) }, uniquingKeysWith: { first, _ in first })
        return galleries.sorted { (rank[$0.gid] ?? .max) < (rank[$1.gid] ?? .max) }
    }

    /// The site's timestamps are seconds since 1970; show them as `yyyy-MM-dd HH:mm` like 3.x did.
    static func formatPosted(_ seconds: Double) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        )
        return Date(timeIntervalSince1970: seconds).formatted(style)
    }

    /// Titles from the API occasionally contain HTML entities.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return (try? Entities.unescape(text)) ?? text
    }
}

/// JSON values written by different app/site versions disagree on string vs number.
enum LenientJSON {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let string as String: Int(string.trimmingCharacters(in: .whitespaces)) ?? Double(string).map { Int($0) }
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let string as String: ["1", "true", "yes"].contains(string.lowercased())
        default: nil
        }
    }
}
