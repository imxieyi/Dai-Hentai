import DaiHentaiCore
import Foundation

/// Fills the demo library with a believable history and a couple of downloads.
enum DemoSeeder {
    static func seed(_ library: LibraryStore) async {
        let galleries = FixtureGalleryService.galleries
        let now = Date.now
        let calendar = Calendar.current
        let hour: TimeInterval = 3600

        // History across 今天 / 昨天 / 本週 / 更早, some half read.
        let history: [(index: Int, viewedAt: Date, page: Int)] = [
            (2, now.addingTimeInterval(-0.2 * hour), 14),
            (5, now.addingTimeInterval(-1.5 * hour), 0),
            (9, calendar.date(byAdding: .day, value: -1, to: now)!, 7),
            (11, calendar.date(byAdding: .day, value: -1, to: now)!.addingTimeInterval(-2 * hour), 0),
            (14, calendar.date(byAdding: .day, value: -3, to: now)!, 5),
            (17, calendar.date(byAdding: .day, value: -4, to: now)!, 0),
            (21, calendar.date(byAdding: .day, value: -12, to: now)!, 3),
            (26, calendar.date(byAdding: .day, value: -30, to: now)!, 0),
        ]
        for entry in history.reversed() {
            let gallery = galleries[entry.index]
            library.recordVisit(gallery)
            library.setLastReadPage(entry.page, for: gallery)
            library.gallery(forKey: gallery.id)?.lastViewedAt = entry.viewedAt
        }

        // One complete download and one that stopped half way.
        let complete = galleries[6]   // 8 pages
        let partial = galleries[3]    // 18 pages
        for (gallery, pages, viewedAt) in [(complete, complete.fileCount, now.addingTimeInterval(-5 * hour)), (partial, 7, calendar.date(byAdding: .day, value: -2, to: now)!)] {
            library.recordVisit(gallery)
            library.markDownloaded(gallery)
            library.gallery(forKey: gallery.id)?.lastViewedAt = viewedAt
            let files = library.files
            let folder = gallery.folderName
            let gid = gallery.gid
            await Task.detached(priority: .userInitiated) {
                for page in 1...pages {
                    try? files.write(FixtureArt.page(gid: gid, page: page), folder: folder, fileName: "\(gid)-\(page)")
                }
            }.value
        }
        library.setLastReadPage(3, for: partial)
        // Touch a preference so the store saves the dates above.
        library.setLastReadPage(0, for: complete)
    }
}
