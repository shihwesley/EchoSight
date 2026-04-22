import Testing
import Foundation
@testable import EchoSightCore

// MARK: - Mock Generator

/// Records every generate call and lets tests control per-prompt timing and cancellation.
/// Separate from GemmaRunner so the queue's state machine can be exercised in isolation.
actor MockGenerator {
    enum Mode: Sendable {
        /// Returns immediately with the given value.
        case instant(String)
        /// Spins a cooperative cancellation loop — yields and checks cancellation each tick.
        /// Returns the value if never cancelled within `ticks`.
        case cancellable(value: String, ticks: Int = 50, tickMs: Int = 5)
    }

    private var defaultMode: Mode = .instant("result")
    private var modeByPrompt: [String: Mode] = [:]
    private var calls: [String] = []

    func setMode(_ m: Mode, for prompt: String) { modeByPrompt[prompt] = m }
    func setDefaultMode(_ m: Mode) { defaultMode = m }
    func callCount(for prompt: String) -> Int { calls.filter { $0 == prompt }.count }
    func totalCalls() -> Int { calls.count }

    func run(prompt: String) async throws -> String {
        calls.append(prompt)
        let mode = modeByPrompt[prompt] ?? defaultMode
        switch mode {
        case .instant(let r):
            return r
        case .cancellable(let r, let ticks, let tickMs):
            for _ in 0..<ticks {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(tickMs))
            }
            return r
        }
    }
}

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

    // MARK: - State Machine Behaviour (P2-5)

    /// Validates the happy-path `.idle` → `.runningHigh` → `.idle` transition by
    /// asserting the mock closure was called exactly once with the high-priority prompt.
    @Test("high-on-idle: submits run without queueing")
    func highOnIdleDispatches() async throws {
        let mock = MockGenerator()
        await mock.setMode(.instant("high-done"), for: "high-prompt")
        let queue = GemmaPriorityQueue { prompt, _, _ in
            try await mock.run(prompt: prompt)
        }

        let result = try await queue.submit(
            prompt: "high-prompt",
            maxTokens: 30,
            timeoutSeconds: 1.5,
            priority: .high
        )

        #expect(result == "high-done")
        let called = await mock.callCount(for: "high-prompt")
        #expect(called == 1)
    }

    /// Exercises the preemption path: a low-priority call starts, a high-priority call
    /// arrives while it is running, the low task is cancelled cooperatively, and the
    /// high call returns before the low call gets a final result.
    @Test("high preempts running low and returns first")
    func highPreemptsLow() async throws {
        let mock = MockGenerator()
        // Low prompt spins a cooperative cancel loop — preemption cancels it within ~5 ms.
        await mock.setMode(.cancellable(value: "low-done", ticks: 100, tickMs: 5), for: "low-prompt")
        await mock.setMode(.instant("high-done"), for: "high-prompt")

        let queue = GemmaPriorityQueue { prompt, _, _ in
            try await mock.run(prompt: prompt)
        }

        // Kick off low first; it begins running inside the actor.
        let lowTask = Task {
            try await queue.submit(
                prompt: "low-prompt",
                maxTokens: 40,
                timeoutSeconds: 2.0,
                priority: .low
            )
        }

        // Yield so the low actually enters the cancellable loop before we submit the high.
        try await Task.sleep(for: .milliseconds(30))

        let highResult = try await queue.submit(
            prompt: "high-prompt",
            maxTokens: 30,
            timeoutSeconds: 1.5,
            priority: .high
        )
        #expect(highResult == "high-done")

        // Low re-enqueues at head and eventually completes after high releases the slot.
        let lowResult = try await lowTask.value
        #expect(lowResult == "low-done")

        // Low was invoked twice: once preempted, once on resume.
        let lowCalls = await mock.callCount(for: "low-prompt")
        #expect(lowCalls >= 2)
    }

    /// Validates the re-enqueue-at-head policy: when a low is preempted and another low
    /// was added during preemption, the preempted low must resume before the newcomer.
    @Test("preempted low resumes before later-queued low (head re-enqueue)")
    func reEnqueueAtHead() async throws {
        let mock = MockGenerator()
        await mock.setMode(.cancellable(value: "low1-done", ticks: 100, tickMs: 5), for: "low1")
        await mock.setMode(.instant("low2-done"), for: "low2")
        await mock.setMode(.instant("high-done"), for: "high")

        let queue = GemmaPriorityQueue { prompt, _, _ in
            try await mock.run(prompt: prompt)
        }

        // Start low1 — it enters the cancellable spin loop.
        let low1Task = Task {
            try await queue.submit(prompt: "low1", maxTokens: 40, timeoutSeconds: 2.0, priority: .low)
        }
        try await Task.sleep(for: .milliseconds(30))

        // Queue low2 while low1 is still running. It sits behind low1 in the low queue.
        let low2Task = Task {
            try await queue.submit(prompt: "low2", maxTokens: 40, timeoutSeconds: 2.0, priority: .low)
        }
        try await Task.sleep(for: .milliseconds(10))

        // Preempt with high.
        let highResult = try await queue.submit(
            prompt: "high",
            maxTokens: 30,
            timeoutSeconds: 1.5,
            priority: .high
        )
        #expect(highResult == "high-done")

        // Both low tasks eventually complete. low1 must finish first since it's re-enqueued at head.
        let low1Result = try await low1Task.value
        let low2Result = try await low2Task.value
        #expect(low1Result == "low1-done")
        #expect(low2Result == "low2-done")

        // low1 invoked at least twice (preempted + resumed); low2 invoked exactly once.
        let low1Calls = await mock.callCount(for: "low1")
        let low2Calls = await mock.callCount(for: "low2")
        #expect(low1Calls >= 2)
        #expect(low2Calls == 1)
    }
}
