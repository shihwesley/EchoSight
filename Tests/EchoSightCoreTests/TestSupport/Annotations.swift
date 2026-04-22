import Foundation
import simd
@testable import EchoSightCore

// MARK: - Annotation Test Factory

/// Shared factory for constructing `WorldAnnotation` values in tests.
///
/// Centralises default values so individual tests only specify what's relevant.
/// Tests that duplicate annotation construction should use these instead.
func makeAnnotation(
    id: UUID = UUID(),
    worldPosition: SIMD3<Float> = .zero,
    worldAnchorId: UUID = UUID(),
    falconLabel: String = "chair",
    meshClassification: String = "floor",
    confidence: Float = 0.85,
    description: String? = nil,
    createdAt: Date = Date(),
    lastSeenAt: Date = Date(),
    captureCount: Int = 1
) -> WorldAnnotation {
    WorldAnnotation(
        id: id,
        worldPosition: worldPosition,
        worldAnchorId: worldAnchorId,
        falconLabel: falconLabel,
        meshClassification: meshClassification,
        confidence: confidence,
        description: description,
        createdAt: createdAt,
        lastSeenAt: lastSeenAt,
        captureCount: captureCount
    )
}
