import Foundation
import Logging

// MARK: - NoveltyDetector

/// Determines whether a world anchor is "cold" (not encountered in the last 30 minutes).
///
/// An anchor is cold if:
///   - `lastSeenAt` returns `nil` (never encountered before), OR
///   - the most recent encounter is more than `coldThreshold` ago.
///
/// Callers supply a `lastSeenAt` closure so this type has no direct coupling to `AnnotationStore`.
/// Thread-safe: the threshold and closure are immutable after init.
///
/// Log category: `echosight.ambient`
public struct NoveltyDetector: Sendable {

    // MARK: - Constants

    public static let defaultColdThreshold: TimeInterval = 30 * 60  // 30 minutes

    // MARK: - Properties

    private let coldThreshold: TimeInterval
    private let log = Logger(label: "echosight.ambient")

    // MARK: - Init

    public init(coldThreshold: TimeInterval = defaultColdThreshold) {
        self.coldThreshold = coldThreshold
    }

    // MARK: - Public API

    /// Returns `true` if the anchor should be considered cold.
    ///
    /// - Parameters:
    ///   - anchorId: The ARKit world anchor UUID.
    ///   - lastSeenAt: The most recent encounter timestamp, or `nil` if never seen.
    ///   - now: Reference timestamp for the check (injectable for testing; defaults to `Date()`).
    public func isCold(anchorId: UUID, lastSeenAt: Date?, now: Date = Date()) -> Bool {
        guard let last = lastSeenAt else {
            log.debug("ambient.novelty.evaluated", metadata: [
                "cold": "true", "reason": "neverSeen",
            ])
            return true
        }
        let delta = now.timeIntervalSince(last)
        let cold = delta > coldThreshold
        log.debug("ambient.novelty.evaluated", metadata: [
            "cold": .string("\(cold)"),
            "lastSeenDelta": .string("\(Int(delta))s"),
            "threshold": .string("\(Int(coldThreshold))s"),
        ])
        return cold
    }
}
