import DaiHentaiCore
import SwiftData
import SwiftUI

struct ListTab: View {
    var body: some View {
        TabStack(tab: .list) {
            GalleryListView()
        }
    }
}

/// 列表: the site's gallery list for the saved search filter.
struct GalleryListView: View {
    @Environment(AppModel.self) private var model
    @Query private var stored: [StoredGallery]
    @Namespace private var searchZoom

    private var feed: GalleryFeed { model.feed }
    private var feedKey: GalleryFeed.Key { .init(site: model.site, filter: model.library.searchFilter) }

    var body: some View {
        @Bindable var router = model.router
        @Bindable var library = model.library
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                FilterSummaryRow(site: model.site, filter: $library.searchFilter) {
                    router.isSearchPresented = true
                }
                .padding(.bottom, 8)

                content
            }
            .padding(.bottom, 12)
        }
        .swipeActionsContainer()
        .background(Color.canvas)
        .refreshable { await feed.reload(feedKey, service: model.makeService()) }
        .task(id: feedKey) { await feed.loadIfNeeded(feedKey, service: model.makeService()) }
        .navigationTitle("列表")
        .toolbar {
            if !model.isLoggedIn {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Ex") { router.isExWebLoginPresented = true }
                        .fontWeight(.semibold)
                        .accessibilityLabel("登入 ExHentai")
                        .accessibilityIdentifier("exLoginButton")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("搜尋", systemImage: "magnifyingglass") { router.isSearchPresented = true }
                    .badge(model.library.searchFilter.activeRefinementCount)
                    .accessibilityIdentifier("searchButton")
            }
            .matchedTransitionSource(id: "search", in: searchZoom)
        }
        .sheet(isPresented: $router.isSearchPresented) {
            SearchSheet()
                .navigationTransition(.zoom(sourceID: "search", in: searchZoom))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch feed.state {
        case .idle, .loading:
            FooterRow(text: "列表載入中...", showsSpinner: true)
                .padding(.top, 80)
                .accessibilityIdentifier("listLoading")
        case .empty:
            KaomojiState(kaomoji: "O3O", title: "找不到相關作品呦", message: model.library.searchFilter.isDefault ? nil : "換個搜尋條件試試看吧") {
                if !model.library.searchFilter.isDefault {
                    Button("調整搜尋條件") { model.router.isSearchPresented = true }
                        .buttonStyle(.borderedProminent)
                    Button("清除所有條件") { model.library.searchFilter = .default }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 40)
        case .failed(let error):
            failure(error)
                .padding(.top, 40)
        case .loaded:
            cards
            footer
        }
    }

    private var cards: some View {
        let badges = badgeLookup
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Metrics.cardSpacing, alignment: .top)], spacing: Metrics.cardSpacing) {
            ForEach(feed.items) { gallery in
                Button {
                    model.open(gallery, fromList: true)
                } label: {
                    GalleryCard(gallery: gallery, badge: CardBadge(stored: badges[gallery.id], downloadProgress: model.downloads.progress(for: gallery.id)))
                }
                .buttonStyle(.plain)
                .contextMenu { GalleryContextMenu(gallery: gallery) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if badges[gallery.id]?.isDownloaded != true {
                        Button("下載", systemImage: "arrow.down.circle") { model.download(gallery) }
                            .tint(.moeAccent)
                            .accessibilityIdentifier("swipeDownload")
                    }
                }
                .onAppear { feed.loadMoreIfNeeded(after: gallery) }
            }
        }
        .padding(.horizontal, Metrics.sideMargin)
    }

    @ViewBuilder
    private var footer: some View {
        if feed.isLoadingMore {
            FooterRow(text: "列表載入中...", showsSpinner: true)
        } else if feed.loadMoreFailed {
            FooterRow(text: "載入失敗了 O口O 點我再試一次") { feed.loadMore() }
        } else if feed.reachedEnd {
            FooterRow(text: "沒有更多作品囉 O3O")
        }
    }

    @ViewBuilder
    private func failure(_ error: SiteError) -> some View {
        if model.site == .exHentai, error == .parse {
            // The sad panda: ExHentai answered with an empty page, so the cookies are no good.
            KaomojiState(kaomoji: "(´・ω・`)", title: "只看到熊貓", message: "Ex 的登入好像失效了, 重新登入或是登出改用 E-Hentai 吧") {
                Button("用網頁重新登入") { model.router.isExWebLoginPresented = true }
                    .buttonStyle(.borderedProminent)
                Button("點我登出") { Task { await model.logOut() } }
                    .buttonStyle(.bordered)
            }
        } else if error == .parse {
            KaomojiState(kaomoji: "O口O", title: "列表解析失敗", message: "網站可能改版了, 等等再試試看") {
                Button("再試一次") { Task { await feed.reload(feedKey, service: model.makeService()) } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            KaomojiState(kaomoji: "O口O", title: "網路錯誤", message: "連不上網站, 檢查一下網路再試一次") {
                Button("再試一次") { Task { await feed.reload(feedKey, service: model.makeService()) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retryButton")
            }
        }
    }

    private var badgeLookup: [String: StoredGallery] {
        let keys = Set(feed.items.map(\.id))
        var lookup: [String: StoredGallery] = [:]
        for gallery in stored where keys.contains(gallery.key) {
            lookup[gallery.key] = gallery
        }
        return lookup
    }
}
