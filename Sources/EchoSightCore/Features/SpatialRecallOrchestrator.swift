import Foundation
import simd
import Logging

// MARK: - SpatialRecallOrchestrator

/// Actor that owns the 2-press recall state machine.
///
/// State machine (TLA-verified 2026-04-21, 171 states, 58 distinct, depth 8):
///
///   idle
///     → ModeFiredEvent(.recall) & annotations non-empty
///   awaitingSecondPress(firstPressAt:, windowTask:, gestaltToken:)
///     → 5-s windowTask fires → idle (speech NOT cancelled — window is a timing gate, not speech gate)
///     → ModeFiredEvent(.recall) within 5 s → speakingDetail
///   speakingDetail
///     → completion → idle
///
///   ModeChangeEvent (any state) → cancel windowTask + cancelAll speech → idle
///
/// Key pinned decisions (2026-04-21):
///   - Window expiry does NOT cancel gestalt speech. Mode change DOES.
///   - Gestalt spoken at `.high`; detail at `.normal`.
///   - Second press during Gemma: queues detail behind gestalt (race fix).
///
/// Log category: `echosight.recall`
public actor SpatialRecallOrchestrator {

    // MARK: - Dependency Types (closure-based injection for testability)

    /// Returns nearby annotations for a given head position + radius.
    public typealias NearestAnnotationsProvider =
        @Sendable (SIMD3<Float>, Float) async throws -> [WorldAnnotation]

    /// Produces a Gemma gestalt summary; throws on timeout or unavailable.
    public typealias GemmaSummarizer =
        @Sendable ([WorldAnnotation]) async throws -> String

    /// Speaks an utterance at the given priority; returns the token.
    public typealias SpeakAction =
        @Sendable (SpeechUtterance, SpeechPriority) async -> SpeechToken

    /// Cancels all in-flight speech.
    public typealias CancelAllAction = @Sendable () async -> Void

    /// Returns the current head position in world space.
    public typealias HeadPoseProvider = @Sendable () -> SIMD3<Float>

    // MARK: - Private: State

    private enum RecallState {
        case idle
        case awaitingSecondPress(firstPressAt: Date, windowTask: Task<Void, Never>, gestaltToken: SpeechToken)
        case speakingDetail

        var label: String {
            switch self {
            case .idle: return "idle"
            case .awaitingSecondPress: return "awaitingSecondPress"
            case .speakingDetail: return "speakingDetail"
            }
        }

        var isIdle: Bool { if case .idle = self { return true }; return false }
    }

    // MARK: - Constants

    private enum Constants {
        static let windowDuration: TimeInterval = 5.0
        static let queryRadius: Float = 5.0
        static let maxDetailAnnotations = 5
        static let fallbackSpeechEmpty = "I don't remember anything around you yet"
    }

    // MARK: - Dependencies

    private let nearestAnnotations: NearestAnnotationsProvider
    private let gemmaSummarize: GemmaSummarizer
    private let speakAction: SpeakAction
    private let cancelAllAction: CancelAllAction
    private let headPoseProvider: HeadPoseProvider
    private let log = Logger(label: "echosight.recall")

    // MARK: - State

    private var state: RecallState = .idle
    private var listenTask: Task<Void, Never>?

    // MARK: - Init

    /// Primary init — wires directly to real `AnnotationStore`, `GemmaRunner`, `SpeechOut`.
    public init(
        annotationStore: AnnotationStore,
        gemmaRunner: GemmaRunner,
        speechOut: SpeechOut,
        headPoseProvider: @escaping HeadPoseProvider
    ) {
        self.nearestAnnotations = { pos, radius in
            try await annotationStore.nearestAnnotations(to: pos, radius: radius)
        }
        self.gemmaSummarize = { annotations in
            // headPoseProvider is captured here; head pose is sampled at the
            // moment summarize is called so the distance is user-relative.
            try await gemmaRunner.summarize(annotations: annotations, headPose: headPoseProvider())
        }
        self.speakAction = { utterance, priority in
            await speechOut.speak(utterance, priority: priority)
        }
        self.cancelAllAction = {
            await speechOut.cancelAll()
        }
        self.headPoseProvider = headPoseProvider
    }

    /// Testability init — accepts closure overrides for all I/O.
    public init(
        nearestAnnotations: @escaping NearestAnnotationsProvider,
        gemmaSummarize: @escaping GemmaSummarizer,
        speakAction: @escaping SpeakAction,
        cancelAllAction: @escaping CancelAllAction,
        headPoseProvider: @escaping HeadPoseProvider
    ) {
        self.nearestAnnotations = nearestAnnotations
        self.gemmaSummarize = gemmaSummarize
        self.speakAction = speakAction
        self.cancelAllAction = cancelAllAction
        self.headPoseProvider = headPoseProvider
    }

    // MARK: - Start / Stop

    /// Begin listening to the two modal-input event streams.
    /// Safe to call once at app start; subsequent calls no-op.
    public func start(
        firedEvents: AsyncStream<ModeFiredEvent>,
        changeEvents: AsyncStream<ModeChangeEvent>
    ) {
        guard listenTask == nil else { return }
        // P1-2 FIX: Actors are reference types — [weak self] causes the event loop to
        // silently never start if the actor is released before the Task's first suspension.
        // stop() provides the correct teardown path via task cancellation.
        listenTask = Task {
            await self.runEventLoop(firedEvents: firedEvents, changeEvents: changeEvents)
        }
        log.info("recall.started")
    }

    /// Stop the event loop and abort any in-progress recall cleanly.
    public func stop() {
        listenTask?.cancel()
        listenTask = nil
        if !state.isIdle {
            if case .awaitingSecondPress(_, let windowTask, _) = state {
                windowTask.cancel()
            }
            state = .idle
        }
        log.info("recall.stopped")
    }

    // MARK: - Private: Event Loop

    private func runEventLoop(
        firedEvents: AsyncStream<ModeFiredEvent>,
        changeEvents: AsyncStream<ModeChangeEvent>
    ) async {
        enum RecallInput {
            case fired(ModeFiredEvent)
            case changed(ModeChangeEvent)
        }

        let (merged, cont) = AsyncStream<RecallInput>.makeStream()

        // Two child tasks fan-in to a shared stream.
        let firedTask = Task {
            for await event in firedEvents { cont.yield(.fired(event)) }
            cont.finish()
        }
        let changeTask = Task {
            for await event in changeEvents { cont.yield(.changed(event)) }
        }

        defer {
            firedTask.cancel()
            changeTask.cancel()
        }

        for await input in merged {
            if Task.isCancelled { break }
            switch input {
            case .fired(let event) where event.mode == .recall:
                await handleRecallFired(at: event.timestamp)
            case .fired:
                break  // Other mode fires are ignored (only ModeChangeEvent aborts)
            case .changed(let event):
                handleModeChange(event)
            }
        }
    }

    // MARK: - Private: State Machine

    private func handleRecallFired(at timestamp: Date) async {
        log.info("recall.fire.received", metadata: ["state": .string(state.label)])

        switch state {
        case .idle:
            await handleFirstPress(at: timestamp)

        case .awaitingSecondPress(let firstPressAt, let windowTask, let gestaltToken):
            let elapsed = timestamp.timeIntervalSince(firstPressAt)
            if elapsed <= Constants.windowDuration {
                windowTask.cancel()
                log.info("recall.state.transition(from:to:)", metadata: [
                    "from": "awaitingSecondPress", "to": "speakingDetail",
                ])
                state = .speakingDetail
                await speakDetailAnnotations(awaitingGestaltToken: gestaltToken)
            } else {
                // Window expired but state hasn't updated yet; treat as fresh first press.
                windowTask.cancel()
                log.info("recall.window.expired", metadata: ["elapsed": .string("\(Int(elapsed))s")])
                state = .idle
                await handleFirstPress(at: timestamp)
            }

        case .speakingDetail:
            // Detail is speaking — restart as a fresh first press.
            log.info("recall.fire.received", metadata: [
                "state": "speakingDetail", "action": "freshFirstPress",
            ])
            state = .idle
            await handleFirstPress(at: timestamp)
        }
    }

    private func handleFirstPress(at timestamp: Date) async {
        let headPos = headPoseProvider()
        let queryStart = Date()

        let annotations: [WorldAnnotation]
        do {
            annotations = try await nearestAnnotations(headPos, Constants.queryRadius)
        } catch {
            log.error("recall.annotations.queried", metadata: ["error": .string(error.localizedDescription)])
            annotations = []
        }

        let queryMs = Int(Date().timeIntervalSince(queryStart) * 1000)
        log.info("recall.annotations.queried", metadata: [
            "count": .string("\(annotations.count)"),
            "durationMs": .string("\(queryMs)"),
        ])

        guard !annotations.isEmpty else {
            log.info("recall.state.transition(from:to:)", metadata: ["from": "idle", "to": "idle(empty)"])
            await speakAction(SpeechUtterance(text: Constants.fallbackSpeechEmpty), .normal)
            return
        }

        // Fetch gestalt (may fall back to template if Gemma throws).
        log.info("recall.gemma.started")
        let gemmaStart = Date()
        let gestaltText = await fetchGestalt(annotations: annotations)
        let gemmaMs = Int(Date().timeIntervalSince(gemmaStart) * 1000)
        log.info("recall.gemma.completed", metadata: ["durationMs": .string("\(gemmaMs)")])

        // Start window timer BEFORE speaking so the 5 s is from press, not from TTS start.
        let windowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constants.windowDuration))
            await self?.windowDidExpire()
        }

        let gestaltToken = await speakAction(SpeechUtterance(text: gestaltText), .high)

        log.info("recall.state.transition(from:to:)", metadata: ["from": "idle", "to": "awaitingSecondPress"])
        state = .awaitingSecondPress(
            firstPressAt: timestamp,
            windowTask: windowTask,
            gestaltToken: gestaltToken
        )

        log.info("recall.pipeline.total", metadata: [
            "path": "gestalt",
            "durationMs": .string("\(Int(Date().timeIntervalSince(queryStart) * 1000))"),
        ])
    }

    private func fetchGestalt(annotations: [WorldAnnotation]) async -> String {
        do {
            return try await gemmaSummarize(annotations)
        } catch {
            log.info("recall.fallback.template.used", metadata: ["reason": .string("\(error)")])
            return RecallGestaltFormatter.format(annotations: annotations)
        }
    }

    private func speakDetailAnnotations(awaitingGestaltToken gestaltToken: SpeechToken) async {
        let detailStart = Date()

        // Race fix (TLA): await gestalt completion before dispatching detail.
        // If gestalt was cancelled or dropped, suppress detail too.
        let outcome = await gestaltToken.completion
        switch outcome {
        case .cancelled, .dropped:
            log.info("recall.abort", metadata: ["reason": "gestaltCancelledBeforeDetail"])
            state = .idle
            return
        case .finished:
            break
        }

        let headPos = headPoseProvider()
        let annotations: [WorldAnnotation]
        do {
            annotations = try await nearestAnnotations(headPos, Constants.queryRadius)
        } catch {
            log.error("recall.annotations.queried", metadata: [
                "error": .string(error.localizedDescription), "path": "detail",
            ])
            state = .idle
            return
        }

        guard !annotations.isEmpty else { state = .idle; return }

        let sorted = annotations.sorted {
            simd_distance($0.worldPosition, headPos) < simd_distance($1.worldPosition, headPos)
        }
        let topN = Array(sorted.prefix(Constants.maxDetailAnnotations))

        let candidates = topN.map { annotation -> ScoredCandidate in
            let dist = simd_distance(annotation.worldPosition, headPos)
            return ScoredCandidate(
                candidate: AnnotationCandidate(
                    label: annotation.falconLabel,
                    confidence: annotation.confidence,
                    worldPosition: annotation.worldPosition,
                    distance: dist,
                    outcome: .normal
                ),
                score: 1.0 / max(dist, 0.1)
            )
        }

        let detailText = DescriptionTemplateFormatter.format(candidates: candidates)
        await speakAction(SpeechUtterance(text: detailText), .normal)

        log.info("recall.pipeline.total", metadata: [
            "path": "detail",
            "durationMs": .string("\(Int(Date().timeIntervalSince(detailStart) * 1000))"),
        ])
        state = .idle
    }

    private func windowDidExpire() {
        guard case .awaitingSecondPress = state else { return }
        // Window expiry: state returns to idle. Speech NOT cancelled (pinned 2026-04-21).
        // Contrast with mode-change which calls cancelAll().
        log.info("recall.window.expired")
        log.info("recall.state.transition(from:to:)", metadata: [
            "from": "awaitingSecondPress", "to": "idle",
        ])
        state = .idle
    }

    private func handleModeChange(_ event: ModeChangeEvent) {
        log.info("recall.abort", metadata: ["reason": .string("modeChange(to:\(event.to.rawValue))")])

        if case .awaitingSecondPress(_, let windowTask, _) = state {
            windowTask.cancel()
        }

        guard !state.isIdle else { return }
        state = .idle

        // P2-DEFERRED: This cancel Task is fire-and-forget. Track in a Set<Task<Void,Never>>
        // and cancel on stop() to avoid stray executions after teardown. (P2-1, sprint-3.2)
        // Mode change is an explicit user signal — cancel all speech (unlike window expiry).
        Task { await self.cancelAllAction() }

        log.info("recall.state.transition(from:to:)", metadata: ["from": "active", "to": "idle"])
    }
}
