import Foundation
import simd

// MARK: - DescriptionTemplateFormatter

/// Pure function: converts `AnnotationCandidate` values into spoken phrase strings.
///
/// Format per candidate: `"<label> <distance> <cardinal direction>"`
/// Example: "chair 2 metres ahead"
///
/// Shared with `spatial-recall` spec — kept in `EchoSightCore` as a public pure function.
///
/// Cardinal direction is derived from the world-space ray azimuth:
/// - ahead:  azimuth within ±45° of 0°
/// - right:  azimuth in (45°, 135°)
/// - behind: azimuth outside ±135° from 0°
/// - left:   azimuth in (-135°, -45°)
///
/// Distance is rounded to the nearest 0.5 m. Values below 0.5 m are clipped to 0.5 m.
///
/// Empty candidates → `"I don't detect anything in front of you"`
public enum DescriptionTemplateFormatter {

    // MARK: - Public API

    /// Formats a list of salience-ranked candidates into a single spoken description.
    ///
    /// - Parameter candidates: Pre-ranked candidates (top-N by caller). Must be non-empty
    ///   for a meaningful result; empty list returns the graceful fallback phrase.
    /// - Returns: A string ready for `SpeechOut.speak`.
    public static func format(candidates: [ScoredCandidate]) -> String {
        guard !candidates.isEmpty else {
            return "I don't detect anything in front of you"
        }
        let phrases = candidates.map { phrase(for: $0) }
        return phrases.joined(separator: ", ")
    }

    // MARK: - Single-Candidate Phrase

    /// Builds a phrase for one candidate.
    static func phrase(for scored: ScoredCandidate) -> String {
        let dist = roundedDistance(scored.candidate.distance)
        let dir = cardinalDirection(worldPosition: scored.candidate.worldPosition)
        return "\(scored.candidate.label) \(dist) \(dir)"
    }

    // MARK: - Distance

    /// Round distance to nearest 0.5 m, minimum 0.5 m.
    static func roundedDistance(_ raw: Float) -> String {
        let clamped = max(raw, 0.5)
        // Work in half-metre integer buckets to avoid float equality issues.
        // e.g. 1.0 m → bucket 2 (2 × 0.5); 1.5 m → bucket 3 (3 × 0.5).
        let halfBuckets = Int((clamped / 0.5).rounded())
        if halfBuckets == 2 {
            return "1 metre"
        }
        let rounded = Float(halfBuckets) * 0.5
        let formatted = halfBuckets.isMultiple(of: 2)
            ? "\(halfBuckets / 2) metres"
            : "\(String(format: "%.1f", rounded)) metres"
        return formatted
    }

    // MARK: - Cardinal Direction

    /// Derives a cardinal direction word from the object's world-space position.
    ///
    /// Uses azimuth around the up axis (Y). Convention:
    /// - Positive X → right
    /// - Negative X → left
    /// - Negative Z → ahead (ARKit: device looks down -Z)
    ///
    /// Azimuth is `atan2(x, -z)` (east-of-north convention mapped to right-of-ahead).
    static func cardinalDirection(worldPosition: SIMD3<Float>) -> String {
        let azimuthRad = atan2(worldPosition.x, -worldPosition.z)
        let azimuthDeg = azimuthRad * (180.0 / .pi)

        switch azimuthDeg {
        case -45.0 ..< 45.0:
            return "ahead"
        case 45.0 ..< 135.0:
            return "to the right"
        case -135.0 ..< -45.0:
            return "to the left"
        default:
            return "behind you"
        }
    }
}

// MARK: - ScoredCandidate

/// A `AnnotationCandidate` paired with its salience score for ranking.
public struct ScoredCandidate: Sendable {
    public let candidate: AnnotationCandidate
    public let score: Float

    public init(candidate: AnnotationCandidate, score: Float) {
        self.candidate = candidate
        self.score = score
    }
}
