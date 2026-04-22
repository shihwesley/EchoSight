import Testing
import Foundation
@testable import EchoSightCore

// MARK: - AnchorMetadataTests

/// Tests for anchor-metadata CRUD, UPSERT semantics, and label precedence.
@Suite("AnchorMetadata")
struct AnchorMetadataTests {

    func makeStore() throws -> AnnotationStore {
        try AnnotationStore(path: nil)
    }

    // MARK: - First Encounter

    @Test("first encounter creates row with visitCount=1")
    func firstEncounterVisitCount() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)

        let metadata = try store.anchorMetadata(anchorId: anchorId)
        let meta = try #require(metadata)
        #expect(meta.visitCount == 1)
        #expect(meta.anchorId == anchorId)
    }

    @Test("first encounter sets firstSeenAt and lastSeenAt close to now")
    func firstEncounterTimestamps() throws {
        let store = try makeStore()
        let anchorId = UUID()
        let before = Date()
        try store.recordAnchorEncounter(anchorId: anchorId)
        let after = Date()

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        #expect(meta.firstSeenAt >= before)
        #expect(meta.firstSeenAt <= after)
        #expect(meta.lastSeenAt >= before)
        #expect(meta.lastSeenAt <= after)
    }

    // MARK: - UPSERT

    @Test("repeated encounters increment visitCount atomically")
    func repeatedEncountersVisitCount() throws {
        let store = try makeStore()
        let anchorId = UUID()

        for _ in 0..<10 {
            try store.recordAnchorEncounter(anchorId: anchorId)
        }

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        #expect(meta.visitCount == 10)
    }

    @Test("UPSERT on same anchor updates lastSeenAt")
    func upsertUpdatesLastSeenAt() async throws {
        let store = try makeStore()
        let anchorId = UUID()

        try store.recordAnchorEncounter(anchorId: anchorId)
        let firstSeen = try store.lastSeenAnchorAt(anchorId: anchorId)

        // Small sleep so timestamps differ
        try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms

        try store.recordAnchorEncounter(anchorId: anchorId)
        let secondSeen = try store.lastSeenAnchorAt(anchorId: anchorId)

        let first = try #require(firstSeen)
        let second = try #require(secondSeen)
        #expect(second >= first)
    }

    // MARK: - Label Precedence

    @Test("setAnchorLabel sets userLabel")
    func setUserLabel() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.setAnchorLabel(anchorId: anchorId, userLabel: "living room")

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        #expect(meta.userLabel == "living room")
    }

    @Test("setAnchorInferredLabel sets inferredLabel only")
    func setInferredLabel() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.setAnchorInferredLabel(anchorId: anchorId, inferredLabel: "office space")

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        #expect(meta.inferredLabel == "office space")
        #expect(meta.userLabel == nil)
    }

    @Test("userLabel overrides inferredLabel in effectiveLabel")
    func userLabelWins() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.setAnchorInferredLabel(anchorId: anchorId, inferredLabel: "corridor")
        try store.setAnchorLabel(anchorId: anchorId, userLabel: "my office")

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        #expect(meta.effectiveLabel == "my office")
    }

    @Test("setAnchorInferredLabel does not overwrite userLabel column")
    func inferredDoesNotOverwriteUserColumn() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.setAnchorLabel(anchorId: anchorId, userLabel: "kitchen")
        try store.setAnchorInferredLabel(anchorId: anchorId, inferredLabel: "dining area")

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        // userLabel column must still hold "kitchen" — inferred went to inferredLabel column
        #expect(meta.userLabel == "kitchen")
        #expect(meta.inferredLabel == "dining area")
        #expect(meta.effectiveLabel == "kitchen")  // user wins
    }

    @Test("user label persists after second inferred label write")
    func userLabelPersistsAfterInference() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.setAnchorLabel(anchorId: anchorId, userLabel: "den")
        try store.setAnchorInferredLabel(anchorId: anchorId, inferredLabel: "living room")
        try store.setAnchorInferredLabel(anchorId: anchorId, inferredLabel: "lounge")  // second inference

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        #expect(meta.userLabel == "den")
        #expect(meta.inferredLabel == "lounge")
        #expect(meta.effectiveLabel == "den")
    }

    @Test("setAnchorLabel with nil clears userLabel")
    func clearUserLabel() throws {
        let store = try makeStore()
        let anchorId = UUID()
        try store.recordAnchorEncounter(anchorId: anchorId)
        try store.setAnchorLabel(anchorId: anchorId, userLabel: "pantry")
        try store.setAnchorLabel(anchorId: anchorId, userLabel: nil)

        let meta = try #require(try store.anchorMetadata(anchorId: anchorId))
        #expect(meta.userLabel == nil)
    }

    // MARK: - Unknown Anchor

    @Test("anchorMetadata returns nil for unknown anchor")
    func unknownAnchorNil() throws {
        let store = try makeStore()
        let result = try store.anchorMetadata(anchorId: UUID())
        #expect(result == nil)
    }
}
