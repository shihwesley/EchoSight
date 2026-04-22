import Foundation

// MARK: - EnrichmentPromptBuilder

/// Builds the enrichment prompt for async background annotation enrichment.
///
/// Input schema: `{detections, distances, classifications}` (JSON-like structure)
/// Output contract: 1-sentence natural-language description of the detected object.
/// Token budget: ≤40 tokens (set by GemmaRunner, not here).
///
/// No chain-of-thought. Prompt is deliberately short to stay inside the budget.
public enum EnrichmentPromptBuilder {

    // MARK: - Build

    public static func buildPrompt(from context: EnrichmentContext) -> String {
        let detectionsLine = context.detections.enumerated().map { i, label in
            let distance = i < context.distances.count
                ? String(format: "%.1fm", context.distances[i])
                : "unknown"
            let classification = i < context.classifications.count
                ? context.classifications[i]
                : "unknown"
            return "\(label) at \(distance) on \(classification)"
        }.joined(separator: "; ")

        return """
        Describe the following detected objects in one clear sentence for a blind user:
        \(detectionsLine)
        One sentence only. Be specific about location and surface.
        """
    }
}
