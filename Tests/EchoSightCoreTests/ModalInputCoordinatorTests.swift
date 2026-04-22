import Testing
import Foundation
@testable import EchoSightCore

// MARK: - MockSpeechOut

/// Minimal stub that satisfies the SpeechOut interface for testing.
/// Counts calls without invoking AVFoundation.
actor MockSpeechOut {
    var speakCallCount = 0
    var lastUtterance: SpeechUtterance?
    var lastPriority: SpeechPriority?

    func speak(_ utterance: SpeechUtterance, priority: SpeechPriority) async throws -> SpeechToken {
        speakCallCount += 1
        lastUtterance = utterance
        lastPriority = priority
        let token = SpeechToken()
        token.resolve(.finished)
        return token
    }
}

// MARK: - ModalInputCoordinatorTests

/// Tests run against a real `ModalInputCoordinator` with injected mock speech.
///
/// Note: `ModalInputCoordinator` takes a `SpeechOut` actor — to avoid the full
/// AVFoundation stack in unit tests, we build a coordinator backed by a
/// real `SpeechOut` with a stub `silentModeProvider`. AVFoundation calls
/// are swallowed by `SpeechOut`'s internal cancellation logic when no
/// synthesizer delegate is wired.
///
/// For coordination tests (event emission, mode cycling, suppression) we rely on
/// the `AsyncStream` values directly, not on speech side effects.
@Suite("ModalInputCoordinator")
struct ModalInputCoordinatorTests {

    // MARK: - Helpers

    /// Build a coordinator backed by a real SpeechOut (AVFoundation not invoked
    /// in tests because no audio session runs in unit test host).
    private func makeCoordinator(
        silentMode: Bool = false,
        defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!
    ) -> ModalInputCoordinator {
        let speech = SpeechOut(
            silentModeProvider: { silentMode }
        )
        return ModalInputCoordinator(
            speechOut: speech,
            silentModeProvider: { silentMode },
            defaults: defaults
        )
    }

    // MARK: - Mode Cycling

    @Test("Crown forward rotation cycles scene → recall")
    func crownForwardCyclesMode() async {
        let coord = makeCoordinator()
        // Default mode is .scene
        await coord.crownRotated(delta: 0.5) // Large delta → steps forward
        let mode = await coord.currentMode
        #expect(mode == .recall)
    }

    @Test("Crown reverse rotation cycles scene → silent")
    func crownReverseCyclesMode() async {
        let coord = makeCoordinator()
        await coord.crownRotated(delta: -0.5)
        let mode = await coord.currentMode
        #expect(mode == .silent)
    }

    @Test("Mode cycles wraparound read → silent")
    func wraparoundReadToSilent() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let coord = makeCoordinator(defaults: defaults)
        // Set to read directly
        await coord.setMode(.read)
        #expect(await coord.currentMode == .read)
        // Forward step from read → silent
        await coord.crownRotated(delta: 0.5)
        #expect(await coord.currentMode == .silent)
    }

    @Test("Mode cycles wraparound silent → scene")
    func wraparoundSilentToScene() async {
        let coord = makeCoordinator()
        await coord.setMode(.silent)
        await coord.crownRotated(delta: 0.5)
        #expect(await coord.currentMode == .scene)
    }

    // MARK: - Button Press Events

    @Test("Button press emits ModeFiredEvent with current mode")
    func buttonPressEmitsFiredEvent() async {
        let coord = makeCoordinator()
        // Default is .scene
        await coord.buttonPressed()

        var received: ModeFiredEvent?
        for await event in coord.firedEvents {
            received = event
            break
        }
        #expect(received?.mode == .scene)
    }

    @Test("Button press in silent mode emits no event")
    func buttonPressInSilentModeIsNoOp() async {
        let coord = makeCoordinator(silentMode: false)
        await coord.setMode(.silent)

        // Press button — should be suppressed
        await coord.buttonPressed()

        // Verify stream has no pending event by checking with a short timeout
        let hasEvent = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in coord.firedEvents {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(!hasEvent)
    }

    // MARK: - Mode Change Events

    @Test("Crown rotation emits ModeChangeEvent with correct from/to")
    func crownRotationEmitsChangeEvent() async {
        let coord = makeCoordinator()
        // Start at .scene (default)

        // Spin the streams concurrently with the rotation
        async let changeTask: ModeChangeEvent? = {
            for await event in coord.changeEvents {
                return event
            }
            return nil
        }()

        await coord.crownRotated(delta: 0.5) // Forward → .recall

        let event = await changeTask
        #expect(event?.from == .scene)
        #expect(event?.to == .recall)
    }

    @Test("setMode emits ModeChangeEvent")
    func setModeEmitsChangeEvent() async {
        let coord = makeCoordinator()

        async let changeTask: ModeChangeEvent? = {
            for await event in coord.changeEvents {
                return event
            }
            return nil
        }()

        await coord.setMode(.read)

        let event = await changeTask
        #expect(event?.from == .scene)
        #expect(event?.to == .read)
    }

    // MARK: - Persistence

    @Test("Mode persists to UserDefaults and restores")
    func modePersistsAndRestores() async throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!

        let coord1 = makeCoordinator(defaults: defaults)
        await coord1.setMode(.recall)

        // Build a new coordinator backed by the same defaults suite — simulates restart
        let speech2 = SpeechOut(silentModeProvider: { false })
        let coord2 = ModalInputCoordinator(
            speechOut: speech2,
            silentModeProvider: { false },
            defaults: defaults
        )
        let restored = await coord2.currentMode
        #expect(restored == .recall)
    }

    // MARK: - Sub-threshold Crown (no mode change)

    @Test("Sub-threshold Crown delta does not change mode")
    func subThresholdNoop() async {
        let coord = makeCoordinator()
        await coord.crownRotated(delta: 0.01) // Well below default threshold of 0.10
        #expect(await coord.currentMode == .scene)
    }
}
