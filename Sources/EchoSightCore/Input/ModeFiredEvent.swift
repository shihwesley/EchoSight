import Foundation

// MARK: - ModeFiredEvent

/// Published when the Capture Button is pressed while not in `.silent` mode.
///
/// Feature pipelines (`scene-description`, `spatial-recall`, `ocr`) subscribe to
/// `ModalInputCoordinator.firedEvents` and filter for their mode.
///
/// TLA-verified: every non-silent button press produces exactly one event.
/// Silent button presses produce no event (suppressed at coordinator level).
public struct ModeFiredEvent: Sendable {
    /// The active mode at the moment the button was pressed.
    public let mode: Mode

    /// Wall-clock time of the button-up event.
    public let timestamp: Date

    public init(mode: Mode, timestamp: Date = .now) {
        self.mode = mode
        self.timestamp = timestamp
    }
}
