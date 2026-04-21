import Foundation

// MARK: - AnchorChangeEvent

/// An event emitted by `AnchorEventStream` when a world anchor is added or re-recognized.
///
/// Consumed by `ambient-announce` (novelty detection, chime suppression) and
/// `annotation-store`'s `AnchorRehydrator` (cross-session memory hydration).
public struct AnchorChangeEvent: Sendable {

    // MARK: - Kind

    /// Discriminates among three distinct anchor lifecycle events.
    public enum Kind: Sendable {
        /// A world anchor with no prior `AnchorMetadata` row — genuinely new to the store.
        case new

        /// An anchor that exists in `AnchorMetadata` and was re-recognized organically
        /// during a session (user walked back into a previously-mapped room).
        case rerecognized

        /// An anchor re-emitted after an ARKit session interruption and resume.
        ///
        /// `ambient-announce` applies a 3-second chime-dampening window for this kind
        /// to prevent a flood of chimes on session restart. Organic re-recognition
        /// (mid-session, not post-interruption) uses `.rerecognized` so normal novelty
        /// detection still fires.
        ///
        /// Pinned post-TLA verification 2026-04-21.
        case sessionResumeRerecognized
    }

    // MARK: - Properties

    /// The ARKit world anchor identifier.
    public let anchorId: UUID

    /// Which lifecycle event fired for this anchor.
    public let kind: Kind

    /// When the event was observed by `AnchorEventStream`.
    public let timestamp: Date

    // MARK: - Init

    public init(anchorId: UUID, kind: Kind, timestamp: Date) {
        self.anchorId = anchorId
        self.kind = kind
        self.timestamp = timestamp
    }
}
