import Foundation
import Logging

// MARK: - AnchorEventStream

/// Translates ARKit world-anchor updates into `AnchorChangeEvent` values.
///
/// Maintains a per-session `Set<UUID>` so `.rerecognized` only fires once per
/// anchor per session (not on every frame update). On session interruption + resume,
/// the set is flushed and re-recognized anchors are emitted as
/// `.sessionResumeRerecognized` to let `ambient-announce` apply chime dampening.
///
/// The `anchorMetadataQuery` closure is injected by `SpatialSession` and bridges
/// to `annotation-store`'s synchronous lookup. This is the only coupling between
/// these two specs at the event layer.
public actor AnchorEventStream {

    // MARK: - Types

    /// Closure that checks whether an anchor UUID exists in the annotation store.
    /// Called synchronously within actor isolation — must not block.
    public typealias AnchorMetadataQuery = @Sendable (UUID) -> Bool

    // MARK: - Properties

    private let log = Logger(label: "echosight.anchor")
    private var seenThisSession: Set<UUID> = []
    private var isSessionInterrupted = false
    private var continuations: [UUID: AsyncStream<AnchorChangeEvent>.Continuation] = [:]
    private var streamIdCounter: UUID = UUID()

    // MARK: - Dependencies

    private let anchorMetadataQuery: AnchorMetadataQuery

    // MARK: - Init

    /// - Parameter anchorMetadataQuery: Returns `true` if the anchor UUID has a
    ///   prior row in `annotation-store`'s `AnchorMetadata` table.
    public init(anchorMetadataQuery: @escaping AnchorMetadataQuery) {
        self.anchorMetadataQuery = anchorMetadataQuery
    }

    // MARK: - Stream

    /// Creates a new `AsyncStream` that receives all future anchor change events.
    /// Multiple consumers may attach; each gets its own stream.
    public func makeStream() -> AsyncStream<AnchorChangeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { self.register(continuation: continuation, id: id) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(continuation: AsyncStream<AnchorChangeEvent>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: - ARKit Events

    /// Called by `SpatialSession` when ARKit reports a new or updated world anchor.
    ///
    /// - Parameters:
    ///   - anchorId: The anchor's UUID.
    ///   - isNewFromARKit: `true` if this is a first-time add; `false` if ARKit
    ///     is reporting an update or re-recognition of an existing anchor.
    public func handleAnchorUpdate(anchorId: UUID, isNewFromARKit: Bool) {
        guard !seenThisSession.contains(anchorId) else {
            // Already emitted for this session; dedup.
            return
        }
        seenThisSession.insert(anchorId)

        let kind: AnchorChangeEvent.Kind
        if isSessionInterrupted {
            // All anchors re-emitted after a session resume become .sessionResumeRerecognized.
            kind = .sessionResumeRerecognized
        } else if anchorMetadataQuery(anchorId) {
            // Anchor exists in the annotation store — organic mid-session re-recognition.
            kind = .rerecognized
        } else {
            kind = .new
        }

        let event = AnchorChangeEvent(anchorId: anchorId, kind: kind, timestamp: Date())
        emit(event)

        let hashedId = PrivacyFilter.hashAnchorId(anchorId)
        switch kind {
        case .new:
            log.info("anchor.new", metadata: ["anchorId": .string(hashedId)])
        case .rerecognized:
            log.info("anchor.rerecognized", metadata: ["anchorId": .string(hashedId)])
        case .sessionResumeRerecognized:
            log.info("anchor.sessionResumeRerecognized", metadata: [
                "anchorId": .string(hashedId),
                "seenSetSize": .string("\(seenThisSession.count)"),
            ])
        }
    }

    // MARK: - Session Lifecycle

    /// Called by `SpatialSession` when the ARKit session is interrupted.
    public func handleSessionInterrupted() {
        isSessionInterrupted = true
        log.info("spatial.session.interrupted")
    }

    /// Called by `SpatialSession` when the ARKit session resumes.
    /// Flushes the seen-this-session set so re-recognized anchors emit as
    /// `.sessionResumeRerecognized`.
    public func handleSessionResumed() {
        seenThisSession.removeAll()
        isSessionInterrupted = false
        log.info("spatial.session.resumed", metadata: ["seenSetCleared": "true"])
    }

    // MARK: - Emit

    private func emit(_ event: AnchorChangeEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
