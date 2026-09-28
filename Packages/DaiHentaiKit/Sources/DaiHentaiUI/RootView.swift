import DaiHentaiCore
import SwiftData
import SwiftUI

/// The app's root: four tabs like 3.x (列表 · 歷史 · 下載 · 設定).
public struct RootView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        MainTabs()
            .environment(model)
            .modelContainer(model.library.container)
            .tint(.moeAccent)
            .preferredColorScheme(model.configuration.demoDarkMode ? .dark : nil)
    }
}

private struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Query(Self.recentDescriptor) private var recent: [StoredGallery]

    private static var recentDescriptor: FetchDescriptor<StoredGallery> {
        var descriptor = FetchDescriptor<StoredGallery>(sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)])
        descriptor.fetchLimit = 5
        return descriptor
    }

    var body: some View {
        @Bindable var router = model.router
        TabView(selection: $router.tab) {
            Tab("列表", systemImage: "list.bullet.rectangle.portrait", value: AppTab.list) {
                ListTab()
            }
            .accessibilityIdentifier("tab.list")
            Tab("歷史", systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                HistoryTab()
            }
            .accessibilityIdentifier("tab.history")
            Tab("下載", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsTab()
            }
            .badge(model.downloads.activeDownloads.count)
            .accessibilityIdentifier("tab.downloads")
            Tab("設定", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTab()
            }
            .accessibilityIdentifier("tab.settings")
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: accessory != nil) {
            if let accessory {
                BottomAccessory(content: accessory)
            }
        }
        .sheet(item: $router.galleryCard) { route in
            GallerySheet(route: route)
        }
        .sheet(isPresented: $router.isExWebLoginPresented) {
            ExWebLoginView()
        }
        .overlay {
            ToastOverlay(center: model.toasts, isCentered: router.visibleReaders > 0)
        }
        .statusBarHidden(router.visibleReaders > 0)
        .persistentSystemOverlays(router.hidesSystemOverlays ? .hidden : .automatic)
        .background {
            WindowSceneReader { scene in model.lock.attach(to: scene) }
        }
        .task { await model.bootstrap() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.lock.scenePhaseChanged(to: phase)
            if phase == .active { model.refreshLogin() }
        }
        .onChange(of: model.downloads.lastFinished) { _, finished in
            guard let finished else { return }
            model.toasts.show("「\(finished.bestTitle)」下載完成囉", kaomoji: "O3Ob", symbol: "checkmark.circle.fill")
        }
        .sensoryFeedback(.success, trigger: model.downloads.lastFinished)
        .sensoryFeedback(.start, trigger: model.downloads.activeDownloads.count) { old, new in new > old }
    }

    /// 「下載中」 wins over 「繼續看」. Hidden while reading.
    private var accessory: BottomAccessory.Content? {
        guard model.router.visibleReaders == 0 else { return nil }
        let active = model.downloads.activeDownloads
        if !active.isEmpty {
            return .downloading(count: active.count, progress: model.downloads.overallProgress, title: active[0].gallery.bestTitle)
        }
        if let stored = recent.first(where: { $0.lastReadPage > 1 && ($0.fileCount == 0 || $0.lastReadPage < $0.fileCount) }) {
            return .resume(stored.info, page: stored.lastReadPage)
        }
        return nil
    }
}
