// swift-tools-version: 6.0
//
// This manifest describes EchoSightCore as a reusable Swift library.
// The shipping visionOS app (EchoSightApp target, Info.plist, capabilities,
// signing) is defined in project.yml via XcodeGen, which generates the
// EchoSight.xcodeproj used for Xcode builds and TestFlight submissions.
//
// Scope of this file: Core's own dependencies (swift-log, GRDB, mlx-swift).
// Do not add App-layer dependencies here -- add them to project.yml.
import PackageDescription

let package = Package(
    name: "EchoSight",
    platforms: [
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "EchoSightCore",
            targets: ["EchoSightCore"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.0"
        ),
        // GRDB — SQLite persistence for annotation-store (Phase 3, Sprint 1)
        .package(
            url: "https://github.com/groue/GRDB.swift",
            from: "6.0.0"
        ),
        // mlx-swift — placeholder, required for Gemma enrichment (Phase 3)
        // Pinned to a known-good release; update when gemma-enrichment spec lands.
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            from: "0.21.0"
        ),
    ],
    targets: [
        // MARK: - EchoSightCore
        .target(
            name: "EchoSightCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/EchoSightCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "EchoSightCoreTests",
            dependencies: ["EchoSightCore"],
            path: "Tests/EchoSightCoreTests"
        ),
    ]
)
