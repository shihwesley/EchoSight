import Foundation

// MARK: - SpeechState

/// The current state of `SpeechOut`'s single synthesizer slot.
///
/// Emitted on the hot `SpeechOut.state` stream. Late subscribers see the
/// current state; there is no replay of past states.
public enum SpeechState: Sendable {
    /// No utterance in progress.
    case idle

    /// An utterance is currently being spoken.
    case speaking(SpeechToken)

    /// The audio session is ducking another audio source (e.g., VoiceOver).
    case ducking
}
