import Testing
import Foundation
import simd
@testable import EchoSightCore

// MARK: - RoomLabelPromptBuilderTests

@Suite("RoomLabelPromptBuilder")
struct RoomLabelPromptBuilderTests {

    func makeMeshSummary(dominant: MeshClassificationSummary.MeshClass) -> MeshClassificationSummary {
        MeshClassificationSummary(
            distribution: [dominant: 0.7, .wall: 0.2, .unknown: 0.1],
            confidence: 0.85,
            triangleCount: 1200
        )
    }

    func makeAnnotation(label: String) -> WorldAnnotation {
        WorldAnnotation(
            worldPosition: SIMD3<Float>(1, 0, 0),
            worldAnchorId: UUID(),
            falconLabel: label,
            meshClassification: "floor",
            confidence: 0.8
        )
    }

    @Test("prompt includes dominant mesh class")
    func includesDominantClass() {
        let mesh = makeMeshSummary(dominant: .floor)
        let prompt = RoomLabelPromptBuilder.buildPrompt(
            anchorId: UUID(),
            annotations: [],
            meshClassification: mesh
        )
        #expect(prompt.contains("floor"))
    }

    @Test("prompt includes annotation labels")
    func includesAnnotationLabels() {
        let mesh = makeMeshSummary(dominant: .table)
        let annotations = [makeAnnotation(label: "monitor"), makeAnnotation(label: "keyboard")]
        let prompt = RoomLabelPromptBuilder.buildPrompt(
            anchorId: UUID(),
            annotations: annotations,
            meshClassification: mesh
        )
        #expect(prompt.contains("monitor"))
        #expect(prompt.contains("keyboard"))
    }

    @Test("prompt with no annotations uses 'none' placeholder")
    func emptyAnnotations() {
        let mesh = makeMeshSummary(dominant: .seat)
        let prompt = RoomLabelPromptBuilder.buildPrompt(
            anchorId: UUID(),
            annotations: [],
            meshClassification: mesh
        )
        #expect(prompt.contains("none"))
    }

    @Test("prompt is non-empty for sparse mesh")
    func sparseMesh() {
        let mesh = MeshClassificationSummary(
            distribution: [:],
            confidence: 0.1,
            triangleCount: 10
        )
        let prompt = RoomLabelPromptBuilder.buildPrompt(
            anchorId: UUID(),
            annotations: [],
            meshClassification: mesh
        )
        #expect(!prompt.isEmpty)
    }

    @Test("prompt instructs model to reply with short noun phrase")
    func instructsShortOutput() {
        let mesh = makeMeshSummary(dominant: .wall)
        let prompt = RoomLabelPromptBuilder.buildPrompt(
            anchorId: UUID(),
            annotations: [],
            meshClassification: mesh
        )
        #expect(prompt.lowercased().contains("noun phrase") || prompt.lowercased().contains("1-3 word"))
    }
}
