import Foundation
import SQLite3
import SwiftData
import Testing
import UIKit
@testable import DaiHentaiCore

/// Builds a Couchbase Lite 1.4 style `db.sqlite3` (schema copied from CBL 1.4.4, `PRAGMA user_version = 17`).
struct LegacyDatabaseBuilder {
    let directory: URL

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "cbl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func make(_ name: String, documents: [(json: String, current: Bool, deleted: Bool)]) throws {
        let folder = directory.appending(path: "\(name).cblite2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appending(path: "db.sqlite3").path(percentEncoded: false), &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_create_collation_v2(db, "REVID", SQLITE_UTF8, nil, { _, l1, p1, l2, p2 in
            let n = Int(min(l1, l2)); let r = n == 0 ? 0 : memcmp(p1, p2, n); return r != 0 ? r : l1 - l2
        }, nil)
        let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE docs (doc_id INTEGER PRIMARY KEY, docid TEXT UNIQUE NOT NULL);
        CREATE TABLE revs (sequence INTEGER PRIMARY KEY AUTOINCREMENT, doc_id INTEGER NOT NULL REFERENCES docs(doc_id) ON DELETE CASCADE, revid TEXT NOT NULL COLLATE REVID, parent INTEGER REFERENCES revs(sequence) ON DELETE SET NULL, current BOOLEAN, deleted BOOLEAN DEFAULT 0, json BLOB, no_attachments BOOLEAN, UNIQUE (doc_id, revid));
        CREATE INDEX revs_parent ON revs(parent);
        CREATE INDEX revs_by_docid_revid ON revs(doc_id, revid desc, current, deleted);
        CREATE INDEX revs_current ON revs(doc_id, current desc, deleted, revid desc);
        CREATE TABLE localdocs (docid TEXT UNIQUE NOT NULL, revid TEXT NOT NULL COLLATE REVID, json BLOB);
        CREATE TABLE views (view_id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, version TEXT, lastsequence INTEGER DEFAULT 0, total_docs INTEGER DEFAULT -1);
        CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT);
        PRAGMA user_version = 17;
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for (index, document) in documents.enumerated() {
            let docID = index + 1
            #expect(sqlite3_exec(db, "INSERT INTO docs (doc_id, docid) VALUES (\(docID), 'doc\(docID)')", nil, nil, nil) == SQLITE_OK)
            // An older, non-current revision that must be ignored.
            #expect(sqlite3_exec(db, "INSERT INTO revs (doc_id, revid, current, deleted, json) VALUES (\(docID), '1-a', 0, 0, '{\"stale\":true}')", nil, nil, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO revs (doc_id, revid, current, deleted, json) VALUES (?, '2-b', ?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_int(statement, 1, Int32(docID))
            sqlite3_bind_int(statement, 2, document.current ? 1 : 0)
            sqlite3_bind_int(statement, 3, document.deleted ? 1 : 0)
            let bytes = Array(document.json.utf8)
            sqlite3_bind_blob(statement, 4, bytes, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }
}

@Suite(.serialized) @MainActor struct LegacyImportTests {
    @Test func importsHistoriesDownloadsPagesSearchAndPreferences() async throws {
        let builder = try LegacyDatabaseBuilder()
        // Field shapes as 3.x wrote them: gid as a number, filecount/rating as strings, downloaded as 1.
        try builder.make("histories", documents: [
            (#"{"gid":1166044,"token":"2227d8d6a0","title":"Highschool Sample","title_jpn":"","category":"Non-H","filecount":"355","filesize":"126.7 MB","posted":"2018-01-07 02:46","rating":"4.52","tags":["sample tag"],"thumb":"https://ehgt.org/x.jpg","timeStamp":1515304499.844339,"uploader":"someone","userLatestPage":12}"#, true, false),
            (#"{"gid":"2000","token":"abcdef0001","title":"Downloaded One","title_jpn":"ダウンロード/済み","category":"Artist CG Sets","filecount":20,"rating":3,"tags":[],"timeStamp":1600000000,"userLatestPage":0,"downloaded":1}"#, true, false),
            (#"{"gid":"3000","token":"deleted0001","title":"Deleted"}"#, true, true),
        ])
        try builder.make("galleries", documents: [
            (#"{"gid":"1166044","token":"2227d8d6a0","index":0,"pages":["https://e-hentai.org/s/cc24fd08ff/1166044-1","https://e-hentai.org/s/0c3283bed8/1166044-2"]}"#, true, false),
        ])
        try builder.make("search", documents: [
            (#"{"artistcg":0,"asianporn":0,"cosplay":0,"doujinshi":1,"gamecg":0,"imageset":0,"keyword":"c93","manga":1,"misc":0,"non_h":1,"rating":2,"western":0,"chineseOnly":1,"originalOnly":0}"#, true, false),
        ])
        try builder.make("preference", documents: [
            (#"{"scrollDirection":1,"isLockThisApp":1}"#, true, false),
        ])

        let container = try LibraryContainer.make(inMemory: true)
        let summary = try await LegacyCouchbaseImporter(modelContainer: container).importAll(from: builder.directory)
        #expect(summary.galleries == 2)
        #expect(summary.pageLists == 1)
        #expect(summary.importedSearchFilter && summary.importedPreferences)

        let library = LibraryStore(container: container)
        let history = try #require(library.gallery(forKey: "1166044-2227d8d6a0"))
        #expect(history.lastReadPage == 12)
        #expect(history.fileCount == 355)
        #expect(history.rating == 4.52)
        #expect(!history.isDownloaded)
        #expect(abs(history.lastViewedAt.timeIntervalSince1970 - 1515304499.844339) < 0.01)

        let downloaded = try #require(library.gallery(forKey: "2000-abcdef0001"))
        #expect(downloaded.isDownloaded)
        #expect(downloaded.info.category == .artistCG)
        #expect(downloaded.info.folderName == "ダウンロード-済み")
        #expect(library.gallery(forKey: "3000-deleted0001") == nil)

        #expect(library.pageList(gid: "1166044", token: "2227d8d6a0", index: 0)?.count == 2)
        #expect(library.searchFilter == SearchFilter(keyword: "c93", minimumRating: .three, language: .chineseOnly, categories: [.doujinshi, .manga, .nonH]))
        #expect(library.preferences == Preferences(readingDirection: .horizontal, isAppLocked: true))

        // Running it again must not duplicate anything.
        _ = try await LegacyCouchbaseImporter(modelContainer: container).importAll(from: builder.directory)
        #expect(library.allGalleries().count == 2)
    }

    @Test func missingDatabasesAreNotAnError() async throws {
        let container = try LibraryContainer.make(inMemory: true)
        let empty = URL.temporaryDirectory.appending(path: "none-\(UUID().uuidString)")
        let summary = try await LegacyCouchbaseImporter(modelContainer: container).importAll(from: empty)
        #expect(summary == .init())
    }
}

@Suite(.serialized) @MainActor struct LibraryStoreTests {
    func makeStore() throws -> LibraryStore {
        let root = URL.temporaryDirectory.appending(path: "files-\(UUID().uuidString)", directoryHint: .isDirectory)
        return LibraryStore(container: try LibraryContainer.make(inMemory: true), files: GalleryFileStore(root: root))
    }

    @Test func visitsBecomeHistoryAndRememberTheLastPage() throws {
        let store = try makeStore()
        let info = GalleryInfo(gid: "1", token: "a", title: "One", fileCount: 10)
        #expect(store.recordVisit(info) == 0)
        store.setLastReadPage(7, for: info)
        #expect(store.recordVisit(info) == 7)
        #expect(store.recentGalleries(limit: 10).map(\.id) == ["1-a"])
    }

    @Test func downloadsAndDeletion() async throws {
        let store = try makeStore()
        let info = GalleryInfo(gid: "2", token: "b", title: "Two", fileCount: 3)
        store.markDownloaded(info)
        #expect(store.isDownloaded(info))
        try store.files.write(Data([1, 2, 3]), folder: info.folderName, fileName: "2-1")
        store.savePageList(["https://e-hentai.org/s/k/2-1"], gid: "2", token: "b", index: 0)

        store.delete(info)
        #expect(store.gallery(forKey: info.id) == nil)
        #expect(store.pageList(gid: "2", token: "b", index: 0) == nil)
    }

    @Test func clearingHistoryKeepsDownloads() async throws {
        let store = try makeStore()
        let kept = GalleryInfo(gid: "3", token: "c", title: "Kept")
        store.markDownloaded(kept)
        for index in 0..<3 { store.recordVisit(GalleryInfo(gid: "h\(index)", token: "t", title: "History \(index)")) }
        var progress: [(Int, Int)] = []
        await store.deleteAllHistory { progress.append(($0, $1)) }
        #expect(progress.last.map { $0 == (3, 3) } == true)
        #expect(store.allGalleries().map(\.key) == [kept.id])
    }

    @Test func settingsPersist() throws {
        let container = try LibraryContainer.make(inMemory: true)
        let store = LibraryStore(container: container)
        store.searchFilter = SearchFilter(keyword: "abc", minimumRating: .two)
        store.preferences = Preferences(readingDirection: .horizontal, isAppLocked: false)
        let reopened = LibraryStore(container: container)
        #expect(reopened.searchFilter.keyword == "abc")
        #expect(reopened.preferences.readingDirection == .horizontal)
    }
}

@Suite(.serialized) @MainActor struct DownloaderTests {
    @Test func fullDownloadWritesEveryPageWithLegacyFileNames() async throws {
        let root = URL.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = LibraryStore(container: try LibraryContainer.make(inMemory: true), files: GalleryFileStore(root: root))
        let gallery = FixtureGalleryService.galleries[6] // 8 pages
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        center.startDownload(gallery)
        let downloader = try #require(center.downloaders[gallery.id])
        for _ in 0..<400 where !downloader.isComplete {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(downloader.isComplete)
        #expect(library.isDownloaded(gallery))
        #expect(library.files.fileExists(folder: gallery.folderName, fileName: "\(gallery.gid)-1"))
        #expect(library.files.fileExists(folder: gallery.folderName, fileName: "\(gallery.gid)-\(gallery.fileCount)"))
        #expect(library.files.fileExists(folder: gallery.folderName, fileName: GalleryFileStore.coverFileName))
        #expect(center.downloaders[gallery.id] == nil) // released once finished with no reader attached
        #expect(center.lastFinished == gallery)
    }

    @Test func aMissingCoverIsFetchedQuietlyWhenReading() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        for page in 1...gallery.fileCount {
            try library.files.write(FixtureArt.page(gid: gallery.gid, page: page), folder: gallery.folderName, fileName: "\(gallery.gid)-\(page)")
        }
        library.markDownloaded(gallery) // a 3.x download: every page, no cover
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        let downloader = center.attachReader(to: gallery)
        var sawDownloading = false
        for _ in 0..<200 where !downloader.isComplete {
            sawDownloading = sawDownloading || downloader.isDownloadingAll
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.isComplete)
        #expect(downloader.coverState == .ready)
        #expect(library.files.fileExists(folder: gallery.folderName, fileName: GalleryFileStore.coverFileName))
        #expect(!sawDownloading)            // no 「下載中」
        #expect(center.lastFinished == nil) // no 「下載完成囉」
        center.detachReader(from: gallery)
    }

    @Test func resumingFetchesOnlyTheMissingCover() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        for page in 1...gallery.fileCount {
            try library.files.write(FixtureArt.page(gid: gallery.gid, page: page), folder: gallery.folderName, fileName: "\(gallery.gid)-\(page)")
        }
        library.markDownloaded(gallery)
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        center.resume(gallery)
        let downloader = try #require(center.downloaders[gallery.id])
        for _ in 0..<200 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.isComplete)
        #expect(!downloader.didFetchPages)
        #expect(center.lastFinished == nil)
        #expect(center.downloaders[gallery.id] == nil)
    }

    @Test func aCoverThatWontDownloadDoesNotBlockTheDownload() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        let center = DownloadCenter(library: library) { FlakyService(failsCovers: true) }

        center.startDownload(gallery)
        let downloader = try #require(center.downloaders[gallery.id])
        for _ in 0..<400 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!downloader.isDownloadingAll)
        #expect(downloader.arePagesComplete)
        #expect(downloader.coverState == .failed)
        #expect(!downloader.isComplete)
        #expect(center.lastFinished == gallery) // the pages did finish
    }

    @Test func pagesThatKeepFailingEndTheDownload() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        let center = DownloadCenter(library: library) { FlakyService(failingPage: 3) }

        center.startDownload(gallery)
        let downloader = try #require(center.downloaders[gallery.id])
        for _ in 0..<400 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!downloader.isDownloadingAll) // not stuck at 「下載中」
        #expect(downloader.readyCount == gallery.fileCount - 1)
        #expect(downloader.firstFailedPage == 2)
        #expect(center.lastFinished == nil)
    }

    @Test func downloadingOfflineEndsTheDownload() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        let center = DownloadCenter(library: library) { FlakyService(failsLinks: true, failsCovers: true) }

        center.startDownload(gallery)
        let downloader = try #require(center.downloaders[gallery.id])
        for _ in 0..<400 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!downloader.isDownloadingAll)
        #expect(downloader.readyCount == 0)
        #expect(downloader.pageStates.allSatisfy { $0 == .failed })
    }

    @Test func aSavedCoverIsShownWithoutTheNetwork() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        let data = try #require(FixtureArt.cover(gid: gallery.gid).jpegData(compressionQuality: 0.8))
        try library.files.write(data, folder: gallery.folderName, fileName: GalleryFileStore.coverFileName)

        // An unreachable address: only the saved file can produce an image.
        let offline = try #require(URL(string: "https://cover.invalid/\(gallery.gid).jpg"))
        let image = await ImagePipeline().thumbnail(for: offline, localFile: library.files.coverURL(folder: gallery.folderName), maxPixelSize: 200)
        #expect(image != nil)
    }

    private func makeLibrary() throws -> LibraryStore {
        let root = URL.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        return LibraryStore(container: try LibraryContainer.make(inMemory: true), files: GalleryFileStore(root: root))
    }

    @Test func pagesOnDiskAreReadyWithoutNetwork() async throws {
        let root = URL.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = LibraryStore(container: try LibraryContainer.make(inMemory: true), files: GalleryFileStore(root: root))
        let gallery = FixtureGalleryService.galleries[6]
        try library.files.write(FixtureArt.page(gid: gallery.gid, page: 1), folder: gallery.folderName, fileName: "\(gallery.gid)-1")

        let downloader = GalleryDownloader(gallery: gallery, service: FixtureGalleryService(latency: .seconds(30)), library: library)
        downloader.start()
        for _ in 0..<100 where !downloader.pageStates[0].isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.pageStates[0].isReady)
        #expect(downloader.pixelSize(ofPage: 0) == CGSize(width: 1000, height: 1414))
        downloader.stop()
    }

    @Test func reopeningACompleteDownloadIsNotAnnouncedAgain() async throws {
        let root = URL.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = LibraryStore(container: try LibraryContainer.make(inMemory: true), files: GalleryFileStore(root: root))
        let gallery = FixtureGalleryService.galleries[6]
        for page in 1...gallery.fileCount {
            try library.files.write(FixtureArt.page(gid: gallery.gid, page: page), folder: gallery.folderName, fileName: "\(gallery.gid)-\(page)")
        }
        library.markDownloaded(gallery)
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        let downloader = center.attachReader(to: gallery)
        await downloader.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(100))
        #expect(downloader.isComplete)
        #expect(!downloader.isDownloadingAll) // no 「下載中」 flash
        #expect(center.lastFinished == nil)   // no 「下載完成囉」 toast
        center.detachReader(from: gallery)
    }

    @Test func reloadingAPageFetchesItAgain() async throws {
        let root = URL.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        let library = LibraryStore(container: try LibraryContainer.make(inMemory: true), files: GalleryFileStore(root: root))
        let gallery = FixtureGalleryService.galleries[6]
        try library.files.write(Data("not an image".utf8), folder: gallery.folderName, fileName: "\(gallery.gid)-1")

        let downloader = GalleryDownloader(gallery: gallery, service: FixtureGalleryService(latency: .milliseconds(5)), library: library)
        await downloader.waitUntilStarted()
        #expect(!downloader.pageStates[0].isReady) // the broken file isn't an image
        downloader.request([0])
        for _ in 0..<200 where !downloader.pageStates[0].isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.pageStates[0].isReady)
        let readyBefore = downloader.readyCount

        downloader.reload(page: 0)
        #expect(downloader.readyCount == readyBefore - 1)
        for _ in 0..<200 where !downloader.pageStates[0].isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.pageStates[0].isReady)
        #expect(downloader.readyCount == readyBefore)
        #expect(downloader.didFetchPages)
        downloader.stop()
    }

    @Test func missingGalleryIsReported() async throws {
        let library = LibraryStore(container: try LibraryContainer.make(inMemory: true), files: GalleryFileStore(root: .temporaryDirectory))
        let gallery = GalleryInfo(gid: FixtureGalleryService.missingGalleryID, token: "x", title: "Gone", fileCount: 5)
        let downloader = GalleryDownloader(gallery: gallery, service: FixtureGalleryService(latency: .milliseconds(1)), library: library)
        await downloader.waitUntilStarted()
        #expect(downloader.phase == .notFound)
    }
}

/// Fixture content with chosen requests failing.
struct FlakyService: GalleryService {
    var failsLinks = false
    var failsCovers = false
    var failingPage: Int?
    private let base = FixtureGalleryService(latency: .milliseconds(2))

    init(failsLinks: Bool = false, failsCovers: Bool = false, failingPage: Int? = nil) {
        self.failsLinks = failsLinks
        self.failsCovers = failsCovers
        self.failingPage = failingPage
    }

    var site: Site { base.site }

    @concurrent func galleries(filter: SearchFilter, next: String?) async throws(SiteError) -> [GalleryInfo] {
        try await base.galleries(filter: filter, next: next)
    }

    @concurrent func imagePageLinks(gid: String, token: String, index: Int) async throws(SiteError) -> [String] {
        if failsLinks { throw .network }
        return try await base.imagePageLinks(gid: gid, token: token, index: index)
    }

    @concurrent func imageURL(forImagePage pageURL: String) async throws(SiteError) -> URL {
        try await base.imageURL(forImagePage: pageURL)
    }

    @concurrent func imageData(from url: URL) async throws(SiteError) -> Data {
        if failsCovers, url.host() == "thumb" { throw .network }
        if let failingPage, url.host() == "img", url.lastPathComponent == String(failingPage) { throw .network }
        return try await base.imageData(from: url)
    }

    @concurrent func metadata(for references: [SiteParser.GalleryReference]) async throws(SiteError) -> [GalleryInfo] {
        try await base.metadata(for: references)
    }
}

/// Hits the real site. Opt in with `DAIHENTAI_LIVE_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DAIHENTAI_LIVE_TESTS"] == "1"))
struct LiveSiteTests {
    @Test func frontPageGalleryAndImageResolve() async throws {
        let service = LiveGalleryService(site: .eHentai)
        let galleries = try await service.galleries(filter: SearchFilter(), next: nil)
        #expect(galleries.count >= 20)
        let first = try #require(galleries.first)
        #expect(first.fileCount > 0 && !first.token.isEmpty && !first.thumb.isEmpty)

        let nextPage = try await service.galleries(filter: SearchFilter(), next: galleries.last?.gid)
        #expect(!nextPage.isEmpty && nextPage.first?.gid != first.gid)

        let links = try await service.imagePageLinks(gid: first.gid, token: first.token, index: 0)
        #expect(!links.isEmpty)
        let firstImage = try await service.imageURL(forImagePage: links[0])
        #expect(firstImage.scheme?.hasPrefix("http") == true)
        if links.count > 1 {
            // Second page goes through the showpage API with the cached show key.
            let secondImage = try await service.imageURL(forImagePage: links[1])
            #expect(secondImage != firstImage)
        }
        let probe = await SiteDiagnostics.probe(service)
        #expect(probe == SiteProbeResult(list: .success, api: .success))
    }
}
