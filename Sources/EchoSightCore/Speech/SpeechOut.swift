import AVFoundation
import Foundation
import Logging

// MARK: - SpeechOut

/// Single-owner `AVSpeechSynthesizer` actor.
///
/// Owns the one and only `AVSpeechSynthesizer` in EchoSight. Five consumers bind
/// to this actor: `modal-input`, `scene-description`, `ocr`, `spatial-recall`,
/// `ambient-announce`.
///
/// Priority contract (TLA-verified, 70 states, 2026-04-21):
/// - `.high` preempts `.normal` within 100 ms.
/// - `.normal` arriving while `.high` is speaking → dropped immediately.
/// - Same-priority: most-recent wins (in-flight cancelled, new starts).
///
/// Silent-mode gate:
/// - Applied to `.normal` only, at the moment `speak` is called (new-request gate).
/// - In-flight `.normal` that started while silent=FALSE finishes naturally.
/// - `.high` bypasses the gate entirely.
public actor SpeechOut {

    // MARK: - Types

    public typealias SilentModeProvider = @Sendable () -> Bool

    // MARK: - State

    private let log = Logger(label: "echosight.speech")
    private let synthesizer = AVSpeechSynthesizer()
    private let bridge = SynthesizerDelegateBridge()
    private let silentModeProvider: SilentModeProvider

    private var currentToken: SpeechToken?
    private var currentPriority: SpeechPriority?

    // MARK: - State Stream

    private var stateContinuations: [UUID: AsyncStream<SpeechState>.Continuation] = [:]

    /// Hot stream of `SpeechState`. Late subscribers see current state.
    public func makeStateStream() -> AsyncStream<SpeechState> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.registerStateContinuation(continuation, id: id) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unregisterStateContinuation(id: id) }
            }
        }
    }

    private func registerStateContinuation(_ c: AsyncStream<SpeechState>.Continuation, id: UUID) {
        stateContinuations[id] = c
        c.yield(.idle) // Deliver current state to late subscriber.
    }

    private func unregisterStateContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func emitState(_ state: SpeechState) {
        for c in stateContinuations.values { c.yield(state) }
    }

    // MARK: - Init

    /// - Parameter silentModeProvider: Called at each `.normal` speak request.
    ///   Should read `ModalInputCoordinator.currentMode == .silent`. Not called
    ///   for `.high` priority.
    public init(silentModeProvider: @escaping SilentModeProvider = { false }) {
        self.silentModeProvider = silentModeProvider
        synthesizer.delegate = bridge
        // Actor init: must use a Task to call actor-isolated async methods.
        Task {
            await self.configureAudioSession()
            await self.processDelegateEvents()
        }
    }

    // MARK: - Public API

    /// Speak an utterance with the given priority.
    ///
    /// - Returns: A `SpeechToken` whose `.completion` resolves when the utterance
    ///   finishes, is cancelled, or is dropped.
    @discardableResult
    public func speak(_ utterance: SpeechUtterance, priority: SpeechPriority) -> SpeechToken {
        let token = SpeechToken()

        // Silent-mode gate — new-request only, .normal only.
        if priority == .normal && silentModeProvider() {
            log.info("speak.dropped", metadata: ["token": .string(token.id.uuidString.prefix(8) + "…"), "reason": "silentMode"])
            token.resolve(.dropped(reason: .silentMode))
            return token
        }

        // Priority arbitration.
        if let existing = currentToken, let existingPriority = currentPriority {
            if priority == .normal && existingPriority == .high {
                // Drop the incoming .normal.
                log.info("speak.dropped", metadata: ["token": .string(token.id.uuidString.prefix(8) + "…"), "reason": "preemptedByHigh"])
                token.resolve(.dropped(reason: .preemptedByHigh))
                return token
            } else {
                // Cancel in-flight (either .high preempts .normal, or same-priority most-recent-wins).
                synthesizer.stopSpeaking(at: .immediate)
                existing.resolve(.cancelled)
                log.info("speak.preempted", metadata: [
                    "droppedToken": .string(existing.id.uuidString.prefix(8) + "…"),
                    "newPriority": .string("\(priority)"),
                ])
            }
        }

        // Start new utterance.
        currentToken = token
        currentPriority = priority
        let avUtterance = utterance.toAVUtterance()
        synthesizer.speak(avUtterance)

        log.info("speak.accepted", metadata: [
            "token": .string(token.id.uuidString.prefix(8) + "…"),
            "priority": .string("\(priority)"),
        ])

        return token
    }

    /// Cancel a specific token if it is currently speaking or queued.
    public func cancel(_ token: SpeechToken) {
        guard currentToken?.id == token.id else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentToken?.resolve(.cancelled)
        currentToken = nil
        currentPriority = nil
        emitState(.idle)
        log.info("speak.cancelled", metadata: ["token": .string(token.id.uuidString.prefix(8) + "…"), "source": "cancel(token:)"])
    }

    /// Cancel every in-flight utterance immediately.
    public func cancelAll() {
        guard currentToken != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentToken?.resolve(.cancelled)
        currentToken = nil
        currentPriority = nil
        emitState(.idle)
        log.info("speak.cancelled", metadata: ["source": "cancelAll()"])
    }

    // MARK: - Delegate Event Processing

    private func processDelegateEvents() async {
        for await event in bridge.events {
            switch event {
            case .started:
                if let token = currentToken {
                    emitState(.speaking(token))
                    log.debug("speak.started")
                }
            case .finished:
                let token = currentToken
                currentToken = nil
                currentPriority = nil
                token?.resolve(.finished)
                emitState(.idle)
                log.info("speak.finished")
            case .cancelled:
                // Token already resolved in `cancel`/`cancelAll`/preemption path.
                // Guard against double-resolve on AVFoundation's async delegate.
                if currentToken != nil {
                    currentToken?.resolve(.cancelled)
                    currentToken = nil
                    currentPriority = nil
                    emitState(.idle)
                }
            }
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            log.error("speech.audioSession.configFailed", metadata: ["error": .string(error.localizedDescription)])
        }
    }
}
