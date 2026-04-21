import Foundation

// MARK: - SpeechPriority

/// Priority level for a `SpeechOut.speak` request.
///
/// Priority semantics (TLA-verified, 2026-04-21, 70 states):
/// - `.high` arriving while `.normal` is speaking → cancel in-flight `.normal`, start `.high` immediately.
/// - `.normal` arriving while `.high` is speaking → drop (token completes `.dropped(.preemptedByHigh)`).
/// - Same-priority arrival → cancel in-flight, start new (most recent wins).
public enum SpeechPriority: Sendable, Equatable, Comparable {
    case normal
    case high

    // MARK: - Comparable

    /// `.high` > `.normal`.
    public static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool {
        lhs == .normal && rhs == .high
    }
}
