import UIKit
import CoreVideo

// MARK: - CapturedFrame

/// A single captured visual frame from the passthrough camera.
///
/// Produced by any `PassthroughCaptureSource` implementer (capture spec)
/// and consumed by `Detector` implementers (detector spec) and the fusion pipeline.
///
/// Uses `@unchecked Sendable` because `metadata` is `[String: Any]`, which
/// cannot be statically proven Sendable. Callers must not mutate metadata
/// after initialization.
public struct CapturedFrame: @unchecked Sendable {

    // MARK: - Properties

    /// The captured image from the passthrough camera feed.
    public let image: UIImage

    /// When the frame was captured. Used by the head-pose ring buffer for
    /// spatial-core pose interpolation at this exact instant.
    public let timestamp: Date

    /// Arbitrary key/value metadata attached by the capture source.
    /// Keys used by downstream specs:
    /// - `"intrinsics"`: camera intrinsic matrix (`simd_float3x3`)
    /// - `"extrinsics"`: device-to-world transform at capture time (`simd_float4x4`)
    /// - `"exposureDuration"`: shutter speed in seconds (`Double`)
    public let metadata: [String: Any]

    // MARK: - Init

    public init(image: UIImage, timestamp: Date, metadata: [String: Any] = [:]) {
        self.image = image
        self.timestamp = timestamp
        self.metadata = metadata
    }
}
