import Foundation
import UIKit

// MARK: - CameraFrameProviderSource

/// Enterprise fallback stub for `PassthroughCaptureSource`.
///
/// This implementation is reserved for the Enterprise entitlement path
/// (CameraFrameProvider API, available only with Apple Enterprise entitlement).
/// It compiles and conforms to the protocol but always throws `.unavailable`
/// because the entitlement is not available in v0.1.
///
/// When the Enterprise path ships, this stub is replaced with the real implementation
/// that drives `ARKitSession` with `CameraFrameProvider`.
public final class CameraFrameProviderSource: PassthroughCaptureSource, Sendable {

    // MARK: - Init

    public init() {}

    // MARK: - PassthroughCaptureSource

    public var isActive: Bool {
        get async { false }
    }

    public func start() async throws {
        throw EchoSightError.captureFailed(
            CameraFrameProviderError.unavailable
        )
    }

    public func stop() async {
        // No-op: never started
    }

    public func captureFrame() async throws -> CapturedFrame {
        throw EchoSightError.captureFailed(
            CameraFrameProviderError.unavailable
        )
    }
}

// MARK: - CameraFrameProviderError

public enum CameraFrameProviderError: Error, LocalizedError {
    /// Enterprise entitlement not available in this build.
    case unavailable

    public var errorDescription: String? {
        "CameraFrameProvider is unavailable: Enterprise entitlement required."
    }
}
