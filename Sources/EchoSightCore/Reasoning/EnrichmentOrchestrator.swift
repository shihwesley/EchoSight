import Foundation
import Logging

// MARK: - EnrichmentOrchestrator

/// Manages the background enrichment queue: drains `AnnotationCandidate` inputs,
/// calls `GemmaRunner.enrich(context:)`, and writes the result back to `AnnotationStore`.
///
/// Queue depth: max 8. When the queue exceeds 8, the oldest pending item is dropped
/// (the oldest annotation is least likely to still be in view).
///
/// Speak rule: enrichment output is only relevant if the user is still in scene mode,
/// hasn't moved >0.5 m, and is still listening. This check lives in the caller
/// (scene-description pipeline), not here. The orchestrator only writes to the store.
///
/// Write-back: updates `WorldAnnotation.description` via `AnnotationStore.updateDescription`.
///
/// Cancellation: all in-flight enrichment Tasks are cancelled on `stop()`.
///
/// Observability: `echosight.gemma` log category.
public actor EnrichmentOrchestrator {

    // MARK: - Types

    /// An item in the enrichment backlog.
    private struct EnrichmentItem: Sendable {
        let annotationId: UUID
        let anchorId: UUID
        let context: EnrichmentContext
        let enqueuedAt: Date
    }

    // MARK: - Configuration

    private static let maxQueueDepth = 8

    // MARK: - Properties

    private let runner: GemmaRunner
    private let store: AnnotationStore
    private let log = Logger(label: LogCategories.gemma)

    private var queue: [EnrichmentItem] = []
    private var activeTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Init

    public init(runner: GemmaRunner, store: AnnotationStore) {
        self.runner = runner
        self.store = store
    }

    // MARK: - Enqueue

    /// Submits an annotation for background enrichment.
    ///
    /// If the queue is at capacity, the oldest item (index 0) is dropped.
    /// Returns immediately — enrichment runs asynchronously.
    public func enqueue(annotationId: UUID, anchorId: UUID, context: EnrichmentContext) {
        let item = EnrichmentItem(
            annotationId: annotationId,
            anchorId: anchorId,
            context: context,
            enqueuedAt: Date()
        )

        if queue.count >= Self.maxQueueDepth {
            let dropped = queue.removeFirst()
            log.info(
                "gemma.enrichment.dropped",
                metadata: [
                    "droppedAnnotationId": .string(dropped.annotationId.uuidString),
                    "reason": "queue_full",
                ]
            )
        }

        queue.append(item)
        log.info(
            "gemma.call.enqueued",
            metadata: [
                "priority": "low",
                "queueDepth": .string("\(queue.count)"),
            ]
        )

        drainIfIdle()
    }

    // MARK: - Drain

    private func drainIfIdle() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        activeTask = Task { await self.drainLoop() }
    }

    private func drainLoop() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            await enrich(item: item)
        }
        isRunning = false
    }

    private func enrich(item: EnrichmentItem) async {
        do {
            let description = try await runner.enrich(context: item.context)
            try await store.updateDescription(id: item.annotationId, description: description)
            log.info(
                "gemma.call.completed",
                metadata: [
                    "callId": .string(item.annotationId.uuidString),
                    "annotationId": .string(item.annotationId.uuidString),
                ]
            )
        } catch {
            log.error(
                "gemma.enrichment.failed",
                metadata: [
                    "annotationId": .string(item.annotationId.uuidString),
                    "error": .string("\(error)"),
                ]
            )
        }
    }

    // MARK: - Control

    /// Cancels the active enrichment task and clears the queue.
    /// Call when the user leaves scene mode or the app backgrounds.
    public func stop() {
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
        queue.removeAll()
        log.info("gemma.enrichment.stopped")
    }

    /// Current pending queue depth (not including any actively running item).
    public var pendingCount: Int { queue.count }
}
