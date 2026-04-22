import Testing
import Foundation
@testable import EchoSightCore

// MARK: - EnrichmentPromptBuilderTests

@Suite("EnrichmentPromptBuilder")
struct EnrichmentPromptBuilderTests {

    @Test("prompt includes detection labels")
    func includesLabels() {
        let context = EnrichmentContext(
            detections: ["chair", "table"],
            distances: [1.5, 2.3],
            classifications: ["floor", "floor"]
        )
        let prompt = EnrichmentPromptBuilder.buildPrompt(from: context)
        #expect(prompt.contains("chair"))
        #expect(prompt.contains("table"))
    }

    @Test("prompt includes distances")
    func includesDistances() {
        let context = EnrichmentContext(
            detections: ["lamp"],
            distances: [3.2],
            classifications: ["wall"]
        )
        let prompt = EnrichmentPromptBuilder.buildPrompt(from: context)
        #expect(prompt.contains("3.2m"))
    }

    @Test("prompt includes mesh classification")
    func includesClassification() {
        let context = EnrichmentContext(
            detections: ["book"],
            distances: [0.5],
            classifications: ["table"]
        )
        let prompt = EnrichmentPromptBuilder.buildPrompt(from: context)
        #expect(prompt.contains("table"))
    }

    @Test("prompt handles mismatched array lengths gracefully")
    func mismatchedArrays() {
        let context = EnrichmentContext(
            detections: ["sofa", "plant"],
            distances: [2.0],        // only 1 distance for 2 detections
            classifications: []       // no classifications
        )
        let prompt = EnrichmentPromptBuilder.buildPrompt(from: context)
        #expect(prompt.contains("sofa"))
        #expect(prompt.contains("plant"))
        // Should not crash; uses "unknown" for missing entries
        #expect(prompt.contains("unknown"))
    }

    @Test("prompt is non-empty for empty context")
    func emptyContext() {
        let context = EnrichmentContext(detections: [], distances: [], classifications: [])
        let prompt = EnrichmentPromptBuilder.buildPrompt(from: context)
        #expect(!prompt.isEmpty)
    }
}
