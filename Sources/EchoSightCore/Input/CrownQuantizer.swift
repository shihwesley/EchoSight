import Foundation

// MARK: - CrownQuantizer

/// Converts raw Digital Crown rotation deltas into discrete mode steps.
///
/// Sub-threshold deltas are accumulated; once the running total crosses
/// `threshold` the quantizer emits a step and resets the accumulator.
/// This prevents jitter from micro-rotations while still catching slow dials.
///
/// Pure value type — no side effects. Haptic triggering and mode mutation
/// are the caller's responsibility.
///
/// Example:
/// ```swift
/// var q = CrownQuantizer()
/// q.process(delta: 0.04)  // → 0 (accumulated 0.04)
/// q.process(delta: 0.04)  // → 0 (accumulated 0.08)
/// q.process(delta: 0.04)  // → 1 (accumulated 0.12 ≥ 0.10, emit step, reset to 0.02)
/// ```
public struct CrownQuantizer: Sendable {

    // MARK: - Configuration

    /// Crown delta required to emit one mode step. Default 0.10.
    public var threshold: Double

    // MARK: - State

    /// Sub-threshold accumulator. Carries over across calls.
    private var accumulator: Double = 0.0

    // MARK: - Init

    public init(threshold: Double = 0.10) {
        self.threshold = threshold
    }

    // MARK: - Processing

    /// Feed a raw Crown delta.
    ///
    /// Returns the number of full steps encoded in the delta (positive = forward,
    /// negative = reverse). Zero means the delta was absorbed into the accumulator.
    public mutating func process(delta: Double) -> Int {
        accumulator += delta
        // Use floor rather than Int truncation so negative deltas at the sign
        // boundary emit the correct step. Int(-0.5) = 0; floor(-0.5) = -1.
        let steps = Int(floor(accumulator / threshold))
        if steps != 0 {
            accumulator -= Double(steps) * threshold
        }
        return steps
    }

    /// Reset the accumulator without emitting a step. Use on mode-set or focus loss.
    public mutating func reset() {
        accumulator = 0.0
    }
}
