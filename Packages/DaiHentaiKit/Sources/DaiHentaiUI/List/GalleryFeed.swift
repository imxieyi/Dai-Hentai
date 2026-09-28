import DaiHentaiCore
import Foundation

/// The 列表 tab's paged gallery list.
@Observable
final class GalleryFeed {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(SiteError)
    }

    private(set) var items: [GalleryInfo] = []
    private(set) var state: State = .idle
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false
    private(set) var reachedEnd = false
    /// What the current items were loaded for; a different key means the list is stale.
    private(set) var loadedKey: Key?

    struct Key: Hashable {
        var site: Site
        var filter: SearchFilter
    }

    private var generation = 0
    private var service: (any GalleryService)?

    /// Forgets everything so the next `load` starts over (site switch).
    func invalidate() {
        generation += 1
        items = []
        state = .idle
        loadedKey = nil
        reachedEnd = false
        loadMoreFailed = false
        isLoadingMore = false
    }

    /// Loads the first page for `key` unless it is already showing.
    func loadIfNeeded(_ key: Key, service: any GalleryService) async {
        guard key != loadedKey || state == .idle else { return }
        await reload(key, service: service)
    }

    /// Pull to refresh / retry: first page again.
    func reload(_ key: Key, service: any GalleryService) async {
        generation += 1
        let current = generation
        self.service = service
        loadedKey = key
        reachedEnd = false
        loadMoreFailed = false
        isLoadingMore = false
        if items.isEmpty || state != .loaded { state = .loading }
        do {
            let page = try await service.galleries(filter: key.filter, next: nil)
            guard current == generation else { return }
            items = Self.unique(page)
            state = page.isEmpty ? .empty : .loaded
            reachedEnd = page.isEmpty
        } catch {
            guard current == generation else { return }
            items = []
            state = .failed(error)
        }
    }

    /// Infinite scroll: call when `item` appears.
    func loadMoreIfNeeded(after item: GalleryInfo) {
        guard state == .loaded, !reachedEnd, !isLoadingMore, !loadMoreFailed,
              let index = items.firstIndex(of: item), index >= items.count - 6 else { return }
        loadMore()
    }

    func loadMore() {
        guard let service, let key = loadedKey, let last = items.last, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreFailed = false
        let current = generation
        Task {
            do {
                let page = try await service.galleries(filter: key.filter, next: last.gid)
                guard current == generation else { return }
                let known = Set(items.map(\.id))
                let fresh = page.filter { !known.contains($0.id) }
                items += Self.unique(fresh)
                reachedEnd = fresh.isEmpty
            } catch {
                guard current == generation else { return }
                loadMoreFailed = true
            }
            if current == generation { isLoadingMore = false }
        }
    }

    private static func unique(_ galleries: [GalleryInfo]) -> [GalleryInfo] {
        var seen = Set<String>()
        return galleries.filter { seen.insert($0.id).inserted }
    }
}
