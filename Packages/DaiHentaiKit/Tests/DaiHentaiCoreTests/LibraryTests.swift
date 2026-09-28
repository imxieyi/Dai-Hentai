import Foundation
import SQLite3
import SwiftData
import Synchronization
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
        // Every page is the original file: bigger than what the site shows, and marked as such.
        #expect(downloader.isOriginalQuality)
        #expect(downloader.pixelSize(ofPage: 0) == FixtureArt.originalSize(1))
        #expect(downloader.pixelSize(ofPage: 4) == CGSize(width: 1000, height: 1414)) // shown as the original
        #expect(library.downloadGaps(gallery).isEmpty)
        let data = try Data(contentsOf: downloader.fileURL(forPage: 0))
        #expect(GalleryFileStore.isOriginal(data, imageKey: FixtureArt.imageKey(gid: gallery.gid, page: 1)))
    }

    @Test func readingOnlineKeepsWhatTheSiteShows() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        let downloader = GalleryDownloader(gallery: gallery, service: FixtureGalleryService(latency: .milliseconds(5)), library: library)
        await downloader.waitUntilStarted()
        downloader.request([0, 4])
        for _ in 0..<200 where !(downloader.pageStates[0].isReady && downloader.pageStates[4].isReady) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.pixelSize(ofPage: 0) == CGSize(width: 1000, height: 1414))
        #expect(downloader.originalPages == [4]) // page 5 isn't resampled, so what it shows is the original
        #expect(!library.files.isMarkedOriginal(folder: gallery.folderName, fileName: "\(gallery.gid)-1"))
        #expect(library.files.isMarkedOriginal(folder: gallery.folderName, fileName: "\(gallery.gid)-5"))
        downloader.stop()
    }

    @Test func resumingReplacesReducedPagesWithOriginals() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        try writeReducedPages(of: gallery, to: library)
        try library.files.write(Data([1]), folder: gallery.folderName, fileName: GalleryFileStore.coverFileName)
        library.markDownloaded(gallery) // a 3.x download: every page, as the site showed it
        #expect(library.downloadGaps(gallery).hasReducedPages)
        #expect(!library.downloadGaps(gallery).isMissingImages)
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        center.resume(gallery, .originals)
        let downloader = try #require(center.downloaders[gallery.id])
        await downloader.waitUntilStarted()
        #expect(downloader.isDownloadingAll) // doesn't end just because every page is on disk
        #expect(downloader.progress < 1)
        for _ in 0..<400 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.isOriginalQuality)
        #expect(downloader.pixelSize(ofPage: 0) == FixtureArt.originalSize(1))
        #expect(downloader.pageRevisions[0] == 1)   // readers decode the new file
        #expect(downloader.pageRevisions[4] == nil) // page 5 was the original all along: only marked
        #expect(library.downloadGaps(gallery).isEmpty)
        #expect(center.lastFinished == gallery)
    }

    @Test func resumingFromTheReaderLeavesReducedPagesAlone() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        try writeReducedPages(of: gallery, to: library, count: gallery.fileCount - 1)
        library.markDownloaded(gallery)
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        let downloader = center.attachReader(to: gallery)
        for _ in 0..<400 where !(downloader.arePagesComplete && !downloader.isDownloadingAll) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.arePagesComplete)
        #expect(downloader.originalPages == [gallery.fileCount - 1]) // only the missing page, fetched as the original
        #expect(downloader.pageRevisions.isEmpty)
        let gaps = library.downloadGaps(gallery)
        #expect(!gaps.isMissingImages && gaps.hasReducedPages)       // 「升級成原圖」 is up to the user
        center.detachReader(from: gallery)
    }

    @Test func downloadingMissingImagesLeavesReducedPagesAlone() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        try writeReducedPages(of: gallery, to: library, count: gallery.fileCount - 1)
        library.markDownloaded(gallery)
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        center.resume(gallery, .missing)
        let downloader = try #require(center.downloaders[gallery.id])
        for _ in 0..<400 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.isComplete)
        #expect(downloader.originalPages == [gallery.fileCount - 1])
        #expect(downloader.pageRevisions.isEmpty)
        let gaps = library.downloadGaps(gallery)
        #expect(!gaps.isMissingImages)
        #expect(gaps.reducedPageCount == gallery.fileCount - 1)
    }

    @Test func upgradingLeavesMissingPagesAndTheCoverAlone() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        try writeReducedPages(of: gallery, to: library, count: gallery.fileCount - 1)
        library.markDownloaded(gallery)
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        center.resume(gallery, .originals)
        let downloader = try #require(center.downloaders[gallery.id])
        await downloader.waitUntilStarted()
        #expect(downloader.isDownloadingAll)
        for _ in 0..<400 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.readyCount == gallery.fileCount - 1)
        #expect(downloader.originalPages.count == gallery.fileCount - 1)
        #expect(downloader.coverState == .missing)
        let gaps = library.downloadGaps(gallery)
        #expect(gaps.isMissingPages && gaps.isMissingCover && !gaps.hasReducedPages)
    }

    @Test func refusedOriginalsFallBackAndStopBeingAskedFor() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        let requests = RequestLog()
        let center = DownloadCenter(library: library) { FlakyService(refusesOriginals: true, log: requests) }

        center.startDownload(gallery)
        let downloader = try #require(center.downloaders[gallery.id])
        for _ in 0..<400 where downloader.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloader.arePagesComplete)          // still readable offline
        #expect(downloader.originalPages == [4])      // only the page shown as the original
        #expect(downloader.wereOriginalsRefused)
        #expect(requests.originals <= 3)              // the ones already on their way, not one per page
        #expect(center.lastNotice?.kind == .finishedWithoutOriginals(gallery))
        #expect(center.lastFinished == nil)

        // 「升級成原圖」 while still refused: one try, then it stops.
        let before = requests.originals
        center.resume(gallery, .originals)
        let again = try #require(center.downloaders[gallery.id])
        for _ in 0..<400 where again.isDownloadingAll {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requests.originals - before <= 3)
        #expect(center.lastNotice?.kind == .originalsRefused)
        #expect(library.downloadGaps(gallery).hasReducedPages)
    }

    @Test func theRateLimitStopsEveryDownload() async throws {
        let library = try makeLibrary()
        let first = FixtureGalleryService.galleries[6], second = FixtureGalleryService.galleries[22]
        let center = DownloadCenter(library: library) { FlakyService(rateLimitAfter: 5) }

        center.startDownload(first)
        center.startDownload(second)
        let downloaders = try [first, second].map { try #require(center.downloaders[$0.id]) }
        for _ in 0..<400 where downloaders.contains(where: \.isDownloadingAll) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(downloaders.allSatisfy { !$0.isDownloadingAll })
        #expect(downloaders.contains { $0.didHitRateLimit })
        #expect(downloaders.reduce(0) { $0 + $1.readyCount } <= 5)
        #expect(center.downloaders.isEmpty) // no reader: nothing keeps the screen awake
        #expect(center.lastNotice?.kind == .rateLimited)
        #expect(center.lastFinished == nil)
        // Nothing but real pages on disk: the placeholder isn't saved.
        for (gallery, downloader) in zip([first, second], downloaders) {
            #expect(library.files.contents(ofFolder: gallery.folderName, gid: gallery.gid).pages == downloader.readyCount)
        }
    }

    @Test func aBatchWorksThroughGalleriesOneAtATime() async throws {
        let library = try makeLibrary()
        let galleries = [FixtureGalleryService.galleries[6], FixtureGalleryService.galleries[22]]
        for gallery in galleries {
            try writeReducedPages(of: gallery, to: library)
            library.markDownloaded(gallery)
        }
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        center.startBatch(.originals, galleries: galleries)
        #expect(center.batch?.current == galleries[0])
        #expect(center.downloaders[galleries[1].id] == nil)
        var sawSecond = false
        for _ in 0..<600 where center.batch != nil {
            if center.batch?.current == galleries[1] {
                sawSecond = true
                #expect(center.downloaders[galleries[0].id] == nil)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawSecond)
        #expect(center.batch == nil)
        for gallery in galleries {
            #expect(library.downloadGaps(gallery).originalPages == gallery.fileCount)
            #expect(library.downloadGaps(gallery).isMissingCover) // an upgrade doesn't fetch covers
        }
        #expect(center.lastNotice?.kind == .batchFinished(.originals, originalsRefused: false))
        #expect(center.lastFinished == nil) // one toast for the batch, not one per gallery
    }

    @Test func aBatchStopsAtTheRateLimit() async throws {
        let library = try makeLibrary()
        let galleries = [FixtureGalleryService.galleries[6], FixtureGalleryService.galleries[22]]
        galleries.forEach(library.markDownloaded)
        let center = DownloadCenter(library: library) { FlakyService(rateLimitAfter: 4) }

        center.startBatch(.missing, galleries: galleries)
        for _ in 0..<400 where center.batch != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(center.batch == nil)
        #expect(center.lastNotice?.kind == .rateLimited)
        #expect(library.files.contents(ofFolder: galleries[1].folderName, gid: galleries[1].gid).pages == 0) // never started
    }

    @Test func refusedOriginalsEndAnUpgradeBatch() async throws {
        let library = try makeLibrary()
        let galleries = [FixtureGalleryService.galleries[6], FixtureGalleryService.galleries[22]]
        for gallery in galleries {
            try writeReducedPages(of: gallery, to: library)
            library.markDownloaded(gallery)
        }
        let requests = RequestLog()
        let center = DownloadCenter(library: library) { FlakyService(refusesOriginals: true, log: requests) }

        center.startBatch(.originals, galleries: galleries)
        for _ in 0..<400 where center.batch != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(center.lastNotice?.kind == .originalsRefused)
        #expect(requests.originals <= 3)
    }

    @Test func aMissingImagesBatchStopsAskingForRefusedOriginals() async throws {
        let library = try makeLibrary()
        let galleries = [FixtureGalleryService.galleries[6], FixtureGalleryService.galleries[22]]
        galleries.forEach(library.markDownloaded)
        let requests = RequestLog()
        let center = DownloadCenter(library: library) { FlakyService(refusesOriginals: true, log: requests) }

        center.startBatch(.missing, galleries: galleries)
        for _ in 0..<600 where center.batch != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        for gallery in galleries {
            #expect(!library.downloadGaps(gallery).isMissingImages) // still downloaded, as the site shows them
        }
        #expect(requests.originals <= 3) // the second gallery doesn't ask at all
        #expect(center.lastNotice?.kind == .batchFinished(.missing, originalsRefused: true))
    }


    private func writeReducedPages(of gallery: GalleryInfo, to library: LibraryStore, count: Int? = nil) throws {
        for page in 1...(count ?? gallery.fileCount) {
            try library.files.write(FixtureArt.page(gid: gallery.gid, page: page), folder: gallery.folderName, fileName: "\(gallery.gid)-\(page)")
        }
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

    @Test func downloadGapsCoverPagesCoverAndOriginals() throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        library.markDownloaded(gallery)
        #expect(library.downloadGaps(gallery).isMissingPages)
        #expect(library.downloadGaps(gallery).missingPageCount == gallery.fileCount)

        try writeReducedPages(of: gallery, to: library)
        var gaps = library.downloadGaps(gallery)
        #expect(!gaps.isMissingPages)
        #expect(gaps.isMissingCover && gaps.isMissingImages)
        #expect(gaps.reducedPageCount == gallery.fileCount)

        try library.files.write(Data([1]), folder: gallery.folderName, fileName: GalleryFileStore.coverFileName)
        gaps = library.downloadGaps(gallery)
        #expect(!gaps.isMissingImages)
        #expect(gaps.hasReducedPages, "the pages still aren't the originals")

        try writeOriginalPages(of: gallery, to: library)
        gaps = library.downloadGaps(gallery)
        #expect(gaps.originalPages == gallery.fileCount)
        #expect(gaps.isEmpty)
    }

    @Test func rewritingAPageDropsItsOriginalMark() throws {
        let files = GalleryFileStore(root: URL.temporaryDirectory.appending(path: "files-\(UUID().uuidString)", directoryHint: .isDirectory))
        let original = FixtureArt.original(gid: "1", page: 1)
        #expect(GalleryFileStore.isOriginal(original, imageKey: FixtureArt.imageKey(gid: "1", page: 1)))
        #expect(!GalleryFileStore.isOriginal(FixtureArt.page(gid: "1", page: 1), imageKey: FixtureArt.imageKey(gid: "1", page: 1)))

        try files.write(original, folder: "a", fileName: "1-1", isOriginal: true)
        #expect(files.isMarkedOriginal(folder: "a", fileName: "1-1"))
        #expect(files.contents(ofFolder: "a", gid: "1") == GalleryFileStore.FolderContents(pages: 1, originals: 1, hasCover: false))

        try files.write(FixtureArt.page(gid: "1", page: 1), folder: "a", fileName: "1-1")
        #expect(!files.isMarkedOriginal(folder: "a", fileName: "1-1"))
        #expect(files.contents(ofFolder: "a", gid: "1").originals == 0)
        // An unmarked file is checked against its image key.
        #expect(!files.verifyOriginal(folder: "a", fileName: "1-1", imageKey: FixtureArt.imageKey(gid: "1", page: 1)))
        try files.write(original, folder: "a", fileName: "1-1")
        #expect(files.verifyOriginal(folder: "a", fileName: "1-1", imageKey: FixtureArt.imageKey(gid: "1", page: 1)))
        #expect(files.isMarkedOriginal(folder: "a", fileName: "1-1"))
    }

    @Test func resumingFetchesOnlyTheMissingCover() async throws {
        let library = try makeLibrary()
        let gallery = FixtureGalleryService.galleries[6]
        try writeOriginalPages(of: gallery, to: library)
        library.markDownloaded(gallery)
        let center = DownloadCenter(library: library) { FixtureGalleryService(latency: .milliseconds(5)) }

        center.resume(gallery, .missing)
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

    private func writeOriginalPages(of gallery: GalleryInfo, to library: LibraryStore) throws {
        for page in 1...gallery.fileCount {
            try library.files.write(FixtureArt.original(gid: gallery.gid, page: page), folder: gallery.folderName, fileName: "\(gallery.gid)-\(page)", isOriginal: true)
        }
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

/// Counts image requests, shared by every copy of a `FlakyService`.
final class RequestLog: Sendable {
    private let counts = Mutex((images: 0, originals: 0))
    var images: Int { counts.withLock { $0.images } }
    var originals: Int { counts.withLock { $0.originals } }

    /// Records a request for a page image and returns how many there have been.
    func addImage(isOriginal: Bool) -> Int {
        counts.withLock {
            $0.images += 1
            if isOriginal { $0.originals += 1 }
            return $0.images
        }
    }
}

/// Fixture content with chosen requests failing.
struct FlakyService: GalleryService {
    var failsLinks = false
    var failsCovers = false
    var failingPage: Int?
    /// Page images after this many come back as the image-limits placeholder.
    var rateLimitAfter: Int?
    let log: RequestLog
    private let base: FixtureGalleryService

    init(failsLinks: Bool = false, failsCovers: Bool = false, failingPage: Int? = nil, refusesOriginals: Bool = false, rateLimitAfter: Int? = nil, log: RequestLog = RequestLog()) {
        self.failsLinks = failsLinks
        self.failsCovers = failsCovers
        self.failingPage = failingPage
        self.rateLimitAfter = rateLimitAfter
        self.log = log
        self.base = FixtureGalleryService(latency: .milliseconds(2), refusesOriginals: refusesOriginals)
    }

    var site: Site { base.site }

    @concurrent func galleries(filter: SearchFilter, next: String?) async throws(SiteError) -> [GalleryInfo] {
        try await base.galleries(filter: filter, next: next)
    }

    @concurrent func imagePageLinks(gid: String, token: String, index: Int) async throws(SiteError) -> [String] {
        if failsLinks { throw .network }
        return try await base.imagePageLinks(gid: gid, token: token, index: index)
    }

    @concurrent func imageSource(forImagePage pageURL: String) async throws(SiteError) -> PageImageSource {
        try await base.imageSource(forImagePage: pageURL)
    }

    @concurrent func imageData(from url: URL) async throws(SiteError) -> Data {
        if url.host() == "img" || url.host() == "original" {
            let count = log.addImage(isOriginal: url.host() == "original")
            if let rateLimitAfter, count > rateLimitAfter { throw .rateLimited }
        }
        if failsCovers, url.host() == "thumb" { throw .network }
        if let failingPage, url.host() == "img" || url.host() == "original", url.lastPathComponent == String(failingPage) { throw .network }
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
        let firstImage = try await service.imageSource(forImagePage: links[0])
        #expect(firstImage.url.scheme?.hasPrefix("http") == true)
        if links.count > 1 {
            // Second page goes through the showpage API with the cached show key.
            let secondImage = try await service.imageSource(forImagePage: links[1])
            #expect(secondImage.url != firstImage.url)
        }
        let probe = await SiteDiagnostics.probe(service)
        #expect(probe == SiteProbeResult(list: .success, api: .success))
    }
}
