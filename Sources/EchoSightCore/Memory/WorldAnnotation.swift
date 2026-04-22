import Foundation
import simd
import GRDB

// MARK: - WorldAnnotation

/// A persisted observation of a real-world object, keyed by ARKit world anchor UUID.
///
/// Each annotation represents one fused detection that survived the 30 cm merge threshold.
/// The spatial position is stored in world space (ARKit coordinate system).
///
/// GRDB persistence: table `world_annotations`, primary key `id` (UUID text),
/// indexed on `worldAnchorId` for anchor-scoped bulk loads.
public struct WorldAnnotation: Sendable {

    // MARK: - Properties

    /// Stable primary key. Generated at write time, never changes after insert.
    public let id: UUID

    /// World-space position of the annotated object (meters, ARKit coordinate system).
    public let worldPosition: SIMD3<Float>

    /// ARKit persistent world anchor this annotation is attached to.
    public let worldAnchorId: UUID

    /// The reconciled object label produced by the detector/fusion pipeline.
    public let falconLabel: String

    /// Dominant mesh classification for the surface at this position.
    public let meshClassification: String

    /// Fused confidence in range 0.0–1.0.
    public let confidence: Float

    /// Optional free-text description produced by Gemma enrichment.
    /// `nil` until enrichment completes.
    public var description: String?

    /// When this annotation was first written.
    public let createdAt: Date

    /// When this annotation was last observed (updated on merge).
    public var lastSeenAt: Date

    /// Number of times this annotation was confirmed by subsequent captures.
    /// Starts at 1; incremented on merge.
    public var captureCount: Int

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        worldPosition: SIMD3<Float>,
        worldAnchorId: UUID,
        falconLabel: String,
        meshClassification: String,
        confidence: Float,
        description: String? = nil,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        captureCount: Int = 1
    ) {
        self.id = id
        self.worldPosition = worldPosition
        self.worldAnchorId = worldAnchorId
        self.falconLabel = falconLabel
        self.meshClassification = meshClassification
        self.confidence = confidence
        self.description = description
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.captureCount = captureCount
    }
}

// MARK: - GRDB Persistence

/// GRDB record wrapper — bridges the SIMD3<Float> world-position to three Float columns.
struct WorldAnnotationRecord: Codable, FetchableRecord, PersistableRecord {

    static let databaseTableName = "world_annotations"

    var id: String
    var posX: Float
    var posY: Float
    var posZ: Float
    var worldAnchorId: String
    var falconLabel: String
    var meshClassification: String
    var confidence: Float
    var description: String?
    var createdAt: Date
    var lastSeenAt: Date
    var captureCount: Int

    init(from annotation: WorldAnnotation) {
        id = annotation.id.uuidString
        posX = annotation.worldPosition.x
        posY = annotation.worldPosition.y
        posZ = annotation.worldPosition.z
        worldAnchorId = annotation.worldAnchorId.uuidString
        falconLabel = annotation.falconLabel
        meshClassification = annotation.meshClassification
        confidence = annotation.confidence
        description = annotation.description
        createdAt = annotation.createdAt
        lastSeenAt = annotation.lastSeenAt
        captureCount = annotation.captureCount
    }

    func toAnnotation() -> WorldAnnotation? {
        guard let idUUID = UUID(uuidString: id),
              let anchorUUID = UUID(uuidString: worldAnchorId) else { return nil }
        return WorldAnnotation(
            id: idUUID,
            worldPosition: SIMD3<Float>(posX, posY, posZ),
            worldAnchorId: anchorUUID,
            falconLabel: falconLabel,
            meshClassification: meshClassification,
            confidence: confidence,
            description: description,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            captureCount: captureCount
        )
    }
}
