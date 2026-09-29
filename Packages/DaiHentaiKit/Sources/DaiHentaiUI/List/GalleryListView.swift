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
        .navigationTitle(.tabList)
        .toolbar {
            if !model.isLoggedIn {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String("Ex")) { router.isExWebLoginPresented = true }
                        .fontWeight(.semibold)
                        .accessibilityLabel(.listLogInEx)
                        .accessibilityIdentifier("exLoginButton")
                }
            }
        }
        .filterSearch($library.searchFilter, isPresented: $router.isSearchPresented, buttonIdentifier: "searchButton") {
            model.library.recentGalleries(limit: 30)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch feed.state {
        case .idle, .loading:
            FooterRow(text: .listLoading, showsSpinner: true)
                .padding(.top, 80)
                .accessibilityIdentifier("listLoading")
        case .empty:
            NoMatchesState(filter: Bindable(model.library).searchFilter) { model.router.isSearchPresented = true }
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
                        Button(.commonDownload, systemImage: "arrow.down.circle") { model.download(gallery) }
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
            FooterRow(text: .listLoading, showsSpinner: true)
        } else if feed.loadMoreFailed {
            FooterRow(text: .listLoadMoreFailed) { feed.loadMore() }
        } else if feed.reachedEnd {
            FooterRow(text: .listEnd)
        }
    }

    @ViewBuilder
    private func failure(_ error: SiteError) -> some View {
        if model.site == .exHentai, error == .parse {
            // The sad panda: ExHentai answered with an empty page, so the cookies are no good.
            KaomojiState(kaomoji: "(´・ω・`)", title: .listSadPanda, message: .listSadPandaMessage) {
                Button(.listWebLogInAgain) { model.router.isExWebLoginPresented = true }
                    .buttonStyle(.borderedProminent)
                Button(.listLogOut) { Task { await model.logOut() } }
                    .buttonStyle(.bordered)
            }
        } else if error == .parse {
            KaomojiState(kaomoji: "O口O", title: .listParseFailed, message: .listParseFailedMessage) {
                Button(.commonTryAgain) { Task { await feed.reload(feedKey, service: model.makeService()) } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            KaomojiState(kaomoji: "O口O", title: .commonNetworkError, message: .listNetworkMessage) {
                Button(.commonTryAgain) { Task { await feed.reload(feedKey, service: model.makeService()) } }
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
