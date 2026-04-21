import UIKit
import CoreVideo
import QuartzCore

// MARK: - CapturedFrame

/// A single captured visual frame from the passthrough camera.
///
/// Produced by any `PassthroughCaptureSource` implementer (capture spec)
/// and consumed by `Detector` implementers (detector spec) and the fusion pipeline.
///
/// Carries two wall-clock timestamps plus a Mach-time timestamp:
/// - `shutterTimestamp`: from `PHAsset.creationDate` — truth of when the capture occurred
/// - `deliveryTimestamp`: `Date()` at the moment the capture callback fired
/// - `machTimestamp`: `CACurrentMediaTime()` captured when PeekABoo's closure fires
///
/// `machTimestamp` is the monotonic Mach time required by
/// `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)`. The wall-clock
/// timestamps remain available for `HeadPoseRingBuffer` lookups (which use `Date`).
///
/// Uses `@unchecked Sendable` because `metadata` is `[String: Any]`, which
/// cannot be statically proven Sendable. Callers must not mutate metadata
/// after initialization.
public struct CapturedFrame: @unchecked Sendable {

    // MARK: - Properties

    /// The captured image from the passthrough camera feed.
    public let image: UIImage

    /// When the physical shutter occurred. Sourced from `PHAsset.creationDate`.
    /// Used by `HeadPoseRingBuffer` for pose interpolation (wall-clock domain).
    public let shutterTimestamp: Date

    /// When the capture callback fired (i.e., when PhotoKit delivered the asset).
    /// Always >= `shutterTimestamp`. The delta is PhotoKit delivery lag.
    public let deliveryTimestamp: Date

    /// Monotonic Mach time (`CACurrentMediaTime()`) recorded when PeekABoo's
    /// capture closure fired. This is the clock domain expected by
    /// `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)`.
    public let machTimestamp: TimeInterval

    /// Convenience alias for the shutter timestamp. Downstream specs that only
    /// need one wall-clock timestamp use this property.
    public var timestamp: Date { shutterTimestamp }

    /// Arbitrary key/value metadata attached by the capture source.
    /// Keys used by downstream specs:
    /// - `"intrinsics"`: camera intrinsic matrix (`simd_float3x3`)
    /// - `"extrinsics"`: device-to-world transform at capture time (`simd_float4x4`)
    /// - `"exposureDuration"`: shutter speed in seconds (`Double`)
    public let metadata: [String: Any]

    // MARK: - Outcome

    /// Outcome of the capture pipeline step.
    public enum Outcome: Sendable {
        /// Frame produced and delivered normally.
        case ok
        /// Frame produced but with degraded quality or timing.
        case degraded(DegradedReason)
        /// Frame could not be produced.
        case failed(FailedReason)
    }

    public enum DegradedReason: Sendable {
        /// PhotoKit delivered the asset more than 3 seconds after the shutter.
        /// Fusion's head-pose interpolation may land at the wrong world position.
        case latePhotoKitDelivery
        /// User granted only "Limited" Photos access; album operations unavailable.
        case limitedAccess
    }

    public enum FailedReason: Sendable {
        /// Photos permission denied or restricted.
        case photosDenied
        /// PeekABoo capture hung past the 800 ms budget.
        case timeout
        /// Enterprise CameraFrameProvider path — not available in v0.1.
        case unavailable
    }

    /// The outcome of this frame's capture pipeline.
    public let outcome: Outcome

    // MARK: - Init

    public init(
        image: UIImage,
        shutterTimestamp: Date,
        deliveryTimestamp: Date,
        machTimestamp: TimeInterval = CACurrentMediaTime(),
        metadata: [String: Any] = [:],
        outcome: Outcome = .ok
    ) {
        self.image = image
        self.shutterTimestamp = shutterTimestamp
        self.deliveryTimestamp = deliveryTimestamp
        self.machTimestamp = machTimestamp
        self.metadata = metadata
        self.outcome = outcome
    }

    /// Legacy convenience init for callers that only have a single timestamp.
    public init(image: UIImage, timestamp: Date, metadata: [String: Any] = [:]) {
        self.image = image
        self.shutterTimestamp = timestamp
        self.deliveryTimestamp = timestamp
        self.machTimestamp = CACurrentMediaTime()
        self.metadata = metadata
        self.outcome = .ok
    }
}
