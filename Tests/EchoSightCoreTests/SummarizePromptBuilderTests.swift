import Testing
import Foundation
import simd
@testable import EchoSightCore

// MARK: - SummarizePromptBuilderTests

@Suite("SummarizePromptBuilder")
struct SummarizePromptBuilderTests {

    func makeAnnotation(
        label: String,
        position: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
    ) -> WorldAnnotation {
        WorldAnnotation(
            worldPosition: position,
            worldAnchorId: UUID(),
            falconLabel: label,
            meshClassification: "floor",
            confidence: 0.8
        )
    }

    @Test("prompt mentions object labels")
    func includesLabels() {
        let annotations = [
            makeAnnotation(label: "sofa", position: SIMD3<Float>(2, 0, 0)),
            makeAnnotation(label: "plant", position: SIMD3<Float>(-1, 0, 1)),
        ]
        let prompt = SummarizePromptBuilder.buildPrompt(from: annotations)
        #expect(prompt.contains("sofa"))
        #expect(prompt.contains("plant"))
    }

    @Test("prompt for empty annotations mentions no objects")
    func emptyAnnotations() {
        let prompt = SummarizePromptBuilder.buildPrompt(from: [])
        #expect(!prompt.isEmpty)
        #expect(prompt.contains("no remembered objects"))
    }

    @Test("prompt truncates to 8 annotations max")
    func truncatesTo8() {
        let annotations = (0..<20).map { i in
            makeAnnotation(label: "obj\(i)", position: SIMD3<Float>(Float(i), 0, 0))
        }
        let prompt = SummarizePromptBuilder.buildPrompt(from: annotations)
        // obj8 through obj19 should not appear — only first 8 taken
        #expect(!prompt.contains("obj8"))
        #expect(!prompt.contains("obj19"))
    }

    @Test("prompt includes direction hints")
    func includesDirectionHints() {
        let ahead = makeAnnotation(label: "door", position: SIMD3<Float>(0, 0, -3))
        let right = makeAnnotation(label: "window", position: SIMD3<Float>(3, 0, 0))
        let prompt = SummarizePromptBuilder.buildPrompt(from: [ahead, right])
        #expect(prompt.contains("ahead") || prompt.contains("right") || prompt.contains("nearby"))
    }
}
