import Foundation
import simd

// MARK: - AnnotationCandidate

/// A pre-persistence world-space annotation candidate produced by `FusionEngine`.
///
/// Carries the fused label, world position, distance, and a quality outcome
/// so the annotation-store can decide whether to persist or skip.
///
/// Consumers:
/// - `scene-description`: reads label + confidence to build TTS templates
/// - `annotation-store`: persists candidates marked `.normal`; may skip `.degraded`
public struct AnnotationCandidate: Sendable {

    // MARK: - Properties

    /// The reconciled object label (from detector, validated by mesh if available).
    public let label: String

    /// Fused confidence value in range 0.0–1.0.
    public let confidence: Float

    /// Position of the annotation in world space (meters, ARKit coordinate system).
    public let worldPosition: SIMD3<Float>

    /// Distance from the device to the annotation in meters.
    public let distance: Float

    /// Quality outcome for this candidate.
    public let outcome: Outcome

    // MARK: - Outcome

    public enum Outcome: Sendable {
        /// Candidate produced through the normal pipeline (raycast hit + reconciled label).
        case normal

        /// Candidate produced but with reduced reliability. The annotation-store
        /// may still persist it, but can mark it as approximate.
        case degraded(DegradedReason)
    }

    public enum DegradedReason: Sendable {
        /// Head-pose ring buffer underflow: used oldest available pose.
        /// World position may be off if the device moved significantly since ring fill.
        case poseExtrapolated

        /// Ray-cast returned no mesh hits. World position estimated using
        /// `kDefaultRaycastDistanceM` along the ray direction.
        case raycastMiss

        /// Detection label was "person": mesh ray-cast bypassed, used
        /// shoulder-height heuristic (`kPersonShoulderHeightM`).
        case personBypass
    }

    // MARK: - Init

    public init(
        label: String,
        confidence: Float,
        worldPosition: SIMD3<Float>,
        distance: Float,
        outcome: Outcome
    ) {
        self.label = label
        self.confidence = confidence
        self.worldPosition = worldPosition
        self.distance = distance
        self.outcome = outcome
    }
}
