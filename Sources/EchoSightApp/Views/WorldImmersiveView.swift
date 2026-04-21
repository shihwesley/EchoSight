import SwiftUI
import RealityKit

// MARK: - WorldImmersiveView

/// RealityView host for Layer 1 spatial content.
///
/// v0.1 stub: empty scene. SpatialSession (spatial-core spec) attaches
/// its mesh entities and obstacle raycaster to this RealityView's content.
/// The spatial-core spec fills this view's make/update closures.
struct WorldImmersiveView: View {

    var body: some View {
        RealityView { content in
            // Layer 1 entities (mesh anchors, spatial audio) added here
            // by the spatial-core spec's SpatialSession integration.
            // Stub intentionally empty — build gate only.
        } update: { content in
            // Update pass — used by SpatialCueRenderer and ObstacleRaycaster.
        }
    }
}
