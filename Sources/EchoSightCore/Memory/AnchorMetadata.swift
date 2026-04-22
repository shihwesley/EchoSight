import Foundation
import GRDB

// MARK: - AnchorMetadata

/// Per-anchor metadata tracking visit history and room labels.
///
/// One row per ARKit anchor UUID. Foreign-key referenced by `world_annotations.worldAnchorId`.
/// Used by:
/// - `ambient-announce` — reads `lastSeenAt` for the 30-min novelty rule
/// - `spatial-recall`  — reads `inferredLabel` / `userLabel` for room context
/// - `annotation-store` — records encounters and label inference results
///
/// Label precedence: `userLabel` overrides `inferredLabel` in all read queries.
/// Both columns are stored separately so inference never silently overwrites
/// a user correction.
public struct AnchorMetadata: Sendable {

    // MARK: - Properties

    /// ARKit anchor UUID. Primary key — one row per anchor.
    public let anchorId: UUID

    /// When this anchor was first observed.
    public let firstSeenAt: Date

    /// When this anchor was most recently observed (updated on each encounter).
    public var lastSeenAt: Date

    /// Total number of session encounters for this anchor.
    /// Incremented atomically on each `recordAnchorEncounter` call.
    public var visitCount: Int

    /// Room label set explicitly by the user. Overrides `inferredLabel` in reads.
    public var userLabel: String?

    /// Room label inferred by Gemma. Readable only when `userLabel` is `nil`.
    public var inferredLabel: String?

    // MARK: - Derived

    /// The effective label shown to consumers. User label takes precedence.
    public var effectiveLabel: String? {
        userLabel ?? inferredLabel
    }

    // MARK: - Init

    public init(
        anchorId: UUID,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        visitCount: Int = 1,
        userLabel: String? = nil,
        inferredLabel: String? = nil
    ) {
        self.anchorId = anchorId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.visitCount = visitCount
        self.userLabel = userLabel
        self.inferredLabel = inferredLabel
    }
}

// MARK: - GRDB Record

struct AnchorMetadataRecord: Codable, FetchableRecord, PersistableRecord {

    static let databaseTableName = "anchor_metadata"

    var anchorId: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var visitCount: Int
    var userLabel: String?
    var inferredLabel: String?

    init(from metadata: AnchorMetadata) {
        anchorId = metadata.anchorId.uuidString
        firstSeenAt = metadata.firstSeenAt
        lastSeenAt = metadata.lastSeenAt
        visitCount = metadata.visitCount
        userLabel = metadata.userLabel
        inferredLabel = metadata.inferredLabel
    }

    func toMetadata() -> AnchorMetadata? {
        guard let uuid = UUID(uuidString: anchorId) else { return nil }
        return AnchorMetadata(
            anchorId: uuid,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            visitCount: visitCount,
            userLabel: userLabel,
            inferredLabel: inferredLabel
        )
    }
}
