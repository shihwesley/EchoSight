import Testing
import Foundation
import simd
@testable import EchoSightCore

// MARK: - SpatialRecallOrchestratorTests

/// State machine tests for `SpatialRecallOrchestrator`.
///
/// Uses the closure-based testability init so all I/O (store, Gemma, speech)
/// can be intercepted without the real dependencies. Deferred execution
/// (visionOS sim boot exceeds phase-runner watchdog). Manual command:
///   xcodebuild test -scheme EchoSight -destination 'platform=visionOS Simulator,name=Apple Vision Pro' | xcbeautify
@Suite("SpatialRecallOrchestrator")
struct SpatialRecallOrchestratorTests {

    // MARK: - Helpers

    typealias SpokenEntry = (text: String, priority: SpeechPriority)

    /// Test double state shared across closures via actor.
    private actor TestSpeech {
        private(set) var spoken: [SpokenEntry] = []
        private(set) var cancelAllCount = 0

        func record(_ text: String, _ priority: SpeechPriority) {
            spoken.append((text, priority))
        }

        func recordCancelAll() { cancelAllCount += 1 }
    }

    private func makeOrchestrator(
        annotations: [WorldAnnotation] = [],
        gemmaResult: Result<String, Error> = .success("Mock gestalt"),
        headPos: SIMD3<Float> = .zero,
        speech: TestSpeech = TestSpeech()
    ) -> (SpatialRecallOrchestrator, TestSpeech) {
        let orch = SpatialRecallOrchestrator(
            nearestAnnotations: { _, _ in annotations },
            gemmaSummarize: { _ in try gemmaResult.get() },
            speakAction: { utterance, priority in
                await speech.record(utterance.text, priority)
                let token = SpeechToken()
                token.resolve(.finished)
                return token
            },
            cancelAllAction: { await speech.recordCancelAll() },
            headPoseProvider: { headPos }
        )
        return (orch, speech)
    }

    // MARK: - Empty Annotations

    @Test("Empty annotations speaks graceful fallback, no Gemma")
    func emptyAnnotationsFallback() async throws {
        let speech = TestSpeech()
        let (orch, _) = makeOrchestrator(annotations: [], speech: speech)

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(100))

        let spoken = await speech.spoken
        #expect(spoken.count == 1)
        #expect(spoken[0].text.contains("don't remember"))
        #expect(spoken[0].priority == .normal)
    }

    // MARK: - First Press Gestalt

    @Test("First press with annotations speaks Gemma gestalt at .high")
    func firstPressGestaltHighPriority() async throws {
        let annotations = [makeAnnotation(label: "chair"), makeAnnotation(label: "table")]
        let speech = TestSpeech()
        let (orch, _) = makeOrchestrator(
            annotations: annotations,
            gemmaResult: .success("You're in a living room"),
            speech: speech
        )

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(100))

        let spoken = await speech.spoken
        #expect(spoken.count == 1)
        #expect(spoken[0].text == "You're in a living room")
        #expect(spoken[0].priority == .high)
    }

    // MARK: - Gemma Timeout → Template Fallback

    @Test("Gemma failure falls back to RecallGestaltFormatter template")
    func gemmaFailureFallsBackToTemplate() async throws {
        let annotations = [makeAnnotation(label: "chair"), makeAnnotation(label: "door")]
        let speech = TestSpeech()

        enum TestError: Error { case timeout }
        let (orch, _) = makeOrchestrator(
            annotations: annotations,
            gemmaResult: .failure(TestError.timeout),
            speech: speech
        )

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(100))

        let spoken = await speech.spoken
        #expect(spoken.count == 1)
        #expect(spoken[0].text.contains("around you"))  // template phrase
        #expect(spoken[0].priority == .high)
    }

    // MARK: - Second Press Within Window

    @Test("Second press within 5 s speaks gestalt then detail list")
    func secondPressWithinWindow() async throws {
        let annotations = [
            makeAnnotation(label: "chair", pos: SIMD3(1, 0, -1)),
            makeAnnotation(label: "table", pos: SIMD3(2, 0, -2)),
        ]
        let speech = TestSpeech()
        let (orch, _) = makeOrchestrator(
            annotations: annotations,
            gemmaResult: .success("A furnished room"),
            speech: speech
        )

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        // First press
        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(150))

        // Second press within 5 s
        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(150))

        let spoken = await speech.spoken
        #expect(spoken.count == 2)
        #expect(spoken[0].text == "A furnished room")     // gestalt
        #expect(spoken[0].priority == .high)
        #expect(spoken[1].priority == .normal)             // detail
        // Detail should contain a distance/direction phrase
        let detailHasDirection = spoken[1].text.contains("ahead") ||
                                 spoken[1].text.contains("right") ||
                                 spoken[1].text.contains("left") ||
                                 spoken[1].text.contains("metre")
        #expect(detailHasDirection)
    }

    // MARK: - Second Press After Window Expired

    @Test("Second press after window expiry is treated as new first press")
    func secondPressAfterWindowExpiry() async throws {
        // Use a very short window by firing the event much later.
        // Real window is 5 s but we can simulate expiry by checking behavior
        // of fresh first press (both should yield gestalt).
        // We verify: after enough time passes, a second press produces another gestalt (not detail).
        // Note: This test intentionally takes ~6 s to run.
        let annotations = [makeAnnotation(label: "desk")]
        let speech = TestSpeech()
        let (orch, _) = makeOrchestrator(
            annotations: annotations,
            gemmaResult: .success("A workspace"),
            speech: speech
        )

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        // First press
        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(100))

        // Wait > 5 s to let the window expire
        try await Task.sleep(for: .seconds(6))

        // Second press — should be treated as fresh first press (new gestalt)
        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(100))

        let spoken = await speech.spoken
        // Both presses should produce a gestalt (no detail)
        #expect(spoken.count == 2)
        #expect(spoken[0].priority == .high)
        #expect(spoken[1].priority == .high)
    }

    // MARK: - Mode-Change Abort

    @Test("Mode-change calls cancelAll and aborts state machine")
    func modeChangeCallsCancelAll() async throws {
        let annotations = [makeAnnotation(label: "couch")]
        let speech = TestSpeech()
        let (orch, _) = makeOrchestrator(
            annotations: annotations,
            gemmaResult: .success("A living room"),
            speech: speech
        )

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, changeCont) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(100))

        // Mode change — should cancel and call cancelAll
        changeCont.yield(ModeChangeEvent(from: .recall, to: .scene))
        try await Task.sleep(for: .milliseconds(100))

        let cancelCount = await speech.cancelAllCount
        #expect(cancelCount >= 1)
    }

    // MARK: - Window Expiry Does Not Cancel Speech

    @Test("Window expiry does not call cancelAll (pinned 2026-04-21)")
    func windowExpiryDoesNotCancelSpeech() async throws {
        let annotations = [makeAnnotation(label: "bookshelf")]
        let speech = TestSpeech()
        let (orch, _) = makeOrchestrator(
            annotations: annotations,
            gemmaResult: .success("A library area"),
            speech: speech
        )

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        firedCont.yield(ModeFiredEvent(mode: .recall))
        try await Task.sleep(for: .milliseconds(100))

        // Wait for window to expire (5 s + buffer)
        try await Task.sleep(for: .seconds(6))

        // cancelAll must NOT have been called (window expiry is not a speech-lifecycle event)
        let cancelCount = await speech.cancelAllCount
        #expect(cancelCount == 0)
    }

    // MARK: - Non-Recall Mode Fires Ignored

    @Test("Non-recall mode fires are ignored by the orchestrator")
    func nonRecallModeFiresIgnored() async throws {
        let speech = TestSpeech()
        let (orch, _) = makeOrchestrator(speech: speech)

        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await orch.start(firedEvents: firedStream, changeEvents: changeStream)

        firedCont.yield(ModeFiredEvent(mode: .scene))
        firedCont.yield(ModeFiredEvent(mode: .read))
        try await Task.sleep(for: .milliseconds(100))

        let spoken = await speech.spoken
        #expect(spoken.isEmpty)
    }
}

// MARK: - RecallGestaltFormatterTests

@Suite("RecallGestaltFormatter")
struct RecallGestaltFormatterTests {

    @Test("Single annotation produces singular phrase")
    func singleAnnotation() {
        let annotations = [makeAnnotation(label: "chair")]
        let phrase = RecallGestaltFormatter.format(annotations: annotations)
        #expect(phrase.contains("One thing"))
        #expect(phrase.contains("chair"))
    }

    @Test("Duplicate labels deduplicate in enumeration")
    func duplicatesDeduplicateInEnumeration() {
        let annotations = [
            makeAnnotation(label: "chair"),
            makeAnnotation(label: "chair"),
            makeAnnotation(label: "table"),
        ]
        let phrase = RecallGestaltFormatter.format(annotations: annotations)
        // Count phrase reflects actual count (3)
        #expect(phrase.contains("Three things"))
        // label list deduplicates chair
        let chairOccurrences = phrase.components(separatedBy: "chair").count - 1
        #expect(chairOccurrences == 1)
        #expect(phrase.contains("table"))
    }

    @Test("More than 3 unique labels truncates enumeration to 3")
    func truncatesToThreeUniqueLabels() {
        let annotations = (1...5).map { makeAnnotation(label: "object\($0)") }
        let phrase = RecallGestaltFormatter.format(annotations: annotations)
        #expect(phrase.contains("object1"))
        #expect(phrase.contains("object2"))
        #expect(phrase.contains("object3"))
        #expect(!phrase.contains("object4"))
    }

    @Test("High count uses numeric phrase")
    func highCountPhrase() {
        let annotations = (1...10).map { makeAnnotation(label: "item\($0)") }
        let phrase = RecallGestaltFormatter.format(annotations: annotations)
        #expect(phrase.contains("10 things"))
    }
}

// MARK: - Test Factory

private func makeAnnotation(
    label: String = "object",
    pos: SIMD3<Float> = .zero
) -> WorldAnnotation {
    WorldAnnotation(
        worldPosition: pos,
        worldAnchorId: UUID(),
        falconLabel: label,
        meshClassification: "wall",
        confidence: 0.9
    )
}
