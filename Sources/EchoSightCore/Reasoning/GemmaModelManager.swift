import Foundation
import Logging

// MARK: - GemmaModelManager

/// Manages the lifecycle of the Gemma 4 E2B Q4 mlx-swift model.
///
/// Responsibilities:
/// - Load model weights from disk (placeholder path until `onboarding-download` lands in Sprint 3.2)
/// - Track warm-up state so callers can gate on readiness
/// - Provide the raw `generate(prompt:maxTokens:cancelled:)` primitive
///
/// Thread safety: actor-isolated. All callers go through the actor queue.
///
/// Memory target: <2.5 GB resident after warm-up (Q4 quantization keeps Gemma 4 E2B
/// well inside this budget; monitor on-device during acceptance testing).
///
/// Weight path: Sprint 3.2 (`onboarding-download`) writes weights to
/// `<Application Support>/gemma-4-e2b-q4/`. This manager reads from that path.
/// Until Sprint 3.2 ships, the manager enters `.unavailable` state and all
/// `generate` calls throw `.modelUnavailable`.
public actor GemmaModelManager {

    // MARK: - Types

    public enum State: Sendable {
        case unloaded
        case loading
        case ready
        case unavailable(String)  // reason
    }

    public enum ModelError: Error, Sendable {
        case modelUnavailable
        case timeout
        case generationFailed(String)
    }

    // MARK: - Properties

    private(set) public var state: State = .unloaded
    private let log = Logger(label: LogCategories.gemma)

    /// Placeholder weight path — Sprint 3.2 will write here.
    private static let defaultWeightPath: String = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.path ?? "/tmp"
        return "\(appSupport)/gemma-4-e2b-q4"
    }()

    private let weightPath: String

    // MARK: - Init

    public init(weightPath: String? = nil) {
        self.weightPath = weightPath ?? Self.defaultWeightPath
    }

    // MARK: - Lifecycle

    /// Loads the model weights and runs a warm-up pass.
    ///
    /// No-op if already `.ready`. Sets state to `.unavailable` if the weight
    /// directory does not exist (Sprint 3.2 has not run yet).
    public func warmUp() async {
        guard case .unloaded = state else { return }
        state = .loading
        log.info("gemma.warmUp.started", metadata: ["weightPath": .string(weightPath)])

        let start = Date()

        // Check weight directory exists (Sprint 3.2 downloads here)
        guard FileManager.default.fileExists(atPath: weightPath) else {
            let reason = "weight directory not found at \(weightPath); run onboarding-download first"
            state = .unavailable(reason)
            log.warning("gemma.warmUp.unavailable", metadata: ["reason": .string(reason)])
            return
        }

        // TODO(Sprint 3.2): replace stub with actual mlx-swift model load
        // let model = try await LLM.load(path: weightPath)
        // self.model = model
        // Run warm-up inference with empty prompt to prime caches

        state = .ready
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        log.info("gemma.warmUp.completed", metadata: ["durationMs": .string("\(durationMs)")])
    }

    // MARK: - Inference

    /// Generates up to `maxTokens` tokens from `prompt`.
    ///
    /// The `cancelled` closure is polled between each generated token. When it
    /// returns `true`, generation stops immediately and the partial output is returned.
    /// This enables the priority-preemption contract (<100 ms cancel latency at ~20 ms/token).
    ///
    /// - Throws: `ModelError.modelUnavailable` when state is not `.ready`.
    ///           `ModelError.timeout` when `timeoutSeconds` elapses.
    public func generate(
        prompt: String,
        maxTokens: Int,
        timeoutSeconds: Double = 2.0,
        cancelled: @escaping @Sendable () -> Bool
    ) async throws -> String {
        guard case .ready = state else {
            throw ModelError.modelUnavailable
        }

        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)

        // TODO(Sprint 3.2): replace stub with actual mlx-swift inference loop:
        //
        // var output = ""
        // for try await token in model.generate(prompt: prompt, maxTokens: maxTokens) {
        //     if cancelled() { break }
        //     if Date() > deadline { throw ModelError.timeout }
        //     output += token
        // }
        // return output
        //
        // Stub: simulate cooperative generation with Task.sleep between tokens
        var tokens: [String] = []
        let targetTokens = min(maxTokens, 5)  // stub produces at most 5 tokens

        for i in 0..<targetTokens {
            if cancelled() { break }
            if Date() > deadline { throw ModelError.timeout }
            try await Task.sleep(nanoseconds: 1_000_000)  // 1 ms per stub token
            tokens.append("token\(i)")
        }

        return tokens.joined(separator: " ")
    }

    // MARK: - Memory

    /// Unloads model weights from memory. Call on application backgrounding.
    public func unload() {
        guard case .ready = state else { return }
        // TODO(Sprint 3.2): model = nil
        state = .unloaded
        log.info("gemma.model.unloaded")
    }
}
