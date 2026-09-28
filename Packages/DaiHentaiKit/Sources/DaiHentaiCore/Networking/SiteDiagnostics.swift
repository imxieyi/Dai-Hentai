import Foundation

/// Status words from the old settings screen.
public enum ProbeStatus: Sendable, Equatable {
    case testing
    case success
    case parseFailed
    case networkFailed
    case notLoggedIn

    public var title: LocalizedStringResource {
        switch self {
        case .testing: .probeTesting
        case .success: .probeSuccess
        case .parseFailed: .probeParseFailed
        case .networkFailed: .probeNetworkFailed
        case .notLoggedIn: .probeNotLoggedIn
        }
    }

    public var isFailure: Bool {
        switch self {
        case .parseFailed, .networkFailed, .notLoggedIn: true
        case .testing, .success: false
        }
    }
}

public struct SiteProbeResult: Sendable, Equatable {
    public var list: ProbeStatus
    public var api: ProbeStatus

    public init(list: ProbeStatus, api: ProbeStatus) {
        self.list = list
        self.api = api
    }

    public static let testing = SiteProbeResult(list: .testing, api: .testing)
}

/// "Eh/Ex 列表測試" and "Eh/Ex API 使用測試".
public enum SiteDiagnostics {
    /// Loads the front page (list parsing) and then asks the API about the first gallery found.
    @concurrent
    public static func probe(_ service: any GalleryService) async -> SiteProbeResult {
        let unfiltered = SearchFilter()
        do {
            let galleries = try await service.galleries(filter: unfiltered, next: nil)
            // `galleries(filter:)` already went through the gdata API, so both work.
            return SiteProbeResult(list: .success, api: galleries.isEmpty ? .parseFailed : .success)
        } catch .network {
            return SiteProbeResult(list: .networkFailed, api: .networkFailed)
        } catch {
            return SiteProbeResult(list: .parseFailed, api: .parseFailed)
        }
    }
}
