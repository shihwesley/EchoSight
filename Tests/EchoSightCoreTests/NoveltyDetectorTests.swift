import Testing
import Foundation
@testable import EchoSightCore

@Suite("NoveltyDetector")
struct NoveltyDetectorTests {

    let detector = NoveltyDetector(coldThreshold: 30 * 60)

    @Test("nil lastSeen returns cold")
    func nilLastSeenIsCold() {
        let cold = detector.isCold(anchorId: UUID(), lastSeenAt: nil)
        #expect(cold == true)
    }

    @Test("lastSeen within threshold is hot")
    func recentLastSeenIsHot() {
        let now = Date()
        let recentlySeen = now.addingTimeInterval(-10 * 60)  // 10 min ago
        let cold = detector.isCold(anchorId: UUID(), lastSeenAt: recentlySeen, now: now)
        #expect(cold == false)
    }

    @Test("lastSeen exactly at threshold is hot")
    func exactlyAtThresholdIsHot() {
        let now = Date()
        let atThreshold = now.addingTimeInterval(-30 * 60)  // exactly 30 min ago
        let cold = detector.isCold(anchorId: UUID(), lastSeenAt: atThreshold, now: now)
        #expect(cold == false)  // not > threshold (spec uses strict >)
    }

    @Test("lastSeen beyond threshold is cold")
    func beyondThresholdIsCold() {
        let now = Date()
        let longAgo = now.addingTimeInterval(-31 * 60)  // 31 min ago
        let cold = detector.isCold(anchorId: UUID(), lastSeenAt: longAgo, now: now)
        #expect(cold == true)
    }

    @Test("custom threshold is respected")
    func customThreshold() {
        let shortDetector = NoveltyDetector(coldThreshold: 60)  // 1 minute
        let now = Date()
        let twoMinAgo = now.addingTimeInterval(-120)
        #expect(shortDetector.isCold(anchorId: UUID(), lastSeenAt: twoMinAgo, now: now) == true)
        let thirtySecAgo = now.addingTimeInterval(-30)
        #expect(shortDetector.isCold(anchorId: UUID(), lastSeenAt: thirtySecAgo, now: now) == false)
    }
}
