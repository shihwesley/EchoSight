import Foundation

// MARK: - PassthroughCaptureSource

/// Abstracts the visionOS passthrough camera capture pipeline.
///
/// Implementer: `capture` spec (`PassthroughCaptureSession`)
/// Consumer: `fusion` spec (reads frames for detection + head-pose correlation)
///
/// Each call to `captureFrame()` requests a single frame from the underlying
/// capture source. Implementations must be actor-safe; callers may be on any
/// executor. The method throws `EchoSightError.captureFailed` on hardware or
/// permission errors.
public protocol PassthroughCaptureSource: Sendable {

    /// Captures a single passthrough camera frame.
    ///
    /// - Returns: A `CapturedFrame` with the raw image, timestamp, and
    ///   camera metadata (intrinsics, extrinsics, exposure).
    /// - Throws: `EchoSightError.captureFailed` if the camera is unavailable
    ///   or photo library access is denied.
    func captureFrame() async throws -> CapturedFrame

    /// Whether the capture source is currently active and can produce frames.
    var isActive: Bool { get async }

    /// Start the capture source. No-op if already active.
    func start() async throws

    /// Stop the capture source and release camera resources.
    func stop() async
}
