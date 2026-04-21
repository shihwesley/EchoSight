import Foundation

// MARK: - SpeechToken

/// A lightweight handle for a `SpeechOut.speak` request.
///
/// Callers receive a token immediately from `speak(...)`. To learn the outcome,
/// `await token.completion`. Tokens are reference-typed so cancellation can be
/// signaled through the continuation.
public final class SpeechToken: Sendable {

    // MARK: - Completion

    /// The possible outcomes of a speech request.
    public enum Completion: Sendable {
        case finished
        case cancelled
        case dropped(reason: DropReason)
    }

    /// Why a request was dropped without being spoken.
    public enum DropReason: Sendable {
        case preemptedByHigh
        case silentMode
    }

    // MARK: - Properties

    public let id: UUID

    /// Await this to know when the utterance resolves.
    public var completion: Completion {
        get async { await completionChannel.value }
    }

    // MARK: - Internal

    let completionChannel: TokenChannel

    // MARK: - Init

    public init() {
        self.id = UUID()
        self.completionChannel = TokenChannel()
    }

    // MARK: - Resolution (package-internal)

    func resolve(_ completion: Completion) {
        completionChannel.resolve(completion)
    }
}

// MARK: - TokenChannel

/// One-shot async channel that stores and delivers a single `SpeechToken.Completion`.
public final class TokenChannel: Sendable {

    private let continuation: UnsafeContinuation<SpeechToken.Completion, Never>?
    private nonisolated(unsafe) var stored: SpeechToken.Completion?
    private nonisolated(unsafe) var waiters: [CheckedContinuation<SpeechToken.Completion, Never>] = []
    private let lock = NSLock()

    init() {
        self.continuation = nil
    }

    var value: SpeechToken.Completion {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let stored {
                    let value = stored
                    lock.unlock()
                    continuation.resume(returning: value)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    func resolve(_ completion: SpeechToken.Completion) {
        lock.lock()
        stored = completion
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: completion)
        }
    }
}
