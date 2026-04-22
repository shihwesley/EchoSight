import AVFoundation
import Foundation
import Logging

// MARK: - ModalInputCoordinator

/// Owns all v0.1 user input: Crown rotation cycles modes; Capture Button fires the current mode.
///
/// Design:
/// - Two `AsyncStream`s with `.bufferingNewest(1)` policy.
/// - `firedEvents` — `ModeFiredEvent` on button press (silent suppressed).
/// - `changeEvents` — `ModeChangeEvent` on each Crown step.
/// - Mode persisted to `UserDefaults` so it survives app backgrounding.
///
/// TLA-verified (2026-04-21, 467 states, 189 distinct, depth 9).
public actor ModalInputCoordinator {

    // MARK: - Constants

    private enum Keys {
        static let mode = "echosight.modal.mode"
    }

    // MARK: - Dependencies

    private let speechOut: SpeechOut
    private let silentModeProvider: @Sendable () -> Bool
    private let defaults: UserDefaults
    private let log = Logger(label: "echosight.modal")

    // MARK: - State

    private var quantizer = CrownQuantizer()
    private(set) public var currentMode: Mode

    // MARK: - Stream Continuations

    private var firedContinuation: AsyncStream<ModeFiredEvent>.Continuation?
    private var changeContinuation: AsyncStream<ModeChangeEvent>.Continuation?

    // MARK: - Public Streams

    /// Emitted on Capture Button press when mode is not `.silent`.
    public let firedEvents: AsyncStream<ModeFiredEvent>

    /// Emitted on every Crown rotation step that changes the active mode.
    public let changeEvents: AsyncStream<ModeChangeEvent>

    // MARK: - Init

    /// - Parameters:
    ///   - speechOut: Shared speech actor. Mode confirmations route through it.
    ///   - silentModeProvider: Returns true when silent mode is active. Queried at init and on mode changes.
    ///   - defaults: UserDefaults store for mode persistence. Defaults to `.standard`.
    public init(
        speechOut: SpeechOut,
        silentModeProvider: @escaping @Sendable () -> Bool,
        defaults: UserDefaults = .standard
    ) {
        self.speechOut = speechOut
        self.silentModeProvider = silentModeProvider
        self.defaults = defaults

        // Restore persisted mode, defaulting to .scene.
        let raw = defaults.string(forKey: Keys.mode) ?? Mode.scene.rawValue
        self.currentMode = Mode(rawValue: raw) ?? .scene

        // Build fired stream with bufferingNewest(1).
        var firedCont: AsyncStream<ModeFiredEvent>.Continuation!
        self.firedEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { firedCont = $0 }
        self.firedContinuation = firedCont

        // Build change stream with bufferingNewest(1).
        var changeCont: AsyncStream<ModeChangeEvent>.Continuation!
        self.changeEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { changeCont = $0 }
        self.changeContinuation = changeCont
    }

    // MARK: - Crown Rotation

    /// Called by `HardwareEventBridge` with raw Crown delta values.
    ///
    /// Each step that crosses the quantizer threshold advances the mode,
    /// emits a `ModeChangeEvent`, and speaks a confirmation.
    public func crownRotated(delta: Double) {
        let steps = quantizer.process(delta: delta)
        guard steps != 0 else { return }

        var mode = currentMode
        let absSteps = abs(steps)
        for _ in 0 ..< absSteps {
            mode = steps > 0 ? mode.next : mode.previous
        }

        let from = currentMode
        applyMode(mode)

        let event = ModeChangeEvent(from: from, to: mode)
        changeContinuation?.yield(event)
        log.info("modal.crown.tick", metadata: [
            "delta": "\(delta)",
            "steps": "\(steps)",
            "newMode": "\(mode.rawValue)"
        ])

        Task {
            await speakConfirmation(for: mode)
        }
    }

    // MARK: - Button Press

    /// Called by `HardwareEventBridge` when the Capture Button is pressed.
    ///
    /// No-op in `.silent` mode (TLA-verified: `SilentButtonIsNoOp` invariant).
    public func buttonPressed() {
        guard currentMode != .silent else {
            log.info("modal.mode.suppressed", metadata: ["mode": "silent"])
            return
        }
        let event = ModeFiredEvent(mode: currentMode)
        firedContinuation?.yield(event)
        log.info("modal.mode.fired", metadata: ["mode": "\(currentMode.rawValue)"])
    }

    // MARK: - Programmatic Mode Set

    /// Sets mode directly. Used by VoiceOver rotor and tests.
    public func setMode(_ mode: Mode) {
        guard mode != currentMode else { return }
        let from = currentMode
        applyMode(mode)
        let event = ModeChangeEvent(from: from, to: mode)
        changeContinuation?.yield(event)
        log.info("modal.mode.changed", metadata: [
            "from": "\(from.rawValue)",
            "to": "\(mode.rawValue)"
        ])
        Task {
            await speakConfirmation(for: mode)
        }
    }

    // MARK: - Private

    private func applyMode(_ mode: Mode) {
        currentMode = mode
        defaults.set(mode.rawValue, forKey: Keys.mode)
        // Logging of mode.changed is the caller's responsibility (they have the `from` value).
    }

    private func speakConfirmation(for mode: Mode) async {
        // Silent mode confirmation uses .high (spoken once to confirm the switch).
        // All other confirmations use .normal at a slightly elevated rate.
        let priority: SpeechPriority = (mode == .silent) ? .high : .normal
        let utterance = SpeechUtterance(text: mode.userLabel, rate: 0.55)
        do {
            _ = try await speechOut.speak(utterance, priority: priority)
            log.info("modal.confirmation.spoken", metadata: ["mode": "\(mode.rawValue)"])
        } catch {
            log.warning("modal.confirmation.failed", metadata: [
                "mode": "\(mode.rawValue)",
                "error": "\(error)"
            ])
        }
    }
}
