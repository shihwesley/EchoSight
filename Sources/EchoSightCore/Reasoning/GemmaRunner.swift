import Foundation
import simd
import Logging
import Synchronization

// MARK: - GemmaRunner

/// Public API for all Gemma 4 E2B Q4 inference calls.
///
/// Three consumer-facing methods, each with a distinct priority and token budget:
/// - `enrich(context:)` — low priority, ≤40 tokens, async background write path
/// - `summarize(annotations:)` — high priority, ≤30 tokens, 1.5 s budget, used by spatial-recall
/// - `inferRoomLabel(anchor:annotations:meshClassification:)` — high priority, ≤20 tokens, 1.5 s budget
///
/// Callers receive either a result string or a thrown error. On timeout or model
/// unavailable, the caller is responsible for template fallback (spec contract).
///
/// Snapshot pinning: `summarize` and `inferRoomLabel` copy their annotation inputs
/// at call entry. Concurrent rehydration cannot mutate the snapshot.
///
/// Observability: `echosight.gemma` log category.
public actor GemmaRunner {

    // MARK: - Token Budgets

    private enum TokenBudget {
        static let enrich: Int = 40
        static let summarize: Int = 30
        static let inferRoomLabel: Int = 20
    }

    private enum Timeout {
        static let highPriority: Double = 1.5
        static let lowPriority: Double = 2.0
    }

    // MARK: - Dependencies

    private let modelManager: GemmaModelManager
    private let queue: GemmaPriorityQueue
    private let log = Logger(label: LogCategories.gemma)

    // MARK: - Init

    public init(modelManager: GemmaModelManager) {
        self.modelManager = modelManager
        // Pass a closure over modelManager.generate so GemmaPriorityQueue has no
        // reference back to GemmaRunner, breaking the potential retain cycle.
        let manager = modelManager
        self.queue = GemmaPriorityQueue { prompt, maxTokens, timeout in
            // CancelFlag is a class so the onCancel handler and the closure read the
            // same heap object. nonisolated(unsafe) is appropriate here: the flag is
            // set exactly once (onCancel) and read cooperatively inside the model loop.
            let flag = CancelFlag()
            return try await withTaskCancellationHandler {
                try await manager.generate(
                    prompt: prompt,
                    maxTokens: maxTokens,
                    timeoutSeconds: timeout,
                    cancelled: { Task.isCancelled || flag.isCancelled }
                )
            } onCancel: {
                flag.cancel()
            }
        }
    }

    // MARK: - Warm-Up

    /// Warms the model. Must be called before the first inference call.
    /// Safe to await — subsequent calls no-op after first completion.
    public func warmUp() async {
        await modelManager.warmUp()
    }

    // MARK: - Public API

    /// Enriches a world annotation with a natural-language description.
    ///
    /// Low priority — runs in background, does not block scene mode.
    /// Callers should not await on the critical path.
    ///
    /// - Parameter context: Structured detection context from the fusion pipeline.
    /// - Returns: A 1-sentence description of the detected object.
    /// - Throws: `GemmaModelManager.ModelError` on failure.
    public func enrich(context: EnrichmentContext) async throws -> String {
        let prompt = EnrichmentPromptBuilder.buildPrompt(from: context)
        return try await queue.submit(
            prompt: prompt,
            maxTokens: TokenBudget.enrich,
            timeoutSeconds: Timeout.lowPriority,
            priority: .low
        )
    }

    /// Produces a gestalt summary of nearby annotations for spatial-recall.
    ///
    /// High priority — user is waiting; preempts any in-flight enrichment.
    /// 1.5 s budget. Caller owns template fallback on `.timeout` or `.modelUnavailable`.
    ///
    /// Snapshot: `annotations` array is copied at call entry.
    ///
    /// - Parameter annotations: Immutable snapshot of nearby world annotations.
    /// - Returns: A 1-sentence gestalt description.
    public func summarize(annotations: [WorldAnnotation]) async throws -> String {
        let snapshot = Array(annotations)  // snapshot pin
        let prompt = SummarizePromptBuilder.buildPrompt(from: snapshot)
        return try await queue.submit(
            prompt: prompt,
            maxTokens: TokenBudget.summarize,
            timeoutSeconds: Timeout.highPriority,
            priority: .high
        )
    }

    /// Infers a 1-3 word room label from anchor context, annotations, and mesh classifications.
    ///
    /// High priority — called by `ambient-announce` on cold-anchor detection.
    /// 1.5 s budget. Caller owns template fallback on failure.
    ///
    /// Snapshot: `annotations` array is copied at call entry.
    ///
    /// - Returns: A noun phrase such as "living room", "office space", or "corridor".
    public func inferRoomLabel(
        anchorId: UUID,
        annotations: [WorldAnnotation],
        meshClassification: MeshClassificationSummary
    ) async throws -> String {
        let snapshot = Array(annotations)  // snapshot pin
        let prompt = RoomLabelPromptBuilder.buildPrompt(
            anchorId: anchorId,
            annotations: snapshot,
            meshClassification: meshClassification
        )
        return try await queue.submit(
            prompt: prompt,
            maxTokens: TokenBudget.inferRoomLabel,
            timeoutSeconds: Timeout.highPriority,
            priority: .high
        )
    }

}

// MARK: - CancelFlag

/// Thread-safe cancellation flag for cooperative generation loop.
///
/// Uses `Atomic<Bool>` (Swift 6 Synchronization) so the `onCancel` handler
/// and the generate polling loop can share the flag across threads without
/// a data race. Relaxed ordering is sufficient: the only invariant is that
/// eventually the poller sees `true` after `cancel()` is called — correctness
/// does not depend on seeing it immediately.
private final class CancelFlag: Sendable {
    private let _cancelled = Atomic<Bool>(false)

    func cancel() { _cancelled.store(true, ordering: .relaxed) }
    var isCancelled: Bool { _cancelled.load(ordering: .relaxed) }
}

// MARK: - EnrichmentContext

/// Structured input for the enrichment prompt builder.
public struct EnrichmentContext: Sendable {
    public let detections: [String]
    public let distances: [Float]
    public let classifications: [String]

    public init(detections: [String], distances: [Float], classifications: [String]) {
        self.detections = detections
        self.distances = distances
        self.classifications = classifications
    }
}
