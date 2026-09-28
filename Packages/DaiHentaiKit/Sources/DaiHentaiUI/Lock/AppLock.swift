import DaiHentaiCore
import SwiftUI
import UIKit

/// The app lock and the app-switcher privacy shield. Both live in a window above everything else
/// (sheets and alerts included), one per scene.
///
/// Rules: lock again only after going to the background or on a cold launch; prompt once
/// automatically; never quit the app on failure.
@Observable
final class AppLock {
    private(set) var isLocked: Bool {
        didSet { updateWindows() }
    }
    /// Covers the content while the app is inactive (app switcher, Control Center).
    private(set) var isShielded = false {
        didSet { updateWindows() }
    }
    private(set) var isAuthenticating = false
    private(set) var message: LocalizedStringResource?

    private let library: LibraryStore
    private let isDemo: Bool
    private var didAutoPrompt = false
    private var windows: [ObjectIdentifier: UIWindow] = [:]

    init(library: LibraryStore, isDemo: Bool) {
        self.library = library
        self.isDemo = isDemo
        self.isLocked = library.preferences.isAppLocked
        Task { biometricKind = await BiometricAuthenticator.currentKind() }
    }

    /// Face ID / Touch ID, read once off the main thread.
    private(set) var biometricKind: BiometricAuthenticator.Kind = .faceID

    // MARK: - Scenes

    func attach(to scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        guard windows[id] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockOverlay(lock: self))
        if isDemo, ProcessInfo.processInfo.arguments.contains("-DemoDark") {
            window.overrideUserInterfaceStyle = .dark
        }
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.backgroundColor = .clear
        windows[id] = window
        updateWindows()
    }

    private func updateWindows() {
        let visible = isLocked || isShielded
        for window in windows.values {
            window.isHidden = !visible
        }
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(to phase: ScenePhase) {
        let preferences = library.preferences
        switch phase {
        case .background:
            if preferences.isAppLocked {
                isLocked = true
                didAutoPrompt = false
            }
            isShielded = preferences.isAppLocked || preferences.hidesInAppSwitcher
        case .inactive:
            // The Face ID sheet itself makes the app inactive; don't flash the shield over it.
            guard !isAuthenticating else { return }
            isShielded = preferences.isAppLocked || preferences.hidesInAppSwitcher
        case .active:
            isShielded = false
            if isLocked, !didAutoPrompt {
                didAutoPrompt = true
                Task { await unlock() }
            }
        @unknown default:
            break
        }
    }

    // MARK: - Unlocking

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        message = nil
        let outcome = await BiometricAuthenticator.authenticate(reason: String(localized: .lockMessage), allowsPasscodeIfNotEnrolled: true)
        isAuthenticating = false
        switch outcome {
        case .success:
            withAnimation(.smooth) { isLocked = false }
        case .failed:
            message = .lockFailed
        case .lockedOut:
            message = .lockLockout
        case .unavailable:
            message = .lockUnavailable(biometricKind.title)
        }
    }

    /// Settings: 「App 上鎖」 after the confirmation dialog. One biometric check proves it works.
    func enableLock() async -> BiometricAuthenticator.Outcome {
        guard !isAuthenticating else { return .failed }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let outcome = await BiometricAuthenticator.authenticate(reason: String(localized: .lockEnableReason))
        if outcome == .success { library.preferences.isAppLocked = true }
        return outcome
    }

    /// Settings: turning the lock off needs the owner, like 3.x (「驗證身份以解除鎖定」), but never quits.
    func disableLock() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        guard await BiometricAuthenticator.authenticate(reason: String(localized: .lockDisableReason), allowsPasscodeIfNotEnrolled: true) == .success else { return false }
        library.preferences.isAppLocked = false
        return true
    }
}

/// Reports the `UIWindowScene` a SwiftUI view lives in.
struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onScene: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { onScene?(scene) }
        }
    }
}
