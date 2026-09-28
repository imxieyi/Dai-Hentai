import Foundation
import SQLite3
import SwiftData

/// One-time import of the 3.x Couchbase Lite 1.4 databases into SwiftData.
///
/// Couchbase Lite 1.x kept each database at `Application Support/CouchbaseLite/<name>.cblite2/db.sqlite3`
/// with the document bodies as JSON in `revs.json` (current, non-deleted revisions). We read those
/// rows directly with SQLite so the Couchbase dependency can go away. The old files are left untouched.
@ModelActor
public actor LegacyCouchbaseImporter {
    public struct Summary: Sendable, Equatable {
        public var galleries = 0
        public var pageLists = 0
        public var importedSearchFilter = false
        public var importedPreferences = false

        public init() {}
    }

    public static let completedDefaultsKey = "didImportCouchbaseLite"
    public static let defaultDirectory = URL.applicationSupportDirectory.appending(path: "CouchbaseLite", directoryHint: .isDirectory)

    /// Whether there is something to import on this device.
    public nonisolated static func needsImport(directory: URL = defaultDirectory, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completedDefaultsKey) && FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
    }

    /// Imports everything found in `directory`. Safe to call repeatedly: galleries upsert by key.
    public func importAll(from directory: URL = LegacyCouchbaseImporter.defaultDirectory) throws -> Summary {
        var summary = Summary()

        for document in try Self.documents(database: "histories", in: directory) {
            guard let info = Self.galleryInfo(from: document) else { continue }
            let key = info.id
            var descriptor = FetchDescriptor<StoredGallery>(predicate: #Predicate { $0.key == key })
            descriptor.fetchLimit = 1
            let viewedAt = LenientJSON.double(document["timeStamp"]).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let lastReadPage = LenientJSON.int(document["userLatestPage"]) ?? 0
            let isDownloaded = LenientJSON.bool(document["downloaded"]) ?? false
            if let existing = try modelContext.fetch(descriptor).first {
                existing.update(from: info)
                existing.lastReadPage = max(existing.lastReadPage, lastReadPage)
                existing.isDownloaded = existing.isDownloaded || isDownloaded
                if existing.isDownloaded, existing.downloadedAt == nil { existing.downloadedAt = viewedAt }
            } else {
                modelContext.insert(StoredGallery(info, lastReadPage: lastReadPage, lastViewedAt: viewedAt, isDownloaded: isDownloaded))
            }
            summary.galleries += 1
        }

        for document in try Self.documents(database: "galleries", in: directory) {
            guard
                let gid = LenientJSON.string(document["gid"]),
                let token = LenientJSON.string(document["token"]),
                let index = LenientJSON.int(document["index"]),
                let pages = document["pages"] as? [Any]
            else { continue }
            let links = pages.compactMap { LenientJSON.string($0) }
            guard !links.isEmpty else { continue }
            modelContext.insert(StoredPageList(gid: gid, token: token, index: index, pages: links))
            summary.pageLists += 1
        }

        if let document = try Self.documents(database: "search", in: directory).first {
            try modelContext.delete(model: StoredSearchFilter.self)
            modelContext.insert(StoredSearchFilter(Self.searchFilter(from: document)))
            summary.importedSearchFilter = true
        }

        if let document = try Self.documents(database: "preference", in: directory).first {
            try modelContext.delete(model: StoredPreferences.self)
            modelContext.insert(StoredPreferences(Self.preferences(from: document)))
            summary.importedPreferences = true
        }

        try modelContext.save()
        return summary
    }

    // MARK: - Mapping

    static func galleryInfo(from document: [String: Any]) -> GalleryInfo? {
        guard let gid = LenientJSON.string(document["gid"]), let token = LenientJSON.string(document["token"]), !gid.isEmpty, !token.isEmpty else { return nil }
        return GalleryInfo(
            gid: gid,
            token: token,
            thumb: LenientJSON.string(document["thumb"]) ?? "",
            title: LenientJSON.string(document["title"]) ?? "",
            titleJpn: LenientJSON.string(document["title_jpn"]) ?? "",
            categoryName: LenientJSON.string(document["category"]) ?? "",
            uploader: LenientJSON.string(document["uploader"]) ?? "",
            fileCount: LenientJSON.int(document["filecount"]) ?? 0,
            fileSize: LenientJSON.string(document["filesize"]) ?? "",
            rating: LenientJSON.double(document["rating"]) ?? 0,
            posted: LenientJSON.string(document["posted"]) ?? "",
            tags: (document["tags"] as? [Any])?.compactMap { LenientJSON.string($0) } ?? []
        )
    }

    static func searchFilter(from document: [String: Any]) -> SearchFilter {
        var categories = Set<GalleryCategory>()
        for category in GalleryCategory.allCases where LenientJSON.bool(document[category.legacyKey]) ?? true {
            categories.insert(category)
        }
        let language: LanguageFilter =
            LenientJSON.bool(document["chineseOnly"]) == true ? .chineseOnly
            : LenientJSON.bool(document["originalOnly"]) == true ? .originalOnly
            : .any
        return SearchFilter(
            keyword: LenientJSON.string(document["keyword"]) ?? "",
            minimumRating: MinimumRating(rawValue: LenientJSON.int(document["rating"]) ?? 0) ?? .any,
            language: language,
            categories: categories
        )
    }

    static func preferences(from document: [String: Any]) -> Preferences {
        // UICollectionViewScrollDirection: 0 = vertical, 1 = horizontal.
        Preferences(
            readingDirection: LenientJSON.int(document["scrollDirection"]) == 1 ? .horizontal : .vertical,
            isAppLocked: LenientJSON.bool(document["isLockThisApp"]) ?? false
        )
    }

    // MARK: - SQLite

    /// Current, non-deleted document bodies of one Couchbase Lite database.
    static func documents(database name: String, in directory: URL) throws -> [[String: Any]] {
        let file = directory.appending(path: "\(name).cblite2/db.sqlite3", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return [] }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path(percentEncoded: false), &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw ImportError.cannotOpen(name)
        }
        defer { sqlite3_close(db) }

        // The schema declares `revid ... COLLATE REVID`; register a stand-in so SQLite can load it.
        sqlite3_create_collation_v2(db, "REVID", SQLITE_UTF8, nil, { _, lhsLength, lhs, rhsLength, rhs in
            let count = Int(min(lhsLength, rhsLength))
            let result = count == 0 ? 0 : memcmp(lhs, rhs, count)
            return result != 0 ? result : lhsLength - rhsLength
        }, nil)

        let sql = "SELECT doc_id, json FROM revs WHERE current = 1 AND deleted = 0 AND json IS NOT NULL ORDER BY doc_id, sequence DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw ImportError.cannotRead(name, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var lastDocument: Int64?
        var documents: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let documentID = sqlite3_column_int64(statement, 0)
            guard documentID != lastDocument else { continue }
            lastDocument = documentID
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                documents.append(object)
            }
        }
        return documents
    }

    public enum ImportError: Error, Sendable {
        case cannotOpen(String)
        case cannotRead(String, String)
    }
}
