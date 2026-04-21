import Testing
import Foundation
@testable import EchoSightCore

// MARK: - PipelineMetricsBufferTests

@Suite("PipelineMetricsBuffer")
struct PipelineMetricsBufferTests {

    // MARK: - Basic Record

    @Test("Recorded event appears in recent(category:)")
    func recordAppears() async {
        let buffer = PipelineMetricsBuffer(capacity: 32)
        let event = PipelineEvent(category: "echosight.test", event: "test.event")
        buffer.record(event)

        // Fire-and-forget; give the task a moment to land.
        try? await Task.sleep(nanoseconds: 10_000_000)

        let recent = await buffer.recent(category: "echosight.test")
        #expect(recent.contains { $0.event == "test.event" })
    }

    // MARK: - Ring Overwrite

    @Test("Ring evicts oldest at capacity")
    func ringOverwrite() async {
        let buffer = PipelineMetricsBuffer(capacity: 3)

        for i in 0..<4 {
            buffer.record(PipelineEvent(category: "echosight.test", event: "event.\(i)"))
        }

        try? await Task.sleep(nanoseconds: 20_000_000)

        let recent = await buffer.recent(category: "echosight.test")
        #expect(recent.count == 3)
        // Oldest (event.0) should be gone.
        #expect(!recent.contains { $0.event == "event.0" })
        #expect(recent.contains { $0.event == "event.3" })
    }

    // MARK: - Category Isolation

    @Test("Events in different categories don't bleed across")
    func categoryIsolation() async {
        let buffer = PipelineMetricsBuffer(capacity: 32)
        buffer.record(PipelineEvent(category: "echosight.speech", event: "speak.accepted"))
        buffer.record(PipelineEvent(category: "echosight.spatial", event: "anchor.new"))

        try? await Task.sleep(nanoseconds: 10_000_000)

        let speech = await buffer.recent(category: "echosight.speech")
        let spatial = await buffer.recent(category: "echosight.spatial")

        #expect(speech.allSatisfy { $0.category == "echosight.speech" })
        #expect(spatial.allSatisfy { $0.category == "echosight.spatial" })
        #expect(speech.count == 1)
        #expect(spatial.count == 1)
    }

    // MARK: - Privacy Filter

    @Test("PrivacyFilter strips content/text/frame/prompt/transcript keys")
    func privacyFilterStrips() {
        let event = PipelineEvent(
            category: "echosight.test",
            event: "test",
            metadata: [
                "content": "should be stripped",
                "Text": "also stripped",
                "FRAME": "stripped too",
                "safeKey": "kept",
                "promptData": "stripped",
                "transcriptId": "stripped",
            ]
        )
        let sanitized = PrivacyFilter.sanitize(event: event)
        #expect(sanitized.metadata["safeKey"] == "kept")
        #expect(sanitized.metadata["content"] == nil)
        #expect(sanitized.metadata["Text"] == nil)
        #expect(sanitized.metadata["FRAME"] == nil)
        #expect(sanitized.metadata["promptData"] == nil)
        #expect(sanitized.metadata["transcriptId"] == nil)
    }
}
