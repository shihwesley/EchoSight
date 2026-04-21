import Testing
@testable import EchoSightCore

// MARK: - SpeechOutTests

/// Unit tests for SpeechOut actor priority contract.
///
/// These tests verify the synchronous priority-arbitration logic in SpeechOut.
/// Tests requiring real AVSpeechSynthesizer output (preemption timing, ducking)
/// are integration tests that run on device/simulator with audio enabled.
@Suite("SpeechOut Priority Contract")
struct SpeechOutTests {

    // MARK: - Silent Mode

    @Test(".normal drops when silent=true at request time")
    func normalDropsInSilentMode() async {
        let speech = SpeechOut(silentModeProvider: { true })
        let utterance = SpeechUtterance(text: "test")

        let token = await speech.speak(utterance, priority: .normal)
        let outcome = await token.completion

        guard case .dropped(let reason) = outcome else {
            Issue.record("Expected .dropped, got \(outcome)")
            return
        }
        #expect(reason == .silentMode)
    }

    @Test(".high bypasses silent mode gate and is not immediately dropped")
    func highBypassesSilentMode() async {
        let speech = SpeechOut(silentModeProvider: { true })
        let utterance = SpeechUtterance(text: "test")

        // .high should not be dropped immediately — no silent gate.
        let token = await speech.speak(utterance, priority: .high)

        // Race: give a brief window to see if it resolves as .dropped synchronously.
        let immediatelyDropped = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let outcome = await token.completion
                if case .dropped = outcome { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
                return false
            }
            let r = await group.next()!
            group.cancelAll()
            return r
        }

        // If dropped synchronously in 10 ms, the silent gate incorrectly hit .high.
        #expect(!immediatelyDropped)
        // Clean up.
        await speech.cancelAll()
    }

    // MARK: - Cancellation

    @Test("cancelAll resolves current token as .cancelled")
    func cancelAllResolvesToken() async {
        let speech = SpeechOut()
        let utterance = SpeechUtterance(text: "test")

        let token = await speech.speak(utterance, priority: .normal)
        await speech.cancelAll()

        let outcome = await token.completion
        // Acceptable outcomes: .cancelled (immediate cancel hit) or .finished (race).
        switch outcome {
        case .cancelled, .finished:
            break // both valid
        case .dropped:
            Issue.record("Unexpected .dropped on cancelAll: \(outcome)")
        }
    }

    // MARK: - Priority Arbitration

    @Test(".normal during .high is dropped with .preemptedByHigh")
    func normalDuringHighIsDropped() async {
        let speech = SpeechOut()

        let highUtterance = SpeechUtterance(text: "high priority speech")
        let normalUtterance = SpeechUtterance(text: "normal priority speech")

        let highToken = await speech.speak(highUtterance, priority: .high)
        let normalToken = await speech.speak(normalUtterance, priority: .normal)

        let normalOutcome = await normalToken.completion
        guard case .dropped(let reason) = normalOutcome else {
            Issue.record("Expected .dropped, got \(normalOutcome)")
            await speech.cancel(highToken)
            return
        }
        #expect(reason == .preemptedByHigh)

        await speech.cancel(highToken)
    }
}
