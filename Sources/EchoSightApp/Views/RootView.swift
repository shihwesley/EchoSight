import SwiftUI

// MARK: - RootView

/// The primary setup window shown when EchoSight launches.
///
/// v0.1 stub: shows a minimal "Open Space" button. Onboarding flow
/// and mode-status display land in Phase 3 (onboarding-download spec).
struct RootView: View {

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var isSpaceOpen = false

    var body: some View {
        VStack(spacing: 24) {
            Text("EchoSight")
                .font(.extraLargeTitle)

            Text("Spatial accessibility companion")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button(isSpaceOpen ? "Close Space" : "Open Space") {
                Task {
                    if isSpaceOpen {
                        await dismissImmersiveSpace()
                        isSpaceOpen = false
                    } else {
                        let result = await openImmersiveSpace(id: AppIDs.immersiveSpace)
                        if case .opened = result {
                            isSpaceOpen = true
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

#Preview {
    RootView()
}
