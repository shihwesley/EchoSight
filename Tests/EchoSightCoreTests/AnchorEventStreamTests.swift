import Testing
import Foundation
@testable import EchoSightCore

// MARK: - AnchorEventStreamTests

@Suite("AnchorEventStream")
struct AnchorEventStreamTests {

    // MARK: - Emission

    @Test("New anchor emits .new when not in metadata store")
    func newAnchorEmitsNew() async {
        let stream = AnchorEventStream(anchorMetadataQuery: { _ in false })
        let asyncStream = await stream.makeStream()

        let id = UUID()
        await stream.handleAnchorUpdate(anchorId: id, isNewFromARKit: true)

        // Collect one event.
        var iterator = asyncStream.makeAsyncIterator()
        let event = await iterator.next()

        #expect(event?.anchorId == id)
        #expect(event?.kind == .new)
    }

    @Test("Known anchor emits .rerecognized")
    func knownAnchorEmitsRerecognized() async {
        let knownId = UUID()
        let stream = AnchorEventStream(anchorMetadataQuery: { id in id == knownId })
        let asyncStream = await stream.makeStream()

        await stream.handleAnchorUpdate(anchorId: knownId, isNewFromARKit: false)

        var iterator = asyncStream.makeAsyncIterator()
        let event = await iterator.next()

        #expect(event?.kind == .rerecognized)
    }

    @Test("Duplicate anchor in same session is deduped")
    func duplicateDeduped() async {
        let stream = AnchorEventStream(anchorMetadataQuery: { _ in false })

        let id = UUID()
        await stream.handleAnchorUpdate(anchorId: id, isNewFromARKit: true)
        await stream.handleAnchorUpdate(anchorId: id, isNewFromARKit: true)

        // Only one event should have been emitted.
        // We can verify seenThisSession deduplicated by checking stream output.
        let asyncStream = await stream.makeStream()
        // A fresh stream won't receive past events; verify no new emission by
        // re-sending and checking kind hasn't changed.
        await stream.handleAnchorUpdate(anchorId: id, isNewFromARKit: true)
        // If dedup works, nothing new is yielded. Collect with timeout.
        let result = await withTaskGroup(of: AnchorChangeEvent?.self) { group in
            group.addTask {
                var iterator = asyncStream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
                return nil
            }
            let r = await group.next()!
            group.cancelAll()
            return r
        }
        #expect(result == nil)
    }

    // MARK: - Session Resume

    @Test("Session resume clears seen set and emits .sessionResumeRerecognized")
    func sessionResumeEmitsCorrectKind() async {
        let stream = AnchorEventStream(anchorMetadataQuery: { _ in true })

        // Emit normally first.
        let id = UUID()
        await stream.handleAnchorUpdate(anchorId: id, isNewFromARKit: false)

        // Simulate session interruption + resume.
        await stream.handleSessionInterrupted()
        await stream.handleSessionResumed()

        let asyncStream = await stream.makeStream()
        await stream.handleAnchorUpdate(anchorId: id, isNewFromARKit: false)

        var iterator = asyncStream.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.kind == .sessionResumeRerecognized)
    }
}
