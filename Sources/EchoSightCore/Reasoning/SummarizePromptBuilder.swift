import Foundation
import simd

// MARK: - SummarizePromptBuilder

/// Builds the recall-gestalt prompt used by `spatial-recall`.
///
/// Input: up to N `WorldAnnotation` values describing nearby objects.
/// Output contract: 1-sentence gestalt summary of what the user is surrounded by.
/// Token budget: ≤30 tokens (set by GemmaRunner, not here).
///
/// No chain-of-thought. Annotations are presented as label+distance pairs.
public enum SummarizePromptBuilder {

    // MARK: - Build

    /// - Parameters:
    ///   - annotations: Nearby world annotations to summarise.
    ///   - headPose: Current head position in world space. Distances are measured
    ///     from this point for user-relative semantics. Defaults to origin when
    ///     the caller cannot provide a pose (e.g. in tests).
    public static func buildPrompt(
        from annotations: [WorldAnnotation],
        headPose: SIMD3<Float> = .zero
    ) -> String {
        guard !annotations.isEmpty else {
            return """
            The user is in an area with no remembered objects nearby.
            Summarize that in one short sentence.
            """
        }

        let items = annotations.prefix(8).map { annotation -> String in
            let dist = simd_distance(annotation.worldPosition, headPose)
            let direction = cardinalDirection(from: annotation.worldPosition)
            return "\(annotation.falconLabel) \(String(format: "%.1f", dist))m \(direction)"
        }.joined(separator: ", ")

        return """
        Summarize nearby objects for a blind user in one clear sentence:
        \(items)
        One sentence only. Mention the most important objects and their directions.
        """
    }

    // MARK: - Private

    private static func cardinalDirection(from position: SIMD3<Float>) -> String {
        // Use x/z plane for horizontal direction (ARKit: y is up)
        let angle = atan2(position.x, -position.z) * (180.0 / .pi)
        switch angle {
        case -22.5..<22.5:   return "ahead"
        case 22.5..<67.5:    return "right-front"
        case 67.5..<112.5:   return "right"
        case 112.5..<157.5:  return "right-back"
        case 157.5...:       return "behind"
        case ..<(-157.5):    return "behind"
        case -157.5..<(-112.5): return "left-back"
        case -112.5..<(-67.5):  return "left"
        case -67.5..<(-22.5):   return "left-front"
        default:             return "nearby"
        }
    }
}
