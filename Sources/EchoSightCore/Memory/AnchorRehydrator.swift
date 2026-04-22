import Foundation
import Logging

// MARK: - AnchorRehydrator

/// Subscribes to `AnchorChangeEvent` stream and loads persisted annotations
/// into the in-memory spatial hash when a previously-mapped anchor is re-recognized.
///
/// Plumbing only — no user-facing output. On `.rerecognized`:
///   1. Calls `AnnotationStore.rehydrate(worldAnchorId:)` to read SQLite rows
///   2. `AnnotationStore.rehydrate` re-indexes results into the spatial hash
///   3. Marks `anchorId` as rehydrated so `isRehydrated(anchorId:)` returns `true`
///
/// `.new` and `.sessionResumeRerecognized` events are ignored by this subscriber.
///
/// Concurrency: `AnchorRehydrator` is an actor. The `store` dependency is also an actor.
/// Rehydration calls are queued through the store actor — concurrent `.rerecognized`
/// events for the same anchor are idempotent (load is idempotent by design).
///
/// Observability: `echosight.store` log category.
public actor AnchorRehydrator {

    // MARK: - Configuration

    /// Maximum rehydration attempts per anchor. Prevents infinite retry storms
    /// on persistent DB errors (full disk, corruption). After this many failures
    /// the anchor is silently skipped — user will not see stale recall data.
    private static let maxRetries = 5

    // MARK: - Properties

    private let store: AnnotationStore
    private var rehydratedAnchors: Set<UUID> = []
    private var failureCounts: [UUID: Int] = [:]
    private var streamTask: Task<Void, Never>?
    private let log = Logger(label: LogCategories.store)

    // MARK: - Init

    public init(store: AnnotationStore) {
        self.store = store
    }

    // MARK: - Subscription

    /// Starts consuming the given `AnchorChangeEvent` stream.
    ///
    /// Call once per app session. Stopping is handled by task cancellation
    /// (the stream's `onTermination` fires, unregistering the continuation).
    /// Safe to call again after a prior task was cancelled.
    public func subscribe(to stream: AsyncStream<AnchorChangeEvent>) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                await self.handle(event: event)
            }
        }
    }

    /// Cancels the active subscription.
    public func unsubscribe() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Event Handling

    private func handle(event: AnchorChangeEvent) async {
        guard event.kind == .rerecognized else { return }

        let anchorId = event.anchorId
        let hashedId = PrivacyFilter.hashAnchorId(anchorId)

        // Skip anchors that have exceeded the retry cap.
        let currentFailures = failureCounts[anchorId, default: 0]
        guard currentFailures < Self.maxRetries else {
            log.error(
                "store.rehydrate.skipped",
                metadata: [
                    "anchorId": .string(hashedId),
                    "reason": "maxRetriesExceeded",
                    "failureCount": .string("\(currentFailures)"),
                ]
            )
            return
        }

        log.info("store.rehydrate.started", metadata: [
            "anchorId": .string(hashedId),
            "attempt": .string("\(currentFailures + 1)"),
        ])

        let rehydrateStart = Date()
        do {
            let annotations = try await store.rehydrate(worldAnchorId: anchorId)
            rehydratedAnchors.insert(anchorId)
            failureCounts.removeValue(forKey: anchorId)

            let durationMs = Int(Date().timeIntervalSince(rehydrateStart) * 1000)
            log.info(
                "store.rehydrate.completed",
                metadata: [
                    "anchorId": .string(hashedId),
                    "annotationCount": .string("\(annotations.count)"),
                    "durationMs": .string("\(durationMs)"),
                ]
            )
        } catch {
            failureCounts[anchorId] = currentFailures + 1
            let newCount = failureCounts[anchorId]!
            log.error(
                "store.rehydrate.failed",
                metadata: [
                    "anchorId": .string(hashedId),
                    "error": .string("\(error)"),
                    "failureCount": .string("\(newCount)"),
                    "retriesRemaining": .string("\(Self.maxRetries - newCount)"),
                ]
            )
        }
    }

    // MARK: - Query

    /// Returns `true` if this anchor's annotations have been loaded into the
    /// in-memory spatial hash for the current session.
    ///
    /// Used by `spatial-recall` to confirm the cache is warm before the first query.
    public func isRehydrated(anchorId: UUID) -> Bool {
        rehydratedAnchors.contains(anchorId)
    }

    /// Clears the rehydrated-anchor set and failure counts. Call on session
    /// interruption so re-recognized anchors trigger a fresh load after resume.
    public func reset() {
        rehydratedAnchors.removeAll()
        failureCounts.removeAll()
        log.info("store.rehydrate.reset")
    }
}
