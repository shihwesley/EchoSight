import Testing
@testable import EchoSightCore

// MARK: - CrownQuantizerTests

@Suite("CrownQuantizer")
struct CrownQuantizerTests {

    // MARK: - Below Threshold

    @Test("delta below threshold produces 0 steps")
    func belowThreshold() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: 0.04) == 0)
    }

    @Test("multiple sub-threshold deltas accumulate")
    func accumulates() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: 0.04) == 0)
        #expect(q.process(delta: 0.04) == 0)
        // Third call: accumulated 0.12 >= 0.10 → emits 1 step
        #expect(q.process(delta: 0.04) == 1)
    }

    // MARK: - At / Above Threshold

    @Test("delta exactly at threshold produces 1 step")
    func atThreshold() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: 0.10) == 1)
    }

    @Test("delta above threshold produces 1 step, remainder accumulated")
    func aboveThreshold() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: 0.15) == 1)
        // Remainder is 0.05; next small push crosses again
        #expect(q.process(delta: 0.06) == 1)
    }

    @Test("large delta produces multiple steps")
    func largeStep() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: 0.35) == 3)
    }

    // MARK: - Negative (Reverse)

    @Test("negative delta below threshold produces 0 steps")
    func negativeBelowThreshold() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: -0.04) == 0)
    }

    @Test("negative delta at threshold produces -1 step")
    func negativeAtThreshold() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: -0.10) == -1)
    }

    @Test("large negative delta produces multiple negative steps")
    func largeNegativeStep() {
        var q = CrownQuantizer(threshold: 0.10)
        #expect(q.process(delta: -0.35) == -3)
    }

    // MARK: - Reset

    @Test("reset clears accumulator")
    func resetClearsAccumulator() {
        var q = CrownQuantizer(threshold: 0.10)
        _ = q.process(delta: 0.08) // Accumulate 0.08
        q.reset()
        // After reset, should need full threshold again
        #expect(q.process(delta: 0.08) == 0)
    }
}
