import Foundation
import Observation
import UIKit

/// Keeps downloaders alive while a reader shows them or a full download runs,
/// and exposes live progress for list cards ("DL: 42 %").
@MainActor
@Observable
public final class DownloadCenter {
    public private(set) var downloaders: [String: GalleryDownloader] = [:]
    /// Galleries that finished downloading this session (for "下載完成囉" feedback).
    public private(set) var lastFinished: GalleryInfo?

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
        return Double(active.reduce(0) { $0 + $1.readyCount }) / Double(total)
    }

    /// Progress of a running full download, `nil` when none is running for this gallery.
    public func progress(for key: String) -> Double? {
        guard let downloader = downloaders[key], downloader.isDownloadingAll else { return nil }
        return downloader.progress
    }

    public func isDownloading(_ key: String) -> Bool {
        downloaders[key]?.isDownloadingAll ?? false
    }

    /// Called by the reader when it appears.
    public func attachReader(to gallery: GalleryInfo) -> GalleryDownloader {
        let downloader = downloader(for: gallery)
        downloader.readerCount += 1
        downloader.start()
        if library.isDownloaded(gallery), !downloader.isDownloadingAll {
            // A downloaded gallery that isn't complete yet resumes, like 3.x. Check the disk first
            // so a complete one doesn't flash 「下載中」.
            Task { [weak downloader] in
                guard let downloader else { return }
                await downloader.waitUntilStarted()
                guard downloader.readerCount > 0, !downloader.isComplete, downloader.phase != .notFound else { return }
                downloader.downloadAll()
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

    /// "我要下載".
    public func startDownload(_ gallery: GalleryInfo) {
        library.recordVisit(gallery)
        library.markDownloaded(gallery)
        let downloader = downloader(for: gallery)
        downloader.downloadAll()
        updateIdleTimer()
    }

    /// Resumes every downloaded gallery that isn't complete (e.g. from the Downloads tab).
    public func resume(_ gallery: GalleryInfo) {
        startDownload(gallery)
    }

    /// Stops and forgets a gallery's downloader (before deleting it).
    public func cancel(_ gallery: GalleryInfo) {
        downloaders[gallery.id]?.stop()
        downloaders[gallery.id] = nil
        updateIdleTimer()
    }

    /// Stops everything, e.g. when switching between E-Hentai and ExHentai.
    public func cancelAll() {
        downloaders.values.forEach { $0.stop() }
        downloaders.removeAll()
        updateIdleTimer()
    }

    private func downloader(for gallery: GalleryInfo) -> GalleryDownloader {
        if let existing = downloaders[gallery.id] { return existing }
        let downloader = GalleryDownloader(gallery: gallery, service: serviceProvider(), library: library)
        downloader.onFinishedAll = { [weak self, weak downloader] in
            guard let self, let downloader else { return }
            if downloader.didFetchPages { self.lastFinished = downloader.gallery }
            if downloader.readerCount == 0 {
                self.downloaders[downloader.gallery.id] = nil
            }
            self.updateIdleTimer()
        }
        downloaders[gallery.id] = downloader
        return downloader
    }

    /// The screen stays awake while reading or downloading, like 3.x.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !downloaders.isEmpty
    }
}
