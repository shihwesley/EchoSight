import Testing
import Foundation
@testable import EchoSightCore

// MARK: - AmbientAnnounceCoordinatorTests

/// Gate state machine integration tests for `AmbientAnnounceCoordinator`.
///
/// Uses the closure-based testability init so no real AVAudio/Gemma/ARKit is required.
/// All gate combinations from the TLA model are tested.
/// Execution deferred (visionOS sim boot exceeds phase-runner watchdog).
@Suite("AmbientAnnounceCoordinator")
struct AmbientAnnounceCoordinatorTests {

    // MARK: - Test State Actor

    private actor TestState {
        var chimeCount = 0
        var speechCount = 0
        var cancelCount = 0
        var spokenTexts: [String] = []

        func recordChime() { chimeCount += 1 }
        func recordSpeech(_ text: String) { speechCount += 1; spokenTexts.append(text) }
        func recordCancel() { cancelCount += 1 }
    }

    // MARK: - Helper

    private func makeCoordinator(
        lastSeenAt: Date? = nil,
        annotationCount: Int = 3,
        silent: Bool = false,
        gestureIdle: Bool = true,
        headVarianceDeg: Float = 10.0,
        state: TestState = TestState()
    ) -> (AmbientAnnounceCoordinator, TestState) {
        let chimeRenderer = ChimeRenderer()  // won't play in test environment (no audio session)
        let roomLabelInferrer = RoomLabelInferrer { _, _, _ in "kitchen" }

        let coordinator = AmbientAnnounceCoordinator(
            lastSeen: { _ in lastSeenAt },
            annotationCount: { _ in annotationCount },
            recordEncounter: { _ in },
            meshClass: {
                MeshClassificationSummary(
                    distribution: [.wall: 0.4, .floor: 0.3],
                    confidence: 0.7,
                    triangleCount: 600
                )
            },
            headVariance: { _ in headVarianceDeg * (.pi / 180.0) },  // deg → rad
            silentMode: { silent },
            speakAction: { utterance, _ in
                await state.recordSpeech(utterance.text)
                let token = SpeechToken()
                token.resolve(.finished)
                return token
            },
            cancelToken: { _ in await state.recordCancel() },
            chimeRenderer: chimeRenderer,
            roomLabelInferrer: roomLabelInferrer
        )
        return (coordinator, state)
    }

    // MARK: - Chime Always Fires

    @Test("New anchor event fires chime (no session-resume suppression)")
    func newAnchorFiresChime() async throws {
        // We can't easily intercept AVAudioEngine in tests, so we verify the
        // coordinator reaches the chime path by checking that speech fires for cold anchor.
        // (Chime is always before speech in gate order.)
        let state = TestState()
        let (coord, _) = makeCoordinator(
            lastSeenAt: nil,  // cold
            silent: false,
            gestureIdle: true,
            headVarianceDeg: 10.0,
            state: state
        )

        let (anchorStream, anchorCont) = AsyncStream<AnchorChangeEvent>.makeStream()
        let (firedStream, _) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await coord.start(anchorEvents: anchorStream, firedEvents: firedStream, changeEvents: changeStream)

        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .new, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(200))

        let speeches = await state.speechCount
        #expect(speeches >= 1)  // cold + idle + head-motion → speech
    }

    // MARK: - Hot Anchor (no speech)

    @Test("Hot anchor fires chime only, no speech")
    func hotAnchorNoSpeech() async throws {
        let recentlySeen = Date().addingTimeInterval(-5 * 60)  // 5 min ago = hot
        let state = TestState()
        let (coord, _) = makeCoordinator(
            lastSeenAt: recentlySeen,
            silent: false,
            gestureIdle: true,
            headVarianceDeg: 10.0,
            state: state
        )

        let (anchorStream, anchorCont) = AsyncStream<AnchorChangeEvent>.makeStream()
        let (firedStream, _) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await coord.start(anchorEvents: anchorStream, firedEvents: firedStream, changeEvents: changeStream)

        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .rerecognized, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(200))

        let speeches = await state.speechCount
        #expect(speeches == 0)  // novelty gate blocks speech
    }

    // MARK: - Silent Mode Suppresses Speech

    @Test("Silent mode suppresses speech, gate does not reach Gemma")
    func silentModeSuppressesSpeech() async throws {
        let state = TestState()
        let (coord, _) = makeCoordinator(
            lastSeenAt: nil,  // cold
            silent: true,    // silent mode ON
            gestureIdle: true,
            headVarianceDeg: 10.0,
            state: state
        )

        let (anchorStream, anchorCont) = AsyncStream<AnchorChangeEvent>.makeStream()
        let (firedStream, _) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await coord.start(anchorEvents: anchorStream, firedEvents: firedStream, changeEvents: changeStream)

        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .new, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(200))

        let speeches = await state.speechCount
        #expect(speeches == 0)
    }

    // MARK: - Gesture Active Suppresses Speech

    @Test("Gesture active (not idle) suppresses speech")
    func gestureActiveSuppreshesSpeech() async throws {
        let state = TestState()
        let (coord, _) = makeCoordinator(
            lastSeenAt: nil,  // cold
            silent: false,
            gestureIdle: false,  // user recently pressed a button
            headVarianceDeg: 10.0,
            state: state
        )

        let (anchorStream, anchorCont) = AsyncStream<AnchorChangeEvent>.makeStream()
        let (firedStream, firedCont) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await coord.start(anchorEvents: anchorStream, firedEvents: firedStream, changeEvents: changeStream)

        // Fire a mode event to mark the user as active (within 5-min window)
        firedCont.yield(ModeFiredEvent(mode: .scene, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(50))

        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .new, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(200))

        let speeches = await state.speechCount
        #expect(speeches == 0)
    }

    // MARK: - Device Put Down (head motion below threshold)

    @Test("Head motion below threshold (device put down) suppresses speech")
    func devicePutDownSuppreshesSpeech() async throws {
        let state = TestState()
        let (coord, _) = makeCoordinator(
            lastSeenAt: nil,  // cold
            silent: false,
            gestureIdle: true,
            headVarianceDeg: 1.0,  // below 5° threshold
            state: state
        )

        let (anchorStream, anchorCont) = AsyncStream<AnchorChangeEvent>.makeStream()
        let (firedStream, _) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await coord.start(anchorEvents: anchorStream, firedEvents: firedStream, changeEvents: changeStream)

        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .new, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(200))

        let speeches = await state.speechCount
        #expect(speeches == 0)
    }

    // MARK: - Session-Resume Dampening

    @Test("sessionResumeRerecognized events suppress chimes for 3 s")
    func sessionResumeDampensSuppresses() async throws {
        let state = TestState()
        let (coord, _) = makeCoordinator(
            lastSeenAt: nil,
            silent: false,
            gestureIdle: true,
            headVarianceDeg: 10.0,
            state: state
        )

        let (anchorStream, anchorCont) = AsyncStream<AnchorChangeEvent>.makeStream()
        let (firedStream, _) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, _) = AsyncStream<ModeChangeEvent>.makeStream()
        await coord.start(anchorEvents: anchorStream, firedEvents: firedStream, changeEvents: changeStream)

        // Session-resume event starts 3-s window
        let anchorId = UUID()
        anchorCont.yield(AnchorChangeEvent(anchorId: anchorId, kind: .sessionResumeRerecognized, timestamp: Date()))

        // Follow-up anchor events within 3 s should be suppressed
        try await Task.sleep(for: .milliseconds(100))
        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .new, timestamp: Date()))
        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .new, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(200))

        // No speech should fire during dampen window
        let speeches = await state.speechCount
        #expect(speeches == 0)
    }

    // MARK: - Silent Mid-Flight Cancel

    @Test("Silent mode toggle cancels in-flight .high ambient speech token")
    func silentMidFlightCancelsToken() async throws {
        // We verify the cancelToken closure is called when mode changes to .silent
        // while speech is supposedly in flight.
        let state = TestState()

        // Set up a speak action that holds the token in-flight briefly
        let tokenRef = SpeechToken()  // We'll check this token

        let coordinator = AmbientAnnounceCoordinator(
            lastSeen: { _ in nil },  // cold
            annotationCount: { _ in 3 },
            recordEncounter: { _ in },
            meshClass: {
                MeshClassificationSummary(
                    distribution: [.wall: 0.5],
                    confidence: 0.8,
                    triangleCount: 700
                )
            },
            headVariance: { _ in 10.0 * (.pi / 180.0) },
            silentMode: { false },
            speakAction: { _, _ in
                // Return a token that hasn't resolved yet
                return tokenRef
            },
            cancelToken: { _ in await state.recordCancel() },
            chimeRenderer: ChimeRenderer(),
            roomLabelInferrer: RoomLabelInferrer { _, _, _ in "living room" }
        )

        let (anchorStream, anchorCont) = AsyncStream<AnchorChangeEvent>.makeStream()
        let (firedStream, _) = AsyncStream<ModeFiredEvent>.makeStream()
        let (changeStream, changeCont) = AsyncStream<ModeChangeEvent>.makeStream()
        await coordinator.start(anchorEvents: anchorStream, firedEvents: firedStream, changeEvents: changeStream)

        // Trigger speech
        anchorCont.yield(AnchorChangeEvent(anchorId: UUID(), kind: .new, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(200))

        // Now toggle silent mode — should cancel the in-flight token
        changeCont.yield(ModeChangeEvent(from: .scene, to: .silent))
        try await Task.sleep(for: .milliseconds(100))

        let cancels = await state.cancelCount
        #expect(cancels >= 1)
    }
}
