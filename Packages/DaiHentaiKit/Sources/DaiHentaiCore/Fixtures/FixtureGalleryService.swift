import Foundation
import Synchronization
import UIKit

/// Offline stand-in for the site, used by previews, `-DemoMode` and UI tests.
/// Everything it serves is generated: neutral titles and abstract artwork.
public struct FixtureGalleryService: GalleryService {
    public let site: Site
    /// Simulated latency per request.
    public var latency: Duration
    /// Originals come back as this refusal instead (`.loginRequired`, `.originalsNeedGP`), like the site's.
    public var refusesOriginals: SiteError?

    public init(site: Site = .eHentai, latency: Duration = .milliseconds(120), refusesOriginals: SiteError? = nil) {
        self.site = site
        self.latency = latency
        self.refusesOriginals = refusesOriginals
    }

    /// A gid the fixture treats as removed from the site.
    public static let missingGalleryID = "999999"

    public static let galleries: [GalleryInfo] = {
        let titles: [(String, String)] = [
            ("Summer Festival Memories", "夏祭りの思い出"),
            ("Rainy Day Café", "雨の日のカフェ"),
            ("Starlight Express Vol. 2", "星降る列車 2"),
            ("Afterschool Tea Club", "放課後ティータイム"),
            ("The Lighthouse Keeper", ""),
            ("Winter Onsen Trip", "冬の温泉旅行"),
            ("Cherry Blossom Letters", "桜の手紙"),
            ("Robot Garden", "ロボットガーデン"),
            ("Midnight Bakery", "真夜中のパン屋"),
            ("Ocean Blue Diary", "海色ダイアリー"),
            ("Fox Shrine Tales", "狐の神社物語"),
            ("City Pop Nights", ""),
            ("Paper Airplane", "紙飛行機"),
            ("Moonlit Library", "月明かりの図書館"),
            ("Autumn Leaves Sketchbook", "紅葉スケッチブック"),
            ("Retro Game Center", "レトロゲームセンター"),
            ("Snow Globe", "スノードーム"),
            ("Harbor Town Stories", "港町ストーリーズ"),
            ("Sunflower Field", "ひまわり畑"),
            ("Clockwork Cat", "ぜんまい猫"),
        ]
        let categories = GalleryCategory.allCases
        let tagPool = [
            "language:chinese", "language:translated", "language:japanese", "parody:original",
            "other:full color", "other:multi-work series", "other:story arc", "group:moe studio",
            "artist:daidouji", "character:mascot", "other:sole female", "other:tankoubon",
        ]
        return (0..<60).map { index in
            let (title, japanese) = titles[index % titles.count]
            let volume = index / titles.count
            let suffix = volume == 0 ? "" : " #\(volume + 1)"
            let pages = [12, 24, 36, 18, 45, 60, 8, 30][index % 8]
            let tags = (0..<4).map { tagPool[(index * 3 + $0 * 5) % tagPool.count] }
            return GalleryInfo(
                gid: String(3_000_000 - index),
                token: String(format: "%010x", 0xA1B2C3 &* (index + 7)),
                thumb: "fixture://thumb/\(3_000_000 - index)",
                title: "[Moe Studio] \(title)\(suffix)",
                titleJpn: japanese.isEmpty ? "" : "[萌えスタジオ] \(japanese)\(suffix)",
                categoryName: categories[index % categories.count].rawValue,
                uploader: "uploader\(index % 7)",
                fileCount: pages,
                fileSize: Int64(pages * 1_350_000).formatted(.byteCount(style: .file)),
                rating: [4.52, 3.87, 4.91, 2.64, 4.05, 3.33, 5.0, 4.28][index % 8],
                posted: "2026-0\(1 + index % 9)-1\(index % 10) 1\(index % 10):3\(index % 6)",
                tags: Array(Set(tags)).sorted()
            )
        }
    }()

    static let perPage = 25
    static let linksPerPage = 20

    @concurrent public func galleries(filter: SearchFilter, next: String?) async throws(SiteError) -> [GalleryInfo] {
        try await delay()
        let matching = Self.galleries.filter(filter.matches)
        let start = next.flatMap { gid in matching.firstIndex { $0.gid == gid }.map { $0 + 1 } } ?? 0
        return Array(matching.dropFirst(start).prefix(Self.perPage))
    }

    @concurrent public func metadata(for references: [SiteParser.GalleryReference]) async throws(SiteError) -> [GalleryInfo] {
        try await delay()
        return references.compactMap { reference in Self.galleries.first { $0.gid == reference.gid } }
    }

    @concurrent public func imagePageLinks(gid: String, token: String, index: Int) async throws(SiteError) -> [String] {
        try await delay()
        if gid == Self.missingGalleryID { throw .galleryNotFound }
        let count = Self.galleries.first { $0.gid == gid }?.fileCount ?? 20
        // Past the end, the site shows the last page.
        let index = min(index, max(count - 1, 0) / Self.linksPerPage)
        let pages = (index * Self.linksPerPage)..<min((index + 1) * Self.linksPerPage, count)
        // Like the site's, image keys are the start of the original file's SHA-1.
        let keys = await withTaskGroup(of: (Int, String).self) { group in
            for page in pages {
                group.addTask { (page, FixtureArt.imageKey(gid: gid, page: page + 1)) }
            }
            return await group.reduce(into: [Int: String]()) { $0[$1.0] = $1.1 }
        }
        return pages.map { "fixture://s/\(keys[$0] ?? "")/\(gid)-\($0 + 1)" }
    }

    @concurrent public func imageSource(forImagePage pageURL: String) async throws(SiteError) -> PageImageSource {
        guard let page = ImagePage(pageURL), let url = URL(string: "fixture://img/\(page.gid)/\(page.page)") else { throw .parse }
        let original = FixtureArt.isResampled(page: page.page) ? URL(string: "fixture://original/\(page.gid)/\(page.page)") : nil
        return PageImageSource(url: url, originalURL: original)
    }

    @concurrent public func imageData(from url: URL) async throws(SiteError) -> Data {
        try await delay()
        if url.host() == "thumb" {
            // Covers: fixture://thumb/<gid>
            guard let data = FixtureArt.cover(gid: url.lastPathComponent).jpegData(compressionQuality: 0.8) else { throw .parse }
            return data
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, let page = Int(parts[1]) else { throw .parse }
        if url.host() == "original" {
            // Originals: fixture://original/<gid>/<page>
            if let refusesOriginals { throw refusesOriginals }
            return FixtureArt.original(gid: parts[0], page: page)
        }
        return FixtureArt.page(gid: parts[0], page: page)
    }

    private func delay() async throws(SiteError) {
        do {
            try await Task.sleep(for: latency)
        } catch {
            throw .network
        }
    }
}

/// Abstract generated artwork for fixture covers and pages.
public enum FixtureArt {
    static func stableHue(_ seed: String) -> CGFloat {
        var value: UInt32 = 2_166_136_261
        for byte in seed.utf8 { value = (value ^ UInt32(byte)) &* 16_777_619 }
        return CGFloat(value % 360) / 360
    }

    public static func cover(gid: String) -> UIImage {
        render(size: CGSize(width: 250, height: 350), hue: stableHue(gid), label: "萌", caption: String(gid.suffix(3)))
    }

    /// A page as the fixture site shows it: resampled and recompressed, except every fifth page, which
    /// is small enough to be shown as the original itself.
    public static func page(gid: String, page: Int) -> Data {
        rendered("page|\(gid)|\(page)") {
            render(size: pageSize(page), hue: pageHue(gid: gid, page: page), label: "\(page)", caption: "P.\(page)").jpegData(compressionQuality: 0.7) ?? Data()
        }
    }

    /// A page's original file: larger and less compressed than what the site shows, when it resamples it.
    public static func original(gid: String, page: Int) -> Data {
        guard isResampled(page: page) else { return self.page(gid: gid, page: page) }
        return rendered("original|\(gid)|\(page)") {
            render(size: originalSize(page), hue: pageHue(gid: gid, page: page), label: "\(page)", caption: "P.\(page)").jpegData(compressionQuality: 0.9) ?? Data()
        }
    }

    /// A page's image key: the start of its original file's SHA-1, like the site's.
    public static func imageKey(gid: String, page: Int) -> String {
        String(GalleryFileStore.sha1(original(gid: gid, page: page)).prefix(10))
    }

    static func isResampled(page: Int) -> Bool { page % 5 != 0 }

    /// Mix of portrait and landscape pages so the reader handles both.
    private static func pageSize(_ page: Int) -> CGSize {
        page % 7 == 0 ? CGSize(width: 1400, height: 1000) : CGSize(width: 1000, height: 1414)
    }

    /// The original of a resampled page.
    public static func originalSize(_ page: Int) -> CGSize {
        page % 7 == 0 ? CGSize(width: 2240, height: 1600) : CGSize(width: 1600, height: 2262)
    }

    private static func pageHue(gid: String, page: Int) -> CGFloat {
        (stableHue(gid) + CGFloat(page) * 0.07).truncatingRemainder(dividingBy: 1)
    }

    /// Rendered pages are kept, so a page's bytes (and so its image key) never change within a run.
    private static let renders = Mutex<[String: Data]>([:])

    private static func rendered(_ key: String, _ make: () -> Data) -> Data {
        if let data = renders.withLock({ $0[key] }) { return data }
        let data = make()
        return renders.withLock { cache in
            if let existing = cache[key] { return existing }
            cache[key] = data
            return data
        }
    }

    static func render(size: CGSize, hue: CGFloat, label: String, caption: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [
                UIColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1).cgColor,
                UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.75, alpha: 1).cgColor,
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.25).setFill()
            for index in 0..<6 {
                let radius = size.width * (0.08 + CGFloat(index) * 0.03)
                let center = CGPoint(x: size.width * CGFloat((index * 37) % 100) / 100, y: size.height * CGFloat((index * 61) % 100) / 100)
                UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let big: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.width * 0.32, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .paragraphStyle: style,
            ]
            let small: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: size.width * 0.07, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .paragraphStyle: style,
            ]
            let labelHeight = size.width * 0.4
            (label as NSString).draw(in: CGRect(x: 0, y: (size.height - labelHeight) / 2 - size.width * 0.05, width: size.width, height: labelHeight), withAttributes: big)
            (caption as NSString).draw(in: CGRect(x: 0, y: size.height * 0.82, width: size.width, height: size.width * 0.1), withAttributes: small)
        }
    }
}
