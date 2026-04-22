import Testing
import Foundation
import simd
@testable import EchoSightCore

// MARK: - AnnotationMergerTests

@Suite("AnnotationMerger")
struct AnnotationMergerTests {

    let anchorId = UUID()

    func makeAnnotation(
        position: SIMD3<Float>,
        label: String = "chair",
        confidence: Float = 0.8,
        captureCount: Int = 1,
        description: String? = nil
    ) -> WorldAnnotation {
        WorldAnnotation(
            worldPosition: position,
            worldAnchorId: anchorId,
            falconLabel: label,
            meshClassification: "floor",
            confidence: confidence,
            description: description,
            captureCount: captureCount
        )
    }

    // MARK: - findMergeCandidate

    @Test("no candidate when existing list is empty")
    func noCandidateEmpty() {
        let incoming = makeAnnotation(position: SIMD3<Float>(0, 0, 0))
        let result = AnnotationMerger.findMergeCandidate(in: [], for: incoming)
        #expect(result == nil)
    }

    @Test("finds candidate within 30 cm")
    func findsWithin30cm() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0))
        let incoming = makeAnnotation(position: SIMD3<Float>(0.20, 0, 0))  // 20 cm
        let result = AnnotationMerger.findMergeCandidate(in: [existing], for: incoming)
        #expect(result?.id == existing.id)
    }

    @Test("no candidate when only annotation is exactly at 30 cm threshold")
    func atExactThreshold() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0))
        let incoming = makeAnnotation(position: SIMD3<Float>(0.30, 0, 0))  // exactly 30 cm
        // Spec: < radius (strict less-than) — 30 cm does NOT merge
        let result = AnnotationMerger.findMergeCandidate(in: [existing], for: incoming)
        #expect(result == nil)
    }

    @Test("no candidate when annotation is beyond 30 cm")
    func beyondThreshold() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0))
        let incoming = makeAnnotation(position: SIMD3<Float>(0.50, 0, 0))  // 50 cm
        let result = AnnotationMerger.findMergeCandidate(in: [existing], for: incoming)
        #expect(result == nil)
    }

    @Test("picks nearest when multiple candidates qualify")
    func picksNearest() {
        let closer = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0), label: "closer")
        let further = makeAnnotation(position: SIMD3<Float>(0.25, 0, 0), label: "further")
        let incoming = makeAnnotation(position: SIMD3<Float>(0, 0, 0))
        let result = AnnotationMerger.findMergeCandidate(in: [closer, further], for: incoming)
        #expect(result?.falconLabel == "closer")
    }

    @Test("different labels do not prevent merge within threshold")
    func differentLabelsStillMerge() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0), label: "sofa")
        let incoming = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0), label: "couch")
        let result = AnnotationMerger.findMergeCandidate(in: [existing], for: incoming)
        #expect(result != nil)
    }

    // MARK: - merge

    @Test("merge increments captureCount")
    func mergeIncrementsCaptureCount() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0), captureCount: 3)
        let incoming = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0))
        let merged = AnnotationMerger.merge(existing: existing, incoming: incoming)
        #expect(merged.captureCount == 4)
    }

    @Test("merge preserves existing id and worldPosition")
    func mergePreservesId() {
        let existing = makeAnnotation(position: SIMD3<Float>(1, 2, 3))
        let incoming = makeAnnotation(position: SIMD3<Float>(1.10, 2, 3))
        let merged = AnnotationMerger.merge(existing: existing, incoming: incoming)
        #expect(merged.id == existing.id)
        #expect(abs(merged.worldPosition.x - 1.0) < 0.0001)
    }

    @Test("merge takes higher confidence label — incoming wins")
    func mergeHigherConfidenceIncoming() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0), label: "sofa", confidence: 0.6)
        let incoming = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0), label: "couch", confidence: 0.9)
        let merged = AnnotationMerger.merge(existing: existing, incoming: incoming)
        #expect(merged.falconLabel == "couch")
        #expect(abs(merged.confidence - 0.9) < 0.0001)
    }

    @Test("merge takes higher confidence label — existing wins")
    func mergeHigherConfidenceExisting() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0), label: "sofa", confidence: 0.95)
        let incoming = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0), label: "couch", confidence: 0.5)
        let merged = AnnotationMerger.merge(existing: existing, incoming: incoming)
        #expect(merged.falconLabel == "sofa")
        #expect(abs(merged.confidence - 0.95) < 0.0001)
    }

    @Test("merge preserves existing description when present")
    func mergePreservesExistingDescription() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0), description: "A plush blue sofa.")
        let incoming = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0), description: "Some furniture.")
        let merged = AnnotationMerger.merge(existing: existing, incoming: incoming)
        #expect(merged.description == "A plush blue sofa.")
    }

    @Test("merge takes incoming description when existing has none")
    func mergeTakesIncomingDescription() {
        let existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0), description: nil)
        let incoming = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0), description: "Some furniture.")
        let merged = AnnotationMerger.merge(existing: existing, incoming: incoming)
        #expect(merged.description == "Some furniture.")
    }

    @Test("merge updates lastSeenAt from incoming")
    func mergeUpdatesLastSeenAt() {
        let past = Date(timeIntervalSinceNow: -3600)
        let now = Date()

        var existing = makeAnnotation(position: SIMD3<Float>(0, 0, 0))
        existing = WorldAnnotation(
            id: existing.id,
            worldPosition: existing.worldPosition,
            worldAnchorId: existing.worldAnchorId,
            falconLabel: existing.falconLabel,
            meshClassification: existing.meshClassification,
            confidence: existing.confidence,
            description: existing.description,
            createdAt: past,
            lastSeenAt: past,
            captureCount: 1
        )

        var incoming = makeAnnotation(position: SIMD3<Float>(0.10, 0, 0))
        incoming = WorldAnnotation(
            id: incoming.id,
            worldPosition: incoming.worldPosition,
            worldAnchorId: incoming.worldAnchorId,
            falconLabel: incoming.falconLabel,
            meshClassification: incoming.meshClassification,
            confidence: incoming.confidence,
            description: incoming.description,
            createdAt: now,
            lastSeenAt: now,
            captureCount: 1
        )

        let merged = AnnotationMerger.merge(existing: existing, incoming: incoming)
        #expect(merged.lastSeenAt >= now.addingTimeInterval(-1))
    }
}
