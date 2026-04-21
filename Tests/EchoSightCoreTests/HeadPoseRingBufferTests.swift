import Testing
import Foundation
import simd
@testable import EchoSightCore

// MARK: - HeadPoseRingBufferTests

@Suite("HeadPoseRingBuffer")
struct HeadPoseRingBufferTests {

    // MARK: - Edge Cases

    @Test("Empty buffer throws")
    func emptyBufferThrows() {
        let ring = HeadPoseRingBuffer()
        #expect(throws: HeadPoseRingBufferError.empty) {
            try ring.pose(at: Date())
        }
    }

    @Test("Single sample returns itself for any date")
    func singleSampleClamps() throws {
        let ring = HeadPoseRingBuffer()
        let t = Date()
        let identity = simd_float4x4(1)
        ring.append(transform: identity, at: t)

        let before = try ring.pose(at: t.addingTimeInterval(-1))
        let after  = try ring.pose(at: t.addingTimeInterval(+1))
        #expect(before == identity)
        #expect(after  == identity)
    }

    @Test("Interpolation stays within bounds")
    func interpolationBetweenTwoSamples() throws {
        let ring = HeadPoseRingBuffer()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1)

        var a = simd_float4x4(1)
        var b = simd_float4x4(1)
        a[3][0] = 0 // x=0
        b[3][0] = 1 // x=1

        ring.append(transform: a, at: t0)
        ring.append(transform: b, at: t1)

        let mid = try ring.pose(at: t0.addingTimeInterval(0.5))
        // Translation column x should be ~0.5.
        #expect(abs(mid[3][0] - 0.5) < 0.01)
    }

    @Test("Ring wraps around at capacity")
    func ringWrapsAtCapacity() {
        let capacity = 10
        let ring = HeadPoseRingBuffer(capacity: capacity)
        let base = Date()
        for i in 0..<(capacity + 3) {
            ring.append(transform: simd_float4x4(1), at: base.addingTimeInterval(Double(i)))
        }
        // Should have exactly capacity samples.
        #expect(ring.orderedSamples.count == capacity)
    }

    @Test("Ordered samples are chronological")
    func orderedSamplesChronological() {
        let ring = HeadPoseRingBuffer(capacity: 5)
        let base = Date()
        for i in 0..<7 {
            ring.append(transform: simd_float4x4(1), at: base.addingTimeInterval(Double(i) * 0.1))
        }
        let samples = ring.orderedSamples
        for i in 1..<samples.count {
            #expect(samples[i].timestamp >= samples[i - 1].timestamp)
        }
    }

    // MARK: - Head-Pose Variance

    @Test("Stationary head yields ~0 variance")
    func stationaryHead() {
        let ring = HeadPoseRingBuffer()
        let base = Date()
        let identity = simd_float4x4(1)
        for i in 0..<20 {
            ring.append(transform: identity, at: base.addingTimeInterval(Double(i) * 0.1))
        }
        let variance = ring.headPoseVariance(window: 5.0)
        #expect(variance < 0.01)
    }

    @Test("Window larger than buffer uses all samples")
    func windowLargerThanBuffer() {
        let ring = HeadPoseRingBuffer()
        let base = Date()
        ring.append(transform: simd_float4x4(1), at: base.addingTimeInterval(-10))
        ring.append(transform: simd_float4x4(1), at: base.addingTimeInterval(-5))
        // Window of 100 s — should use both samples without error.
        let v = ring.headPoseVariance(window: 100)
        #expect(v >= 0)
    }
}
