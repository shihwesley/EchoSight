import AVFoundation
import Foundation

// MARK: - SpeechUtterance

/// The text and voice parameters for a single spoken output.
public struct SpeechUtterance: Sendable {

    // MARK: - Properties

    /// The text to speak.
    public let text: String

    /// Speaking rate. Maps to `AVSpeechUtterance.rate` (0.0–1.0).
    /// Default 0.5 matches AVFoundation's `AVSpeechUtteranceDefaultSpeechRate`.
    public let rate: Float

    /// Voice pitch multiplier (0.5–2.0). Default 1.0.
    public let pitchMultiplier: Float

    /// Optional voice identifier. Nil uses the system default accessibility voice.
    public let voiceIdentifier: String?

    // MARK: - Init

    public init(
        text: String,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        pitchMultiplier: Float = 1.0,
        voiceIdentifier: String? = nil
    ) {
        self.text = text
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        self.voiceIdentifier = voiceIdentifier
    }

    // MARK: - Conversion

    /// Build an `AVSpeechUtterance` from this value.
    func toAVUtterance() -> AVSpeechUtterance {
        let utt = AVSpeechUtterance(string: text)
        utt.rate = rate
        utt.pitchMultiplier = pitchMultiplier
        if let id = voiceIdentifier {
            utt.voice = AVSpeechSynthesisVoice(identifier: id)
        }
        return utt
    }
}
