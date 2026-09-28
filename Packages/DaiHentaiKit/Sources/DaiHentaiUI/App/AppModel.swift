import DaiHentaiCore
import Foundation
import SwiftData
import SwiftUI

/// Owns everything the screens share: the library, downloads, navigation, toasts, the list feed,
/// the app lock and the ExHentai session.
@Observable
public final class AppModel {
    public let configuration: AppConfiguration
    public let library: LibraryStore
    public let downloads: DownloadCenter
    let router = AppRouter()
    let toasts = ToastCenter()
    let feed = GalleryFeed()
    let lock: AppLock

    /// ExHentai cookies are present; the list and downloads use exhentai.org.
    private(set) var isLoggedIn: Bool
    var site: Site { isLoggedIn ? .exHentai : .eHentai }
    var isDemo: Bool { configuration.mode == .demo }

    private var demoLoggedIn: Bool
    private var didBootstrap = false

    public init(configuration: AppConfiguration = .fromProcess()) {
        self.configuration = configuration
        let container: ModelContainer
        let files: GalleryFileStore
        switch configuration.mode {
        case .live:
            files = .documents
            do {
                container = try LibraryContainer.make()
            } catch {
                // Never crash on a broken store; run from memory and say so once bootstrapped.
                container = try! LibraryContainer.make(inMemory: true)
            }
        case .demo:
            let root = URL.temporaryDirectory.appending(path: "DemoLibrary", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            files = GalleryFileStore(root: root)
            container = try! LibraryContainer.make(inMemory: true)
        }

        let library = LibraryStore(container: container, files: files)
        self.library = library
        self.demoLoggedIn = configuration.demoLoggedIn
        self.isLoggedIn = configuration.mode == .demo ? configuration.demoLoggedIn : ExSession.isLoggedIn()
        if configuration.mode == .demo, configuration.demoLocked {
            library.preferences.isAppLocked = true
        }
        self.lock = AppLock(library: library, isDemo: configuration.mode == .demo)
        self.downloads = DownloadCenter(library: library, serviceProvider: { FixtureGalleryService() })
        downloads.setServiceProvider { [unowned self] in self.makeService() }
    }

    /// A service for the current site.
    func makeService() -> any GalleryService {
        switch configuration.mode {
        case .live: LiveGalleryService(site: site)
        case .demo: FixtureGalleryService(site: site, latency: configuration.demoLatency)
        }
    }

    func makeService(for site: Site) -> any GalleryService {
        switch configuration.mode {
        case .live: LiveGalleryService(site: site)
        case .demo: FixtureGalleryService(site: site, latency: configuration.demoLatency)
        }
    }

    // MARK: - Launch

    /// First-launch work: importing 3.x data, or seeding the demo library.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        switch configuration.mode {
        case .live:
            await importLegacyDataIfNeeded()
        case .demo:
            if !configuration.demoEmptyLibrary { await DemoSeeder.seed(library) }
        }
    }

    private func importLegacyDataIfNeeded() async {
        guard LegacyCouchbaseImporter.needsImport() else { return }
        let importer = LegacyCouchbaseImporter(modelContainer: library.container)
        do {
            let summary = try await importer.importAll()
            UserDefaults.standard.set(true, forKey: LegacyCouchbaseImporter.completedDefaultsKey)
            library.reloadSettings()
            if summary.galleries > 0 {
                toasts.show(.toastLegacyImported(summary.galleries), kaomoji: "O3Ob", duration: .seconds(3))
            }
        } catch {
            // Try again on the next launches, but don't nag forever about a damaged old database.
            let attempts = UserDefaults.standard.integer(forKey: Self.importAttemptsKey) + 1
            UserDefaults.standard.set(attempts, forKey: Self.importAttemptsKey)
            if attempts >= 3 {
                UserDefaults.standard.set(true, forKey: LegacyCouchbaseImporter.completedDefaultsKey)
                toasts.show(.toastLegacyImportGaveUp, kaomoji: "O口O", duration: .seconds(3))
            } else {
                toasts.show(.toastLegacyImportFailed, kaomoji: "O口O", duration: .seconds(3))
            }
        }
    }

    private static let importAttemptsKey = "legacyImportAttempts"

    // MARK: - ExHentai session

    /// Re-reads the cookies; switching sites restarts the list and stops downloads, like 3.x.
    func refreshLogin() {
        let loggedIn = isDemo ? demoLoggedIn : ExSession.isLoggedIn()
        guard loggedIn != isLoggedIn else { return }
        isLoggedIn = loggedIn
        downloads.cancelAll()
        feed.invalidate()
    }

    /// 「Ex 登入整個失敗 還是只有熊貓 點我登出」: no confirmation, like 3.x.
    func logOut() async {
        if isDemo {
            demoLoggedIn = false
        } else {
            await ExSession.logOut()
        }
        refreshLogin()
        toasts.show(.toastLoggedOut, kaomoji: "O3O")
    }

    /// ExKey login: writes the cookies, then only reports success when ExHentai really answers.
    func logIn(exKey: String) async -> ProbeStatus {
        if isDemo {
            guard ExSession.parse(exKey: exKey) != nil else { return .parseFailed }
            demoLoggedIn = true
        } else {
            guard ExSession.logIn(exKey: exKey) else { return .parseFailed }
            await ExSession.exportCookiesToWebKit()
        }
        let result = await SiteDiagnostics.probe(makeService(for: .exHentai))
        if result.list == .success {
            refreshLogin()
            return .success
        }
        // Keep the cookies (the site may just be slow) but don't claim success.
        refreshLogin()
        return result.list
    }

    /// Called when the web login sheet sees the member cookies.
    func didFinishWebLogin() async {
        if !isDemo { await ExSession.importWebKitCookies() }
        refreshLogin()
        if isLoggedIn { toasts.show(.commonLoggedIn, kaomoji: "O3Ob") }
    }

    /// Demo stand-in for the web login.
    func demoWebLogin() {
        demoLoggedIn = true
        refreshLogin()
    }

    // MARK: - Actions shared by several screens

    /// 「我要下載」.
    func download(_ gallery: GalleryInfo) {
        guard !library.isDownloaded(gallery) || !downloads.isDownloading(gallery.id) else { return }
        downloads.startDownload(gallery)
        toasts.show(.toastDownloadStarted, kaomoji: "O3O", symbol: "arrow.down.circle.fill")
    }

    /// Deletes a gallery (history record or download) with its images.
    func delete(_ gallery: GalleryInfo) {
        downloads.cancel(gallery)
        library.delete(gallery)
    }

    /// New search from 相關字詞 or a tag: replaces the keyword and shows the list.
    func search(keyword: String) {
        var filter = library.searchFilter
        filter.keyword = keyword
        library.searchFilter = filter
        router.showList()
    }

    /// Opens a gallery the way the user asked for: 作品卡 first (the old alert), or straight to reading.
    func open(_ gallery: GalleryInfo, fromList: Bool) {
        if fromList, library.preferences.asksBeforeOpening {
            router.galleryCard = GalleryCardRoute(gallery: gallery)
        } else {
            router.openReader(gallery)
        }
    }
}
