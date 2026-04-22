import Foundation

// MARK: - RoomLabelPromptBuilder

/// Builds the ambient room-label prompt used by `ambient-announce`.
///
/// Input: anchor age (from AnchorMetadata.firstSeenAt), nearby annotations,
/// and the mesh classification distribution from `MeshClassificationSummary`.
/// Output contract: 1-3 word noun phrase — "living room", "office space", "corridor".
/// Token budget: ≤20 tokens (set by GemmaRunner, not here).
///
/// No chain-of-thought. Short output — ambient-announce needs a label, not a paragraph.
public enum RoomLabelPromptBuilder {

    // MARK: - Build

    public static func buildPrompt(
        anchorId: UUID,
        annotations: [WorldAnnotation],
        meshClassification: MeshClassificationSummary
    ) -> String {
        let annotationList = annotations.prefix(5)
            .map { $0.falconLabel }
            .joined(separator: ", ")
            .ifEmpty("none")

        let primaryClass = meshClassification.dominantClass.rawValue
        let distribution = meshClassification.topClasses(limit: 3)
            .map { "\($0.key.rawValue): \(String(format: "%.0f%%", $0.value * 100))" }
            .joined(separator: ", ")
            .ifEmpty("unknown")

        return """
        Classify this room in 1-3 words based on the following context:
        - Objects present: \(annotationList)
        - Primary surface type: \(primaryClass)
        - Surface distribution: \(distribution)
        Reply with only the room type as a short noun phrase (e.g. "living room", "kitchen", "corridor").
        No punctuation. No explanation.
        """
    }
}

// MARK: - MeshClassificationSummary Extension

// P3-DEFERRED: this extension on a Spatial-module type lives in the Reasoning module.
// Move topClasses(limit:) adjacent to MeshClassificationSummary in Spatial/ when convenient.
extension MeshClassificationSummary {
    /// Returns the top N mesh classes sorted by proportion descending.
    func topClasses(limit: Int) -> [(key: MeshClass, value: Float)] {
        distribution
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (key: $0.key, value: $0.value) }
    }
}

// MARK: - String Helper

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
