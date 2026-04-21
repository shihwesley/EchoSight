// swift-tools-version: 6.0
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
