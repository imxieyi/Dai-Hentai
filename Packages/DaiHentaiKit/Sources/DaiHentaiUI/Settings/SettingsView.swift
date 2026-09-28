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
            Section(.settingsReadingSection) {
                Picker(.readerScrollDirection, selection: $library.preferences.readingDirection) {
                    ForEach(ReadingDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                Toggle(.settingsAsksBeforeOpening, isOn: $library.preferences.asksBeforeOpening)
            }
            privacySection
            aboutSection
        }
        .navigationTitle(.tabSettings)
        .refreshable { await runDiagnostics() }
        .task { await runDiagnostics() }
        .task(id: galleries.count) { await measureUsage() }
        .sheet(isPresented: $isExKeyPresented) {
            ExKeyLoginView()
        }
        .alert(Text(verbatim: "O3O"), isPresented: $isConfirmingClear) {
            Button(.commonOkayHappy, role: .destructive) { clearHistory() }
            Button(.commonNotNow, role: .cancel) {}
        } message: {
            Text(.commonConfirmClearHistory)
        }
        .alert(Text(.settingsLockConfirmTitle), isPresented: $isConfirmingLock) {
            Button(.settingsLockConfirmOK) { Task { await enableLock() } }
            Button(.settingsLockConfirmCancel, role: .cancel) {}
        } message: {
            Text(.settingsLockConfirmMessage)
        }
        .overlay {
            if let clearProgress {
                GlassHUD(title: .commonDeletingProgress(clearProgress.done, clearProgress.total), progress: clearProgress.total == 0 ? 1 : Double(clearProgress.done) / Double(clearProgress.total))
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
                statusRow(.settingsEhListTest, status: eh.list)
            }
            statusRow(.settingsEhAPITest, status: eh.api, parseFailureText: .settingsUnknown)

            if model.isLoggedIn {
                NavigationLink(value: Route.web(title: "ExHentai", url: Site.exHentai.baseURL)) {
                    statusRow(.settingsExListTest, status: ex.list)
                }
            } else {
                statusRow(.settingsExListTest, status: .notLoggedIn)
            }
            statusRow(.settingsExAPITest, status: model.isLoggedIn ? ex.api : .notLoggedIn, parseFailureText: .settingsUnknown)

            if !model.isLoggedIn {
                Button {
                    model.router.isExWebLoginPresented = true
                } label: {
                    Label(.settingsWebLogIn, systemImage: "person.crop.circle.badge.checkmark")
                }
                .accessibilityIdentifier("settingsWebLogin")
            }
            Button {
                isExKeyPresented = true
            } label: {
                Label(.settingsExKeyLogIn, systemImage: "key")
            }
            .accessibilityIdentifier("settingsExKey")
            if model.isLoggedIn {
                Button(role: .destructive) {
                    Task { await model.logOut() }
                } label: {
                    Label(.settingsLogOut, systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } header: {
            Text(.settingsStatusSection)
        } footer: {
            Text(model.isLoggedIn ? LocalizedStringResource.settingsStatusFooterEx : .settingsStatusFooterEh)
        }
    }

    private func statusRow(_ title: LocalizedStringResource, status: ProbeStatus, parseFailureText: LocalizedStringResource? = nil) -> some View {
        LabeledContent {
            StatusBadge(status: status, parseFailureText: parseFailureText)
        } label: {
            Text(title)
        }
    }

    // MARK: - 用量

    private var usageSection: some View {
        Section(.settingsUsageSection) {
            if let usage {
                StorageBar(usage: usage)
                    .padding(.vertical, 4)
                LabeledContent(.tabHistory, value: "\(usage.historyBytes.formatted(.byteCount(style: .file))) (\(usage.historyCount))")
                LabeledContent(.tabDownloads, value: "\(usage.downloadBytes.formatted(.byteCount(style: .file))) (\(usage.downloadCount))")
            } else {
                LabeledContent(.tabHistory, value: String(localized: .commonCalculating))
                LabeledContent(.tabDownloads, value: String(localized: .commonCalculating))
            }
            Button(.commonClearHistory, role: .destructive) {
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
                Label(.settingsLock, systemImage: model.lock.biometricKind.symbolName)
            }
            .disabled(isLockBusy)
            .accessibilityIdentifier("lockToggle")
            Toggle(isOn: $library.preferences.hidesInAppSwitcher) {
                Label(.settingsHideInSwitcher, systemImage: "eye.slash")
            }
        } header: {
            Text(.settingsPrivacySection)
        } footer: {
            Text(model.library.preferences.isAppLocked ? LocalizedStringResource.settingsLockedFooter : .settingsUnlockedFooter)
        }
    }

    private func enableLock() async {
        isLockBusy = true
        defer { isLockBusy = false }
        switch await model.lock.enableLock() {
        case .success:
            model.toasts.show(.settingsLocked, kaomoji: "O3Ob", symbol: "lock.fill")
        case .unavailable:
            model.toasts.show(.settingsNoBiometrics, kaomoji: "o.o")
        case .lockedOut:
            model.toasts.show(.settingsLockout, kaomoji: "O口O")
        case .failed:
            break
        }
    }

    private func disableLock() async {
        isLockBusy = true
        defer { isLockBusy = false }
        if await model.lock.disableLock() {
            model.toasts.show(.settingsUnlocked, kaomoji: "O3O", symbol: "lock.open.fill")
        }
    }

    // MARK: - 關於

    private var aboutSection: some View {
        Section(.settingsAboutSection) {
            LabeledContent(.settingsVersion, value: Self.version)
            Link(destination: URL(string: "https://github.com/DaidoujiChen/Dai-Hentai")!) {
                Label(String("GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            if model.isDemo {
                Label(.settingsDemoMode, systemImage: "theatermasks")
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
            model.toasts.show(.commonHistoryCleared, kaomoji: "O3Ob")
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
                legend(.tabHistory, color: Color.moeAccent.opacity(0.45))
                legend(.tabDownloads, color: Color.moeAccent)
                Spacer()
                Text((usage.historyBytes + usage.downloadBytes).formatted(.byteCount(style: .file)))
                    .font(.footnote.weight(.semibold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(.settingsTotalAccessibility((usage.historyBytes + usage.downloadBytes).formatted(.byteCount(style: .file))))
    }

    private func legend(_ title: LocalizedStringResource, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
