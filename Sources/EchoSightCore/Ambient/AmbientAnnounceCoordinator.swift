import Foundation
import simd
import Logging

// MARK: - AmbientAnnounceCoordinator

/// Actor that coordinates all ambient announce decisions.
///
/// Gate evaluation order (TLA-verified 2026-04-21, 14,817 states, 2,448 distinct, depth 18):
///   1. Session-resume dampening — suppress all chimes during 3-s window post-resume
///   2. Chime rate limit — 2 s minimum between chimes
///   3. Fire chime
///   4. Novelty check — skip speech if anchor is not cold (>30 min since last seen)
///   5. Silent mode check — speech suppressed; chime already played
///   6. Gesture idle check — no mode fire in last 5 min
///   7. Head-motion check — head-pose variance > 5° (device-put-down suppression)
///   8. Speech rate limit — 60 s minimum between speeches
///   9. Gemma inferRoomLabel (with mesh-class fallback on timeout)
///   10. SpeechOut.speak(.high) + record encounter
///
/// Pinned decisions (post-TLA 2026-04-21):
///   - Silent-mid-flight: coordinator cancels its own `.high` token when a `.silent`
///     ModeChangeEvent arrives and speech is in flight. Asymmetric with `.normal`.
///   - Session-resume: `.sessionResumeRerecognized` anchor events suppress chimes
///     for 3 s to prevent ARKit session-recovery audio storms.
///
/// Log category: `echosight.ambient`
public actor AmbientAnnounceCoordinator {

    // MARK: - Dependency Types

    /// Returns the most recent anchor encounter timestamp, or nil if never seen.
    public typealias LastSeenProvider =
        @Sendable (UUID) async throws -> Date?

    /// Returns annotation count for an anchor.
    public typealias AnnotationCountProvider =
        @Sendable (UUID) async throws -> Int

    /// Records that an anchor was encountered (updates `anchorMetadata.lastSeenAt`).
    public typealias RecordEncounterAction =
        @Sendable (UUID) async throws -> Void

    /// Returns the current mesh classification summary.
    public typealias MeshClassProvider =
        @Sendable () -> MeshClassificationSummary

    /// Returns cumulative head-pose angular variance over the given window (radians).
    public typealias HeadVarianceProvider =
        @Sendable (TimeInterval) -> Float

    /// Returns `true` if silent mode is currently active.
    public typealias SilentModeProvider =
        @Sendable () -> Bool

    /// Speaks an utterance at the given priority; returns the token.
    public typealias SpeakAction =
        @Sendable (SpeechUtterance, SpeechPriority) async -> SpeechToken

    /// Cancels a specific speech token.
    public typealias CancelTokenAction =
        @Sendable (SpeechToken) async -> Void

    // MARK: - Constants

    private enum Constants {
        static let headMotionThresholdDeg: Float = 5.0
        static let headMotionWindow: TimeInterval = 30.0
    }

    // MARK: - Dependencies

    private let lastSeen: LastSeenProvider
    private let annotationCount: AnnotationCountProvider
    private let recordEncounter: RecordEncounterAction
    private let meshClass: MeshClassProvider
    private let headVariance: HeadVarianceProvider
    private let silentMode: SilentModeProvider
    private let speakAction: SpeakAction
    private let cancelToken: CancelTokenAction
    private let chimeRenderer: ChimeRenderer
    private let roomLabelInferrer: RoomLabelInferrer
    private let log = Logger(label: "echosight.ambient")

    // MARK: - State (owned structs, mutated within actor isolation)

    private var idleTracker = IdleTracker()
    private var rateLimiter = AnnounceRateLimiter()
    private var noveltyDetector = NoveltyDetector()
    private var sessionResumeDampener = SessionResumeDampener()
    private var currentSpeechToken: SpeechToken?
    private var listenTask: Task<Void, Never>?

    // MARK: - Init (production)

    /// Wires directly to real `AnnotationStore`, `GemmaRunner`, `SpeechOut`, `SpatialSession`.
    public init(
        annotationStore: AnnotationStore,
        gemmaRunner: GemmaRunner,
        speechOut: SpeechOut,
        meshClassProvider: @escaping MeshClassProvider,
        headVarianceProvider: @escaping HeadVarianceProvider,
        silentModeProvider: @escaping SilentModeProvider
    ) {
        self.lastSeen = { id in try await annotationStore.lastSeenAnchorAt(anchorId: id) }
        self.annotationCount = { id in try await annotationStore.annotationCount(anchorId: id) }
        self.recordEncounter = { id in try await annotationStore.recordAnchorEncounter(anchorId: id) }
        self.meshClass = meshClassProvider
        self.headVariance = headVarianceProvider
        self.silentMode = silentModeProvider
        self.speakAction = { utterance, priority in await speechOut.speak(utterance, priority: priority) }
        self.cancelToken = { token in await speechOut.cancel(token) }
        self.chimeRenderer = ChimeRenderer()
        self.roomLabelInferrer = RoomLabelInferrer { anchorId, annotations, mesh in
            try await gemmaRunner.inferRoomLabel(
                anchorId: anchorId,
                annotations: annotations,
                meshClassification: mesh
            )
        }
    }

    /// Testability init — accepts closure overrides for all I/O.
    public init(
        lastSeen: @escaping LastSeenProvider,
        annotationCount: @escaping AnnotationCountProvider,
        recordEncounter: @escaping RecordEncounterAction,
        meshClass: @escaping MeshClassProvider,
        headVariance: @escaping HeadVarianceProvider,
        silentMode: @escaping SilentModeProvider,
        speakAction: @escaping SpeakAction,
        cancelToken: @escaping CancelTokenAction,
        chimeRenderer: ChimeRenderer,
        roomLabelInferrer: RoomLabelInferrer
    ) {
        self.lastSeen = lastSeen
        self.annotationCount = annotationCount
        self.recordEncounter = recordEncounter
        self.meshClass = meshClass
        self.headVariance = headVariance
        self.silentMode = silentMode
        self.speakAction = speakAction
        self.cancelToken = cancelToken
        self.chimeRenderer = chimeRenderer
        self.roomLabelInferrer = roomLabelInferrer
    }

    // MARK: - Start / Stop

    /// Begin listening to anchor change + modal input event streams.
    public func start(
        anchorEvents: AsyncStream<AnchorChangeEvent>,
        firedEvents: AsyncStream<ModeFiredEvent>,
        changeEvents: AsyncStream<ModeChangeEvent>
    ) {
        guard listenTask == nil else { return }
        // P1-2 FIX: Remove [weak self] — actors are reference types and [weak self]
        // causes the event loop to silently not start if the actor releases before the
        // Task's first suspension. stop() handles teardown via task cancellation.
        listenTask = Task {
            await self.runEventLoop(
                anchorEvents: anchorEvents,
                firedEvents: firedEvents,
                changeEvents: changeEvents
            )
        }
        log.info("ambient.started")
    }

    public func stop() {
        listenTask?.cancel()
        listenTask = nil
        log.info("ambient.stopped")
    }

    // MARK: - Private: Event Loop

    private func runEventLoop(
        anchorEvents: AsyncStream<AnchorChangeEvent>,
        firedEvents: AsyncStream<ModeFiredEvent>,
        changeEvents: AsyncStream<ModeChangeEvent>
    ) async {
        enum AmbientInput {
            case anchor(AnchorChangeEvent)
            case fired(ModeFiredEvent)
            case changed(ModeChangeEvent)
        }

        let (merged, cont) = AsyncStream<AmbientInput>.makeStream()

        let anchorTask = Task { for await e in anchorEvents { cont.yield(.anchor(e)) } }
        let firedTask  = Task { for await e in firedEvents  { cont.yield(.fired(e))  } }
        let changeTask = Task { for await e in changeEvents { cont.yield(.changed(e)) } }

        defer {
            anchorTask.cancel()
            firedTask.cancel()
            changeTask.cancel()
        }

        for await input in merged {
            if Task.isCancelled { break }
            switch input {
            case .anchor(let event):   await handleAnchorEvent(event)
            case .fired(let event):    idleTracker.recordModeFired(at: event.timestamp)
            case .changed(let event):  handleModeChange(event)
            }
        }
    }

    // MARK: - Private: Anchor Event Handling

    private func handleAnchorEvent(_ event: AnchorChangeEvent) async {
        let now = Date()
        let anchorId = event.anchorId
        let hashedId = String(anchorId.uuidString.prefix(8))
        log.info("ambient.anchor.received", metadata: ["hashedId": .string(hashedId), "kind": .string("\(event.kind)")])

        // Gate 1: Session-resume dampening — suppresses all chimes during 3-s window.
        if event.kind == .sessionResumeRerecognized {
            sessionResumeDampener.trigger(now: now)
        }

        if sessionResumeDampener.isSuppressing(now: now) {
            log.debug("ambient.chime.suppressed", metadata: ["reason": "sessionResumeDampen"])
            return
        }

        // Gate 2: Chime rate limit.
        guard rateLimiter.canChime(now: now) else { return }

        // Gate 3: Fire chime (always, for non-suppressed events).
        rateLimiter.recordChime(now: now)
        await chimeRenderer.play()
        log.info("ambient.chime.fired")

        // Gate 4: Novelty check.
        let lastSeenDate: Date?
        do {
            lastSeenDate = try await lastSeen(anchorId)
        } catch {
            log.error("ambient.novelty.lastSeen.failed", metadata: ["error": .string(error.localizedDescription)])
            return
        }

        guard noveltyDetector.isCold(anchorId: anchorId, lastSeenAt: lastSeenDate, now: now) else {
            log.debug("ambient.speech.gated", metadata: ["passed": "false", "failedGate": "novelty(hot)"])
            return
        }

        // Gate 5: Silent mode. (Must be checked by this coordinator — .high bypasses SpeechOut's gate.)
        guard !silentMode() else {
            log.info("ambient.silent.suppressed")
            log.debug("ambient.speech.gated", metadata: ["passed": "false", "failedGate": "silentMode"])
            return
        }

        // Gate 6: Gesture idle.
        guard idleTracker.isIdle(now: now) else {
            log.debug("ambient.speech.gated", metadata: ["passed": "false", "failedGate": "gestureActive"])
            return
        }

        // Gate 7: Head-motion (device-put-down suppression).
        let varianceRad = headVariance(Constants.headMotionWindow)
        let varianceDeg = varianceRad * (180.0 / .pi)
        guard varianceDeg >= Constants.headMotionThresholdDeg else {
            log.info("ambient.idle.evaluated", metadata: [
                "gestureIdle": "true",
                "headMotion": "false",
                "variance": .string("\(String(format: "%.1f", varianceDeg))deg"),
            ])
            log.debug("ambient.speech.gated", metadata: ["passed": "false", "failedGate": "headMotionBelow"])
            return
        }

        log.info("ambient.idle.evaluated", metadata: [
            "gestureIdle": "true",
            "headMotion": "true",
            "variance": .string("\(String(format: "%.1f", varianceDeg))deg"),
        ])

        // Gate 8: Speech rate limit.
        guard rateLimiter.canSpeak(now: now) else {
            log.debug("ambient.speech.gated", metadata: ["passed": "false", "failedGate": "speechRateLimit"])
            return
        }

        log.debug("ambient.speech.gated", metadata: ["passed": "true", "failedGate": "none"])

        // Gate 9: Gemma inferRoomLabel (with mesh fallback).
        let isFirstVisit = (lastSeenDate == nil)
        let count: Int
        do {
            count = try await annotationCount(anchorId)
        } catch {
            count = 0
        }

        let mesh = meshClass()
        let label = await roomLabelInferrer.infer(
            anchorId: anchorId,
            annotations: [],  // ambient doesn't pass full annotation snapshot (not in spec)
            meshClassification: mesh,
            isFirstVisit: isFirstVisit
        )

        // Gate 10: Speak.
        let announceText = buildAnnounceText(
            label: label,
            lastSeen: lastSeenDate,
            annotationCount: count,
            isFirstVisit: isFirstVisit,
            now: now
        )

        rateLimiter.recordSpeech(now: now)

        let token = await speakAction(SpeechUtterance(text: announceText), .high)
        currentSpeechToken = token

        log.info("ambient.speech.fired", metadata: [
            "roomLabel": .string(label),
            "wasPreempting": .string("false"),
        ])

        // Record encounter so this anchor is no longer cold for the next 30 min.
        do {
            try await recordEncounter(anchorId)
        } catch {
            log.error("ambient.encounter.recordFailed", metadata: ["error": .string(error.localizedDescription)])
        }
    }

    // MARK: - Private: Mode Change Handling

    private func handleModeChange(_ event: ModeChangeEvent) {
        idleTracker.recordModeFired(at: event.timestamp)

        // Silent-mid-flight cancel (post-TLA gate resolution 2026-04-21):
        // If a .silent mode change arrives while ambient has an in-flight .high utterance,
        // cancel our own token immediately. Ambient speech is app-initiated (push).
        // A silent toggle is an explicit "stop pushing things at me" signal.
        // P2-DEFERRED: This cancel Task is fire-and-forget. Track it in a Set<Task<Void,Never>>
        // and cancel on stop() to avoid stray executions after teardown. (P2-1, sprint-3.2)
        if event.to == .silent, let token = currentSpeechToken {
            let tokenRef = token
            let cancelAction = cancelToken
            Task {
                await cancelAction(tokenRef)
            }
            currentSpeechToken = nil
            log.info("ambient.speech.cancelledBysilentToggle")
        }
    }

    // MARK: - Private: Announce Text Builder

    private func buildAnnounceText(
        label: String,
        lastSeen: Date?,
        annotationCount: Int,
        isFirstVisit: Bool,
        now: Date
    ) -> String {
        if isFirstVisit {
            let countPhrase = annotationCount > 0
                ? " I'm starting to remember this place."
                : ""
            return "\(label).\(countPhrase)"
        }

        let timePhrase: String
        if let last = lastSeen {
            let delta = now.timeIntervalSince(last)
            timePhrase = humanReadableDelta(delta)
        } else {
            timePhrase = "a while ago"
        }

        let countPhrase = annotationCount == 1
            ? "1 annotation remembered"
            : "\(annotationCount) annotations remembered"

        return "You're in \(label). Last here \(timePhrase). \(countPhrase)."
    }

    private func humanReadableDelta(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)

        if days >= 1 {
            return days == 1 ? "1 day ago" : "\(days) days ago"
        } else if hours >= 1 {
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else if minutes >= 1 {
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        } else {
            return "less than a minute ago"
        }
    }
}
