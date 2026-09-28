import DaiHentaiCore
import Foundation
import SwiftUI

/// Reading state for one gallery: which page is current, what is laid out, progress saving.
///
/// Vertical mode only lays out a contiguous run of downloaded pages (from `runStart`), followed by a
/// 「第 N 頁載入中...」 row, so pages never change height under the reader's finger — the same rule
/// as 3.x. Horizontal mode lays out every page at screen size.
@Observable
final class ReaderModel {
    let gallery: GalleryInfo
    private let startPage: Int?
    private unowned let app: AppModel

    private(set) var downloader: GalleryDownloader?
    /// 0-based page at the middle of the screen.
    private(set) var currentPage = 0
    /// Vertical: first page of the laid-out run.
    private(set) var runStart = 0
    /// 1-based page offered by 「您曾經閱讀過此作品」.
    var resumeOffer: Int?
    var isChromeVisible = true
    private(set) var direction: ReadingDirection
    /// A scroll the view should perform: (0-based page, animated).
    private(set) var scrollRequest: ScrollRequest?
    /// Target of a programmatic scroll still settling. Layout passes during it must not move
    /// `currentPage` (a fresh scroll view first reports whatever page it happens to show).
    private(set) var pendingScroll: Int?
    /// Bumped when a page is reloaded so its image is decoded again.
    private(set) var pageVersions: [Int: Int] = [:]
    var isDeleted = false
    private var pendingPrepend: Int?
    private var saveTask: Task<Void, Never>?
    private var hasUserPosition = false
    /// The user has dragged the pages at least once.
    private var hasScrolled = false

    struct ScrollRequest: Equatable {
        let id = UUID()
        var page: Int
        var animated: Bool
        var anchor: UnitPoint = .top
    }

    static let headerHeight: CGFloat = 64
    /// Scroll id of the 「第 N 頁載入中...」 row (pages use their index).
    static let tailID = -2

    init(route: ReaderRoute, app: AppModel) {
        self.gallery = route.gallery
        self.startPage = route.startPage
        self.app = app
        self.direction = app.library.preferences.readingDirection
    }

    // MARK: - Lifecycle

    func appear() {
        if downloader == nil {
            let lastPage = app.library.recordVisit(gallery)
            downloader = app.downloads.attachReader(to: gallery)
            if let startPage, startPage > 1 {
                jump(to: startPage - 1, animated: false)
                hasUserPosition = true
            } else if startPage == nil, lastPage > 1 {
                resumeOffer = lastPage
            } else {
                hasUserPosition = startPage != nil
            }
        } else if let downloader, app.downloads.downloaders[gallery.id] !== downloader {
            // Came back after the tab was switched away: pick the downloader up again.
            self.downloader = app.downloads.attachReader(to: gallery)
        }
        requestAround()
    }

    func disappear() {
        saveNow()
        guard !isDeleted else { return }
        app.downloads.detachReader(from: gallery)
    }

    /// Network failed with nothing on disk: start over.
    func retry() {
        app.downloads.detachReader(from: gallery)
        downloader = app.downloads.attachReader(to: gallery)
        requestAround()
    }

    // MARK: - Pages

    var pageCount: Int { downloader?.pageCount ?? gallery.fileCount }

    func isReady(_ page: Int) -> Bool {
        guard let downloader, downloader.pageStates.indices.contains(page) else { return false }
        return downloader.pageStates[page].isReady
    }

    func state(of page: Int) -> GalleryDownloader.PageState {
        guard let downloader, downloader.pageStates.indices.contains(page) else { return .idle }
        return downloader.pageStates[page]
    }

    /// Vertical: end (exclusive) of the contiguous run of ready pages starting at `runStart`.
    var runEnd: Int {
        var index = runStart
        while index < pageCount, isReady(index) { index += 1 }
        return index
    }

    /// First page from `start` on that isn't on disk yet.
    private func firstMissing(from start: Int) -> Int? {
        (max(0, start)..<pageCount).first { !isReady($0) }
    }

    func aspectRatio(of page: Int) -> CGFloat {
        guard let size = downloader?.pixelSize(ofPage: page), size.width > 0 else { return 1.414 }
        return size.height / size.width
    }

    func fileURL(forPage page: Int) -> URL? {
        downloader?.fileURL(forPage: page)
    }

    /// Legacy title line: 「當前:12 總共:40」 / 「當前:12 卡在:13」 / 「讀取中」.
    var statusText: String {
        guard let downloader, downloader.readyCount > 0 else { return "讀取中" }
        let stuck = direction == .vertical ? (runEnd < pageCount ? runEnd : nil) : firstMissing(from: currentPage)
        if let stuck {
            return "當前:\(currentPage + 1) 卡在:\(stuck + 1)"
        }
        return "當前:\(currentPage + 1) 總共:\(pageCount)"
    }

    // MARK: - Position

    /// Vertical: a page (or the loading row) crossed the middle of the screen.
    func pageReachedCenter(_ page: Int) {
        guard pageCount > 0, pendingScroll == nil else { return }
        setCurrent(min(max(page, 0), pageCount - 1))
    }

    /// Asks the view to scroll, holding `currentPage` until it has.
    private func requestScroll(to page: Int, animated: Bool = false) {
        pendingScroll = page
        scrollRequest = ScrollRequest(page: page, animated: animated)
    }

    func scrollSettled(on page: Int) {
        if pendingScroll == page { pendingScroll = nil }
    }

    /// Rotation: keep the current page.
    func keepCurrentPage() {
        requestScroll(to: currentPage)
    }

    func userDidScroll() {
        hasScrolled = true
        pendingScroll = nil
        if isEarlierRowVisible { loadEarlierPages() }
    }

    /// Vertical: whether the 「載入前面的頁面」 row is on screen. Right after a jump it is, so
    /// loading waits until the user actually scrolls up to it.
    private var isEarlierRowVisible = false

    func earlierRowVisibilityChanged(_ visible: Bool) {
        isEarlierRowVisible = visible
        if visible, hasScrolled { loadEarlierPages() }
        checkPrepend()
    }

    /// Horizontal: the page filling the screen.
    func updateHorizontal(offsetX: CGFloat, pageWidth: CGFloat) {
        guard pageCount > 0, pageWidth > 0, pendingScroll == nil else { return }
        let page = Int(((offsetX + pageWidth / 2) / pageWidth).rounded(.down))
        setCurrent(min(max(page, 0), pageCount - 1))
    }

    private func setCurrent(_ page: Int) {
        guard page != currentPage else { return }
        currentPage = page
        if hasScrolled, page > 0 {
            // Scrolling on means "from the start" was the answer.
            if resumeOffer != nil { withAnimation(.smooth) { resumeOffer = nil } }
            hasUserPosition = true
        }
        requestAround()
        scheduleSave()
    }

    /// Scrubber, 跳到第幾頁…, 繼續從 N 頁看起, keyboard.
    func jump(to page: Int, animated: Bool = false) {
        let target = min(max(page, 0), max(pageCount - 1, 0))
        if direction == .vertical, !(runStart...runEnd).contains(target) {
            // Outside the laid-out run: start a new run there.
            runStart = target
            pendingPrepend = nil
        }
        currentPage = target
        hasUserPosition = true
        resumeOffer = nil
        requestScroll(to: target, animated: animated && direction == .horizontal)
        requestAround()
        scheduleSave()
    }

    func acceptResume() {
        guard let page = resumeOffer else { return }
        withAnimation(.smooth) { resumeOffer = nil }
        jump(to: page - 1)
    }

    func declineResume() {
        withAnimation(.smooth) { resumeOffer = nil }
        hasUserPosition = true
        scheduleSave()
    }

    /// Vertical: the 「載入前面的頁面」 row came into view.
    func loadEarlierPages() {
        guard runStart > 0, pendingPrepend == nil else { return }
        let newStart = max(0, runStart - 10)
        pendingPrepend = newStart
        downloader?.request(Array((newStart..<runStart).reversed()))
        // What's on screen stays first in line.
        requestAround()
        checkPrepend()
    }

    /// Adds the earlier pages once they are all on disk, keeping the current page where it is.
    func checkPrepend() {
        // Only while the user is at the top, so reading further down is never interrupted.
        guard let newStart = pendingPrepend, isEarlierRowVisible else { return }
        // The anchor page must be laid out too, or there is nothing to keep in place.
        guard (newStart...runStart).allSatisfy(isReady) else { return }
        let anchor = runStart
        pendingPrepend = nil
        runStart = newStart
        requestScroll(to: anchor)
    }

    var isLoadingEarlierPages: Bool { pendingPrepend != nil }

    func setDirection(_ newDirection: ReadingDirection) {
        guard newDirection != direction else { return }
        let page = currentPage
        direction = newDirection
        app.library.preferences.readingDirection = newDirection
        app.toasts.show(newDirection == .horizontal ? "閱讀方向改為橫向" : "閱讀方向改為直向", duration: .seconds(1))
        if newDirection == .vertical, !(runStart...runEnd).contains(page) {
            runStart = page
        }
        requestScroll(to: page)
        requestAround()
    }

    func toggleChrome() {
        withAnimation(.smooth(duration: 0.25)) { isChromeVisible.toggle() }
    }

    func reload(page: Int) {
        downloader?.reload(page: page)
        pageVersions[page, default: 0] += 1
        Task { await ImagePipeline.shared.removePages(inFolder: app.library.files.folderURL(gallery.folderName)) }
    }

    /// Asks the downloader for what's about to be read.
    func requestAround() {
        guard let downloader, downloader.pageCount > 0 else { return }
        var pages = Array(currentPage..<min(currentPage + 4, pageCount))
        if direction == .vertical {
            let end = runEnd
            if end < pageCount { pages += Array(end..<min(end + 3, pageCount)) }
        } else if currentPage > 0 {
            pages.append(currentPage - 1)
        }
        downloader.request(pages)
    }

    // MARK: - Progress

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Saves the 1-based page. Skipped while 「您曾經閱讀過此作品」 is still unanswered.
    func saveNow() {
        saveTask?.cancel()
        guard !isDeleted, hasUserPosition, resumeOffer == nil, pageCount > 0 else { return }
        app.library.setLastReadPage(currentPage + 1, for: gallery)
    }

    // MARK: - Actions

    var isDownloaded: Bool { app.library.isDownloaded(gallery) }

    func download() {
        app.download(gallery)
    }

    func delete() {
        isDeleted = true
        saveTask?.cancel()
        app.delete(gallery)
        app.router.popReader(of: gallery)
        app.toasts.show("作品刪掉囉", kaomoji: "O3O", symbol: "trash")
    }
}
