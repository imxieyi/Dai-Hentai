// swift-tools-version: 6.4
import PackageDescription

let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "DaiHentaiKit",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v27)],
    products: [
        .library(name: "DaiHentaiCore", targets: ["DaiHentaiCore"]),
        .library(name: "DaiHentaiUI", targets: ["DaiHentaiUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.9.6"),
    ],
    targets: [
        // Models, SwiftData store, legacy Couchbase importer, site client and downloader.
        .target(
            name: "DaiHentaiCore",
            dependencies: ["SwiftSoup"],
            resources: [.process("Resources")],
            swiftSettings: approachableConcurrency
        ),
        // SwiftUI screens. Everything here is main-actor isolated by default.
        .target(
            name: "DaiHentaiUI",
            dependencies: ["DaiHentaiCore"],
            resources: [.process("Resources")],
            swiftSettings: approachableConcurrency + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "DaiHentaiCoreTests",
            dependencies: ["DaiHentaiCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: approachableConcurrency
        ),
    ],
    swiftLanguageModes: [.v6]
)
