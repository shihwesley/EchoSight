import SwiftUI
import EchoSightCore

// MARK: - EchoSightApp

@main
struct EchoSightApp: App {

    init() {
        // Install observability before any feature code or SwiftUI body runs.
        // Subsequent calls are no-ops (idempotent).
        ObservabilityBootstrap.install()
    }

    var body: some Scene {
        // MARK: Setup Window

        WindowGroup {
            RootView()
        }

        // MARK: Immersive Space

        ImmersiveSpace(id: AppIDs.immersiveSpace) {
            WorldImmersiveView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

// MARK: - AppIDs

/// Stable string identifiers for scenes and spaces used across the app.
enum AppIDs {
    static let immersiveSpace = "WorldImmersiveSpace"
}
