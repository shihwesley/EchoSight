import Foundation
import Logging

// MARK: - SessionResumeDampener

/// Suppresses all chimes for 3 s after an ARKit session-resume event.
///
/// On `AnchorChangeEvent.kind == .sessionResumeRerecognized`, ARKit re-emits all
/// previously known anchors in rapid succession. The 2-s chime rate limit alone
/// would still produce one spurious chime. This 3-s suppression window eliminates it.
///
/// Post-TLA gate resolution 2026-04-21: `NoChimeDuringSessionResumeDampen` invariant
/// holds — every anchor event during the window routes to a no-op path.
///
/// Not an actor: owned and mutated exclusively by `AmbientAnnounceCoordinator`.
///
/// Log category: `echosight.ambient`
public struct SessionResumeDampener {

    // MARK: - Constants

    public static let defaultDampenWindow: TimeInterval = 3.0

    // MARK: - Properties

    private var dampenUntil: Date?
    private let dampenWindow: TimeInterval
    private let log = Logger(label: "echosight.ambient")

    // MARK: - Init

    public init(dampenWindow: TimeInterval = defaultDampenWindow) {
        self.dampenWindow = dampenWindow
    }

    // MARK: - API

    /// Call when an event with `kind == .sessionResumeRerecognized` arrives.
    /// Starts or resets the 3-s suppression window.
    public mutating func trigger(now: Date = Date()) {
        dampenUntil = now.addingTimeInterval(dampenWindow)
        log.info("ambient.sessionResumeDampener.triggered", metadata: [
            "dampenWindowSec": .string("\(Int(dampenWindow))"),
        ])
    }

    /// Returns `true` if the current time is within the suppression window.
    public func isSuppressing(now: Date = Date()) -> Bool {
        guard let until = dampenUntil else { return false }
        return now < until
    }
}
