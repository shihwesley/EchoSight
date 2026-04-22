import Testing
import Foundation
import Vision
@testable import EchoSightCore

// MARK: - OcrPipelineTests

@Suite("OcrPipeline")
struct OcrPipelineTests {

    // MARK: - TextConfidenceFilter (pure, directly testable)

    @Suite("TextConfidenceFilter")
    struct ConfidenceFilterTests {

        @Test("default threshold is 0.4")
        func defaultThreshold() {
            #expect(TextConfidenceFilter.defaultThreshold == 0.4)
        }

        @Test("filter on empty array returns empty")
        func filterEmpty() {
            let result = TextConfidenceFilter.filter([])
            #expect(result.isEmpty)
        }

        @Test("partition on empty array returns empty kept and dropped")
        func partitionEmpty() {
            let (kept, dropped) = TextConfidenceFilter.partition([])
            #expect(kept.isEmpty)
            #expect(dropped.isEmpty)
        }

        @Test("observations above threshold are kept")
        func keptAboveThreshold() {
            let high = RawTextObservation(text: "hello", confidence: 0.9, boundingBox: .zero)
            let result = TextConfidenceFilter.filter([high], threshold: 0.4)
            #expect(result.count == 1)
            #expect(result[0].text == "hello")
        }

        @Test("observations below threshold are dropped")
        func droppedBelowThreshold() {
            let low = RawTextObservation(text: "garbage", confidence: 0.2, boundingBox: .zero)
            let result = TextConfidenceFilter.filter([low], threshold: 0.4)
            #expect(result.isEmpty)
        }

        @Test("observations exactly at threshold are kept")
        func atThresholdKept() {
            let atThreshold = RawTextObservation(text: "text", confidence: 0.4, boundingBox: .zero)
            let result = TextConfidenceFilter.filter([atThreshold], threshold: 0.4)
            #expect(result.count == 1)
        }

        @Test("partition separates kept and dropped correctly")
        func partitionCorrect() {
            let high = RawTextObservation(text: "kept", confidence: 0.8, boundingBox: .zero)
            let low = RawTextObservation(text: "dropped", confidence: 0.1, boundingBox: .zero)
            let (kept, dropped) = TextConfidenceFilter.partition([high, low])
            #expect(kept.count == 1 && kept[0].text == "kept")
            #expect(dropped.count == 1 && dropped[0].text == "dropped")
        }
    }

    // MARK: - Pipeline Integration

    @Test("pipeline fires on .read event and does not crash on empty image")
    func pipelineRunsOnReadEvent() async throws {
        let capture = MockCaptureSource()
        let speech = SpeechOut(silentModeProvider: { false })
        let pipeline = OcrPipeline(captureSource: capture, speechOut: speech)

        var firedContinuation: AsyncStream<ModeFiredEvent>.Continuation!
        let firedEvents = AsyncStream<ModeFiredEvent>(bufferingPolicy: .bufferingNewest(1)) {
            firedContinuation = $0
        }
        let changeEvents = AsyncStream<ModeChangeEvent>(bufferingPolicy: .bufferingNewest(1)) { _ in }

        await pipeline.start(firedEvents: firedEvents, changeEvents: changeEvents)

        // Fire a .read event — pipeline should complete without crash.
        firedContinuation.yield(ModeFiredEvent(mode: .read))

        // 500 ms is enough for a no-text white image Vision request.
        try await Task.sleep(for: .milliseconds(500))
        // Test passes if we reach here without crash.
    }

    @Test("pipeline ignores .scene events")
    func pipelineIgnoresSceneEvent() async throws {
        let capture = MockCaptureSource()
        let speech = SpeechOut(silentModeProvider: { false })
        let pipeline = OcrPipeline(captureSource: capture, speechOut: speech)

        var firedContinuation: AsyncStream<ModeFiredEvent>.Continuation!
        let firedEvents = AsyncStream<ModeFiredEvent>(bufferingPolicy: .bufferingNewest(1)) {
            firedContinuation = $0
        }
        let changeEvents = AsyncStream<ModeChangeEvent>(bufferingPolicy: .bufferingNewest(1)) { _ in }

        await pipeline.start(firedEvents: firedEvents, changeEvents: changeEvents)

        // Fire a .scene event — OcrPipeline should not react.
        firedContinuation.yield(ModeFiredEvent(mode: .scene))

        try await Task.sleep(for: .milliseconds(100))

        // MockCaptureSource tracks whether captureFrame was called.
        let captureCount = await capture.captureCallCount
        #expect(captureCount == 0)
    }

    @Test("mode change event cancels in-flight pipeline")
    func modeChangeCancelsPipeline() async throws {
        let capture = SlowCaptureSource(delayMs: 300)
        let speech = SpeechOut(silentModeProvider: { false })
        let pipeline = OcrPipeline(captureSource: capture, speechOut: speech)

        var firedContinuation: AsyncStream<ModeFiredEvent>.Continuation!
        let firedEvents = AsyncStream<ModeFiredEvent>(bufferingPolicy: .bufferingNewest(1)) {
            firedContinuation = $0
        }
        var changeContinuation: AsyncStream<ModeChangeEvent>.Continuation!
        let changeEvents = AsyncStream<ModeChangeEvent>(bufferingPolicy: .bufferingNewest(1)) {
            changeContinuation = $0
        }

        await pipeline.start(firedEvents: firedEvents, changeEvents: changeEvents)

        // Fire read — pipeline starts, waiting for slow capture.
        firedContinuation.yield(ModeFiredEvent(mode: .read))

        // Inject mode change before capture completes.
        try await Task.sleep(for: .milliseconds(50))
        changeContinuation.yield(ModeChangeEvent(from: .read, to: .scene))

        // Wait past the capture delay — confirm no crash.
        try await Task.sleep(for: .milliseconds(400))
        // Test passes if we reach here.
    }
}

// MARK: - MockCaptureSource

private actor MockCaptureSource: PassthroughCaptureSource {
    private(set) var captureCallCount = 0

    var isActive: Bool { true }
    func start() async throws {}
    func stop() async {}

    func captureFrame() async throws -> CapturedFrame {
        captureCallCount += 1
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return CapturedFrame(image: image, timestamp: .now)
    }
}

// MARK: - SlowCaptureSource

private actor SlowCaptureSource: PassthroughCaptureSource {
    private let delayMs: Int

    init(delayMs: Int) { self.delayMs = delayMs }

    var isActive: Bool { true }
    func start() async throws {}
    func stop() async {}

    func captureFrame() async throws -> CapturedFrame {
        try await Task.sleep(for: .milliseconds(delayMs))
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return CapturedFrame(image: image, timestamp: .now)
    }
}
