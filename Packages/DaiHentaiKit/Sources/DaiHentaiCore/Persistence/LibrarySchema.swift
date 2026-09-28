import Foundation
import SwiftData

/// A gallery the user has opened (history) or downloaded. Replaces the Couchbase `histories` database.
@Model
public final class StoredGallery {
    #Unique<StoredGallery>([\.key])
    #Index<StoredGallery>([\.lastViewedAt], [\.isDownloaded, \.lastViewedAt])

    /// `gid-token`.
    public var key: String
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
    /// 1-based page the reader was on when last closed (0 = never read).
    public var lastReadPage: Int
    public var lastViewedAt: Date
    public var isDownloaded: Bool
    public var downloadedAt: Date?

    public init(_ info: GalleryInfo, lastReadPage: Int = 0, lastViewedAt: Date = .now, isDownloaded: Bool = false) {
        self.key = info.id
        self.gid = info.gid
        self.token = info.token
        self.thumb = info.thumb
        self.title = info.title
        self.titleJpn = info.titleJpn
        self.categoryName = info.categoryName
        self.uploader = info.uploader
        self.fileCount = info.fileCount
        self.fileSize = info.fileSize
        self.rating = info.rating
        self.posted = info.posted
        self.tags = info.tags
        self.lastReadPage = lastReadPage
        self.lastViewedAt = lastViewedAt
        self.isDownloaded = isDownloaded
        self.downloadedAt = isDownloaded ? lastViewedAt : nil
    }

    public var info: GalleryInfo {
        GalleryInfo(gid: gid, token: token, thumb: thumb, title: title, titleJpn: titleJpn, categoryName: categoryName, uploader: uploader, fileCount: fileCount, fileSize: fileSize, rating: rating, posted: posted, tags: tags)
    }

    /// Refreshes metadata from a newer copy without touching reading state.
    func update(from info: GalleryInfo) {
        if !info.thumb.isEmpty { thumb = info.thumb }
        if !info.title.isEmpty { title = info.title }
        if !info.titleJpn.isEmpty { titleJpn = info.titleJpn }
        if !info.categoryName.isEmpty { categoryName = info.categoryName }
        if !info.uploader.isEmpty { uploader = info.uploader }
        if info.fileCount > 0 { fileCount = info.fileCount }
        if !info.fileSize.isEmpty { fileSize = info.fileSize }
        if info.rating > 0 { rating = info.rating }
        if !info.posted.isEmpty { posted = info.posted }
        if !info.tags.isEmpty { tags = info.tags }
    }
}

/// Cached image-page links for one thumbnail page of a gallery. Replaces the Couchbase `galleries` database.
@Model
public final class StoredPageList {
    #Unique<StoredPageList>([\.key])

    /// `gid-token-index`.
    public var key: String
    public var gid: String
    public var token: String
    public var index: Int
    public var pages: [String]

    public init(gid: String, token: String, index: Int, pages: [String]) {
        self.key = Self.key(gid: gid, token: token, index: index)
        self.gid = gid
        self.token = token
        self.index = index
        self.pages = pages
    }

    public static func key(gid: String, token: String, index: Int) -> String { "\(gid)-\(token)-\(index)" }
}

/// The one saved search filter. Replaces the Couchbase `search` database.
@Model
public final class StoredSearchFilter {
    public var keyword: String
    public var minimumRating: Int
    public var language: String
    public var enabledCategories: [String]

    public init(_ filter: SearchFilter) {
        keyword = filter.keyword
        minimumRating = filter.minimumRating.rawValue
        language = filter.language.rawValue
        enabledCategories = filter.categories.map(\.rawValue).sorted()
    }

    public var filter: SearchFilter {
        get {
            SearchFilter(
                keyword: keyword,
                minimumRating: MinimumRating(rawValue: minimumRating) ?? .any,
                language: LanguageFilter(rawValue: language) ?? .any,
                categories: Set(enabledCategories.compactMap(GalleryCategory.init(rawValue:)))
            )
        }
        set {
            keyword = newValue.keyword
            minimumRating = newValue.minimumRating.rawValue
            language = newValue.language.rawValue
            enabledCategories = newValue.categories.map(\.rawValue).sorted()
        }
    }
}

public enum ReadingDirection: String, CaseIterable, Codable, Sendable, Identifiable {
    case vertical
    case horizontal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vertical: "上下捲動"
        case .horizontal: "左右捲動"
        }
    }

    public var toggled: ReadingDirection { self == .vertical ? .horizontal : .vertical }
}

public struct Preferences: Hashable, Sendable {
    public var readingDirection: ReadingDirection
    public var isAppLocked: Bool
    /// 「點列表作品時先跳出作品卡」: tapping a list card shows the 作品卡 first (like the old alert).
    public var asksBeforeOpening: Bool
    /// 「切換 App 時遮住畫面」: hide content in the app switcher even without the lock.
    public var hidesInAppSwitcher: Bool

    public init(readingDirection: ReadingDirection = .vertical, isAppLocked: Bool = false, asksBeforeOpening: Bool = true, hidesInAppSwitcher: Bool = false) {
        self.readingDirection = readingDirection
        self.isAppLocked = isAppLocked
        self.asksBeforeOpening = asksBeforeOpening
        self.hidesInAppSwitcher = hidesInAppSwitcher
    }
}

/// App preferences. Replaces the Couchbase `preference` database.
@Model
public final class StoredPreferences {
    public var readingDirection: String
    public var isAppLocked: Bool
    public var asksBeforeOpening: Bool = true
    public var hidesInAppSwitcher: Bool = false

    public init(_ preferences: Preferences) {
        readingDirection = preferences.readingDirection.rawValue
        isAppLocked = preferences.isAppLocked
        asksBeforeOpening = preferences.asksBeforeOpening
        hidesInAppSwitcher = preferences.hidesInAppSwitcher
    }

    public var preferences: Preferences {
        get {
            Preferences(
                readingDirection: ReadingDirection(rawValue: readingDirection) ?? .vertical,
                isAppLocked: isAppLocked,
                asksBeforeOpening: asksBeforeOpening,
                hidesInAppSwitcher: hidesInAppSwitcher
            )
        }
        set {
            readingDirection = newValue.readingDirection.rawValue
            isAppLocked = newValue.isAppLocked
            asksBeforeOpening = newValue.asksBeforeOpening
            hidesInAppSwitcher = newValue.hidesInAppSwitcher
        }
    }
}

public enum LibrarySchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [StoredGallery.self, StoredPageList.self, StoredSearchFilter.self, StoredPreferences.self]
    }
}

public enum LibraryMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum LibraryContainer {
    /// The app's SwiftData container. `inMemory` is used by tests, previews and demo mode.
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LibrarySchemaV1.self)
        let configuration = ModelConfiguration("Library", schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, migrationPlan: LibraryMigrationPlan.self, configurations: configuration)
    }
}
