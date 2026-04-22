import Foundation

// MARK: - RecallGestaltFormatter

/// Template-based fallback for the Gemma-summarize path in `spatial-recall`.
///
/// Used when `GemmaRunner.summarize` exceeds its 1.5 s budget or the model
/// is unavailable. Produces a deterministic spoken phrase from annotation counts
/// and labels so the user always gets an audio response.
///
/// Pure function — no state, no I/O.
public enum RecallGestaltFormatter {

    // MARK: - Constants

    private enum Limit {
        /// Max label count to enumerate in the spoken phrase.
        static let maxEnumerated = 3
    }

    // MARK: - Public API

    /// Builds a spoken gestalt phrase from a flat annotation snapshot.
    ///
    /// - Parameter annotations: Non-empty array of nearby `WorldAnnotation` values.
    ///   Caller guarantees non-empty (empty case is handled upstream with a
    ///   separate "don't remember" phrase before this formatter is ever reached).
    /// - Returns: A phrase such as "Three things around you: a chair, a table, a doorway"
    ///   or "One thing around you: a chair".
    public static func format(annotations: [WorldAnnotation]) -> String {
        let count = annotations.count

        // Deduplicate labels, preserve first-occurrence order.
        // P2-DEFERRED: Empty falconLabel strings produce "a " (trailing space) in the spoken phrase.
        // Filter empty labels here and add a precondition on annotations.isEmpty.
        // (P2-3, sprint-3.2)
        var seen = Set<String>()
        let uniqueLabels: [String] = annotations.compactMap { annotation in
            let label = annotation.falconLabel.lowercased()
            guard !label.isEmpty, !seen.contains(label) else { return nil }
            seen.insert(label)
            return label
        }

        let enumerated = Array(uniqueLabels.prefix(Limit.maxEnumerated))

        if enumerated.isEmpty {
            return countPhrase(count) + "."
        }

        let labelList = enumerated.map { "a \($0)" }.joined(separator: ", ")
        return "\(countPhrase(count)): \(labelList)"
    }

    // MARK: - Private

    private static func countPhrase(_ count: Int) -> String {
        switch count {
        case 1:  return "One thing around you"
        case 2:  return "Two things around you"
        case 3:  return "Three things around you"
        case 4:  return "Four things around you"
        case 5:  return "Five things around you"
        default: return "\(count) things around you"
        }
    }
}
