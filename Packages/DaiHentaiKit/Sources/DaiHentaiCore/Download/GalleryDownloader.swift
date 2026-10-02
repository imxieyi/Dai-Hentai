import CoreGraphics
import Foundation
import Observation

/// Loads one gallery's pages: discovers image-page links 20-ish at a time, downloads images
/// to disk with a small prioritized queue, and tracks per-page state for the reader.
///
/// Files are named `{gid}-{page}` in the gallery folder, the same as 3.x, so pages already
/// on disk are shown without touching the network. A full download also saves the cover
/// (`cover`), which 3.x never did.
///
/// Online reading saves what the site shows (resampled and recompressed). A downloaded gallery
/// saves the original files instead, where the site allows it. Replacing reduced pages already on
/// disk with originals is separate work (`Work.originals`), since it spends the user's image limits.
///
/// Once the image limits run out, the site only shows a placeholder: that stops everything.
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

    /// What a full download does.
    public struct Work: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Missing pages (as originals where the site allows it) and the cover.
        public static let missing = Work(rawValue: 1 << 0)
        /// Reduced pages on disk, replaced with originals.
        public static let originals = Work(rawValue: 1 << 1)
    }

    /// Why the site wouldn't hand out originals.
    public enum OriginalsRefusal: Hashable, Sendable {
        /// Originals need a login. Holds for every gallery.
        case needsLogin
        /// This gallery's originals cost GP (older galleries, or any during peak hours), and the account is short.
        case needsGP
        /// Something else came back instead of the file.
        case other
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
    /// What the running full download does; empty when none is running.
    public private(set) var work: Work = []
    public var isDownloadingAll: Bool { !work.isEmpty }
    /// Whether any page came from the network this session (a complete gallery found on disk doesn't count).
    public private(set) var didFetchPages = false
    public private(set) var coverState: CoverState = .unknown
    /// Pages (0-based) on disk as the site's original file.
    public private(set) var originalPages: Set<Int> = []
    /// Reduced pages this full download still replaces with originals, including the ones it's replacing now.
    public private(set) var pagesToReplace: Set<Int> = []
    /// Bumped when a page's file is replaced while it stays readable, so readers decode it again.
    public private(set) var pageRevisions: [Int: Int] = [:]
    /// The site answered an original's link with something else during this download (a login page, or
    /// "requires GP"). Missing pages carry on as the site shows them; replacing pages stops.
    public private(set) var originalsRefusal: OriginalsRefusal?
    public var wereOriginalsRefused: Bool { originalsRefusal != nil }
    /// The image limits ran out, which stopped everything.
    public private(set) var didHitRateLimit = false

    public var pageCount: Int { pageStates.count }
    /// Pages a full download is done with: on disk, and no longer waiting to be replaced with the original.
    public var completedCount: Int { readyCount - pagesToReplace.count }
    public var progress: Double { pageCount == 0 ? 0 : Double(completedCount) / Double(pageCount) }
    /// Every page is on disk. This is what readers and progress care about.
    public var arePagesComplete: Bool { pageCount > 0 && readyCount == pageCount }
    /// Every page is on disk as the original.
    public var isOriginalQuality: Bool { pageCount > 0 && originalPages.count == pageCount }
    /// The cover is on disk, or there is none to save (old records without a thumbnail).
    public var hasCover: Bool { coverState == .ready || gallery.thumbURL == nil }
    /// Every page and the cover are on disk.
    public var isComplete: Bool { arePagesComplete && hasCover }
    /// First page (0-based) whose download failed, if any ("卡在").
    public var firstFailedPage: Int? { pageStates.firstIndex(of: .failed) }

    var readerCount = 0
    var onFinishedAll: (@MainActor () -> Void)?
    /// Called once the image limits stopped this downloader, so other downloads stop too.
    var onRateLimited: (@MainActor () -> Void)?

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
    /// Saved link pages turned out to disagree with the site, so they're being fetched again (once per downloader).
    private var isRefreshingLinks = false
    private var didRefreshLinks = false
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

    /// A full download: keeps going until its `work` is done, or nothing is left to try.
    /// - `.missing` (「繼續下載」): every missing page, saved as the original where the site allows it,
    ///   and the cover.
    /// - `.originals` (「升級成原圖」): reduced pages on disk (from online reading, 3.x, or a refused
    ///   original) are replaced with originals. They stay readable meanwhile.
    ///
    /// 「我要下載」 does both. `asksForOriginals: false` skips originals for missing pages (another gallery
    /// was just refused them for want of a login).
    public func downloadAll(_ work: Work = [.missing, .originals], asksForOriginals: Bool = true) {
        guard !work.isEmpty else { return }
        self.work.formUnion(work)
        originalsRefusal = asksForOriginals ? nil : .needsLogin
        didHitRateLimit = false
        start()
        queueRemainingPages()
        if work.contains(.missing) {
            coverAttempts = 0
            fetchCover()
        }
        pump()
        settle()
    }

    private func queueRemainingPages() {
        if work.contains(.missing) {
            let missing = pageStates.indices.filter { !pageStates[$0].isReady && pageStates[$0] != .downloading }
            for index in missing where pageStates[index] != .queued {
                pageStates[index] = .queued
            }
            queue.append(contentsOf: missing.filter { !queue.contains($0) })
        }
        queueReplacements(pageStates.indices.filter { pageStates[$0].isReady })
    }

    /// Queues pages on disk that aren't originals to be replaced, when this download does that.
    /// They go after the missing pages.
    private func queueReplacements(_ indices: [Int]) {
        guard work.contains(.originals), !wereOriginalsRefused else { return }
        let reduced = indices.filter { pageStates[$0].isReady && !originalPages.contains($0) && !pagesToReplace.contains($0) }
        for index in reduced { retries[index] = nil }
        pagesToReplace.formUnion(reduced)
        queue.append(contentsOf: reduced.filter { !queue.contains($0) })
    }

    /// The site won't hand out originals right now: stop asking until the next full download.
    private func refuseOriginals(_ reason: OriginalsRefusal) {
        if originalsRefusal == nil || reason == .needsLogin { originalsRefusal = reason }
        let waiting = pagesToReplace.filter { downloadTasks[$0] == nil }
        pagesToReplace.subtract(waiting)
        queue.removeAll { waiting.contains($0) }
    }

    /// Downloaded galleries keep originals; online reading keeps what the site shows.
    private var savesOriginals: Bool {
        !wereOriginalsRefused && (isDownloadingAll || library.isDownloaded(gallery))
    }

    /// The site only shows its image-limits placeholder now: stop everything, and let the others know.
    private func hitRateLimit() {
        guard !didHitRateLimit else { return }
        stop()
        didHitRateLimit = true
        onRateLimited?()
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
                if self.work.contains(.missing), self.coverAttempts < 3 {
                    self.fetchCover()
                    return
                }
            }
            self.settle()
        }
    }

    /// Stops all work (reader closed without a full download, or gallery deleted).
    public func stop() {
        work = []
        queue.removeAll()
        pagesToReplace.removeAll()
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
        guard pageStates.indices.contains(index), pageStates[index] != .downloading, downloadTasks[index] == nil else { return }
        try? FileManager.default.removeItem(at: fileURL(forPage: index))
        if pageStates[index].isReady { readyCount -= 1 }
        originalPages.remove(index)
        pagesToReplace.remove(index)
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
        let (sizes, originals, coverOnDisk) = await Task.detached(priority: .userInitiated) { () -> ([Int: CGSize], Set<Int>, Bool) in
            var sizes: [Int: CGSize] = [:]
            var originals: Set<Int> = []
            for index in 0..<count {
                let fileName = "\(gid)-\(index + 1)"
                if let size = GalleryFileStore.pixelSize(ofImageAt: files.fileURL(folder: folder, fileName: fileName)) {
                    sizes[index] = size
                    if files.isMarkedOriginal(folder: folder, fileName: fileName) { originals.insert(index) }
                }
            }
            let coverOnDisk = GalleryFileStore.pixelSize(ofImageAt: files.coverURL(folder: folder)) != nil
            return (sizes, originals, coverOnDisk)
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
            if originals.contains(index) { originalPages.insert(index) }
        }
        // A full download that started before the disk was checked replaces what turned up.
        queueReplacements(sizes.keys.sorted())

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
    private func loadLinkPage(_ linkPage: Int, ignoringCache: Bool = false) async -> LinkOutcome {
        if loadedLinkPages.contains(linkPage) { return .success }
        if let running = linkTasks[linkPage] {
            await running.value
            return loadedLinkPages.contains(linkPage) ? .success : .failure(.network)
        }

        var outcome = LinkOutcome.failure(.network)
        let task = Task { [gallery, service, library] in
            if !ignoringCache, let cached = library.pageList(gid: gallery.gid, token: gallery.token, index: linkPage), !cached.isEmpty {
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
        if isDownloadingAll {
            queueRemainingPages()
            pump()
        }
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
            guard isWaiting(page) else {
                queue.remove(at: index)
                continue
            }
            if let link = links[page] {
                queue.remove(at: index)
                if pageStates[page].isReady {
                    startReplacement(page, link: link)
                } else {
                    startDownload(page, link: link)
                }
            } else if let linkPage = linkPage(forPage: page) {
                if loadedLinkPages.contains(linkPage) {
                    if !didRefreshLinks {
                        // The saved link pages may hold a different number of links each (3.x saved 20 a page, and
                        // the site's thumbnail settings change): ask the site before believing the page is gone.
                        refreshLinks()
                        index += 1
                        continue
                    }
                    // The site lists fewer pages than the gallery claims.
                    giveUp(page)
                    queue.remove(at: index)
                    continue
                }
                if !isRefreshingLinks, linkTasks[linkPage] == nil, linkTasks.count < maxConcurrentLinkFetches {
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
                if phase != .loading, !isRetryingFirstLinkPage, !isRefreshingLinks {
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

    /// Fetches the first link page from the site again, and forgets the saved ones after it, so link pages are
    /// counted the way the site lists them now. Links already found stay: each one names its page.
    private func refreshLinks() {
        didRefreshLinks = true
        isRefreshingLinks = true
        loadedLinkPages.removeAll()
        linksPerPage = nil
        Task {
            let outcome = await self.loadLinkPage(0, ignoringCache: true)
            self.isRefreshingLinks = false
            if case .success = outcome {
                self.library.deletePageLists(gid: self.gallery.gid, token: self.gallery.token, after: 0)
            } else {
                self.failQueuedPages()
            }
            self.pump()
            self.settle()
        }
    }

    /// A queued page still to download, or a reduced page still to replace.
    private func isWaiting(_ page: Int) -> Bool {
        guard pageStates.indices.contains(page), downloadTasks[page] == nil else { return false }
        return pageStates[page] == .queued || (pageStates[page].isReady && pagesToReplace.contains(page))
    }

    /// Nothing more to try for a queued page (it fails) or a page to replace (it stays reduced).
    private func giveUp(_ page: Int) {
        if pageStates[page] == .queued {
            pageStates[page] = .failed
        } else {
            pagesToReplace.remove(page)
        }
    }

    private func failQueuedPages() {
        for index in queue where isWaiting(index) {
            giveUp(index)
        }
        queue.removeAll()
    }

    private func failPages(onLinkPage linkPage: Int) {
        guard let perPage = linksPerPage else { return }
        for index in (linkPage * perPage)..<min((linkPage + 1) * perPage, pageCount) where links[index] == nil && isWaiting(index) {
            giveUp(index)
        }
        queue.removeAll { !isWaiting($0) }
    }

    private func startDownload(_ index: Int, link: String) {
        pageStates[index] = .downloading
        let service = service, files = files, folder = folder, fileName = fileName(forPage: index), wantsOriginal = savesOriginals
        downloadTasks[index] = Task {
            let outcome = await Self.fetchPage(link: link, wantsOriginal: wantsOriginal, service: service, files: files, folder: folder, fileName: fileName)
            guard !Task.isCancelled else {
                // Stopped while the page was being saved: it's on disk all the same.
                if case .saved(let fetched) = outcome, !self.pageStates[index].isReady {
                    self.readyCount += 1
                    self.pageStates[index] = .ready(fetched.size)
                    if fetched.isOriginal { self.originalPages.insert(index) }
                }
                return
            }
            self.downloadTasks[index] = nil
            if case .rateLimited = outcome {
                self.pageStates[index] = .failed
                self.hitRateLimit()
                return
            }
            if case .saved(let fetched) = outcome {
                self.didFetchPages = true
                if !self.pageStates[index].isReady { self.readyCount += 1 }
                self.pageStates[index] = .ready(fetched.size)
                if fetched.isOriginal {
                    self.originalPages.insert(index)
                } else {
                    self.originalPages.remove(index)
                }
                if let refusal = fetched.originalRefusal {
                    self.refuseOriginals(refusal)
                } else if !fetched.isOriginal, !fetched.askedForOriginal {
                    // Fetched for reading just before 「我要下載」.
                    self.queueReplacements([index])
                }
            } else {
                self.pageStates[index] = .failed
                let attempts = self.retries[index, default: 0] + 1
                self.retries[index] = attempts
                if self.work.contains(.missing), attempts < 3 {
                    self.pageStates[index] = .queued
                    self.queue.append(index)
                }
            }
            self.pump()
            self.settle()
        }
    }

    private func startReplacement(_ index: Int, link: String) {
        let service = service, files = files, folder = folder, fileName = fileName(forPage: index)
        downloadTasks[index] = Task {
            let outcome = await Self.replaceWithOriginal(link: link, service: service, files: files, folder: folder, fileName: fileName)
            guard !Task.isCancelled else { return }
            self.downloadTasks[index] = nil
            switch outcome {
            case .original(let size, let replaced):
                self.originalPages.insert(index)
                self.pagesToReplace.remove(index)
                if replaced {
                    self.didFetchPages = true
                    self.pageStates[index] = .ready(size)
                    self.pageRevisions[index, default: 0] += 1
                }
            case .refused(let reason):
                self.pagesToReplace.remove(index)
                self.refuseOriginals(reason)
            case .rateLimited:
                self.hitRateLimit()
                return
            case .failed:
                let attempts = self.retries[index, default: 0] + 1
                self.retries[index] = attempts
                if self.work.contains(.originals), attempts < 3 {
                    self.queue.append(index)
                } else {
                    self.pagesToReplace.remove(index)
                }
            }
            self.pump()
            self.settle()
        }
    }

    private struct FetchedPage: Sendable {
        var size: CGSize
        /// The saved file is the original: fetched as such, or the page shows the original itself.
        var isOriginal: Bool
        /// The original was asked for: this is the best this download gets, even if the fetch fell back.
        var askedForOriginal: Bool
        /// The site answered the original's link with something else.
        var originalRefusal: OriginalsRefusal?
    }

    private enum PageFetch: Sendable {
        case saved(FetchedPage)
        case failed
        case rateLimited
    }

    /// Downloads a missing page: the original when `wantsOriginal` and the site hands it out,
    /// otherwise (or when that fails) what the page shows, so the page is readable either way.
    @concurrent
    private static func fetchPage(link: String, wantsOriginal: Bool, service: any GalleryService, files: GalleryFileStore, folder: String, fileName: String) async -> PageFetch {
        let imageKey = ImagePage(link)?.imageKey ?? ""
        do {
            let source = try await service.imageSource(forImagePage: link)
            var refusal: OriginalsRefusal?
            if wantsOriginal, let originalURL = source.originalURL {
                do {
                    let data = try await service.imageData(from: originalURL)
                    if GalleryFileStore.isOriginal(data, imageKey: imageKey), let size = GalleryFileStore.pixelSize(ofImageData: data) {
                        try files.write(data, folder: folder, fileName: fileName, isOriginal: true)
                        return .saved(FetchedPage(size: size, isOriginal: true, askedForOriginal: true, originalRefusal: nil))
                    }
                    // Something that isn't the file.
                    refusal = .other
                } catch SiteError.rateLimited {
                    return .rateLimited
                } catch SiteError.network {
                    // Network trouble: fall back to what the page shows.
                } catch {
                    // A login bounce, "requires GP", or some other page instead of the file.
                    refusal = Self.refusal(for: error)
                }
            }
            let data = try await service.imageData(from: source.url)
            guard let size = GalleryFileStore.pixelSize(ofImageData: data) else { return .failed }
            let isOriginal = GalleryFileStore.isOriginal(data, imageKey: imageKey)
            try files.write(data, folder: folder, fileName: fileName, isOriginal: isOriginal)
            return .saved(FetchedPage(size: size, isOriginal: isOriginal, askedForOriginal: wantsOriginal && source.originalURL != nil, originalRefusal: refusal))
        } catch SiteError.rateLimited {
            return .rateLimited
        } catch {
            return .failed
        }
    }

    private enum Replacement: Sendable {
        /// The file is the original now: it already was, or it was just `replaced`.
        case original(CGSize, replaced: Bool)
        /// The site answered the original's link with something else (a login page, or "requires GP").
        case refused(OriginalsRefusal)
        case rateLimited
        case failed
    }

    /// Replaces a reduced page on disk with the original. The reduced file stays until the original is in hand.
    @concurrent
    private static func replaceWithOriginal(link: String, service: any GalleryService, files: GalleryFileStore, folder: String, fileName: String) async -> Replacement {
        guard let imageKey = ImagePage(link)?.imageKey else { return .failed }
        // Pages the site never resampled were saved as originals all along (by 3.x too); they only need the mark.
        if files.verifyOriginal(folder: folder, fileName: fileName, imageKey: imageKey),
           let size = GalleryFileStore.pixelSize(ofImageAt: files.fileURL(folder: folder, fileName: fileName)) {
            return .original(size, replaced: false)
        }
        let source: PageImageSource
        do {
            source = try await service.imageSource(forImagePage: link)
        } catch {
            return error == .rateLimited ? .rateLimited : .failed
        }
        // Without an original link, what the page shows is the original.
        let hasOriginalLink = source.originalURL != nil
        do {
            let data = try await service.imageData(from: source.originalURL ?? source.url)
            guard GalleryFileStore.isOriginal(data, imageKey: imageKey), let size = GalleryFileStore.pixelSize(ofImageData: data) else {
                return hasOriginalLink ? .refused(.other) : .failed
            }
            try files.write(data, folder: folder, fileName: fileName, isOriginal: true)
            return .original(size, replaced: true)
        } catch SiteError.rateLimited {
            return .rateLimited
        } catch SiteError.network {
            return .failed
        } catch {
            // A login bounce, "requires GP", or some other page instead of the original.
            return hasOriginalLink ? .refused(refusal(for: error)) : .failed
        }
    }

    private nonisolated static func refusal(for error: any Error) -> OriginalsRefusal {
        switch error as? SiteError {
        case .loginRequired: .needsLogin
        case .originalsNeedGP: .needsGP
        default: .other
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

    /// Ends a full download once its work is done (every page and the cover on disk, reduced pages
    /// replaced), or once nothing is left to try (pages or the cover failed after their retries, or
    /// originals were refused). The Downloads tab's buttons pick it up again later.
    private func settle() {
        guard isDownloadingAll, phase != .loading else { return }
        let isIdle = queue.isEmpty && downloadTasks.isEmpty && linkTasks.isEmpty && coverTask == nil && !isRefreshingLinks
        let isDone = (!work.contains(.missing) || isComplete) && pagesToReplace.isEmpty
        guard isDone || isIdle else { return }
        work = []
        onFinishedAll?()
    }

    private func fileName(forPage index: Int) -> String {
        if links.indices.contains(index), let link = links[index] {
            return ImagePage.fileName(for: link)
        }
        return "\(gallery.gid)-\(index + 1)"
    }
}
