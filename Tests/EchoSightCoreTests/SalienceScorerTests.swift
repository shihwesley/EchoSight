import Testing
import simd
@testable import EchoSightCore

// MARK: - SalienceScorerTests

@Suite("SalienceScorer")
struct SalienceScorerTests {

    // MARK: - Helpers

    private func makeCandidate(
        label: String = "object",
        confidence: Float,
        distance: Float,
        worldPosition: SIMD3<Float> = SIMD3<Float>(0, 0, -3)
    ) -> AnnotationCandidate {
        AnnotationCandidate(
            label: label,
            confidence: confidence,
            worldPosition: worldPosition,
            distance: distance,
            outcome: .normal
        )
    }

    // MARK: - Ranking

    @Test("higher confidence + closer → higher score")
    func highConfidenceCloseRanksFirst() {
        let near = makeCandidate(label: "near", confidence: 0.9, distance: 1.0)
        let far = makeCandidate(label: "far", confidence: 0.5, distance: 5.0)

        let ranked = SalienceScorer.topN(from: [far, near])
        #expect(ranked.first?.candidate.label == "near")
    }

    @Test("topN limits results")
    func topNLimitsResults() {
        let candidates = (0..<10).map { i in
            makeCandidate(label: "obj\(i)", confidence: Float(i) / 10.0, distance: 2.0)
        }
        let ranked = SalienceScorer.topN(from: candidates, topN: 3)
        #expect(ranked.count == 3)
    }

    @Test("empty candidates returns empty")
    func emptyCandidates() {
        let ranked = SalienceScorer.topN(from: [])
        #expect(ranked.isEmpty)
    }

    @Test("tiebreaker preserves insertion order")
    func tiebreakerInsertionOrder() {
        // Same confidence, same distance → same score → insertion order wins.
        let a = makeCandidate(label: "first", confidence: 0.8, distance: 2.0)
        let b = makeCandidate(label: "second", confidence: 0.8, distance: 2.0)

        let ranked = SalienceScorer.topN(from: [a, b])
        // sorted is stable in Swift — insertion order preserved on equal scores.
        #expect(ranked.first?.candidate.label == "first")
    }

    @Test("distance clamped to 0.5 m minimum prevents infinity")
    func distanceClampPreventsInfinity() {
        let tooClose = makeCandidate(confidence: 0.9, distance: 0.1)
        let ranked = SalienceScorer.topN(from: [tooClose])
        #expect(ranked.first != nil)
        #expect(ranked.first!.score.isFinite)
    }
}
