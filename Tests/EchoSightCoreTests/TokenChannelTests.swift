import Foundation
import Testing

@testable import EchoSightCore

struct TokenChannelTests {

    @Test
    func storedValueDeliveredToLateWaiter() async {
        let channel = TokenChannel()
        channel.resolve(.finished)

        let result = await channel.value
        #expect(result == .finished)
    }

    @Test
    func pendingWaiterResolvesOnResolve() async {
        let channel = TokenChannel()

        async let result = channel.value
        try? await Task.sleep(nanoseconds: 10_000_000)
        channel.resolve(.cancelled)

        #expect(await result == .cancelled)
    }

    @Test
    func manyConcurrentWaitersAllReceiveValue() async {
        let channel = TokenChannel()
        let waiterCount = 50

        await withTaskGroup(of: SpeechToken.Completion.self) { group in
            for _ in 0..<waiterCount {
                group.addTask { await channel.value }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            channel.resolve(.finished)

            var receivedCount = 0
            for await completion in group {
                #expect(completion == .finished)
                receivedCount += 1
            }
            #expect(receivedCount == waiterCount)
        }
    }

    @Test
    func concurrentStoredReadsDoNotDoubleUnlock() async {
        let channel = TokenChannel()
        channel.resolve(.dropped(reason: .silentMode))

        await withTaskGroup(of: SpeechToken.Completion.self) { group in
            for _ in 0..<100 {
                group.addTask { await channel.value }
            }
            for await completion in group {
                #expect(completion == .dropped(reason: .silentMode))
            }
        }
    }
}

extension SpeechToken.Completion: Equatable {
    public static func == (lhs: SpeechToken.Completion, rhs: SpeechToken.Completion) -> Bool {
        switch (lhs, rhs) {
        case (.finished, .finished), (.cancelled, .cancelled):
            return true
        case let (.dropped(l), .dropped(r)):
            return l == r
        default:
            return false
        }
    }
}

extension SpeechToken.DropReason: Equatable {
    public static func == (lhs: SpeechToken.DropReason, rhs: SpeechToken.DropReason) -> Bool {
        switch (lhs, rhs) {
        case (.preemptedByHigh, .preemptedByHigh), (.silentMode, .silentMode):
            return true
        default:
            return false
        }
    }
}
