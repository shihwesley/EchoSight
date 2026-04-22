import Foundation
import Logging

// MARK: - AnchorRehydrator

/// Subscribes to `AnchorChangeEvent` stream and loads persisted annotations
/// into the in-memory spatial hash when a previously-mapped anchor is re-recognized.
///
/// Plumbing only — no user-facing output. On `.rerecognized`:
///   1. Calls `AnnotationStore.load(worldAnchorId:)` to read SQLite rows
///   2. `AnnotationStore.load` re-indexes results into the spatial hash
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

    // MARK: - Properties

    private let store: AnnotationStore
    private var rehydratedAnchors: Set<UUID> = []
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

        log.info("store.rehydrate.started", metadata: ["anchorId": .string(hashedId)])

        let rehydrateStart = Date()
        do {
            let annotations = try await store.load(worldAnchorId: anchorId)
            rehydratedAnchors.insert(anchorId)

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
            // P2-DEFERRED(Sprint 3.x): failed rehydration should not permanently block retry.
            // Currently isRehydrated() stays false (never inserted), so the next .rerecognized
            // event will re-attempt — which is correct behaviour. The note here is to add an
            // explicit retry-count cap to avoid infinite rehydration storms on persistent DB errors.
            log.error(
                "store.rehydrate.failed",
                metadata: [
                    "anchorId": .string(hashedId),
                    "error": .string("\(error)"),
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

    /// Clears the rehydrated-anchor set. Call on session interruption
    /// so re-recognized anchors trigger a fresh load after session resume.
    public func reset() {
        rehydratedAnchors.removeAll()
        log.info("store.rehydrate.reset")
    }
}
