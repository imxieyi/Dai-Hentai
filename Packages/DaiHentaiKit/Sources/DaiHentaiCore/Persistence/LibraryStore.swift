import Foundation
import Observation
import SwiftData

/// Main-actor façade over the SwiftData library: history, downloads, page-link cache,
/// the saved search filter and preferences.
@MainActor
@Observable
public final class LibraryStore {
    public let container: ModelContainer
    public let files: GalleryFileStore
    private var context: ModelContext { container.mainContext }

    /// The saved search filter. Setting it persists immediately.
    public var searchFilter: SearchFilter {
        didSet {
            guard searchFilter != oldValue else { return }
            storedFilter().filter = searchFilter
            save()
        }
    }

    /// App preferences. Setting them persists immediately.
    public var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            storedPreferences().preferences = preferences
            save()
        }
    }

    public init(container: ModelContainer, files: GalleryFileStore = .documents) {
        self.container = container
        self.files = files
        let context = container.mainContext
        self.searchFilter = (try? context.fetch(FetchDescriptor<StoredSearchFilter>()).first?.filter) ?? .default
        self.preferences = (try? context.fetch(FetchDescriptor<StoredPreferences>()).first?.preferences) ?? Preferences()
    }

    /// Re-reads the singletons (after the legacy importer wrote them).
    public func reloadSettings() {
        searchFilter = (try? context.fetch(FetchDescriptor<StoredSearchFilter>()).first?.filter) ?? .default
        preferences = (try? context.fetch(FetchDescriptor<StoredPreferences>()).first?.preferences) ?? Preferences()
    }

    // MARK: - Galleries

    public func gallery(forKey key: String) -> StoredGallery? {
        var descriptor = FetchDescriptor<StoredGallery>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Records that the gallery was opened: adds it to history (or bumps it to the top) and
    /// returns the page the user was last on (1-based, 0 when never read).
    @discardableResult
    public func recordVisit(_ info: GalleryInfo) -> Int {
        if let stored = gallery(forKey: info.id) {
            stored.update(from: info)
            stored.lastViewedAt = .now
            save()
            return stored.lastReadPage
        }
        context.insert(StoredGallery(info))
        save()
        return 0
    }

    public func lastReadPage(for info: GalleryInfo) -> Int {
        gallery(forKey: info.id)?.lastReadPage ?? 0
    }

    public func setLastReadPage(_ page: Int, for info: GalleryInfo) {
        guard let stored = gallery(forKey: info.id) else { return }
        stored.lastReadPage = page
        save()
    }

    public func isDownloaded(_ info: GalleryInfo) -> Bool {
        gallery(forKey: info.id)?.isDownloaded ?? false
    }

    /// What a downloaded gallery still lacks on disk (「下載缺少的圖片」 / 「升級成原圖」).
    public func downloadGaps(_ info: GalleryInfo) -> DownloadGaps {
        let info = gallery(forKey: info.id)?.info ?? info
        return DownloadGaps(info: info, contents: files.contents(ofFolder: info.folderName, gid: info.gid))
    }

    public func markDownloaded(_ info: GalleryInfo) {
        let stored = gallery(forKey: info.id) ?? {
            let new = StoredGallery(info)
            context.insert(new)
            return new
        }()
        stored.isDownloaded = true
        stored.downloadedAt = .now
        save()
    }

    /// Deletes a gallery record and its images.
    public func delete(_ info: GalleryInfo) {
        let folder = gallery(forKey: info.id)?.info.folderName ?? info.folderName
        if let stored = gallery(forKey: info.id) {
            context.delete(stored)
        }
        deletePageLists(gid: info.gid, token: info.token)
        save()
        let files = files
        Task.detached(priority: .utility) { files.removeFolder(folder) }
    }

    /// Clears the whole history (not downloads), reporting progress as `(done, total)`.
    public func deleteAllHistory(progress: (Int, Int) -> Void = { _, _ in }) async {
        let descriptor = FetchDescriptor<StoredGallery>(predicate: #Predicate { !$0.isDownloaded })
        let histories = (try? context.fetch(descriptor)) ?? []
        let total = histories.count
        for (index, stored) in histories.enumerated() {
            let folder = stored.info.folderName
            let files = files
            await Task.detached(priority: .userInitiated) { files.removeFolder(folder) }.value
            deletePageLists(gid: stored.gid, token: stored.token)
            context.delete(stored)
            progress(index + 1, total)
        }
        save()
    }

    public func allGalleries() -> [StoredGallery] {
        (try? context.fetch(FetchDescriptor<StoredGallery>())) ?? []
    }

    /// The most recently viewed galleries (history and downloads), newest first.
    public func recentGalleries(limit: Int) -> [GalleryInfo] {
        var descriptor = FetchDescriptor<StoredGallery>(sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map(\.info)
    }

    // MARK: - Page-link cache

    public func pageList(gid: String, token: String, index: Int) -> [String]? {
        let key = StoredPageList.key(gid: gid, token: token, index: index)
        var descriptor = FetchDescriptor<StoredPageList>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.pages
    }

    public func savePageList(_ pages: [String], gid: String, token: String, index: Int) {
        let key = StoredPageList.key(gid: gid, token: token, index: index)
        var descriptor = FetchDescriptor<StoredPageList>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.pages = pages
        } else {
            context.insert(StoredPageList(gid: gid, token: token, index: index, pages: pages))
        }
        save()
    }

    private func deletePageLists(gid: String, token: String) {
        try? context.delete(model: StoredPageList.self, where: #Predicate { $0.gid == gid && $0.token == token })
    }

    // MARK: - Singletons

    private func storedFilter() -> StoredSearchFilter {
        if let existing = try? context.fetch(FetchDescriptor<StoredSearchFilter>()).first { return existing }
        let new = StoredSearchFilter(.default)
        context.insert(new)
        return new
    }

    private func storedPreferences() -> StoredPreferences {
        if let existing = try? context.fetch(FetchDescriptor<StoredPreferences>()).first { return existing }
        let new = StoredPreferences(Preferences())
        context.insert(new)
        return new
    }

    private func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error)")
        }
    }
}

/// How a downloaded gallery's folder falls short of the gallery.
public struct DownloadGaps: Equatable, Sendable {
    public var pageCount: Int
    public var pagesOnDisk: Int
    public var originalPages: Int
    public var isMissingCover: Bool

    public init(info: GalleryInfo, contents: GalleryFileStore.FolderContents) {
        pageCount = info.fileCount
        pagesOnDisk = contents.pages
        originalPages = contents.originals
        isMissingCover = !contents.hasCover && info.thumbURL != nil
    }

    public var isMissingPages: Bool { pageCount > 0 && pagesOnDisk < pageCount }
    public var missingPageCount: Int { max(0, pageCount - pagesOnDisk) }
    /// Pages or the cover are missing: 「下載缺少的圖片」 / 「繼續下載」 fetches them.
    public var isMissingImages: Bool { isMissingPages || isMissingCover }
    /// Pages on disk that aren't the originals (online reading, 3.x, or originals the site refused):
    /// 「升級成原圖」 replaces them.
    public var reducedPageCount: Int { max(0, pagesOnDisk - originalPages) }
    public var hasReducedPages: Bool { reducedPageCount > 0 }
    public var isEmpty: Bool { !isMissingImages && !hasReducedPages }
}

/// Storage used by history and downloads, computed off the main actor.
public struct StorageUsage: Sendable, Equatable {
    public var historyBytes: Int64 = 0
    public var historyCount = 0
    public var downloadBytes: Int64 = 0
    public var downloadCount = 0

    public init() {}

    public static func measure(_ galleries: [(folder: String, isDownloaded: Bool)], files: GalleryFileStore) async -> StorageUsage {
        await Task.detached(priority: .utility) {
            var usage = StorageUsage()
            for gallery in galleries {
                let bytes = files.size(ofFolder: gallery.folder)
                if gallery.isDownloaded {
                    usage.downloadBytes += bytes
                    usage.downloadCount += 1
                } else {
                    usage.historyBytes += bytes
                    usage.historyCount += 1
                }
            }
            return usage
        }.value
    }
}
