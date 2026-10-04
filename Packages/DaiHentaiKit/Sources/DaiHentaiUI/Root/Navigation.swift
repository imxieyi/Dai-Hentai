import DaiHentaiCore
import SwiftUI

/// A tab's navigation stack with the shared destinations and its own zoom namespace.
struct TabStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder var root: () -> Root

    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    var body: some View {
        // Every view in the stack says the same thing about the tab bar, from the path.
        let tabBar: Visibility = model.router.hidesTabBar(for: tab) ? .hidden : .visible
        NavigationStack(path: Binding(get: { model.router.path(for: tab) }, set: { model.router.setPath($0, for: tab) })) {
            root()
                .toolbarVisibility(tabBar, for: .tabBar)
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case .reader(let reader):
                            ReaderView(route: reader)
                                .zoomDestination(id: reader.gallery.id, namespace: zoom)
                        case let .web(title, url):
                            SiteWebView(title: title, url: url)
                        }
                    }
                    .toolbarVisibility(tabBar, for: .tabBar)
                }
        }
        .environment(\.zoomNamespace, zoom)
    }
}

/// Context-menu items shared by every gallery card.
struct GalleryContextMenu: View {
    let gallery: GalleryInfo
    var showsDelete = false

    @Environment(AppModel.self) private var model

    var body: some View {
        let isDownloaded = model.library.isDownloaded(gallery)
        let isDownloading = model.downloads.isDownloading(gallery.id)
        // The Downloads tab's two jobs, for this gallery alone, when there's something for them to do.
        let gaps = isDownloaded && !isDownloading ? model.library.downloadGaps(gallery) : nil
        Button(.commonReadNow, systemImage: "book") {
            model.router.openReader(gallery)
        }
        if !isDownloaded {
            Button(.commonWantDownload, systemImage: "arrow.down.circle") {
                model.download(gallery)
            }
        } else if let gaps {
            if gaps.isMissingImages {
                Button(.commonResumeDownload, systemImage: "arrow.down.circle") {
                    model.downloads.resume(gallery, .missing)
                }
                .accessibilityIdentifier("menuResumeDownload")
            }
            if gaps.hasReducedPages {
                Button(.commonUpgradeToOriginals, systemImage: "photo.badge.arrow.down") {
                    model.downloads.resume(gallery, .originals)
                }
                .accessibilityIdentifier("menuUpgradeToOriginals")
            }
        }
        Button(.commonSearchRelated, systemImage: "text.magnifyingglass") {
            model.router.galleryCard = GalleryCardRoute(gallery: gallery, relatedWord: "")
        }
        ShareLink(item: gallery.galleryURL(on: model.site), subject: Text(gallery.bestTitle), message: Text(gallery.bestTitle)) {
            Label(.commonShare, systemImage: "square.and.arrow.up")
        }
        if showsDelete {
            Divider()
            Button(isDownloaded ? LocalizedStringResource.menuDeleteDownload : .menuDeleteRecord, systemImage: "trash", role: .destructive) {
                withAnimation { model.delete(gallery) }
            }
        }
    }
}
