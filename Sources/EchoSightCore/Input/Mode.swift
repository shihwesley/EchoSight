import Foundation

// MARK: - Mode

/// The four operational modes EchoSight cycles through via Digital Crown.
///
/// Order matches the Crown rotation cycle: silent → scene → recall → read → silent.
/// TLA-verified (2026-04-21, 467 states).
public enum Mode: String, CaseIterable, Sendable {
    case scene
    case recall
    case read
    case silent

    // MARK: - User-Facing Labels

    /// Short spoken confirmation label for mode-change announcement.
    public var userLabel: String {
        switch self {
        case .scene: return "describe mode"
        case .recall: return "recall mode"
        case .read: return "read mode"
        case .silent: return "silent"
        }
    }

    // MARK: - Cycle Navigation

    /// Next mode in forward Crown rotation (wraps silent → scene).
    public var next: Mode {
        switch self {
        case .silent: return .scene
        case .scene: return .recall
        case .recall: return .read
        case .read: return .silent
        }
    }

    /// Previous mode in reverse Crown rotation (wraps scene → silent).
    public var previous: Mode {
        switch self {
        case .scene: return .silent
        case .recall: return .scene
        case .read: return .recall
        case .silent: return .read
        }
    }
}
