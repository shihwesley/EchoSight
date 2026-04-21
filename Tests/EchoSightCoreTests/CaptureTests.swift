import Foundation
import Testing

@testable import EchoSightCore

// MARK: - CapturedFrame Tests

struct CapturedFrameTests {

    // MARK: - Dual timestamps

    @Test
    func shutterAndDeliveryTimestampsAreDifferent() {
        let shutter = Date(timeIntervalSinceNow: -0.5)
        let delivery = Date()
        let frame = CapturedFrame(
            image: .init(),
            shutterTimestamp: shutter,
            deliveryTimestamp: delivery
        )
        #expect(frame.shutterTimestamp != frame.deliveryTimestamp)
        #expect(frame.deliveryTimestamp.timeIntervalSince(frame.shutterTimestamp) > 0)
    }

    @Test
    func timestampAliasesShutterTimestamp() {
        let shutter = Date(timeIntervalSinceNow: -1.0)
        let delivery = Date()
        let frame = CapturedFrame(
            image: .init(),
            shutterTimestamp: shutter,
            deliveryTimestamp: delivery
        )
        #expect(frame.timestamp == frame.shutterTimestamp)
    }

    @Test
    func legacyInitSetsBothTimestampsEqual() {
        let ts = Date()
        let frame = CapturedFrame(image: .init(), timestamp: ts)
        #expect(frame.shutterTimestamp == ts)
        #expect(frame.deliveryTimestamp == ts)
        #expect(frame.timestamp == ts)
    }

    // MARK: - Outcome

    @Test
    func defaultOutcomeIsOk() {
        let frame = CapturedFrame(
            image: .init(),
            shutterTimestamp: Date(),
            deliveryTimestamp: Date()
        )
        if case .ok = frame.outcome {
            // pass
        } else {
            Issue.record("Expected .ok outcome, got \(frame.outcome)")
        }
    }

    @Test
    func degradedLateDeliveryOutcomePreserved() {
        let frame = CapturedFrame(
            image: .init(),
            shutterTimestamp: Date(timeIntervalSinceNow: -4.0),
            deliveryTimestamp: Date(),
            outcome: .degraded(.latePhotoKitDelivery)
        )
        if case .degraded(let reason) = frame.outcome {
            #expect(reason == .latePhotoKitDelivery)
        } else {
            Issue.record("Expected .degraded(.latePhotoKitDelivery), got \(frame.outcome)")
        }
    }

    @Test
    func degradedLimitedAccessOutcomePreserved() {
        let frame = CapturedFrame(
            image: .init(),
            shutterTimestamp: Date(),
            deliveryTimestamp: Date(),
            outcome: .degraded(.limitedAccess)
        )
        if case .degraded(let reason) = frame.outcome {
            #expect(reason == .limitedAccess)
        } else {
            Issue.record("Expected .degraded(.limitedAccess), got \(frame.outcome)")
        }
    }

    @Test
    func lagOverThreeSecondsIsDetectable() {
        let shutter = Date(timeIntervalSinceNow: -3.5)
        let delivery = Date()
        let lag = delivery.timeIntervalSince(shutter)
        #expect(lag > 3.0)
    }

    @Test
    func lagUnderThreeSecondsIsNormal() {
        let shutter = Date(timeIntervalSinceNow: -0.4)
        let delivery = Date()
        let lag = delivery.timeIntervalSince(shutter)
        #expect(lag < 3.0)
    }
}

// MARK: - CameraFrameProviderSource Tests

struct CameraFrameProviderSourceTests {

    @Test
    func captureFrameThrowsUnavailable() async throws {
        let source = CameraFrameProviderSource()
        do {
            _ = try await source.captureFrame()
            Issue.record("Expected captureFrame() to throw, but it returned a frame")
        } catch EchoSightError.captureFailed(let underlying) {
            // Expected: captureFailed with CameraFrameProviderError.unavailable
            #expect(underlying is CameraFrameProviderError)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func startThrowsUnavailable() async throws {
        let source = CameraFrameProviderSource()
        do {
            try await source.start()
            Issue.record("Expected start() to throw, but it returned normally")
        } catch EchoSightError.captureFailed(let underlying) {
            #expect(underlying is CameraFrameProviderError)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func stopIsNoop() async {
        let source = CameraFrameProviderSource()
        await source.stop() // Should not throw or crash
    }

    @Test
    func isActiveReturnsFalse() async {
        let source = CameraFrameProviderSource()
        let active = await source.isActive
        #expect(active == false)
    }

    @Test
    func conformsToPassthroughCaptureSource() {
        let source: any PassthroughCaptureSource = CameraFrameProviderSource()
        // Conformance verified at compile time — this test documents the requirement
        _ = source
    }
}

// MARK: - EchoSightAlbumError Tests

struct EchoSightAlbumErrorTests {

    @Test
    func creationFailedErrorHasDescription() {
        let error = EchoSightAlbumError.creationFailed(nil)
        #expect(error.errorDescription != nil)
        #expect(!(error.errorDescription ?? "").isEmpty)
    }

    @Test
    func creationFailedWithUnderlyingIncludesDetails() {
        let underlying = NSError(domain: "Photos", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Disk full"
        ])
        let error = EchoSightAlbumError.creationFailed(underlying)
        #expect(error.errorDescription?.contains("Disk full") == true)
    }

    @Test
    func albumNotFoundHasDescription() {
        let error = EchoSightAlbumError.albumNotFound
        #expect(error.errorDescription != nil)
        #expect(!(error.errorDescription ?? "").isEmpty)
    }
}

// MARK: - CameraFrameProviderError Tests

struct CameraFrameProviderErrorTests {

    @Test
    func unavailableHasDescription() {
        let error = CameraFrameProviderError.unavailable
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("Enterprise") == true)
    }
}
