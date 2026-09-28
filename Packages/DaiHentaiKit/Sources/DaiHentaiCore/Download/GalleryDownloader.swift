import CoreGraphics
import Foundation
import Observation

/// Loads one gallery's pages: discovers image-page links 20-ish at a time, downloads images
/// to disk with a small prioritized queue, and tracks per-page state for the reader.
///
/// Files are named `{gid}-{page}` in the gallery folder, the same as 3.x, so pages already
/// on disk are shown without touching the network. A full download also saves the cover
/// (`cover`), which 3.x never did.
@MainActor
@Observable
public final class GalleryDownloader {
    public enum PageState: Equatable, Sendable {
        case idle
        case queued
        case downloading
        case ready(CGSize)
        case failed

        public var isReady: Bool {
            if case .ready = self { true } else { false }
        }
    }

    public enum Phase: Equatable, Sendable {
        /// Checking the gallery / scanning the disk.
        case loading
        case ready
        /// The site says the gallery is gone ("這部作品好像不見囉").
        case notFound
        /// Nothing on disk and the network failed.
        case failed
    }

    public enum CoverState: Equatable, Sendable {
        /// The disk hasn't been checked yet.
        case unknown
        case missing
        case downloading
        case ready
        case failed
    }

    public let gallery: GalleryInfo
    public private(set) var phase: Phase = .loading
    public private(set) var pageStates: [PageState]
    public private(set) var readyCount = 0
    public private(set) var isDownloadingAll = false
    /// Whether any page came from the network this session (a complete gallery found on disk doesn't count).
    public private(set) var didFetchPages = false
    public private(set) var coverState: CoverState = .unknown

    public var pageCount: Int { pageStates.count }
    public var progress: Double { pageCount == 0 ? 0 : Double(readyCount) / Double(pageCount) }
    /// Every page is on disk. This is what readers and progress care about.
    public var arePagesComplete: Bool { pageCount > 0 && readyCount == pageCount }
    /// The cover is on disk, or there is none to save (old records without a thumbnail).
    public var hasCover: Bool { coverState == .ready || gallery.thumbURL == nil }
    /// Every page and the cover are on disk.
    public var isComplete: Bool { arePagesComplete && hasCover }
    /// First page (0-based) whose download failed, if any ("卡在").
    public var firstFailedPage: Int? { pageStates.firstIndex(of: .failed) }

    var readerCount = 0
    var onFinishedAll: (@MainActor () -> Void)?

    private let service: any GalleryService
    private let library: LibraryStore
    private let files: GalleryFileStore
    private let folder: String
    private var links: [String?]
    private var linksPerPage: Int?
    private var loadedLinkPages: Set<Int> = []
    private var linkTasks: [Int: Task<Void, Never>] = [:]
    private var downloadTasks: [Int: Task<Void, Never>] = [:]
    private var queue: [Int] = []
    private var retries: [Int: Int] = [:]
    private var startTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?
    private var coverAttempts = 0
    private var isRetryingFirstLinkPage = false
    private let maxConcurrentDownloads = 3
    private let maxConcurrentLinkFetches = 2

    public init(gallery: GalleryInfo, service: any GalleryService, library: LibraryStore) {
        self.gallery = gallery
        self.service = service
        self.library = library
        self.files = library.files
        self.folder = gallery.folderName
        let count = max(gallery.fileCount, 0)
        self.pageStates = Array(repeating: .idle, count: count)
        self.links = Array(repeating: nil, count: count)
    }

    // MARK: - Public API

    /// Scans the disk and checks the gallery online. Idempotent.
    public func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in await self?.performStart() }
    }

    /// Waits until the first check is done.
    public func waitUntilStarted() async {
        start()
        await startTask?.value
    }

    /// Asks for pages (0-based) to be loaded, most important first. Failed pages are retried.
    public func request(_ indices: [Int]) {
        var front: [Int] = []
        for index in indices where pageStates.indices.contains(index) {
            switch pageStates[index] {
            case .idle, .failed, .queued:
                pageStates[index] = .queued
                front.append(index)
            case .downloading, .ready:
                continue
            }
        }
        guard !front.isEmpty else { return }
        queue.removeAll { front.contains($0) }
        queue.insert(contentsOf: front, at: 0)
        pump()
    }

    /// "我要下載": keep going until every page and the cover are on disk, or nothing is left to try.
    public func downloadAll() {
        isDownloadingAll = true
        start()
        let missing = pageStates.indices.filter { !pageStates[$0].isReady && pageStates[$0] != .downloading }
        for index in missing where pageStates[index] != .queued {
            pageStates[index] = .queued
        }
        queue.append(contentsOf: missing.filter { !queue.contains($0) })
        coverAttempts = 0
        fetchCover()
        pump()
        settle()
    }

    /// Saves the cover next to the pages, unless it's already there.
    public func fetchCover() {
        guard coverTask == nil, coverState != .ready, let url = gallery.thumbURL else { return }
        coverState = .downloading
        let service = service, files = files, folder = folder
        coverTask = Task {
            let saved = await Self.saveCover(from: url, service: service, files: files, folder: folder)
            guard !Task.isCancelled else { return }
            self.coverTask = nil
            if saved {
                self.coverState = .ready
            } else {
                self.coverState = .failed
                self.coverAttempts += 1
                if self.isDownloadingAll, self.coverAttempts < 3 {
                    self.fetchCover()
                    return
                }
            }
            self.settle()
        }
    }

    /// Stops all work (reader closed without a full download, or gallery deleted).
    public func stop() {
        isDownloadingAll = false
        queue.removeAll()
        startTask?.cancel()
        coverTask?.cancel()
        coverTask = nil
        if coverState == .downloading { coverState = .missing }
        linkTasks.values.forEach { $0.cancel() }
        downloadTasks.values.forEach { $0.cancel() }
        linkTasks.removeAll()
        downloadTasks.removeAll()
        for index in pageStates.indices where pageStates[index] == .queued || pageStates[index] == .downloading {
            pageStates[index] = .idle
        }
    }

    /// 「重新載入這頁」: throws the file away and downloads the page again.
    public func reload(page index: Int) {
        guard pageStates.indices.contains(index), pageStates[index] != .downloading else { return }
        try? FileManager.default.removeItem(at: fileURL(forPage: index))
        if pageStates[index].isReady { readyCount -= 1 }
        pageStates[index] = .idle
        retries[index] = nil
        request([index])
    }

    public func fileURL(forPage index: Int) -> URL {
        files.fileURL(folder: folder, fileName: fileName(forPage: index))
    }

    public func pixelSize(ofPage index: Int) -> CGSize? {
        guard pageStates.indices.contains(index), case .ready(let size) = pageStates[index] else { return nil }
        return size
    }

    // MARK: - Start

    private func performStart() async {
        // 1. Whatever is already on disk is readable immediately (also offline).
        let folder = folder, files = files, gid = gallery.gid, count = pageCount
        let (sizes, coverOnDisk) = await Task.detached(priority: .userInitiated) { () -> ([Int: CGSize], Bool) in
            var sizes: [Int: CGSize] = [:]
            for index in 0..<count {
                let url = files.fileURL(folder: folder, fileName: "\(gid)-\(index + 1)")
                if let size = GalleryFileStore.pixelSize(ofImageAt: url) { sizes[index] = size }
            }
            let coverOnDisk = GalleryFileStore.pixelSize(ofImageAt: files.coverURL(folder: folder)) != nil
            return (sizes, coverOnDisk)
        }.value
        guard !Task.isCancelled else { return }
        if coverOnDisk {
            coverState = .ready
        } else if coverState == .unknown {
            coverState = .missing
        }
        for (index, size) in sizes where pageStates.indices.contains(index) && !pageStates[index].isReady {
            pageStates[index] = .ready(size)
            readyCount += 1
        }

        // 2. First link page tells us the gallery exists and how many links each page holds.
        let outcome = await loadLinkPage(0)
        switch outcome {
        case .success:
            phase = .ready
        case .failure(.galleryNotFound):
            phase = readyCount > 0 ? .ready : .notFound
        case .failure:
            phase = readyCount > 0 || pageCount > 0 ? .ready : .failed
        }
        pump()
        settle()
    }

    // MARK: - Links

    private enum LinkOutcome {
        case success
        case failure(SiteError)
    }

    @discardableResult
    private func loadLinkPage(_ linkPage: Int) async -> LinkOutcome {
        if loadedLinkPages.contains(linkPage) { return .success }
        if let running = linkTasks[linkPage] {
            await running.value
            return loadedLinkPages.contains(linkPage) ? .success : .failure(.network)
        }

        var outcome = LinkOutcome.failure(.network)
        let task = Task { [gallery, service, library] in
            if let cached = library.pageList(gid: gallery.gid, token: gallery.token, index: linkPage), !cached.isEmpty {
                self.apply(links: cached, linkPage: linkPage)
                outcome = .success
                return
            }
            do throws(SiteError) {
                let fetched = try await service.imagePageLinks(gid: gallery.gid, token: gallery.token, index: linkPage)
                library.savePageList(fetched, gid: gallery.gid, token: gallery.token, index: linkPage)
                self.apply(links: fetched, linkPage: linkPage)
                outcome = .success
            } catch {
                outcome = .failure(error)
            }
        }
        linkTasks[linkPage] = task
        await task.value
        linkTasks[linkPage] = nil
        return outcome
    }

    private func apply(links fetched: [String], linkPage: Int) {
        if linkPage == 0 {
            linksPerPage = fetched.count
            if pageCount == 0 { grow(to: fetched.count) }
        }
        loadedLinkPages.insert(linkPage)
        for link in fetched {
            guard let page = ImagePage(link) else { continue }
            let index = page.page - 1
            if index >= pageCount { grow(to: index + 1) }
            links[index] = link
        }
        // Galleries with unknown size (old records): keep discovering while pages come back full.
        if gallery.fileCount == 0, let perPage = linksPerPage, fetched.count == perPage {
            Task { await self.loadLinkPage(linkPage + 1); self.pump(); self.settle() }
        }
    }

    private func grow(to count: Int) {
        guard count > pageStates.count else { return }
        pageStates += Array(repeating: .idle, count: count - pageStates.count)
        links += Array(repeating: nil, count: count - links.count)
        if isDownloadingAll { downloadAll() }
    }

    private func linkPage(forPage index: Int) -> Int? {
        guard let perPage = linksPerPage, perPage > 0 else { return nil }
        return index / perPage
    }

    // MARK: - Queue

    private func pump() {
        guard phase != .loading || !links.allSatisfy({ $0 == nil }) else { return }
        var index = 0
        while downloadTasks.count < maxConcurrentDownloads, index < queue.count {
            let page = queue[index]
            guard pageStates.indices.contains(page), pageStates[page] == .queued else {
                queue.remove(at: index)
                continue
            }
            if let link = links[page] {
                queue.remove(at: index)
                startDownload(page, link: link)
            } else if let linkPage = linkPage(forPage: page) {
                if loadedLinkPages.contains(linkPage) {
                    // The site lists fewer pages than the gallery claims.
                    pageStates[page] = .failed
                    queue.remove(at: index)
                    continue
                }
                if linkTasks[linkPage] == nil, linkTasks.count < maxConcurrentLinkFetches {
                    Task {
                        let outcome = await self.loadLinkPage(linkPage)
                        if case .failure = outcome { self.failPages(onLinkPage: linkPage) }
                        self.pump()
                        self.settle()
                    }
                }
                index += 1
            } else {
                // The first link page failed (offline?): try it once more, then give up on what's queued.
                if phase != .loading, !isRetryingFirstLinkPage {
                    isRetryingFirstLinkPage = true
                    Task {
                        let outcome = await self.loadLinkPage(0)
                        self.isRetryingFirstLinkPage = false
                        if case .failure = outcome { self.failQueuedPages() }
                        self.pump()
                        self.settle()
                    }
                }
                index += 1
            }
        }
    }

    private func failQueuedPages() {
        for index in queue where pageStates.indices.contains(index) && pageStates[index] == .queued {
            pageStates[index] = .failed
        }
        queue.removeAll()
    }

    private func failPages(onLinkPage linkPage: Int) {
        guard let perPage = linksPerPage else { return }
        for index in (linkPage * perPage)..<min((linkPage + 1) * perPage, pageCount) where links[index] == nil && pageStates[index] == .queued {
            pageStates[index] = .failed
        }
        queue.removeAll { pageStates.indices.contains($0) && pageStates[$0] == .failed }
    }

    private func startDownload(_ index: Int, link: String) {
        pageStates[index] = .downloading
        let service = service, files = files, folder = folder, fileName = fileName(forPage: index)
        downloadTasks[index] = Task {
            let size = await Self.fetchImage(link: link, service: service, files: files, folder: folder, fileName: fileName)
            guard !Task.isCancelled else { return }
            self.downloadTasks[index] = nil
            if let size {
                self.didFetchPages = true
                if !self.pageStates[index].isReady { self.readyCount += 1 }
                self.pageStates[index] = .ready(size)
            } else {
                self.pageStates[index] = .failed
                let attempts = self.retries[index, default: 0] + 1
                self.retries[index] = attempts
                if self.isDownloadingAll, attempts < 3 {
                    self.pageStates[index] = .queued
                    self.queue.append(index)
                }
            }
            self.pump()
            self.settle()
        }
    }

    @concurrent
    private static func fetchImage(link: String, service: any GalleryService, files: GalleryFileStore, folder: String, fileName: String) async -> CGSize? {
        do {
            let url = try await service.imageURL(forImagePage: link)
            let data = try await service.imageData(from: url)
            guard let size = GalleryFileStore.pixelSize(ofImageData: data) else { return nil }
            try files.write(data, folder: folder, fileName: fileName)
            return size
        } catch {
            return nil
        }
    }

    @concurrent
    private static func saveCover(from url: URL, service: any GalleryService, files: GalleryFileStore, folder: String) async -> Bool {
        if GalleryFileStore.pixelSize(ofImageAt: files.coverURL(folder: folder)) != nil { return true }
        do {
            let data = try await service.imageData(from: url)
            guard GalleryFileStore.pixelSize(ofImageData: data) != nil else { return false }
            try files.write(data, folder: folder, fileName: GalleryFileStore.coverFileName)
            return true
        } catch {
            return false
        }
    }

    /// Ends a full download once everything is on disk, or once nothing is left to try
    /// (pages or the cover failed after their retries). 「繼續下載」 picks it up again later.
    private func settle() {
        guard isDownloadingAll, phase != .loading else { return }
        let isIdle = queue.isEmpty && downloadTasks.isEmpty && linkTasks.isEmpty && coverTask == nil
        guard isComplete || isIdle else { return }
        isDownloadingAll = false
        onFinishedAll?()
    }

    private func fileName(forPage index: Int) -> String {
        if links.indices.contains(index), let link = links[index] {
            return ImagePage.fileName(for: link)
        }
        return "\(gallery.gid)-\(index + 1)"
    }
}
