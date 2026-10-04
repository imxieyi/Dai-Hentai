import DaiHentaiCore
import SwiftUI

enum AppTab: Hashable {
    case list, history, downloads, settings
}

/// Opening a gallery. `startPage` is 1-based; `nil` lets the reader offer
/// 「您曾經閱讀過此作品」 when there is saved progress.
struct ReaderRoute: Hashable {
    let gallery: GalleryInfo
    var startPage: Int?
}

enum Route: Hashable {
    case reader(ReaderRoute)
    case web(title: String, url: URL)
}

/// Which 作品卡 is showing and whether it can start reading (it can't when opened from the reader).
struct GalleryCardRoute: Identifiable, Hashable {
    let gallery: GalleryInfo
    var showsReadActions = true
    /// Open straight on 相關字詞 with this word picked.
    var relatedWord: String?

    var id: String { gallery.id }
}

@Observable
final class AppRouter {
    var tab: AppTab = .list
    var listPath: [Route] = []
    var historyPath: [Route] = []
    var downloadsPath: [Route] = []
    var settingsPath: [Route] = []

    var galleryCard: GalleryCardRoute?
    var isSearchPresented = false
    var isExWebLoginPresented = false
    /// Number of reader views on screen. A popped reader's view stays until its transition ends.
    var visibleReaders = 0
    /// The reader asks for this when its chrome is hidden.
    var hidesSystemOverlays = false

    func path(for tab: AppTab) -> [Route] {
        switch tab {
        case .list: listPath
        case .history: historyPath
        case .downloads: downloadsPath
        case .settings: settingsPath
        }
    }

    /// The reader and the web page take the whole screen: no tab bar over them. This follows the path,
    /// not the views' lifetimes, so a popped reader that lingers (its transition interrupted) can't keep the
    /// tab bar hidden.
    func hidesTabBar(for tab: AppTab) -> Bool {
        switch path(for: tab).last {
        case .reader?, .web?: true
        case nil: false
        }
    }

    /// A reader is on screen (top of the shown tab): the status bar, the tab accessory and the home
    /// indicator make way for it.
    var isReaderShown: Bool {
        if case .reader? = path(for: tab).last { true } else { false }
    }

    func setPath(_ path: [Route], for tab: AppTab) {
        switch tab {
        case .list: listPath = path
        case .history: historyPath = path
        case .downloads: downloadsPath = path
        case .settings: settingsPath = path
        }
    }

    /// Pushes the reader on the current tab (closing a 作品卡 first).
    func openReader(_ gallery: GalleryInfo, startPage: Int? = nil) {
        galleryCard = nil
        var path = path(for: tab)
        if case .reader(let current)? = path.last, current.gallery.id == gallery.id {
            path.removeLast()
        }
        path.append(.reader(ReaderRoute(gallery: gallery, startPage: startPage)))
        setPath(path, for: tab)
    }

    /// Goes back to the list (for a new search from a tag or 相關字詞).
    func showList() {
        galleryCard = nil
        isSearchPresented = false
        tab = .list
        listPath = []
    }

    func popReader(of gallery: GalleryInfo) {
        var path = path(for: tab)
        if case .reader(let route)? = path.last, route.gallery.id == gallery.id {
            path.removeLast()
            setPath(path, for: tab)
        }
    }
}

// MARK: - Zoom transitions

extension EnvironmentValues {
    /// The tab's namespace for cover → reader zoom transitions.
    @Entry var zoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Marks a cover as the source of the zoom into the reader.
    @ViewBuilder
    func zoomSource(id: String, namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Zooms out of the source cover, or cross-fades with Reduce Motion.
    func zoomDestination(id: String, namespace: Namespace.ID?) -> some View {
        modifier(ZoomDestination(id: id, namespace: namespace))
    }
}

private struct ZoomDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.navigationTransition(.crossFade)
        } else if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
