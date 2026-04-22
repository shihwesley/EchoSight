import Foundation
import Logging

// MARK: - GemmaPriorityQueue

/// Serialises access to the single `GemmaModelManager` with high/low priority lanes.
///
/// Priority semantics (from spec Eng Review):
/// - `.high` (summarize, inferRoomLabel) — user is waiting; preempts any in-flight `.low`
/// - `.low`  (enrich) — background; runs only when no `.high` call is pending or running
///
/// Preemption flow:
///   1. High-priority call arrives while `.low` is running
///   2. Running low task is cancelled (cooperative — GemmaModelManager checks isCancelled)
///   3. Cancelled low item is re-enqueued at the HEAD of the low queue (not tail)
///   4. High-priority call runs immediately
///   5. On high completion, next item from low head is dispatched
///
/// Re-enqueue at head (spec-pinned): prevents enrichment starvation under recall-heavy usage.
/// Under simultaneous preemptions the same enrichment task resumes from front each time.
///
/// If the high-priority slot is already busy, additional high-priority calls wait using
/// Swift concurrency (actor serialisation). This queue is single-writer: one inference
/// at a time.
public actor GemmaPriorityQueue {

    // MARK: - Types

    public enum Priority: Sendable {
        case high
        case low
    }

    public enum QueueError: Error, Sendable {
        case cancelled
        case modelUnavailable
        case timeout
    }

    // MARK: - State

    private enum RunState {
        case idle
        case runningLow(Task<String, Error>)
        case runningHigh
        case cancellingLow
    }

    // MARK: - Storage

    private var state: RunState = .idle
    private var lowQueue: [EnqueuedCall] = []
    private var highQueue: [EnqueuedCall] = []

    // Closure type to avoid circular reference with GemmaRunner
    typealias GenerateFn = @Sendable (String, Int, Double) async throws -> String

    private let generate: GenerateFn
    private let log = Logger(label: LogCategories.gemma)

    // MARK: - Enqueued Call

    // Not Sendable — lives entirely inside the actor's isolation domain.
    struct EnqueuedCall {
        let id: UUID
        let prompt: String
        let maxTokens: Int
        let timeoutSeconds: Double
        let continuation: CheckedContinuation<String, Error>

        init(
            prompt: String,
            maxTokens: Int,
            timeoutSeconds: Double,
            continuation: CheckedContinuation<String, Error>
        ) {
            self.id = UUID()
            self.prompt = prompt
            self.maxTokens = maxTokens
            self.timeoutSeconds = timeoutSeconds
            self.continuation = continuation
        }
    }

    // MARK: - Init

    /// - Parameter generate: Closure that performs actual mlx inference.
    ///   Signature: `(prompt, maxTokens, timeoutSeconds) async throws -> String`
    ///   Injected by `GemmaRunner` at init time via a closure over its `generateRaw` method.
    init(generate: @escaping GenerateFn) {
        self.generate = generate
    }

    // MARK: - Enqueue

    /// Submits a call to the queue and suspends until the result is available.
    ///
    /// High-priority calls preempt any running low-priority call. Low-priority
    /// calls wait behind any in-flight or pending high call.
    public func submit(
        prompt: String,
        maxTokens: Int,
        timeoutSeconds: Double,
        priority: Priority
    ) async throws -> String {
        let depth = priority == .high ? highQueue.count : lowQueue.count
        log.info(
            "gemma.call.enqueued",
            metadata: [
                "priority": .string("\(priority)"),
                "queueDepth": .string("\(depth)"),
            ]
        )

        return try await withCheckedThrowingContinuation { continuation in
            let call = EnqueuedCall(
                prompt: prompt,
                maxTokens: maxTokens,
                timeoutSeconds: timeoutSeconds,
                continuation: continuation
            )
            switch priority {
            case .high:
                highQueue.append(call)
                Task { await self.scheduleNext() }
            case .low:
                lowQueue.append(call)
                Task { await self.scheduleNext() }
            }
        }
    }

    // MARK: - Scheduling

    private func scheduleNext() async {
        // High queue takes absolute priority
        if !highQueue.isEmpty {
            switch state {
            case .idle:
                let call = highQueue.removeFirst()
                state = .runningHigh
                await runCall(call, priority: .high)

            case .runningLow(let task):
                // Preempt: cancel the low task.
                // The drain loop's catch CancellationError re-enqueues at head.
                let call = highQueue.removeFirst()
                state = .cancellingLow
                task.cancel()
                // Cooperative cancellation — at most ~20 ms (one token period).
                // Set state to runningHigh and proceed; the low task's catch block
                // will re-enqueue itself when it lands.
                state = .runningHigh
                await runCall(call, priority: .high)

            case .runningHigh, .cancellingLow:
                // Already running something — completion will reschedule
                return
            }
            return
        }

        // No high calls — dispatch from low queue
        if !lowQueue.isEmpty {
            switch state {
            case .idle:
                let call = lowQueue.removeFirst()
                let generateFn = self.generate
                let capturedCall = call
                let task = Task {
                    try await generateFn(capturedCall.prompt, capturedCall.maxTokens, capturedCall.timeoutSeconds)
                }
                state = .runningLow(task)
                log.info(
                    "gemma.call.started",
                    metadata: [
                        "priority": "low",
                        "callId": .string(call.id.uuidString),
                    ]
                )
                do {
                    let result = try await task.value
                    call.continuation.resume(returning: result)
                } catch is CancellationError {
                    // Preempted — re-enqueue at head
                    lowQueue.insert(call, at: 0)
                    log.info(
                        "gemma.call.reEnqueued",
                        metadata: [
                            "callId": .string(call.id.uuidString),
                            "position": "head",
                        ]
                    )
                    // Don't resume continuation yet; will resume when it next runs
                } catch {
                    call.continuation.resume(throwing: error)
                }
                if case .runningLow = state { state = .idle }
                await scheduleNext()

            case .runningLow, .runningHigh, .cancellingLow:
                return  // something else is running; will schedule on completion
            }
        }
    }

    // MARK: - Run

    private func runCall(_ call: EnqueuedCall, priority: Priority) async {
        log.info(
            "gemma.call.started",
            metadata: [
                "priority": .string("\(priority)"),
                "callId": .string(call.id.uuidString),
            ]
        )
        do {
            let result = try await generate(call.prompt, call.maxTokens, call.timeoutSeconds)
            call.continuation.resume(returning: result)
            log.info(
                "gemma.call.completed",
                metadata: [
                    "callId": .string(call.id.uuidString),
                    "durationMs": "n/a",
                ]
            )
        } catch {
            log.info(
                "gemma.call.timeout",
                metadata: [
                    "callId": .string(call.id.uuidString),
                    "priority": .string("\(priority)"),
                ]
            )
            call.continuation.resume(throwing: error)
        }
        if priority == .high {
            state = .idle
        }
        await scheduleNext()
    }
}
