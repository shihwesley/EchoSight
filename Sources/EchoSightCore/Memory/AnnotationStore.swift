import Foundation
import simd
import GRDB
import Logging

// MARK: - AnnotationStore

/// GRDB-backed SQLite store for `WorldAnnotation` and `AnchorMetadata`.
///
/// Consumers:
/// - `spatial-recall`    — `nearestAnnotations(to:radius:)` + `load(worldAnchorId:)`
/// - `ambient-announce`  — `lastSeenAnchorAt(anchorId:)` + `annotationCount(anchorId:)` + `anchorMetadata(anchorId:)`
/// - `gemma-enrichment`  — snapshot reads via `nearestAnnotations` + `load(worldAnchorId:)`
/// - `AnchorRehydrator`  — `load(worldAnchorId:)` on `.rerecognized` event
///
/// Thread safety: `DatabaseQueue` serialises all writes. Concurrent reads go through
/// `dbQueue.read { }` which is safe for concurrent callers. The in-memory
/// `SpatialHash` is only mutated inside the actor.
///
/// Observability: `echosight.store` log category.
public actor AnnotationStore {

    // MARK: - Types

    public enum StoreError: Error, Sendable {
        case databaseSetupFailed(Error)
        case invalidUUID(String)
    }

    // MARK: - Properties

    private let dbQueue: DatabaseQueue
    private var spatialHash: SpatialHash
    private let log = Logger(label: LogCategories.store)

    // MARK: - Init

    /// Opens (or creates) the SQLite database at `path` and runs migrations.
    /// Pass `nil` for an in-memory database (useful in tests).
    public init(path: String? = nil) throws {
        do {
            if let path {
                dbQueue = try DatabaseQueue(path: path)
            } else {
                dbQueue = try DatabaseQueue()
            }
            spatialHash = SpatialHash()
            try AnnotationStore.runMigrations(on: dbQueue)
            log.info("store.opened", metadata: ["path": .string(path ?? ":memory:")])
        } catch {
            throw StoreError.databaseSetupFailed(error)
        }
    }

    // MARK: - Migrations

    private static func runMigrations(on dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_world_annotations") { db in
            try db.create(table: "world_annotations") { t in
                t.column("id", .text).primaryKey()
                t.column("posX", .real).notNull()
                t.column("posY", .real).notNull()
                t.column("posZ", .real).notNull()
                t.column("worldAnchorId", .text).notNull()
                t.column("falconLabel", .text).notNull()
                t.column("meshClassification", .text).notNull()
                t.column("confidence", .real).notNull()
                t.column("description", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.column("captureCount", .integer).notNull().defaults(to: 1)
            }
            try db.create(
                index: "idx_world_annotations_anchorId",
                on: "world_annotations",
                columns: ["worldAnchorId"]
            )
        }

        migrator.registerMigration("v1_anchor_metadata") { db in
            try db.create(table: "anchor_metadata") { t in
                t.column("anchorId", .text).primaryKey()
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull()
                t.column("visitCount", .integer).notNull().defaults(to: 1)
                t.column("userLabel", .text)
                t.column("inferredLabel", .text)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Write: WorldAnnotation

    /// Writes an annotation. If a matching annotation exists within `mergeRadius` of
    /// `candidate.worldPosition` for the same anchor, delegates to `AnnotationMerger`.
    /// Otherwise inserts a new row.
    ///
    /// - Returns: The stored annotation (either merged or newly inserted).
    @discardableResult
    public func write(annotation: WorldAnnotation, mergeRadius: Float = 0.30) throws -> WorldAnnotation {
        // Merge check hits the `idx_world_annotations_anchorId` index only; spatial hash
        // is updated downstream on the stored annotation alone, not rebuilt for every sibling.
        let existingForAnchor = try fetchAnnotationsForMerge(worldAnchorId: annotation.worldAnchorId)
        let result: WorldAnnotation

        if let existing = AnnotationMerger.findMergeCandidate(
            in: existingForAnchor,
            for: annotation,
            radius: mergeRadius
        ) {
            let merged = AnnotationMerger.merge(existing: existing, incoming: annotation)
            try dbQueue.write { db in
                let record = WorldAnnotationRecord(from: merged)
                try record.update(db)
            }
            spatialHash.update(id: merged.id, position: merged.worldPosition)
            log.info(
                "store.write",
                metadata: [
                    "annotationId": .string(merged.id.uuidString),
                    "merged": "true",
                    "captureCount": .string("\(merged.captureCount)"),
                ]
            )
            result = merged
        } else {
            try dbQueue.write { db in
                let record = WorldAnnotationRecord(from: annotation)
                try record.insert(db)
            }
            spatialHash.insert(id: annotation.id, position: annotation.worldPosition)
            log.info(
                "store.write",
                metadata: [
                    "annotationId": .string(annotation.id.uuidString),
                    "merged": "false",
                ]
            )
            result = annotation
        }
        return result
    }

    /// Updates just the `description` field for an existing annotation (Gemma write-back).
    public func updateDescription(id: UUID, description: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE world_annotations SET description = ? WHERE id = ?",
                arguments: [description, id.uuidString]
            )
        }
    }

    // MARK: - Read: WorldAnnotation

    /// Loads all annotations attached to a given anchor UUID.
    ///
    /// Also inserts any loaded annotations into the in-memory spatial hash
    /// (used by `AnchorRehydrator` on `.rerecognized` events).
    ///
    /// P2-DEFERRED(Sprint 3.x): CQS violation — a method named `load` that also mutates
    /// `spatialHash` is surprising at call sites. Split into `load` (pure read) and
    /// `rehydrate` (read + hash update), with only `AnchorRehydrator` calling `rehydrate`.
    public func load(worldAnchorId: UUID) throws -> [WorldAnnotation] {
        let records = try dbQueue.read { db in
            try WorldAnnotationRecord.filter(
                Column("worldAnchorId") == worldAnchorId.uuidString
            ).fetchAll(db)
        }
        let annotations = records.compactMap { $0.toAnnotation() }
        // Re-index into spatial hash (idempotent — SpatialHash.insert is a no-op on duplicate)
        for a in annotations {
            spatialHash.insert(id: a.id, position: a.worldPosition)
        }
        return annotations
    }

    /// Returns annotations within `radius` meters of `headPose` using the spatial hash.
    ///
    /// The result is an immutable copy snapped at call entry — concurrent rehydration
    /// cannot mutate it mid-call.
    public func nearestAnnotations(
        to headPose: SIMD3<Float>,
        radius: Float = 5.0
    ) throws -> [WorldAnnotation] {
        let start = Date()
        let candidateIds = spatialHash.candidateIds(near: headPose, radius: radius)

        let annotations: [WorldAnnotation]
        if candidateIds.isEmpty {
            annotations = []
        } else {
            let uuidStrings = candidateIds.map { $0.uuidString }
            let records = try dbQueue.read { db in
                let placeholders = uuidStrings.map { _ in "?" }.joined(separator: ", ")
                return try WorldAnnotationRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM world_annotations WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(uuidStrings)
                )
            }
            // Fine-filter to actual radius (hash cells may overlap boundary)
            annotations = records.compactMap { $0.toAnnotation() }.filter { a in
                simd_distance(a.worldPosition, headPose) <= radius
            }
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        log.info(
            "store.query.nearest",
            metadata: [
                "radius": .string("\(radius)"),
                "resultCount": .string("\(annotations.count)"),
                "durationMs": .string("\(durationMs)"),
            ]
        )
        return annotations
    }

    /// Soft-delete: removes annotations older than `date`.
    /// Decay policy is off by default in v0.1 — call explicitly when needed.
    public func purge(olderThan date: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM world_annotations WHERE lastSeenAt < ?",
                arguments: [date]
            )
        }
        // Rebuild spatial hash after purge (simpler than tracking deletes)
        try rebuildSpatialHash()
    }

    // MARK: - Write: AnchorMetadata

    /// UPSERT: inserts a new row on first encounter, updates `lastSeenAt` and
    /// increments `visitCount` on subsequent ones. Safe for concurrent callers —
    /// actor isolation serialises access.
    public func recordAnchorEncounter(anchorId: UUID) throws {
        try dbQueue.write { db in
            if let _ = try AnchorMetadataRecord.filter(
                Column("anchorId") == anchorId.uuidString
            ).fetchOne(db) {
                try db.execute(
                    sql: """
                        UPDATE anchor_metadata
                        SET lastSeenAt = ?, visitCount = visitCount + 1
                        WHERE anchorId = ?
                        """,
                    arguments: [Date(), anchorId.uuidString]
                )
            } else {
                let record = AnchorMetadataRecord(
                    from: AnchorMetadata(anchorId: anchorId)
                )
                try record.insert(db)
            }
        }

        let visitCount = try anchorVisitCount(anchorId: anchorId) ?? 1
        log.info(
            "store.anchorEncounter.recorded",
            metadata: [
                "anchorId": .string(PrivacyFilter.hashAnchorId(anchorId)),
                "visitCount": .string("\(visitCount)"),
            ]
        )
    }

    /// Sets or clears the user-supplied room label. User label overrides inferred label.
    public func setAnchorLabel(anchorId: UUID, userLabel: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE anchor_metadata SET userLabel = ? WHERE anchorId = ?",
                arguments: [userLabel, anchorId.uuidString]
            )
        }
    }

    /// Sets or clears the Gemma-inferred room label.
    /// Never overwrites a user label in the `userLabel` column.
    public func setAnchorInferredLabel(anchorId: UUID, inferredLabel: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE anchor_metadata SET inferredLabel = ? WHERE anchorId = ?",
                arguments: [inferredLabel, anchorId.uuidString]
            )
        }
    }

    // MARK: - Read: AnchorMetadata

    /// Returns the last-seen date for an anchor, or `nil` if the anchor is not known.
    /// Used by `ambient-announce` for the 30-minute novelty rule.
    public func lastSeenAnchorAt(anchorId: UUID) throws -> Date? {
        let hit = try dbQueue.read { db in
            try AnchorMetadataRecord.filter(
                Column("anchorId") == anchorId.uuidString
            ).fetchOne(db)
        }
        log.info(
            "store.query.anchorMetadata",
            metadata: [
                "anchorId": .string(PrivacyFilter.hashAnchorId(anchorId)),
                "hit": .string(hit != nil ? "true" : "false"),
            ]
        )
        return hit?.lastSeenAt
    }

    /// Returns the full `AnchorMetadata` for an anchor, or `nil` if unknown.
    public func anchorMetadata(anchorId: UUID) throws -> AnchorMetadata? {
        let record = try dbQueue.read { db in
            try AnchorMetadataRecord.filter(
                Column("anchorId") == anchorId.uuidString
            ).fetchOne(db)
        }
        return record?.toMetadata()
    }

    /// Returns the number of annotations stored for an anchor.
    /// Used by `ambient-announce` speech content ("M annotations remembered").
    public func annotationCount(anchorId: UUID) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM world_annotations WHERE worldAnchorId = ?",
                arguments: [anchorId.uuidString]
            ) ?? 0
        }
    }

    /// Returns `true` if this anchor UUID has a row in `anchor_metadata`.
    /// Used by `AnchorEventStream.anchorMetadataQuery` to discriminate `.new` from `.rerecognized`.
    ///
    /// Non-throwing by contract (the caller is a synchronous closure injected into `AnchorEventStream`).
    /// On DB error, logs the failure and defaults to `false` — the error case causes `.new` to fire
    /// instead of `.rerecognized`, which is the safer fallback (no data loss, just a redundant announce).
    public func hasAnchorMetadata(anchorId: UUID) -> Bool {
        do {
            return try dbQueue.read { db in
                try AnchorMetadataRecord.filter(
                    Column("anchorId") == anchorId.uuidString
                ).fetchCount(db) > 0
            }
        } catch {
            log.error(
                "store.query.anchorMetadata.error",
                metadata: [
                    "anchorId": .string(PrivacyFilter.hashAnchorId(anchorId)),
                    "error": .string("\(error)"),
                ]
            )
            return false
        }
    }

    // MARK: - Private Helpers

    private func anchorVisitCount(anchorId: UUID) throws -> Int? {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT visitCount FROM anchor_metadata WHERE anchorId = ?",
                arguments: [anchorId.uuidString]
            )
        }
    }

    /// Reads annotations for an anchor without mutating `spatialHash`.
    /// Used by `write()` on the merge-candidate lookup path to keep bulk ingestion O(N)
    /// instead of O(N²) from redundant hash re-indexing.
    private func fetchAnnotationsForMerge(worldAnchorId: UUID) throws -> [WorldAnnotation] {
        let records = try dbQueue.read { db in
            try WorldAnnotationRecord.filter(
                Column("worldAnchorId") == worldAnchorId.uuidString
            ).fetchAll(db)
        }
        return records.compactMap { $0.toAnnotation() }
    }

    private func rebuildSpatialHash() throws {
        let records = try dbQueue.read { db in
            try WorldAnnotationRecord.fetchAll(db)
        }
        var fresh = SpatialHash()
        for record in records {
            let pos = SIMD3<Float>(record.posX, record.posY, record.posZ)
            if let uuid = UUID(uuidString: record.id) {
                fresh.insert(id: uuid, position: pos)
            }
        }
        spatialHash = fresh
    }
}
