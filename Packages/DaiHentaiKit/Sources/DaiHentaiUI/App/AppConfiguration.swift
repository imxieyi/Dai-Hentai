import DaiHentaiCore
import Foundation

/// How the app runs. `demo` is fully offline: generated galleries, an in-memory library and a
/// throwaway image folder. It is used for previews, screenshots and UI tests.
public struct AppConfiguration: Sendable {
    public enum Mode: Sendable, Equatable {
        case live
        case demo
    }

    public var mode: Mode
    /// Demo only: start as if ExHentai cookies were present.
    public var demoLoggedIn = false
    /// Demo only: start with the app lock on.
    public var demoLocked = false
    /// Demo only: start with empty history and downloads.
    public var demoEmptyLibrary = false
    /// Demo only: force dark mode (screenshots without touching the device's appearance).
    public var demoDarkMode = false
    /// Demo only: simulated site latency.
    public var demoLatency: Duration = .milliseconds(150)

    public init(mode: Mode) {
        self.mode = mode
    }

    public static let live = AppConfiguration(mode: .live)
    public static let demo = AppConfiguration(mode: .demo)

    /// Reads `-DemoMode`, `-DemoLoggedIn`, `-DemoLocked`, `-DemoEmptyLibrary`, `-DemoDark` from the launch arguments.
    public static func fromProcess(_ process: ProcessInfo = .processInfo) -> AppConfiguration {
        let arguments = Set(process.arguments)
        guard arguments.contains("-DemoMode") else { return .live }
        var configuration = AppConfiguration.demo
        configuration.demoLoggedIn = arguments.contains("-DemoLoggedIn")
        configuration.demoLocked = arguments.contains("-DemoLocked")
        configuration.demoEmptyLibrary = arguments.contains("-DemoEmptyLibrary")
        configuration.demoDarkMode = arguments.contains("-DemoDark")
        return configuration
    }
}
