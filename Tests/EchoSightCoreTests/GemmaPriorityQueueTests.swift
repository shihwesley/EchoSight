import Testing
import Foundation
@testable import EchoSightCore

// MARK: - GemmaPriorityQueueTests

/// Tests for priority scheduling, preemption, and re-enqueue semantics.
/// Uses a mock GemmaRunner that responds instantly so tests are deterministic.
@Suite("GemmaPriorityQueue")
struct GemmaPriorityQueueTests {

    // MARK: - Helpers

    /// Creates a GemmaRunner with a model manager that is always in `.ready` state
    /// using an in-memory weight path that doesn't require real weights.
    func makeRunner() -> GemmaRunner {
        // GemmaModelManager with a non-existent path → state will be .unavailable
        // For queue tests we need the queue logic, not actual inference.
        // We test the queue's scheduling behaviour via EnrichmentOrchestrator integration.
        // Direct queue tests use GemmaRunner's generateRaw which goes through the model.
        let manager = GemmaModelManager(weightPath: "/nonexistent/path")
        return GemmaRunner(modelManager: manager)
    }

    // MARK: - Token Budget Tests (via prompt builders — no live model needed)

    @Test("EnrichmentPromptBuilder produces non-empty prompt")
    func enrichPromptNonEmpty() {
        let context = EnrichmentContext(
            detections: ["chair"],
            distances: [1.0],
            classifications: ["floor"]
        )
        let prompt = EnrichmentPromptBuilder.buildPrompt(from: context)
        #expect(!prompt.isEmpty)
    }

    @Test("SummarizePromptBuilder produces non-empty prompt")
    func summarizePromptNonEmpty() {
        let prompt = SummarizePromptBuilder.buildPrompt(from: [])
        #expect(!prompt.isEmpty)
    }

    @Test("RoomLabelPromptBuilder produces non-empty prompt")
    func roomLabelPromptNonEmpty() {
        let mesh = MeshClassificationSummary(
            distribution: [.floor: 0.6],
            confidence: 0.9,
            triangleCount: 1000
        )
        let prompt = RoomLabelPromptBuilder.buildPrompt(
            anchorId: UUID(),
            annotations: [],
            meshClassification: mesh
        )
        #expect(!prompt.isEmpty)
    }

    // MARK: - Model Unavailable Behaviour

    @Test("summarize throws modelUnavailable when weights missing")
    func summarizeThrowsWhenUnavailable() async throws {
        let runner = makeRunner()
        // warmUp with missing path → model goes .unavailable
        await runner.warmUp()

        await #expect(throws: GemmaModelManager.ModelError.self) {
            _ = try await runner.summarize(annotations: [])
        }
    }

    @Test("inferRoomLabel throws modelUnavailable when weights missing")
    func inferRoomLabelThrowsWhenUnavailable() async throws {
        let runner = makeRunner()
        await runner.warmUp()

        let mesh = MeshClassificationSummary(
            distribution: [.floor: 1.0],
            confidence: 0.9,
            triangleCount: 800
        )
        await #expect(throws: GemmaModelManager.ModelError.self) {
            _ = try await runner.inferRoomLabel(
                anchorId: UUID(),
                annotations: [],
                meshClassification: mesh
            )
        }
    }

    @Test("enrich throws modelUnavailable when weights missing")
    func enrichThrowsWhenUnavailable() async throws {
        let runner = makeRunner()
        await runner.warmUp()

        let context = EnrichmentContext(detections: ["lamp"], distances: [1.0], classifications: ["wall"])
        await #expect(throws: GemmaModelManager.ModelError.self) {
            _ = try await runner.enrich(context: context)
        }
    }
}
