import DaiHentaiCore
import SwiftUI

/// A tab's navigation stack with the shared destinations and its own zoom namespace.
struct TabStack<Root: View>: View {
    let tab: AppTab
    @ViewBuilder var root: () -> Root

    @Environment(AppModel.self) private var model
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: Binding(get: { model.router.path(for: tab) }, set: { model.router.setPath($0, for: tab) })) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .reader(let reader):
                        ReaderView(route: reader)
                            .zoomDestination(id: reader.gallery.id, namespace: zoom)
                    case let .web(title, url):
                        SiteWebView(title: title, url: url)
                    }
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
        Button(.commonReadNow, systemImage: "book") {
            model.router.openReader(gallery)
        }
        if !isDownloaded || !isDownloading {
            Button(isDownloaded ? LocalizedStringResource.commonResumeDownload : .commonWantDownload, systemImage: "arrow.down.circle") {
                model.download(gallery)
            }
            .disabled(isDownloaded && isDownloading)
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
