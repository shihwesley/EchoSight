import Foundation
import Logging
import Vision

// MARK: - RawTextObservation

/// Sendable value type extracted from `VNRecognizedTextObservation` inside the
/// Vision callback. Crossing concurrency boundaries with `VNRecognizedTextObservation`
/// directly violates Swift 6 strict concurrency (it is not `Sendable`).
///
/// Per Sprint 2.1 `VisionDetector` pattern: extract relevant fields inside the
/// callback before resuming to a `CheckedContinuation`.
public struct RawTextObservation: Sendable {
    /// The top candidate string from Vision.
    public let text: String
    /// Vision confidence for the top candidate (0–1).
    public let confidence: Float
    /// Bounding box in Vision coordinate space (origin bottom-left, Y up, normalized).
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

// MARK: - OcrPipeline

/// Read mode: subscribes to `ModeFiredEvent(.read)` and `ModeChangeEvent`,
/// runs capture → VNRecognizeTextRequest → filter → sort → speak.
///
/// **Concurrency model:**
/// - Each `.read` fire cancels any in-flight pipeline (most-recent-wins).
/// - Mode change also cancels via `ModeChangeEvent` subscription.
/// - Long text is chunked at natural boundaries; each chunk is awaited
///   before speaking the next, with cancellation checked between chunks.
/// - A new `.read` fire mid-read cancels current and restarts.
///
/// **VNRecognizeTextRequest note:**
/// Per Sprint 2.1 `VisionDetector` pattern, the request is built fresh per call
/// to avoid actor-stored request `Sendable` issues. Results are extracted into
/// `RawTextObservation` (a `Sendable` value type) inside the Vision callback
/// before crossing the concurrency boundary.
///
/// **English only in v0.1.** Multi-language detection is a v1.0 spec item.
public actor OcrPipeline {

    // MARK: - Dependencies

    private let captureSource: any PassthroughCaptureSource
    private let speechOut: SpeechOut
    private let log = Logger(label: "echosight.read")

    // MARK: - Configuration

    private let confidenceThreshold: Float
    private let bandThreshold: CGFloat

    // MARK: - State

    private var currentTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - captureSource: Provides `CapturedFrame` on demand.
    ///   - speechOut: Shared speech actor.
    ///   - confidenceThreshold: Drop observations below this. Default 0.4.
    ///   - bandThreshold: Y-band grouping threshold for reading-order sort. Default 0.05.
    public init(
        captureSource: any PassthroughCaptureSource,
        speechOut: SpeechOut,
        confidenceThreshold: Float = TextConfidenceFilter.defaultThreshold,
        bandThreshold: CGFloat = ReadingOrderSorter.bandThreshold
    ) {
        self.captureSource = captureSource
        self.speechOut = speechOut
        self.confidenceThreshold = confidenceThreshold
        self.bandThreshold = bandThreshold
    }

    // MARK: - Event Subscriptions

    /// Subscribe to `ModalInputCoordinator` event streams.
    /// Call once at startup.
    public func start(
        firedEvents: AsyncStream<ModeFiredEvent>,
        changeEvents: AsyncStream<ModeChangeEvent>
    ) {
        // Fire subscription — react to .read events.
        // Actors are reference types — [weak self] is an anti-pattern in actor-owned
        // Tasks. It can cause the loop to silently not start if the actor deallocates
        // before the Task's first suspension. Capture self directly; stop() cancels.
        Task {
            for await event in firedEvents where event.mode == .read {
                await self.handleFire(event: event)
            }
        }

        // Cancel subscription — abort on any mode change.
        Task {
            for await _ in changeEvents {
                await self.cancelCurrentPipeline(reason: "mode-change")
            }
        }
    }

    // MARK: - Fire Handler

    private func handleFire(event: ModeFiredEvent) {
        // Cancel in-flight — most-recent-wins (handles "re-fire during read").
        currentTask?.cancel()
        log.info("read.fire.received")

        currentTask = Task {
            await self.runPipeline()
        }
    }

    // MARK: - Cancel

    private func cancelCurrentPipeline(reason: String) {
        guard let task = currentTask else { return }
        task.cancel()
        currentTask = nil
        log.info("read.cancelled", metadata: ["reason": "\(reason)"])
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
            log.warning("read.capture.failed", metadata: ["error": "\(error)"])
            await speakFallback()
            return
        }
        guard !Task.isCancelled else { return }
        log.info("read.capture.complete", metadata: [
            "durationMs": "\(Int(Date().timeIntervalSince(captureStart) * 1000))"
        ])

        // 2. Run VNRecognizeTextRequest — returns Sendable RawTextObservation values.
        let vnStart = Date()
        let observations = await recognizeText(in: frame)
        guard !Task.isCancelled else { return }
        log.info("read.vnRequest.complete", metadata: [
            "observationCount": "\(observations.count)",
            "durationMs": "\(Int(Date().timeIntervalSince(vnStart) * 1000))"
        ])

        // 3. Sort into reading order, then filter by confidence.
        let sorted = ReadingOrderSorter.sort(observations, bandThreshold: bandThreshold)
        let kept = sorted.filter { $0.confidence >= confidenceThreshold }
        let droppedCount = sorted.count - kept.count
        log.info("read.filter.kept", metadata: ["count": "\(kept.count)"])
        log.info("read.filter.dropped", metadata: ["count": "\(droppedCount)"])

        guard !kept.isEmpty else {
            guard !Task.isCancelled else { return }
            await speakFallback()
            return
        }

        // 4. Extract strings and chunk.
        let strings = kept.map { $0.text }
        let chunks = paragraphChunks(from: strings)
        log.info("read.chunks.created", metadata: [
            "count": "\(chunks.count)",
            "totalChars": "\(chunks.joined().count)"
        ])

        // 5. Speak each chunk, awaiting completion before the next.
        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else {
                log.info("read.cancelled", metadata: [
                    "reason": "task-cancelled",
                    "chunkIndex": "\(index)"
                ])
                return
            }

            log.info("read.speak.started", metadata: ["chunkIndex": "\(index)"])
            let chunkStart = Date()
            do {
                let token = try await speechOut.speak(
                    SpeechUtterance(text: chunk),
                    priority: .normal
                )
                let outcome = await token.completion
                log.info("read.speak.chunk.finished", metadata: [
                    "chunkIndex": "\(index)",
                    "durationMs": "\(Int(Date().timeIntervalSince(chunkStart) * 1000))",
                    "outcome": "\(outcome)"
                ])
                // If token was cancelled/dropped, abort remaining chunks.
                if case .cancelled = outcome { return }
                if case .dropped = outcome { return }
            } catch {
                log.warning("read.speak.failed", metadata: [
                    "chunkIndex": "\(index)",
                    "error": "\(error)"
                ])
                return
            }
        }

        log.info("read.pipeline.total", metadata: [
            "durationMs": "\(Int(Date().timeIntervalSince(pipelineStart) * 1000))",
            "outcome": "completed"
        ])
    }

    // MARK: - Vision Request

    /// Runs `VNRecognizeTextRequest` on the frame's image.
    ///
    /// Built fresh per call. Returns `[RawTextObservation]` — a `Sendable` value type
    /// extracted inside the Vision callback before resuming the continuation.
    private func recognizeText(in frame: CapturedFrame) async -> [RawTextObservation] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    self.log.warning("read.vnRequest.error", metadata: ["error": "\(error)"])
                    continuation.resume(returning: [])
                    return
                }
                // Extract Sendable value types inside the callback before crossing
                // the concurrency boundary (VNRecognizedTextObservation is not Sendable).
                let raw: [RawTextObservation] = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { obs -> RawTextObservation? in
                        guard let top = obs.topCandidates(1).first else { return nil }
                        return RawTextObservation(
                            text: top.string,
                            confidence: top.confidence,
                            boundingBox: obs.boundingBox
                        )
                    }
                continuation.resume(returning: raw)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // English only in v0.1 — multi-language is v1.0.
            request.recognitionLanguages = ["en-US"]

            guard let cgImage = frame.image.cgImage else {
                log.warning("read.vnRequest.noCGImage")
                continuation.resume(returning: [])
                return
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                log.warning("read.vnRequest.performFailed", metadata: ["error": "\(error)"])
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Paragraph Chunking

    /// Split text strings into speech chunks at natural boundaries.
    ///
    /// Each observation string is treated as a line. Lines are joined with a space.
    /// Text is split at `~250` character boundaries at word breaks to cap chunk length
    /// and allow mid-read cancellation between chunks.
    private func paragraphChunks(from lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }

        let fullText = lines.joined(separator: " ")
        let targetChunkChars = 250

        if fullText.count <= targetChunkChars {
            return [fullText]
        }

        var chunks: [String] = []
        var remaining = fullText[fullText.startIndex...]

        while !remaining.isEmpty {
            if remaining.count <= targetChunkChars {
                chunks.append(String(remaining))
                break
            }
            let endIdx = remaining.index(remaining.startIndex, offsetBy: targetChunkChars)
            if let spaceIdx = remaining[..<endIdx].lastIndex(of: " ") {
                chunks.append(String(remaining[..<spaceIdx]))
                remaining = remaining[remaining.index(after: spaceIdx)...]
            } else {
                chunks.append(String(remaining[..<endIdx]))
                remaining = remaining[endIdx...]
            }
        }
        return chunks
    }

    // MARK: - Fallback

    private func speakFallback() async {
        guard !Task.isCancelled else { return }
        do {
            _ = try await speechOut.speak(
                SpeechUtterance(text: "I don't see any readable text"),
                priority: .normal
            )
        } catch {
            log.warning("read.fallback.speak.failed", metadata: ["error": "\(error)"])
        }
    }
}
