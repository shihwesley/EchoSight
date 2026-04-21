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

    /// Per-anchor classification + face count, used to maintain
    /// `classificationCounts` incrementally (add on upsert, subtract on removal).
    private var anchorContributions: [UUID: (cls: MeshClassificationSummary.MeshClass, faces: Int)] = [:]

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
            removeClassificationContribution(for: anchor.id)
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

        // If this anchor was already contributing, subtract the old values first
        // so an update doesn't double-count.
        if let old = anchorContributions[anchor.id] {
            classificationCounts[old.cls, default: 0] -= old.faces
            if (classificationCounts[old.cls] ?? 0) <= 0 {
                classificationCounts.removeValue(forKey: old.cls)
            }
            totalTriangles -= old.faces
        }

        anchorContributions[anchor.id] = (cls, faceCount)
        classificationCounts[cls, default: 0] += faceCount
        totalTriangles += faceCount
    }

    private func removeClassificationContribution(for anchorId: UUID) {
        guard let contribution = anchorContributions.removeValue(forKey: anchorId) else {
            return
        }
        classificationCounts[contribution.cls, default: 0] -= contribution.faces
        if (classificationCounts[contribution.cls] ?? 0) <= 0 {
            classificationCounts.removeValue(forKey: contribution.cls)
        }
        totalTriangles -= contribution.faces
        if totalTriangles < 0 { totalTriangles = 0 }
    }

    private func primaryClassification(from anchor: MeshAnchor) -> MeshClassificationSummary.MeshClass {
        // Map ARKit's classification to our enum.
        // The dominant class by face count is used as the anchor's primary class.
        // Full per-face mode deferred to v1.0 mesh-classification spec.
        return .unknown
    }
}
