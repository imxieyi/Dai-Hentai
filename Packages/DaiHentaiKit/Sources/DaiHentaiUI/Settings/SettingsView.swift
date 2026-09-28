import DaiHentaiCore
import SwiftData
import SwiftUI

struct SettingsTab: View {
    var body: some View {
        TabStack(tab: .settings) {
            SettingsView()
        }
    }
}

/// 設定: same sections as 3.x — App 狀態 · 用量 · 觀看習慣 · 隱私設定 — plus 關於.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Query private var galleries: [StoredGallery]
    @State private var eh = SiteProbeResult.testing
    @State private var ex = SiteProbeResult.testing
    @State private var usage: StorageUsage?
    @State private var isExKeyPresented = false
    @State private var isConfirmingClear = false
    @State private var clearProgress: (done: Int, total: Int)?
    @State private var isConfirmingLock = false
    @State private var isLockBusy = false

    var body: some View {
        @Bindable var library = model.library
        Form {
            statusSection
            usageSection
            Section("觀看習慣") {
                Picker("滑動方向切換", selection: $library.preferences.readingDirection) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                Toggle("點列表作品時先跳出作品卡", isOn: $library.preferences.asksBeforeOpening)
            }
            privacySection
            aboutSection
        }
        .navigationTitle("設定")
        .refreshable { await runDiagnostics() }
        .task { await runDiagnostics() }
        .task(id: galleries.count) { await measureUsage() }
        .sheet(isPresented: $isExKeyPresented) {
            ExKeyLoginView()
        }
        .alert("O3O", isPresented: $isConfirmingClear) {
            Button("好 O3Ob", role: .destructive) { clearHistory() }
            Button("先不要好了 OwO\"", role: .cancel) {}
        } message: {
            Text("我們現在要刪除所有觀看紀錄囉!")
        }
        .alert("確定要上鎖嗎?", isPresented: $isConfirmingLock) {
            Button("OK, 鎖8") { Task { await enableLock() } }
            Button("O口O 真假, 我考慮一下", role: .cancel) {}
        } message: {
            Text("未來只可以透過指紋或是臉來解鎖, 密碼無法!")
        }
        .overlay {
            if let clearProgress {
                GlassHUD(title: "作品刪除中 ( \(clearProgress.done) / \(clearProgress.total) )", progress: clearProgress.total == 0 ? 1 : Double(clearProgress.done) / Double(clearProgress.total))
            }
        }
        .onChange(of: model.isLoggedIn) {
            Task { await runDiagnostics() }
        }
    }

    // MARK: - App 狀態

    private var statusSection: some View {
        Section {
            NavigationLink(value: Route.web(title: "E-Hentai", url: Site.eHentai.baseURL)) {
                statusRow("Eh 列表測試 (點擊開啟網頁)", status: eh.list)
            }
            statusRow("Eh API 使用測試", status: eh.api, parseFailureText: "不知道")

            if model.isLoggedIn {
                NavigationLink(value: Route.web(title: "ExHentai", url: Site.exHentai.baseURL)) {
                    statusRow("Ex 列表測試 (點擊開啟網頁)", status: ex.list)
                }
            } else {
                statusRow("Ex 列表測試 (點擊開啟網頁)", status: .notLoggedIn)
            }
            statusRow("Ex API 使用測試", status: model.isLoggedIn ? ex.api : .notLoggedIn, parseFailureText: "不知道")

            if !model.isLoggedIn {
                Button {
                    model.router.isExWebLoginPresented = true
                } label: {
                    Label("用網頁登入 Ex", systemImage: "person.crop.circle.badge.checkmark")
                }
                .accessibilityIdentifier("settingsWebLogin")
            }
            Button {
                isExKeyPresented = true
            } label: {
                Label("ExKey 登錄", systemImage: "key")
            }
            .accessibilityIdentifier("settingsExKey")
            if model.isLoggedIn {
                Button(role: .destructive) {
                    Task { await model.logOut() }
                } label: {
                    Label("Ex 登入整個失敗 還是只有熊貓 點我登出", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } header: {
            Text("App 狀態")
        } footer: {
            Text(model.isLoggedIn ? "已經登入 Ex, 列表和下載會使用 ExHentai。" : "沒有登入時, 列表和下載會使用 E-Hentai。")
        }
    }

    private func statusRow(_ title: String, status: ProbeStatus, parseFailureText: String? = nil) -> some View {
        LabeledContent {
            StatusBadge(status: status, parseFailureText: parseFailureText)
        } label: {
            Text(title)
        }
    }

    // MARK: - 用量

    private var usageSection: some View {
        Section("用量") {
            if let usage {
                StorageBar(usage: usage)
                    .padding(.vertical, 4)
                LabeledContent("歷史", value: "\(usage.historyBytes.formatted(.byteCount(style: .file))) (\(usage.historyCount))")
                LabeledContent("下載", value: "\(usage.downloadBytes.formatted(.byteCount(style: .file))) (\(usage.downloadCount))")
            } else {
                LabeledContent("歷史", value: "計算中...")
                LabeledContent("下載", value: "計算中...")
            }
            Button("清除所有觀看紀錄", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled((usage?.historyCount ?? 0) == 0)
        }
        .monospacedDigit()
    }

    // MARK: - 隱私設定

    private var privacySection: some View {
        @Bindable var library = model.library
        return Section {
            Toggle(isOn: Binding(get: { model.library.preferences.isAppLocked }, set: { newValue in
                if newValue {
                    isConfirmingLock = true
                } else {
                    Task { await disableLock() }
                }
            })) {
                Label("App 上鎖", systemImage: model.lock.biometricKind.symbolName)
            }
            .disabled(isLockBusy)
            .accessibilityIdentifier("lockToggle")
            Toggle(isOn: $library.preferences.hidesInAppSwitcher) {
                Label("切換 App 時遮住畫面", systemImage: "eye.slash")
            }
        } header: {
            Text("隱私設定")
        } footer: {
            Text(model.library.preferences.isAppLocked ? "目前是上鎖狀態" : "目前是沒有上鎖狀態")
        }
    }

    private func enableLock() async {
        isLockBusy = true
        defer { isLockBusy = false }
        switch await model.lock.enableLock() {
        case .success:
            model.toasts.show("上鎖囉", kaomoji: "O3Ob", symbol: "lock.fill")
        case .unavailable:
            model.toasts.show("這台裝置沒有設定 Face ID 或 Touch ID, 鎖不住", kaomoji: "o.o")
        case .lockedOut:
            model.toasts.show("失敗太多次囉, 請先用密碼解鎖手機", kaomoji: "O口O")
        case .failed:
            break
        }
    }

    private func disableLock() async {
        isLockBusy = true
        defer { isLockBusy = false }
        if await model.lock.disableLock() {
            model.toasts.show("解除上鎖囉", kaomoji: "O3O", symbol: "lock.open.fill")
        }
    }

    // MARK: - 關於

    private var aboutSection: some View {
        Section("關於") {
            LabeledContent("版本", value: Self.version)
            Link(destination: URL(string: "https://github.com/DaidoujiChen/Dai-Hentai")!) {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            if model.isDemo {
                Label("展示模式: 所有作品都是產生出來的", systemImage: "theatermasks")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Work

    private func runDiagnostics() async {
        eh = .testing
        ex = model.isLoggedIn ? .testing : SiteProbeResult(list: .notLoggedIn, api: .notLoggedIn)
        async let ehResult = SiteDiagnostics.probe(model.makeService(for: .eHentai))
        if model.isLoggedIn {
            async let exResult = SiteDiagnostics.probe(model.makeService(for: .exHentai))
            let (first, second) = await (ehResult, exResult)
            eh = first
            ex = second
        } else {
            eh = await ehResult
        }
    }

    private func measureUsage() async {
        let items = galleries.map { (folder: $0.info.folderName, isDownloaded: $0.isDownloaded) }
        let measured = await StorageUsage.measure(items, files: model.library.files)
        withAnimation { usage = measured }
    }

    private func clearHistory() {
        clearProgress = (0, usage?.historyCount ?? 0)
        Task {
            await model.library.deleteAllHistory { done, total in
                clearProgress = (done, total)
            }
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation { clearProgress = nil }
            model.toasts.show("觀看紀錄都清掉囉", kaomoji: "O3Ob")
            await measureUsage()
        }
    }
}

/// History vs downloads, as one stacked bar.
private struct StorageBar: View {
    let usage: StorageUsage

    var body: some View {
        let total = max(usage.historyBytes + usage.downloadBytes, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.moeAccent.opacity(0.45))
                        .frame(width: proxy.size.width * CGFloat(usage.historyBytes) / CGFloat(total))
                    Rectangle()
                        .fill(Color.moeAccent)
                }
                .clipShape(.capsule)
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                legend("歷史", color: Color.moeAccent.opacity(0.45))
                legend("下載", color: Color.moeAccent)
                Spacer()
                Text((usage.historyBytes + usage.downloadBytes).formatted(.byteCount(style: .file)))
                    .font(.footnote.weight(.semibold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("總共 \((usage.historyBytes + usage.downloadBytes).formatted(.byteCount(style: .file)))")
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
