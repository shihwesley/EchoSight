import Foundation
import simd

// MARK: - SalienceScorer

/// Scores and ranks `AnnotationCandidate` values for scene-description TTS.
///
/// Salience formula: `score = confidence × centralityBias / max(distance, 0.5)`
///
/// - `confidence`: detector confidence in [0, 1]
/// - `centralityBias`: 1.0 for center-field objects, < 1.0 for periphery (future)
///   v0.1: always 1.0 (no angle/FOV data on candidates)
/// - `distance`: metres; clamped to 0.5 to avoid division by zero and to prevent
///   very close objects from dominating unfairly
///
/// Tiebreaker: insertion order (stable sort preserves upstream ordering).
public enum SalienceScorer {

    // MARK: - Configuration

    /// Maximum candidates returned after ranking. Spec: 3–5 by salience.
    public static let defaultTopN = 5

    // MARK: - Public API

    /// Score and rank `candidates`, returning the top-N `ScoredCandidate` values.
    ///
    /// - Parameters:
    ///   - candidates: Raw fusion outputs.
    ///   - topN: Maximum number of results. Default `defaultTopN`.
    /// - Returns: Ranked candidates, most salient first. Never more than `topN`.
    public static func topN(
        from candidates: [AnnotationCandidate],
        topN: Int = defaultTopN
    ) -> [ScoredCandidate] {
        let scored = candidates.map { candidate in
            ScoredCandidate(candidate: candidate, score: score(candidate))
        }
        // Stable descending sort — insertion order breaks ties.
        let sorted = scored.sorted { $0.score > $1.score }
        return Array(sorted.prefix(topN))
    }

    // MARK: - Scoring

    /// Computes the salience score for a single candidate.
    static func score(_ candidate: AnnotationCandidate) -> Float {
        let dist = max(candidate.distance, 0.5)
        return candidate.confidence / dist
    }
}
