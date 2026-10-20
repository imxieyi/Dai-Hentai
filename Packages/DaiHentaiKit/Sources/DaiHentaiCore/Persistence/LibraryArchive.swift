import Foundation
import SwiftData

/// The whole library as one JSON file (「匯出資料庫」), to move to another device or keep as a backup.
///
/// The records copy `LibrarySchemaV1` field by field, but are their own types so the file format only
/// changes when `version` does. Images are not part of it: they stay in `Documents`.
public struct LibraryArchive: Codable, Equatable, Sendable {
    public static let formatIdentifier = "tw.daidouji.dai-hentai.library"
    public static let currentVersion = 1

    public var format = Self.formatIdentifier
    public var version = Self.currentVersion
    public var exportedAt: Date
    public var searchFilter: SearchFilterRecord
    public var preferences: PreferencesRecord
    /// Newest first.
    public var galleries: [GalleryRecord]
    public var pageLists: [PageListRecord]

    public init(exportedAt: Date, searchFilter: SearchFilterRecord, preferences: PreferencesRecord, galleries: [GalleryRecord], pageLists: [PageListRecord]) {
        self.exportedAt = exportedAt
        self.searchFilter = searchFilter
        self.preferences = preferences
        self.galleries = galleries
        self.pageLists = pageLists
    }

    /// `StoredGallery`: history (`isDownloaded == false`) and downloads.
    public struct GalleryRecord: Codable, Equatable, Sendable {
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
        /// 1-based, 0 = never read.
        public var lastReadPage: Int
        public var lastViewedAt: Date
        public var isDownloaded: Bool
        public var downloadedAt: Date?

        public init(_ stored: StoredGallery) {
            gid = stored.gid
            token = stored.token
            thumb = stored.thumb
            title = stored.title
            titleJpn = stored.titleJpn
            categoryName = stored.categoryName
            uploader = stored.uploader
            fileCount = stored.fileCount
            fileSize = stored.fileSize
            rating = stored.rating
            posted = stored.posted
            tags = stored.tags
            lastReadPage = stored.lastReadPage
            lastViewedAt = stored.lastViewedAt
            isDownloaded = stored.isDownloaded
            downloadedAt = stored.downloadedAt
        }
    }

    /// `StoredPageList`: the image-page links of one thumbnail page.
    public struct PageListRecord: Codable, Equatable, Sendable {
        public var gid: String
        public var token: String
        public var index: Int
        public var pages: [String]

        public init(_ stored: StoredPageList) {
            gid = stored.gid
            token = stored.token
            index = stored.index
            pages = stored.pages
        }
    }

    /// `StoredSearchFilter`: the list's saved search.
    public struct SearchFilterRecord: Codable, Equatable, Sendable {
        public var keyword: String
        public var minimumRating: Int
        public var language: String
        public var enabledCategories: [String]

        public init(_ stored: StoredSearchFilter) {
            keyword = stored.keyword
            minimumRating = stored.minimumRating
            language = stored.language
            enabledCategories = stored.enabledCategories
        }
    }

    /// `StoredPreferences`.
    public struct PreferencesRecord: Codable, Equatable, Sendable {
        public var readingDirection: String
        public var isAppLocked: Bool
        public var asksBeforeOpening: Bool
        public var hidesInAppSwitcher: Bool

        public init(_ stored: StoredPreferences) {
            readingDirection = stored.readingDirection
            isAppLocked = stored.isAppLocked
            asksBeforeOpening = stored.asksBeforeOpening
            hidesInAppSwitcher = stored.hidesInAppSwitcher
        }
    }

    // MARK: - JSON

    /// Dates are ISO 8601 with milliseconds, so the history keeps its order.
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormat.format(date))
        }
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> LibraryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return try dateFormat.parse(try container.decode(String.self))
        }
        return try decoder.decode(LibraryArchive.self, from: data)
    }

    /// `Dai-Hentai-Library-2026-10-21.json`, dated in the device's time zone.
    public static func fileName(exportedAt date: Date) -> String {
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        return "Dai-Hentai-Library-\(day).json"
    }
}

/// Reads the library off the main actor for 「匯出資料庫」.
@ModelActor
public actor LibraryExporter {
    /// Everything in the store. A search filter or preferences that were never changed (so never saved)
    /// come out as the defaults the app uses.
    public func archive(exportedAt: Date = .now) throws -> LibraryArchive {
        let galleries = try modelContext.fetch(FetchDescriptor<StoredGallery>(sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]))
        let pageLists = try modelContext.fetch(FetchDescriptor<StoredPageList>(sortBy: [SortDescriptor(\.gid), SortDescriptor(\.token), SortDescriptor(\.index)]))
        let filter = try modelContext.fetch(FetchDescriptor<StoredSearchFilter>()).first ?? StoredSearchFilter(.default)
        let preferences = try modelContext.fetch(FetchDescriptor<StoredPreferences>()).first ?? StoredPreferences(Preferences())
        return LibraryArchive(
            exportedAt: exportedAt,
            searchFilter: .init(filter),
            preferences: .init(preferences),
            galleries: galleries.map(LibraryArchive.GalleryRecord.init),
            pageLists: pageLists.map(LibraryArchive.PageListRecord.init)
        )
    }

    /// Writes `archive()` into `directory` (created if needed) and returns the file.
    public func export(to directory: URL, exportedAt: Date = .now) throws -> URL {
        let data = try archive(exportedAt: exportedAt).encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: LibraryArchive.fileName(exportedAt: exportedAt), directoryHint: .notDirectory)
        try data.write(to: file, options: .atomic)
        return file
    }
}
