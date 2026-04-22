import Foundation

// MARK: - PipelineMetricsBuffer

/// Actor-backed ring buffer storing the last N pipeline events per category.
///
/// `record` is nonisolated and fire-and-forget — callers never await it,
/// so pipeline hot paths see zero blocking overhead. The actor hop happens
/// on a detached task.
///
/// Capacity: 32 events per category (fixed). The 33rd event evicts the oldest.
public actor PipelineMetricsBuffer {

    // MARK: - Constants

    public static let shared = PipelineMetricsBuffer()

    private let capacity: Int

    // MARK: - Storage

    /// Events keyed by category, each a fixed-capacity deque.
    private var store: [String: [PipelineEvent]] = [:]

    /// AsyncStream continuations for live-tail consumers (DebugConsoleView).
    private var liveConsumers: [UUID: AsyncStream<PipelineEvent>.Continuation] = [:]

    // MARK: - Init

    public init(capacity: Int = 32) {
        self.capacity = capacity
    }

    // MARK: - Write

    /// Record a pipeline event. Non-blocking from the caller's perspective.
    nonisolated public func record(_ event: PipelineEvent) {
        Task { await self._record(event) }
    }

    private func _record(_ event: PipelineEvent) {
        var bucket = store[event.category, default: []]
        if bucket.count >= capacity {
            bucket.removeFirst()
        }
        bucket.append(event)
        store[event.category] = bucket
        // Notify live consumers.
        for c in liveConsumers.values { c.yield(event) }
    }

    // MARK: - Read

    /// Returns the last N events for a specific category, oldest first.
    public func recent(category: String) -> [PipelineEvent] {
        store[category, default: []]
    }

    /// Returns all events across all categories, sorted by timestamp ascending.
    public func recentAll() -> [PipelineEvent] {
        store.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Live Stream

    /// Returns an `AsyncStream` that yields each new `PipelineEvent` as it is recorded.
    public func liveStream() -> AsyncStream<PipelineEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { self._registerLiveConsumer(continuation, id: id) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self._unregisterLiveConsumer(id: id) }
            }
        }
    }

    private func _registerLiveConsumer(_ c: AsyncStream<PipelineEvent>.Continuation, id: UUID) {
        liveConsumers[id] = c
    }

    private func _unregisterLiveConsumer(id: UUID) {
        liveConsumers.removeValue(forKey: id)
    }
}
