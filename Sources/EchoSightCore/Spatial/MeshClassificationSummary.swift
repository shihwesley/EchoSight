import Foundation

// MARK: - MeshClassificationSummary

/// On-demand snapshot of the current spatial mesh classification distribution.
///
/// Produced by `SpatialSession` and consumed by `ambient-announce` at the moment
/// of anchor novelty for Gemma's room-label inference fallback.
/// Not streamed — computed on-demand only (dormant if no consumer calls it).
public struct MeshClassificationSummary: Sendable {

    // MARK: - MeshClass

    /// Surface classification categories matching ARKit's `ARMeshClassification`.
    public enum MeshClass: String, Sendable, CaseIterable {
        case wall
        case floor
        case ceiling
        case table
        case seat
        case window
        case door
        case unknown
    }

    // MARK: - Properties

    /// Fractional coverage per class. Values sum to approximately 1.0.
    /// May not exactly equal 1.0 if some triangles carry unrecognized classifications.
    public let distribution: [MeshClass: Float]

    /// Confidence in the distribution (0.0–1.0).
    /// Low when the mesh is still populating (few triangles observed).
    public let confidence: Float

    /// Total number of mesh triangles counted in this snapshot.
    public let triangleCount: Int

    /// When this snapshot was taken.
    public let timestamp: Date

    // MARK: - Init

    public init(
        distribution: [MeshClass: Float],
        confidence: Float,
        triangleCount: Int,
        timestamp: Date = Date()
    ) {
        self.distribution = distribution
        self.confidence = confidence
        self.triangleCount = triangleCount
        self.timestamp = timestamp
    }

    // MARK: - Convenience

    /// Returns the dominant mesh class, or `.unknown` if the distribution is empty.
    public var dominantClass: MeshClass {
        distribution.max(by: { $0.value < $1.value })?.key ?? .unknown
    }

    /// True if the confidence is high enough for room-label inference.
    /// Threshold: ≥0.6 confidence and ≥500 triangles.
    public var isReliable: Bool {
        confidence >= 0.6 && triangleCount >= 500
    }
}
