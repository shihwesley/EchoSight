import Foundation
import Logging
import RealityKit

// MARK: - SceneDescriptionPipeline

/// Scene mode: subscribes to `ModeFiredEvent(.scene)` and `ModeChangeEvent`,
/// runs capture → detect → fuse → speak, cancels on mode switch.
///
/// **Concurrency model:**
/// - One `Task` runs per fire event. If a new fire arrives while one is in-flight,
///   the previous task is cancelled (same-priority cancel, most-recent-wins).
/// - Mode change also cancels the current task via `ModeChangeEvent` subscription.
/// - `FusionEngine` is main-actor for `Scene.raycast`; all other stages run off main.
///
/// **Pipeline time budget:** ≤1.5 s p95 from fire event to first syllable.
///
/// **Annotation store queue:** candidates are enqueued fire-and-forget (not awaited)
/// so enqueue latency never blocks speech.
public actor SceneDescriptionPipeline {

    // MARK: - Dependencies

    private let captureSource: any PassthroughCaptureSource
    private let detector: any Detector
    private let fusionEngine: FusionEngine
    private let speechOut: SpeechOut
    private let log = Logger(label: "echosight.scene")

    /// Optional: if set, candidates are enqueued here after speaking.
    /// Weak / non-owning: annotation-store is separate. Use `@Sendable` closure
    /// to avoid retaining the store.
    private let enqueueAnnotations: (@Sendable ([AnnotationCandidate]) -> Void)?

    // MARK: - State

    private var currentTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - captureSource: Provides `CapturedFrame` on demand.
    ///   - detector: Runs object detection on the frame.
    ///   - fusionEngine: Fuses detections with head pose and mesh.
    ///   - speechOut: Shared speech actor.
    ///   - enqueueAnnotations: Optional fire-and-forget callback for annotation-store.
    public init(
        captureSource: any PassthroughCaptureSource,
        detector: any Detector,
        fusionEngine: FusionEngine,
        speechOut: SpeechOut,
        enqueueAnnotations: (@Sendable ([AnnotationCandidate]) -> Void)? = nil
    ) {
        self.captureSource = captureSource
        self.detector = detector
        self.fusionEngine = fusionEngine
        self.speechOut = speechOut
        self.enqueueAnnotations = enqueueAnnotations
    }

    // MARK: - Event Subscriptions

    /// Subscribe to `ModalInputCoordinator` event streams.
    ///
    /// Call once at startup. Runs two concurrent `Task`s that consume the
    /// streams for the lifetime of this actor. The tasks hold no strong
    /// reference cycles: they capture `self` weakly via `unowned` is not
    /// usable across actors; instead, use isolated `self` — the actor executor
    /// ensures mutual exclusion.
    public func start(
        firedEvents: AsyncStream<ModeFiredEvent>,
        changeEvents: AsyncStream<ModeChangeEvent>
    ) {
        // Fire subscription — react to .scene events.
        Task { [weak self] in
            guard let self else { return }
            for await event in firedEvents where event.mode == .scene {
                await self.handleFire(event: event)
            }
        }

        // Cancel subscription — abort on mode change.
        Task { [weak self] in
            guard let self else { return }
            for await _ in changeEvents {
                await self.cancelCurrentPipeline(reason: "mode-change")
            }
        }
    }

    // MARK: - Fire Handler

    private func handleFire(event: ModeFiredEvent) {
        // Cancel any in-flight pipeline — most-recent-wins.
        currentTask?.cancel()
        log.info("scene.fire.received", metadata: ["timestamp": "\(event.timestamp)"])

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline()
        }
    }

    // MARK: - Cancel

    private func cancelCurrentPipeline(reason: String) {
        guard let task = currentTask else { return }
        task.cancel()
        currentTask = nil
        log.info("scene.cancelled", metadata: ["reason": "\(reason)"])
    }

    // MARK: - Pipeline

    private func runPipeline() async {
        let pipelineStart = Date()

        // 1. Capture
        let captureStart = Date()
        let frame: CapturedFrame
        do {
            frame = try await captureSource.captureFrame()
        } catch {
            guard !Task.isCancelled else { return }
            log.warning("scene.capture.failed", metadata: ["error": "\(error)"])
            await speakFallback()
            return
        }
        guard !Task.isCancelled else { return }
        log.info("scene.capture.complete", metadata: [
            "durationMs": "\(Int(Date().timeIntervalSince(captureStart) * 1000))"
        ])

        // 2. Detect
        let detectStart = Date()
        let detections: [DetectionResult]
        do {
            detections = try await detector.detect(in: frame)
        } catch {
            guard !Task.isCancelled else { return }
            log.warning("scene.detect.failed", metadata: ["error": "\(error)"])
            await speakFallback()
            return
        }
        guard !Task.isCancelled else { return }
        log.info("scene.detect.complete", metadata: [
            "detectionCount": "\(detections.count)",
            "durationMs": "\(Int(Date().timeIntervalSince(detectStart) * 1000))"
        ])

        // 3. Fuse
        // `scene: nil` — FusionEngine falls back to 3 m default distance on nil scene.
        // v1.0: inject a live RealityKit.Scene for mesh ray-cast (requires main actor hop).
        let fuseStart = Date()
        let fusedCandidates = await fusionEngine.fuse(
            detections: detections,
            frame: frame,
            scene: nil
        )
        guard !Task.isCancelled else { return }
        log.info("scene.fuse.complete", metadata: [
            "candidateCount": "\(fusedCandidates.count)",
            "durationMs": "\(Int(Date().timeIntervalSince(fuseStart) * 1000))"
        ])

        // 4. Score + rank
        let topCandidates = SalienceScorer.topN(from: fusedCandidates)

        // 5. Format
        let text = DescriptionTemplateFormatter.format(candidates: topCandidates)

        // 6. Speak
        guard !Task.isCancelled else { return }
        log.info("scene.speak.started")
        let speakStart = Date()
        let token = await speechOut.speak(
            SpeechUtterance(text: text),
            priority: .normal
        )
        let outcome = await token.completion
        log.info("scene.speak.finished", metadata: [
            "durationMs": "\(Int(Date().timeIntervalSince(speakStart) * 1000))",
            "outcome": "\(outcome)"
        ])

        // 7. Enqueue for annotation-store (fire-and-forget)
        if !fusedCandidates.isEmpty {
            enqueueAnnotations?(fusedCandidates)
        }

        log.info("scene.pipeline.total", metadata: [
            "durationMs": "\(Int(Date().timeIntervalSince(pipelineStart) * 1000))"
        ])
    }

    // MARK: - Fallback

    private func speakFallback() async {
        guard !Task.isCancelled else { return }
        _ = await speechOut.speak(
            SpeechUtterance(text: "I don't detect anything in front of you"),
            priority: .normal
        )
    }
}
