import Foundation

public enum Site: String, Sendable, Codable, CaseIterable {
    case eHentai
    case exHentai

    public var baseURL: URL {
        switch self {
        case .eHentai: URL(string: "https://e-hentai.org/")!
        case .exHentai: URL(string: "https://exhentai.org/")!
        }
    }

    public var apiURL: URL { baseURL.appending(path: "api.php") }

    public var shortName: String {
        switch self {
        case .eHentai: "Eh"
        case .exHentai: "Ex"
        }
    }
}

/// Minimum-rating choices, in the order of the old segmented control.
public enum MinimumRating: Int, CaseIterable, Codable, Sendable, Identifiable {
    case any = 0, two, three, four, five

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .any: "不限"
        case .two: "2星以上"
        case .three: "3星以上"
        case .four: "4星以上"
        case .five: "滿星"
        }
    }

    /// Value for the site's `f_srdd` parameter, `nil` when unrestricted.
    var siteValue: Int? { self == .any ? nil : rawValue + 1 }
}

/// Language restriction. At most one applies (the old app treated them as exclusive).
public enum LanguageFilter: String, CaseIterable, Codable, Sendable, Identifiable {
    case any
    case chineseOnly
    case originalOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: "不限"
        case .chineseOnly: "中文"
        case .originalOnly: "原汁原味不翻譯"
        }
    }

    var keywordSuffix: String {
        switch self {
        case .any: ""
        case .chineseOnly: " language:Chinese"
        case .originalOnly: " -translated -rewrite"
        }
    }
}

/// The single persisted search filter.
public struct SearchFilter: Hashable, Codable, Sendable {
    public var keyword: String
    public var minimumRating: MinimumRating
    public var language: LanguageFilter
    public var categories: Set<GalleryCategory>

    public init(
        keyword: String = "",
        minimumRating: MinimumRating = .any,
        language: LanguageFilter = .any,
        categories: Set<GalleryCategory> = Set(GalleryCategory.allCases)
    ) {
        self.keyword = keyword
        self.minimumRating = minimumRating
        self.language = language
        self.categories = categories
    }

    public static let `default` = SearchFilter()

    public var isDefault: Bool { self == .default }

    /// Number of non-default refinements, for badges.
    public var activeRefinementCount: Int {
        var count = 0
        if minimumRating != .any { count += 1 }
        if language != .any { count += 1 }
        if categories.count != GalleryCategory.allCases.count { count += 1 }
        return count
    }

    /// Query items for the list page. `next` is the gid of the last gallery already shown.
    public func queryItems(next: String?) -> [URLQueryItem] {
        let excluded = GalleryCategory.allCases
            .filter { !categories.contains($0) }
            .reduce(0) { $0 | $1.filterBit }
        let search = (keyword + language.keywordSuffix).trimmingCharacters(in: .whitespaces)

        var items: [URLQueryItem] = []
        if excluded != 0 { items.append(URLQueryItem(name: "f_cats", value: String(excluded))) }
        if !search.isEmpty { items.append(URLQueryItem(name: "f_search", value: search)) }
        if let stars = minimumRating.siteValue {
            items += [
                URLQueryItem(name: "advsearch", value: "1"),
                URLQueryItem(name: "f_sname", value: "on"),
                URLQueryItem(name: "f_stags", value: "on"),
                URLQueryItem(name: "f_sr", value: "on"),
                URLQueryItem(name: "f_srdd", value: String(stars)),
            ]
        }
        if let next { items.append(URLQueryItem(name: "next", value: next)) }
        items.append(URLQueryItem(name: "inline_set", value: "dm_l"))
        return items
    }

    public func listURL(on site: Site, next: String?) -> URL {
        site.baseURL.appending(queryItems: queryItems(next: next))
    }
}
