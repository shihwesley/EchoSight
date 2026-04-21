import Foundation

// MARK: - Outcome

/// The result of a pipeline action.
public enum Outcome: Sendable {
    case ok
    case degraded(reason: String)
    case cancelled
    case failed(reason: String)
    case dropped(reason: String)
}

// MARK: - PipelineEvent

/// A single observable event from any EchoSight feature.
///
/// Recorded by `PipelineMetricsBuffer.record(_:)` (fire-and-forget, non-blocking).
/// Rendered in `DebugConsoleView` and included in `logExport()`.
public struct PipelineEvent: Sendable {

    // MARK: - Properties

    /// When the event occurred.
    public let timestamp: Date

    /// The log category (one of `LogCategories` constants).
    public let category: String

    /// Short event identifier (e.g. `"speak.accepted"`, `"anchor.new"`).
    public let event: String

    /// Optional duration if the event is the end of a timed operation.
    public let durationMs: Double?

    /// How the operation resolved.
    public let outcome: Outcome

    /// Arbitrary key/value pairs. Values sanitized by `PrivacyFilter` before export.
    public let metadata: [String: String]

    // MARK: - Init

    public init(
        category: String,
        event: String,
        durationMs: Double? = nil,
        outcome: Outcome = .ok,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.category = category
        self.event = event
        self.durationMs = durationMs
        self.outcome = outcome
        self.metadata = metadata
    }
}
