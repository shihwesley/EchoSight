import Foundation
import Logging

// MARK: - AnnounceRateLimiter

/// Enforces minimum gaps between chimes and speech outputs.
///
/// Two independent rate limits:
///   - **Chime:** 2 s minimum between chimes. Protects against anchor storms
///     during ARKit session recovery.
///   - **Speech:** 60 s minimum between full announce speeches.
///
/// Not an actor: owned and mutated exclusively by `AmbientAnnounceCoordinator`.
///
/// Log category: `echosight.ambient`
public struct AnnounceRateLimiter {

    // MARK: - Constants

    public static let defaultChimeMinGap: TimeInterval = 2.0
    public static let defaultSpeechMinGap: TimeInterval = 60.0

    // MARK: - Properties

    private var lastChimeAt: Date?
    private var lastSpeechAt: Date?
    private let chimeMinGap: TimeInterval
    private let speechMinGap: TimeInterval
    private let log = Logger(label: "echosight.ambient")

    // MARK: - Init

    public init(
        chimeMinGap: TimeInterval = defaultChimeMinGap,
        speechMinGap: TimeInterval = defaultSpeechMinGap
    ) {
        self.chimeMinGap = chimeMinGap
        self.speechMinGap = speechMinGap
    }

    // MARK: - Chime

    /// Returns `true` if a chime is permitted right now.
    public func canChime(now: Date = Date()) -> Bool {
        guard let last = lastChimeAt else { return true }
        let ok = now.timeIntervalSince(last) >= chimeMinGap
        if !ok {
            log.debug("ambient.chime.suppressed", metadata: [
                "reason": "rateLimit",
                "msSinceLast": .string("\(Int(now.timeIntervalSince(last) * 1000))"),
            ])
        }
        return ok
    }

    /// Record that a chime just fired. Must be called after `canChime()` returns `true`.
    public mutating func recordChime(now: Date = Date()) {
        lastChimeAt = now
    }

    // MARK: - Speech

    /// Returns `true` if a speech announcement is permitted right now.
    public func canSpeak(now: Date = Date()) -> Bool {
        guard let last = lastSpeechAt else { return true }
        let elapsed = now.timeIntervalSince(last)
        let ok = elapsed >= speechMinGap
        if !ok {
            log.debug("ambient.rateLimiter.speech.suppressed", metadata: [
                "msSinceLast": .string("\(Int(elapsed * 1000))"),
            ])
        }
        return ok
    }

    /// Record that a speech announcement just fired.
    public mutating func recordSpeech(now: Date = Date()) {
        lastSpeechAt = now
    }
}
