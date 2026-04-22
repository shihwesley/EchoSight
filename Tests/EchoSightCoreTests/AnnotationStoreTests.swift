import Testing
import Foundation
import simd
@testable import EchoSightCore

// MARK: - AnnotationStoreTests

/// Tests for CRUD operations, SQLite round-trip, and anchor-metadata API.
/// Uses in-memory database (nil path) so no filesystem state leaks between tests.
@Suite("AnnotationStore")
struct AnnotationStoreTests {

    // MARK: - Helpers

    func makeStore() throws -> AnnotationStore {
        try AnnotationStore(path: nil)
    }

    func makeAnnotation(
        anchorId: UUID = UUID(),
        position: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        label: String = "chair",
        confidence: Float = 0.9
    ) -> WorldAnnotation {
        WorldAnnotation(
            worldPosition: position,
            worldAnchorId: anchorId,
            falconLabel: label,
            meshClassification: "table",
            confidence: confidence
        )
    }

    // MARK: - Round-Trip

    @Test("write then load returns same annotation")
    func roundTrip() throws {
        let store = try makeStore()
        let anchorId = UUID()
        let annotation = makeAnnotation(anchorId: anchorId, position: SIMD3<Float>(1, 2, 3))

        try store.write(annotation: annotation)

        let loaded = try store.load(worldAnchorId: anchorId)
        #expect(loaded.count == 1)
        let retrieved = try #require(loaded.first)
        #expect(retrieved.id == annotation.id)
        #expect(retrieved.falconLabel == "chair")
        #expect(abs(retrieved.worldPosition.x - 1.0) < 0.0001)
        #expect(abs(retrieved.worldPosition.y - 2.0) < 0.0001)
        #expect(abs(retrieved.worldPosition.z - 3.0) < 0.0001)
    }

    @Test("description update write-back")
    func descriptionUpdateWriteBack() throws {
        let store = try makeStore()
        let anchorId = UUID()
        let annotation = makeAnnotation(anchorId: anchorId)

        try store.write(annotation: annotation)
        try store.updateDescription(id: annotation.id, description: "A red wooden chair near the window.")

        let loaded = try store.load(worldAnchorId: anchorId)
        #expect(loaded.first?.description == "A red wooden chair near the window.")
    }

    @Test("load unknown anchor returns empty array")
    func loadUnknownAnchor() throws {
        let store = try makeStore()
        let result = try store.load(worldAnchorId: UUID())
        #expect(result.isEmpty)
    }

    @Test("multiple annotations per anchor")
    func multipleAnnotationsPerAnchor() throws {
        let store = try makeStore()
        let anchorId = UUID()

        for i in 0..<5 {
            let annotation = WorldAnnotation(
                worldPosition: SIMD3<Float>(Float(i) * 2, 0, 0),  // >30 cm apart; no merge
                worldAnchorId: anchorId,
                falconLabel: "item\(i)",
                meshClassification: "floor",
                confidence: 0.8
            )
            try store.write(annotation: annotation)
        }

        let loaded = try store.load(worldAnchorId: anchorId)
        #expect(loaded.count == 5)
    }

    // MARK: - Anchor Metadata

    @Test("recordAnchorEncounter creates row on first call")
    func firstEncounterCreatesRow() throws {
        let store = try makeStore()
        let anchorId = UUID()

        try store.recordAnchorEncounter(anchorId: anchorId)

        let date = try store.lastSeenAnchorAt(anchorId: anchorId)
        #expect(date != nil)
    }

    @Test("recordAnchorEncounter increments visitCount")
    func incrementsVisitCount() throws {
        let store = try makeStore()
        let anchorId = UUID()

        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.recordAnchorEncounter(anchorId: anchorId)

        let metadata = try store.anchorMetadata(anchorId: anchorId)
        #expect(metadata?.visitCount == 3)
    }

    @Test("lastSeenAnchorAt returns nil for unknown anchor")
    func lastSeenNilForUnknown() throws {
        let store = try makeStore()
        let result = try store.lastSeenAnchorAt(anchorId: UUID())
        #expect(result == nil)
    }

    @Test("annotationCount returns 0 for empty anchor")
    func annotationCountZero() throws {
        let store = try makeStore()
        let count = try store.annotationCount(anchorId: UUID())
        #expect(count == 0)
    }

    @Test("annotationCount returns correct count")
    func annotationCountCorrect() throws {
        let store = try makeStore()
        let anchorId = UUID()

        for i in 0..<7 {
            let a = WorldAnnotation(
                worldPosition: SIMD3<Float>(Float(i) * 2, 0, 0),
                worldAnchorId: anchorId,
                falconLabel: "obj",
                meshClassification: "wall",
                confidence: 0.7
            )
            try store.write(annotation: a)
        }

        let count = try store.annotationCount(anchorId: anchorId)
        #expect(count == 7)
    }

    @Test("hasAnchorMetadata returns false before first encounter")
    func hasMetadataBefore() throws {
        let store = try makeStore()
        #expect(store.hasAnchorMetadata(anchorId: UUID()) == false)
    }

    @Test("hasAnchorMetadata returns true after encounter")
    func hasMetadataAfter() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)
        #expect(store.hasAnchorMetadata(anchorId: anchorId) == true)
    }

    // MARK: - Nearest Annotations

    @Test("nearestAnnotations returns empty when hash empty")
    func nearestEmpty() throws {
        let store = try makeStore()
        let result = try store.nearestAnnotations(to: SIMD3<Float>(0, 0, 0), radius: 5.0)
        #expect(result.isEmpty)
    }

    @Test("nearestAnnotations filters by radius")
    func nearestFiltersByRadius() throws {
        let store = try makeStore()
        let anchorId = UUID()

        // Within 5 m
        let near = makeAnnotation(anchorId: anchorId, position: SIMD3<Float>(2, 0, 0))
        // Outside 5 m
        let far = makeAnnotation(anchorId: UUID(), position: SIMD3<Float>(10, 0, 0))

        try store.write(annotation: near)
        try store.write(annotation: far)

        let results = try store.nearestAnnotations(to: SIMD3<Float>(0, 0, 0), radius: 5.0)
        #expect(results.count == 1)
        #expect(results.first?.id == near.id)
    }
}
