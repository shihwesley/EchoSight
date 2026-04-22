import Foundation
import Logging

// MARK: - IdleTracker

/// Tracks user gesture activity by recording `ModeFiredEvent` timestamps.
///
/// A user is considered idle if no mode-fired event has occurred in the past
/// `idleThreshold` seconds. The compound idle rule (spec Gate 4) also requires
/// head-motion above a threshold — that check is handled in `AmbientAnnounceCoordinator`.
///
/// Not an actor: all mutation must happen on the actor that owns this tracker
/// (`AmbientAnnounceCoordinator`). Value semantics via a struct with mutable properties.
///
/// Log category: `echosight.ambient`
public struct IdleTracker {

    // MARK: - Constants

    public static let defaultIdleThreshold: TimeInterval = 5 * 60  // 5 minutes

    // MARK: - Properties

    private var lastFiredAt: Date?
    private let idleThreshold: TimeInterval
    private let log = Logger(label: "echosight.ambient")

    // MARK: - Init

    public init(idleThreshold: TimeInterval = defaultIdleThreshold) {
        self.idleThreshold = idleThreshold
    }

    // MARK: - Mutation

    /// Record a mode-fired event. Resets the idle window.
    public mutating func recordModeFired(at timestamp: Date = .now) {
        lastFiredAt = timestamp
        log.debug("ambient.idle.reset", metadata: ["timestamp": .string("\(timestamp)")])
    }

    // MARK: - Query

    /// Returns `true` if the user has been gesture-idle for at least `idleThreshold`.
    ///
    /// - Parameter now: Reference timestamp (injectable for testing).
    public func isIdle(now: Date = Date()) -> Bool {
        guard let last = lastFiredAt else {
            // Never fired — user has been idle since app start.
            log.debug("ambient.idle.evaluated", metadata: [
                "gestureIdle": "true", "reason": "neverFired",
            ])
            return true
        }
        let elapsed = now.timeIntervalSince(last)
        let idle = elapsed >= idleThreshold
        log.debug("ambient.idle.evaluated", metadata: [
            "gestureIdle": .string("\(idle)"),
            "elapsedSec": .string("\(Int(elapsed))"),
            "threshold": .string("\(Int(idleThreshold))"),
        ])
        return idle
    }
}
