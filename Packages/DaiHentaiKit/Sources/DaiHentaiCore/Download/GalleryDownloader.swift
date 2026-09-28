import CoreGraphics
import Foundation
import Observation

/// Loads one gallery's pages: discovers image-page links 20-ish at a time, downloads images
/// to disk with a small prioritized queue, and tracks per-page state for the reader.
///
/// Files are named `{gid}-{page}` in the gallery folder, the same as 3.x, so pages already
/// on disk are shown without touching the network.
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

    public let gallery: GalleryInfo
    public private(set) var phase: Phase = .loading
    public private(set) var pageStates: [PageState]
    public private(set) var readyCount = 0
    public private(set) var isDownloadingAll = false
    /// Whether any page came from the network this session (a complete gallery found on disk doesn't count).
    public private(set) var didFetchPages = false

    public var pageCount: Int { pageStates.count }
    public var progress: Double { pageCount == 0 ? 0 : Double(readyCount) / Double(pageCount) }
    public var isComplete: Bool { pageCount > 0 && readyCount == pageCount }
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

    /// "我要下載": keep going until every page is on disk.
    public func downloadAll() {
        isDownloadingAll = true
        start()
        let missing = pageStates.indices.filter { !pageStates[$0].isReady && pageStates[$0] != .downloading }
        for index in missing where pageStates[index] != .queued {
            pageStates[index] = .queued
        }
        queue.append(contentsOf: missing.filter { !queue.contains($0) })
        pump()
        finishIfComplete()
    }

    /// Stops all work (reader closed without a full download, or gallery deleted).
    public func stop() {
        isDownloadingAll = false
        queue.removeAll()
        startTask?.cancel()
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
        let sizes = await Task.detached(priority: .userInitiated) { () -> [Int: CGSize] in
            var sizes: [Int: CGSize] = [:]
            for index in 0..<count {
                let url = files.fileURL(folder: folder, fileName: "\(gid)-\(index + 1)")
                if let size = GalleryFileStore.pixelSize(ofImageAt: url) { sizes[index] = size }
            }
            return sizes
        }.value
        guard !Task.isCancelled else { return }
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
        finishIfComplete()
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
            Task { await self.loadLinkPage(linkPage + 1); self.pump() }
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
            } else {
                if let linkPage = linkPage(forPage: page), linkTasks[linkPage] == nil, !loadedLinkPages.contains(linkPage), linkTasks.count < maxConcurrentLinkFetches {
                    Task {
                        let outcome = await self.loadLinkPage(linkPage)
                        if case .failure = outcome { self.failPages(onLinkPage: linkPage) }
                        self.pump()
                    }
                }
                index += 1
            }
        }
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
            self.finishIfComplete()
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

    private func finishIfComplete() {
        guard isDownloadingAll, isComplete else { return }
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
