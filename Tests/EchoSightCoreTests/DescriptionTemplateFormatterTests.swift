import Testing
import simd
@testable import EchoSightCore

// MARK: - DescriptionTemplateFormatterTests

@Suite("DescriptionTemplateFormatter")
struct DescriptionTemplateFormatterTests {

    // MARK: - Helpers

    private func makeCandidate(
        label: String,
        confidence: Float = 0.9,
        worldPosition: SIMD3<Float>,
        distance: Float
    ) -> ScoredCandidate {
        let candidate = AnnotationCandidate(
            label: label,
            confidence: confidence,
            worldPosition: worldPosition,
            distance: distance,
            outcome: .normal
        )
        return ScoredCandidate(candidate: candidate, score: confidence / max(distance, 0.5))
    }

    // MARK: - Empty Candidates

    @Test("empty candidates returns fallback phrase")
    func emptyFallback() {
        let result = DescriptionTemplateFormatter.format(candidates: [])
        #expect(result == "I don't detect anything in front of you")
    }

    // MARK: - Single Candidate Phrases

    @Test("ahead direction for object at negative Z")
    func aheadDirection() {
        // Object directly in front: X≈0, Z negative
        let scored = makeCandidate(
            label: "chair",
            worldPosition: SIMD3<Float>(0, 0, -3),
            distance: 3.0
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase == "chair 3 metres ahead")
    }

    @Test("right direction for object at positive X")
    func rightDirection() {
        let scored = makeCandidate(
            label: "door",
            worldPosition: SIMD3<Float>(3, 0, -1),
            distance: 3.16
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase.contains("to the right"))
    }

    @Test("left direction for object at negative X")
    func leftDirection() {
        let scored = makeCandidate(
            label: "window",
            worldPosition: SIMD3<Float>(-3, 0, -1),
            distance: 3.16
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase.contains("to the left"))
    }

    @Test("behind direction for object at positive Z")
    func behindDirection() {
        let scored = makeCandidate(
            label: "person",
            worldPosition: SIMD3<Float>(0, 0, 5),
            distance: 5.0
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase.contains("behind you"))
    }

    // MARK: - Distance Rounding

    @Test("distance below 0.5 m rounds up to 0.5 m")
    func distanceClamp() {
        let scored = makeCandidate(
            label: "object",
            worldPosition: SIMD3<Float>(0, 0, -0.2),
            distance: 0.2
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase.contains("0.5 metre"))
    }

    @Test("distance 1.0 m uses singular")
    func distanceSingular() {
        let scored = makeCandidate(
            label: "table",
            worldPosition: SIMD3<Float>(0, 0, -1.0),
            distance: 1.0
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase.contains("1 metre"))
        #expect(!phrase.contains("metres"))
    }

    @Test("distance 2.0 m uses plural")
    func distancePlural() {
        let scored = makeCandidate(
            label: "chair",
            worldPosition: SIMD3<Float>(0, 0, -2.0),
            distance: 2.0
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase.contains("2 metres"))
    }

    @Test("distance 2.3 m rounds to 2.5 m")
    func distanceRoundsToHalf() {
        let scored = makeCandidate(
            label: "table",
            worldPosition: SIMD3<Float>(0, 0, -2.3),
            distance: 2.3
        )
        let phrase = DescriptionTemplateFormatter.phrase(for: scored)
        #expect(phrase.contains("2.5 metres"))
    }

    // MARK: - Multi-Candidate

    @Test("multiple candidates joined with comma-space")
    func multipleCandidates() {
        let c1 = makeCandidate(
            label: "chair",
            worldPosition: SIMD3<Float>(0, 0, -2),
            distance: 2.0
        )
        let c2 = makeCandidate(
            label: "door",
            worldPosition: SIMD3<Float>(3, 0, -2),
            distance: 3.6
        )
        let result = DescriptionTemplateFormatter.format(candidates: [c1, c2])
        #expect(result.contains("chair"))
        #expect(result.contains("door"))
        #expect(result.contains(", "))
    }
}
