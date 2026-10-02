import Foundation
import Observation
import UIKit

/// Keeps downloaders alive while a reader shows them or a full download runs,
/// and exposes live progress for list cards ("DL: 42 %").
///
/// The Downloads tab's 「下載缺少的圖片」 and 「升級成原圖」 run as a batch, one gallery at a time.
/// Running out of image limits stops the batch and every other download.
///
/// The site wants GP for older galleries' originals, so 「升級成原圖」 goes newest first, and stops once
/// `gpStreakLimit` galleries in a row wanted GP: the older ones left would too.
@MainActor
@Observable
public final class DownloadCenter {
    public private(set) var downloaders: [String: GalleryDownloader] = [:]
    /// Galleries that finished downloading this session (for "下載完成囉" feedback).
    public private(set) var lastFinished: GalleryInfo?
    /// The latest other news about downloads, for a toast.
    public private(set) var lastNotice: Notice?
    /// The running 「下載缺少的圖片」 or 「升級成原圖」.
    public private(set) var batch: Batch?

    public struct Notice: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A download finished, but the site refused the originals.
            case finishedWithoutOriginals(GalleryInfo, GalleryDownloader.OriginalsRefusal)
            /// Replacing pages with originals stopped: the site refused them.
            case originalsRefused(GalleryDownloader.OriginalsRefusal)
            /// The image limits ran out, so every download stopped.
            case rateLimited
            /// A batch went through every gallery. `refusedOriginals` counts the galleries the site refused
            /// originals, by reason; their missing pages came as the site shows them.
            case batchFinished(GalleryDownloader.Work, refusedOriginals: [GalleryDownloader.OriginalsRefusal: Int])
            /// 「升級成原圖」 stopped: this many galleries in a row wanted GP for their originals.
            case upgradeStoppedForGP(Int)
        }

        public let id = UUID()
        public let kind: Kind
    }

    public struct Batch: Equatable, Sendable {
        public let work: GalleryDownloader.Work
        public let total: Int
        /// Galleries finished so far.
        public var done = 0
        public var current: GalleryInfo?
    }

    private var batchQueue: [GalleryInfo] = []
    private var batchRefusals: [GalleryDownloader.OriginalsRefusal: Int] = [:]
    /// Galleries in a row that wanted GP for their originals, in the running batch.
    private var batchGPStreak = 0
    /// How many galleries in a row may want GP before 「升級成原圖」 stops.
    public static let gpStreakLimit = 10
    private let library: LibraryStore
    private var serviceProvider: @MainActor () -> any GalleryService

    public init(library: LibraryStore, serviceProvider: @escaping @MainActor () -> any GalleryService) {
        self.library = library
        self.serviceProvider = serviceProvider
    }

    public func setServiceProvider(_ provider: @escaping @MainActor () -> any GalleryService) {
        serviceProvider = provider
    }

    /// Full downloads currently running, newest first.
    public var activeDownloads: [GalleryDownloader] {
        downloaders.values.filter(\.isDownloadingAll).sorted { $0.gallery.title < $1.gallery.title }
    }

    /// Combined progress of all running full downloads.
    public var overallProgress: Double {
        let active = activeDownloads
        let total = active.reduce(0) { $0 + $1.pageCount }
        guard total > 0 else { return 0 }
        return Double(active.reduce(0) { $0 + $1.completedCount }) / Double(total)
    }

    /// Progress of a running full download, `nil` when none is running for this gallery.
    public func progress(for key: String) -> Double? {
        guard let downloader = downloaders[key], downloader.isDownloadingAll else { return nil }
        return downloader.progress
    }

    public func isDownloading(_ key: String) -> Bool {
        downloaders[key]?.isDownloadingAll ?? false
    }

    /// The running batch's progress, counting the gallery it's on.
    public var batchProgress: Double {
        guard let batch, batch.total > 0 else { return 0 }
        let current = batch.current.flatMap { downloaders[$0.id]?.progress } ?? 0
        return (Double(batch.done) + current) / Double(batch.total)
    }

    /// Called by the reader when it appears.
    public func attachReader(to gallery: GalleryInfo) -> GalleryDownloader {
        let downloader = downloader(for: gallery)
        downloader.readerCount += 1
        downloader.start()
        if library.isDownloaded(gallery), !downloader.isDownloadingAll {
            // A downloaded gallery that isn't complete yet resumes, like 3.x. Check the disk first
            // so a complete one doesn't flash 「下載中」. A missing cover alone is fetched quietly.
            // Reduced pages stay: replacing them spends the user's image limits, so it waits for 「升級成原圖」.
            Task { [weak downloader] in
                guard let downloader else { return }
                await downloader.waitUntilStarted()
                guard downloader.readerCount > 0, downloader.phase != .notFound else { return }
                if !downloader.arePagesComplete {
                    downloader.downloadAll(.missing)
                } else if !downloader.hasCover {
                    downloader.fetchCover()
                }
                self.updateIdleTimer()
            }
        }
        updateIdleTimer()
        return downloader
    }

    /// Called by the reader when it goes away.
    public func detachReader(from gallery: GalleryInfo) {
        guard let downloader = downloaders[gallery.id] else { return }
        downloader.readerCount = max(0, downloader.readerCount - 1)
        if downloader.readerCount == 0, !downloader.isDownloadingAll {
            downloader.stop()
            downloaders[gallery.id] = nil
        }
        updateIdleTimer()
    }

    /// "我要下載": every page as the original, including pages read online before.
    public func startDownload(_ gallery: GalleryInfo) {
        library.recordVisit(gallery)
        library.markDownloaded(gallery)
        let downloader = downloader(for: gallery)
        downloader.downloadAll([.missing, .originals])
        updateIdleTimer()
    }

    /// 「繼續下載」 (`.missing`) or 「升級成原圖」 (`.originals`) for one download, from its context menu.
    /// Doesn't count as a visit, so the list keeps its order.
    public func resume(_ gallery: GalleryInfo, _ work: GalleryDownloader.Work) {
        library.markDownloaded(gallery)
        downloader(for: gallery).downloadAll(work)
        updateIdleTimer()
    }

    /// 「下載缺少的圖片」 (`.missing`) or 「升級成原圖」 (`.originals`, newest gallery first) for these
    /// downloads, one at a time.
    public func startBatch(_ work: GalleryDownloader.Work, galleries: [GalleryInfo]) {
        guard batch == nil, !galleries.isEmpty else { return }
        batch = Batch(work: work, total: galleries.count)
        // Gallery IDs go up with time.
        batchQueue = work == .originals ? galleries.sorted { (Int($0.gid) ?? 0) > (Int($1.gid) ?? 0) } : galleries
        batchRefusals = [:]
        batchGPStreak = 0
        startNextInBatch()
    }

    public func stopBatch() {
        let current = batch?.current
        batch = nil
        batchQueue.removeAll()
        if let current, let downloader = downloaders[current.id] {
            downloader.stop()
            if downloader.readerCount == 0 { downloaders[current.id] = nil }
        }
        updateIdleTimer()
    }

    private func startNextInBatch() {
        guard var batch else { return }
        while !batchQueue.isEmpty {
            let next = batchQueue.removeFirst()
            if isDownloading(next.id) {
                // Already downloading on its own.
                batch.done += 1
                continue
            }
            batch.current = next
            self.batch = batch
            // Without a login, no gallery gets originals. "Requires GP" is about one gallery: the next may be free.
            let asksForOriginals = batchRefusals[.needsLogin] == nil
            downloader(for: next).downloadAll(batch.work, asksForOriginals: asksForOriginals)
            updateIdleTimer()
            return
        }
        self.batch = nil
        lastNotice = Notice(kind: .batchFinished(batch.work, refusedOriginals: batchRefusals))
    }

    /// The batch's current gallery is done (or gone): on to the next one.
    private func advanceBatch(past gallery: GalleryInfo) {
        guard var batch, batch.current?.id == gallery.id else { return }
        batch.done += 1
        batch.current = nil
        self.batch = batch
        startNextInBatch()
    }

    /// Stops and forgets a gallery's downloader (before deleting it).
    public func cancel(_ gallery: GalleryInfo) {
        downloaders[gallery.id]?.stop()
        downloaders[gallery.id] = nil
        batchQueue.removeAll { $0.id == gallery.id }
        advanceBatch(past: gallery)
        updateIdleTimer()
    }

    /// Stops everything, e.g. when switching between E-Hentai and ExHentai.
    public func cancelAll() {
        batch = nil
        batchQueue.removeAll()
        downloaders.values.forEach { $0.stop() }
        downloaders.removeAll()
        updateIdleTimer()
    }

    /// The image limits ran out: nothing will download for a while, so stop the batch and every download.
    /// Readers keep their downloader (pages that fail show 「重新載入」).
    private func stopForRateLimit() {
        batch = nil
        batchQueue.removeAll()
        downloaders.values.filter(\.isDownloadingAll).forEach { $0.stop() }
        downloaders = downloaders.filter { $0.value.readerCount > 0 }
        lastNotice = Notice(kind: .rateLimited)
        updateIdleTimer()
    }

    private func downloader(for gallery: GalleryInfo) -> GalleryDownloader {
        if let existing = downloaders[gallery.id] { return existing }
        let downloader = GalleryDownloader(gallery: gallery, service: serviceProvider(), library: library)
        downloader.onFinishedAll = { [weak self, weak downloader] in
            guard let self, let downloader else { return }
            let gallery = downloader.gallery
            if downloader.readerCount == 0 {
                self.downloaders[gallery.id] = nil
            }
            self.updateIdleTimer()
            if let batch = self.batch, batch.current?.id == gallery.id {
                // A batch tells the user once, at the end.
                if let refusal = downloader.originalsRefusal {
                    self.batchRefusals[refusal, default: 0] += 1
                }
                self.batchGPStreak = downloader.originalsRefusal == .needsGP ? self.batchGPStreak + 1 : 0
                if batch.work == .originals, downloader.originalsRefusal == .needsLogin {
                    // The next gallery wouldn't get originals either.
                    self.batch = nil
                    self.batchQueue.removeAll()
                    self.lastNotice = Notice(kind: .originalsRefused(.needsLogin))
                } else if batch.work == .originals, self.batchGPStreak >= Self.gpStreakLimit {
                    // The galleries left are older still.
                    self.batch = nil
                    self.batchQueue.removeAll()
                    self.lastNotice = Notice(kind: .upgradeStoppedForGP(self.batchGPStreak))
                } else {
                    self.advanceBatch(past: gallery)
                }
                return
            }
            // Announce new pages only: not a cover top-up, and not a download that gave up.
            let didFinishPages = downloader.didFetchPages && downloader.arePagesComplete
            if let refusal = downloader.originalsRefusal {
                self.lastNotice = Notice(kind: didFinishPages ? .finishedWithoutOriginals(gallery, refusal) : .originalsRefused(refusal))
            } else if didFinishPages {
                self.lastFinished = gallery
            }
        }
        downloader.onRateLimited = { [weak self] in
            self?.stopForRateLimit()
        }
        downloaders[gallery.id] = downloader
        return downloader
    }

    /// The screen stays awake while reading or downloading, like 3.x.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !downloaders.isEmpty
    }
}
