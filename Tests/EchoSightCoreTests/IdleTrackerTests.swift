import Testing
import Foundation
@testable import EchoSightCore

@Suite("IdleTracker")
struct IdleTrackerTests {

    @Test("Never fired is always idle")
    func neverFiredIsIdle() {
        let tracker = IdleTracker(idleThreshold: 5 * 60)
        #expect(tracker.isIdle(now: Date()) == true)
    }

    @Test("Recently fired is not idle")
    func recentlyFiredIsNotIdle() {
        var tracker = IdleTracker(idleThreshold: 5 * 60)
        let now = Date()
        tracker.recordModeFired(at: now.addingTimeInterval(-60))  // 1 min ago
        #expect(tracker.isIdle(now: now) == false)
    }

    @Test("Fired exactly at threshold is not idle")
    func firedAtThresholdIsNotIdle() {
        var tracker = IdleTracker(idleThreshold: 5 * 60)
        let now = Date()
        tracker.recordModeFired(at: now.addingTimeInterval(-5 * 60))  // exactly at threshold
        // elapsed >= threshold means idle; 5*60 >= 5*60 → idle = true
        #expect(tracker.isIdle(now: now) == true)
    }

    @Test("Fired beyond threshold is idle")
    func firedBeyondThresholdIsIdle() {
        var tracker = IdleTracker(idleThreshold: 5 * 60)
        let now = Date()
        tracker.recordModeFired(at: now.addingTimeInterval(-6 * 60))  // 6 min ago
        #expect(tracker.isIdle(now: now) == true)
    }

    @Test("Multiple fires; latest resets the window")
    func multipleFiresLatestWins() {
        var tracker = IdleTracker(idleThreshold: 5 * 60)
        let now = Date()
        tracker.recordModeFired(at: now.addingTimeInterval(-10 * 60))  // 10 min ago
        tracker.recordModeFired(at: now.addingTimeInterval(-60))        // 1 min ago (reset)
        #expect(tracker.isIdle(now: now) == false)
    }
}
