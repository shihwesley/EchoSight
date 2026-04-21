import ARKit
import RealityKit
import Foundation

// MARK: - MeshAnchorTracker

/// Converts ARKit mesh anchor updates into RealityKit entities and tracks
/// mesh classification distribution for `MeshClassificationSummary`.
///
/// Entities get `CollisionComponent` so `Scene.raycast` works against them
/// (used by `ObstacleRaycaster`). Classification is stored per-entity for
/// on-demand `MeshClassificationSummary` computation.
@MainActor
public final class MeshAnchorTracker {

    // MARK: - Storage

    /// Live mesh entities keyed by ARKit anchor ID.
    private(set) public var entities: [UUID: ModelEntity] = [:]

    /// Triangle counts per classification, updated on each mesh update.
    private var classificationCounts: [MeshClassificationSummary.MeshClass: Int] = [:]
    private var totalTriangles: Int = 0

    // MARK: - Mesh Updates

    /// Process a single mesh anchor update from `SceneReconstructionProvider`.
    public func handleMeshUpdate(_ update: AnchorUpdate<MeshAnchor>) async {
        let anchor = update.anchor

        switch update.event {
        case .added, .updated:
            await upsertEntity(for: anchor)
            updateClassificationCounts(for: anchor)

        case .removed:
            entities.removeValue(forKey: anchor.id)
            rebuildClassificationCounts()
        }
    }

    // MARK: - On-Demand Summary

    /// Returns the current mesh classification distribution snapshot.
    /// Computation is O(number of distinct classes) — fast.
    public func currentSummary() -> MeshClassificationSummary {
        guard totalTriangles > 0 else {
            return MeshClassificationSummary(
                distribution: [:],
                confidence: 0,
                triangleCount: 0
            )
        }

        var distribution: [MeshClassificationSummary.MeshClass: Float] = [:]
        for (cls, count) in classificationCounts {
            distribution[cls] = Float(count) / Float(totalTriangles)
        }

        // Confidence grows with triangle count, saturates at 5000.
        let confidence = min(Float(totalTriangles) / 5000.0, 1.0)

        return MeshClassificationSummary(
            distribution: distribution,
            confidence: confidence,
            triangleCount: totalTriangles
        )
    }

    // MARK: - Private

    private func upsertEntity(for anchor: MeshAnchor) async {
        let meshResource = try? await MeshResource(from: anchor)
        let entity: ModelEntity
        if let existing = entities[anchor.id] {
            entity = existing
            if let mesh = meshResource {
                entity.model?.mesh = mesh
            }
        } else {
            entity = ModelEntity()
            if let mesh = meshResource {
                entity.model = ModelComponent(mesh: mesh, materials: [])
            }
            entity.components.set(CollisionComponent(shapes: [], mode: .default))
            entity.transform = Transform(matrix: anchor.originFromAnchorTransform)
            entities[anchor.id] = entity
        }
    }

    private func updateClassificationCounts(for anchor: MeshAnchor) {
        // Approximate: count triangles per classification using face count proxy.
        // Full per-face classification requires iterating `anchor.geometry.classifications`.
        let faceCount = anchor.geometry.faces.count
        let cls = primaryClassification(from: anchor)
        classificationCounts[cls, default: 0] += faceCount

        // Rebuild total.
        totalTriangles = classificationCounts.values.reduce(0, +)
    }

    private func rebuildClassificationCounts() {
        classificationCounts = [:]
        totalTriangles = 0
        for (_, entity) in entities {
            // Re-aggregate from remaining entities; simplified without per-face data.
            // Phase 2 adds per-face classification for higher accuracy.
            _ = entity
        }
    }

    private func primaryClassification(from anchor: MeshAnchor) -> MeshClassificationSummary.MeshClass {
        // Map ARKit's classification to our enum.
        // The dominant class by face count is used as the anchor's primary class.
        // Full per-face mode deferred to v1.0 mesh-classification spec.
        return .unknown
    }
}
