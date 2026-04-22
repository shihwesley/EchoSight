import Foundation

// MARK: - TextConfidenceFilter

/// Drops `RawTextObservation` values below a confidence threshold.
///
/// Vision's top candidate confidence is in [0, 1]. Motion-blurred or occluded
/// text typically scores < 0.4. Filtering these before speaking prevents garbage
/// text from being read aloud.
///
/// Default threshold: 0.4 (spec requirement). Tunable at the call site.
public enum TextConfidenceFilter {

    // MARK: - Configuration

    /// Default minimum confidence for an observation to be kept.
    public static let defaultThreshold: Float = 0.4

    // MARK: - Public API

    /// Filter observations and return only those meeting the confidence threshold.
    ///
    /// - Parameters:
    ///   - observations: `RawTextObservation` values from the Vision pipeline.
    ///   - threshold: Minimum confidence (inclusive). Default `defaultThreshold`.
    /// - Returns: Observations whose confidence meets the threshold.
    public static func filter(
        _ observations: [RawTextObservation],
        threshold: Float = defaultThreshold
    ) -> [RawTextObservation] {
        return observations.filter { $0.confidence >= threshold }
    }

    /// Extract text strings from observations meeting the confidence threshold.
    ///
    /// Convenience for callers that only need the string values.
    public static func strings(
        from observations: [RawTextObservation],
        threshold: Float = defaultThreshold
    ) -> [String] {
        return observations
            .filter { $0.confidence >= threshold }
            .map { $0.text }
    }

    /// Separate the observations into kept and dropped sets (useful for logging).
    public static func partition(
        _ observations: [RawTextObservation],
        threshold: Float = defaultThreshold
    ) -> (kept: [RawTextObservation], dropped: [RawTextObservation]) {
        let kept = observations.filter { $0.confidence >= threshold }
        let dropped = observations.filter { $0.confidence < threshold }
        return (kept, dropped)
    }
}
