import simd
import Foundation

// MARK: - HeadPoseRingBuffer

/// A fixed-capacity ring buffer of head-pose samples at 100 Hz.
///
/// Stores a 5-second window of `(Date, simd_float4x4)` pairs.
/// Supports O(log N) interpolation for any timestamp within the window,
/// and O(N) head-pose variance accumulation for the ambient-announce idle rule.
///
/// Not actor-isolated — callers serialize access externally (typically from
/// `SpatialSession`'s actor context).
public final class HeadPoseRingBuffer: @unchecked Sendable {

    // MARK: - Types

    public struct Sample: Sendable {
        public let timestamp: Date
        public let transform: simd_float4x4
    }

    // MARK: - Constants

    /// Capacity at 100 Hz over 5 seconds.
    private let capacity: Int

    // MARK: - Storage

    private var buffer: [Sample]
    private var writeIndex: Int = 0
    private var count: Int = 0

    // MARK: - Init

    /// - Parameter capacity: Maximum number of samples. Default 500 (5 s at 100 Hz).
    public init(capacity: Int = 500) {
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
    }

    // MARK: - Write

    /// Append a new head-pose sample. Overwrites oldest when at capacity.
    public func append(transform: simd_float4x4, at timestamp: Date = Date()) {
        let sample = Sample(timestamp: timestamp, transform: transform)
        if count < capacity {
            buffer.append(sample)
            count += 1
        } else {
            buffer[writeIndex] = sample
        }
        writeIndex = (writeIndex + 1) % capacity
    }

    // MARK: - Read

    /// Returns all samples in chronological order.
    public var orderedSamples: [Sample] {
        guard count > 0 else { return [] }
        if count < capacity {
            return buffer
        }
        // Reconstruct chronological order from circular layout.
        let tail = Array(buffer[writeIndex...])
        let head = Array(buffer[..<writeIndex])
        return tail + head
    }

    /// Interpolates (or clamps) the head-pose transform at the given timestamp.
    ///
    /// - Parameter date: Target timestamp.
    /// - Returns: Interpolated `simd_float4x4` if `date` is within the window.
    /// - Throws: `HeadPoseRingBufferError.empty` if no samples have been recorded.
    public func pose(at date: Date) throws -> simd_float4x4 {
        let samples = orderedSamples
        guard !samples.isEmpty else {
            throw HeadPoseRingBufferError.empty
        }
        // Clamp to oldest/newest.
        if date <= samples.first!.timestamp { return samples.first!.transform }
        if date >= samples.last!.timestamp  { return samples.last!.transform }

        // Binary search for surrounding pair.
        var lo = 0
        var hi = samples.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if samples[mid].timestamp <= date {
                lo = mid
            } else {
                hi = mid
            }
        }
        let a = samples[lo]
        let b = samples[hi]
        let span = b.timestamp.timeIntervalSince(a.timestamp)
        guard span > 0 else { return a.transform }
        let t = Float(date.timeIntervalSince(a.timestamp) / span)
        return simd_interpolate(a.transform, b.transform, t)
    }

    // MARK: - Head-Pose Variance

    /// Cumulative angular rotation (radians) over the given time window.
    ///
    /// Used by `ambient-announce` for the compound idle rule (gesture-idle AND
    /// head-motion-active). Returns 0 if fewer than 2 samples are in the window.
    ///
    /// - Parameter window: How far back to look. Clamped to available buffer.
    public func headPoseVariance(window: TimeInterval) -> Float {
        let samples = orderedSamples
        guard samples.count >= 2 else { return 0 }

        let cutoff = Date().addingTimeInterval(-window)
        let windowSamples = samples.filter { $0.timestamp >= cutoff }
        guard windowSamples.count >= 2 else { return 0 }

        var totalAngular: Float = 0
        for i in 1..<windowSamples.count {
            let delta = simd_mul(
                simd_inverse(windowSamples[i - 1].transform),
                windowSamples[i].transform
            )
            // Extract rotation angle from rotation part of the delta matrix.
            let r = delta
            let trace = r[0][0] + r[1][1] + r[2][2]
            let cosAngle = (trace - 1) / 2
            let clampedCos = max(-1, min(1, cosAngle))
            totalAngular += acos(clampedCos)
        }
        return totalAngular
    }

    // MARK: - Helpers

    /// Linear blend of two 4x4 transforms (position + rotation separately).
    private func simd_interpolate(
        _ a: simd_float4x4,
        _ b: simd_float4x4,
        _ t: Float
    ) -> simd_float4x4 {
        // Blend translation columns.
        var result = simd_float4x4(1)
        for col in 0..<4 {
            result[col] = simd_mix(a[col], b[col], simd_float4(repeating: t))
        }
        return result
    }
}

// MARK: - HeadPoseRingBufferError

public enum HeadPoseRingBufferError: Error {
    case empty
}
