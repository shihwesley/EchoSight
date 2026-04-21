import AVFoundation
import Foundation

// MARK: - SynthesizerDelegateBridge

/// `@unchecked Sendable` bridge over `AVSpeechSynthesizerDelegate`.
///
/// `AVSpeechSynthesizerDelegate` is not Sendable-safe. This bridge receives
/// delegate callbacks on whichever thread AVFoundation chooses, then enqueues
/// onto the `SpeechOut` actor via an `AsyncStream` continuation.
final class SynthesizerDelegateBridge: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    // MARK: - Events

    // AVSpeechUtterance is not Sendable; strip it from the event.
    // SpeechOut doesn't need utterance identity from delegate callbacks —
    // it owns a single slot and resolves the current token on each event.
    enum Event: Sendable {
        case started
        case finished
        case cancelled
    }

    // MARK: - Stream

    private let continuation: AsyncStream<Event>.Continuation

    let events: AsyncStream<Event>

    // MARK: - Init

    override init() {
        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        continuation.yield(.started)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation.yield(.finished)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        continuation.yield(.cancelled)
    }
}
