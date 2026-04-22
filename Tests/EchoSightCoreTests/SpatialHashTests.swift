import Testing
import Foundation
import simd
@testable import EchoSightCore

// MARK: - SpatialHashTests

@Suite("SpatialHash")
struct SpatialHashTests {

    // MARK: - Insert / Count

    @Test("insert increments count")
    func insertCount() {
        var hash = SpatialHash()
        let id = UUID()
        hash.insert(id: id, position: SIMD3<Float>(0, 0, 0))
        #expect(hash.count == 1)
    }

    @Test("duplicate insert is idempotent")
    func duplicateInsert() {
        var hash = SpatialHash()
        let id = UUID()
        hash.insert(id: id, position: SIMD3<Float>(0, 0, 0))
        hash.insert(id: id, position: SIMD3<Float>(0, 0, 0))
        #expect(hash.count == 1)
    }

    @Test("remove decrements count")
    func removeCount() {
        var hash = SpatialHash()
        let id = UUID()
        hash.insert(id: id, position: SIMD3<Float>(0, 0, 0))
        hash.remove(id: id)
        #expect(hash.count == 0)
    }

    @Test("remove unknown id is no-op")
    func removeUnknown() {
        var hash = SpatialHash()
        hash.remove(id: UUID())  // should not crash
        #expect(hash.count == 0)
    }

    // MARK: - Query Correctness

    @Test("candidateIds includes nearby annotation")
    func includesNearby() {
        var hash = SpatialHash()
        let id = UUID()
        hash.insert(id: id, position: SIMD3<Float>(0.5, 0, 0))
        let candidates = hash.candidateIds(near: SIMD3<Float>(0, 0, 0), radius: 2.0)
        #expect(candidates.contains(id))
    }

    @Test("candidateIds excludes far annotation")
    func excludesFar() {
        var hash = SpatialHash()
        let id = UUID()
        hash.insert(id: id, position: SIMD3<Float>(100, 0, 0))
        let candidates = hash.candidateIds(near: SIMD3<Float>(0, 0, 0), radius: 5.0)
        #expect(!candidates.contains(id))
    }

    @Test("candidateIds radius=0 returns same-cell items")
    func radiusZero() {
        var hash = SpatialHash()
        let id = UUID()
        hash.insert(id: id, position: SIMD3<Float>(0, 0, 0))
        let candidates = hash.candidateIds(near: SIMD3<Float>(0.1, 0, 0), radius: 0)
        #expect(candidates.contains(id))
    }

    @Test("candidateIds returns all items in sphere")
    func returnsAllInSphere() {
        var hash = SpatialHash()
        var ids: [UUID] = []
        // Place 10 annotations within 4 m radius
        for i in 0..<10 {
            let id = UUID()
            ids.append(id)
            hash.insert(id: id, position: SIMD3<Float>(Float(i) * 0.3, 0, 0))
        }
        let candidates = hash.candidateIds(near: SIMD3<Float>(0, 0, 0), radius: 5.0)
        for id in ids {
            #expect(candidates.contains(id))
        }
    }

    // MARK: - Cell Boundary

    @Test("annotations on different sides of a cell boundary are in adjacent cells")
    func cellBoundary() {
        var hash = SpatialHash()
        let a = UUID()
        let b = UUID()
        // Place at x=0.99 (cell 0) and x=1.01 (cell 1)
        hash.insert(id: a, position: SIMD3<Float>(0.99, 0, 0))
        hash.insert(id: b, position: SIMD3<Float>(1.01, 0, 0))
        // Query at x=1.0 with radius 1.5 — should catch both
        let candidates = hash.candidateIds(near: SIMD3<Float>(1.0, 0, 0), radius: 1.5)
        #expect(candidates.contains(a))
        #expect(candidates.contains(b))
    }

    // MARK: - Update

    @Test("update moves annotation to new cell")
    func updateMovesCell() {
        var hash = SpatialHash()
        let id = UUID()
        hash.insert(id: id, position: SIMD3<Float>(0, 0, 0))
        hash.update(id: id, position: SIMD3<Float>(100, 0, 0))

        let nearOrigin = hash.candidateIds(near: SIMD3<Float>(0, 0, 0), radius: 1.0)
        let nearFar = hash.candidateIds(near: SIMD3<Float>(100, 0, 0), radius: 1.0)

        #expect(!nearOrigin.contains(id))
        #expect(nearFar.contains(id))
    }

    // MARK: - Snapshot Immutability (value type)

    @Test("copy of SpatialHash is independent snapshot")
    func snapshotImmutability() {
        var original = SpatialHash()
        let id = UUID()
        original.insert(id: id, position: SIMD3<Float>(0, 0, 0))

        var copy = original  // value copy
        copy.remove(id: id)

        // original still has the id
        let candidates = original.candidateIds(near: SIMD3<Float>(0, 0, 0), radius: 1.0)
        #expect(candidates.contains(id))
        #expect(original.count == 1)
        #expect(copy.count == 0)
    }
}
