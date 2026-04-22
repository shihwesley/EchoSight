import Foundation

// MARK: - ModeChangeEvent

/// Published on every Crown rotation step that changes the active mode.
///
/// Consumers:
/// - `spatial-recall`: aborts in-flight recall window on any mode change.
/// - `ambient-announce`: gates silent-mode suppression.
/// - `scene-description` / `ocr`: cancel in-flight pipelines on mode change.
public struct ModeChangeEvent: Sendable {
    /// Mode before the Crown step.
    public let from: Mode

    /// Mode after the Crown step.
    public let to: Mode

    /// Wall-clock time of the step.
    public let timestamp: Date

    public init(from: Mode, to: Mode, timestamp: Date = .now) {
        self.from = from
        self.to = to
        self.timestamp = timestamp
    }
}
