import Foundation
import simd

// MARK: - AnnotationMerger

/// 30 cm duplicate-collapse logic for the annotation write path.
///
/// When a new `WorldAnnotation` arrives for an anchor that already has
/// persisted annotations, the merger scans existing rows for any within
/// `mergeRadius` (default 0.30 m) of the incoming position.
///
/// Merge semantics (spec section "merge(existing:incoming:)"):
/// - `captureCount` increments by 1
/// - `lastSeenAt` takes the incoming value (fresher observation wins)
/// - `confidence` keeps whichever is higher
/// - `falconLabel` keeps the label attached to the higher-confidence entry
/// - `description` is preserved if existing; incoming value wins if existing is nil
/// - All other fields (`id`, `worldAnchorId`, `createdAt`, `worldPosition`) stay
///   from the existing row — position is not updated on merge (anchor-keyed stability)
///
/// Stateless enum — no stored state, all functions static.
public enum AnnotationMerger {

    // MARK: - Merge Candidate Search

    /// Finds the closest existing annotation within `radius` of `incoming`.
    ///
    /// Returns `nil` if no candidate exists within the threshold.
    /// If multiple candidates qualify (rare), returns the nearest one.
    public static func findMergeCandidate(
        in existing: [WorldAnnotation],
        for incoming: WorldAnnotation,
        radius: Float = 0.30
    ) -> WorldAnnotation? {
        existing
            .filter { simd_distance($0.worldPosition, incoming.worldPosition) < radius }
            .min(by: { a, b in
                simd_distance(a.worldPosition, incoming.worldPosition)
                    < simd_distance(b.worldPosition, incoming.worldPosition)
            })
    }

    // MARK: - Merge

    /// Produces a merged annotation from `existing` (persisted) and `incoming` (new capture).
    ///
    /// The returned value preserves `existing.id`, `existing.worldPosition`, and
    /// `existing.createdAt` — only observation-count and quality fields are updated.
    public static func merge(
        existing: WorldAnnotation,
        incoming: WorldAnnotation
    ) -> WorldAnnotation {
        let (winningLabel, winningConfidence): (String, Float) =
            incoming.confidence >= existing.confidence
                ? (incoming.falconLabel, incoming.confidence)
                : (existing.falconLabel, existing.confidence)

        let mergedDescription: String?
        if let existingDesc = existing.description {
            mergedDescription = existingDesc  // preserve existing enrichment
        } else {
            mergedDescription = incoming.description  // take incoming if we have nothing
        }

        return WorldAnnotation(
            id: existing.id,
            worldPosition: existing.worldPosition,
            worldAnchorId: existing.worldAnchorId,
            falconLabel: winningLabel,
            meshClassification: existing.meshClassification,
            confidence: winningConfidence,
            description: mergedDescription,
            createdAt: existing.createdAt,
            lastSeenAt: incoming.lastSeenAt,
            captureCount: existing.captureCount + 1
        )
    }
}
