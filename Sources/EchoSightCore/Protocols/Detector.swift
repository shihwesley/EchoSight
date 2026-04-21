import UIKit

// MARK: - DetectionResult

/// A single object detection result from a `Detector` run.
///
/// Coordinates are in the normalized image space of the source `CapturedFrame`
/// (origin at top-left, range 0.0–1.0 for both axes).
public struct DetectionResult: Sendable {

    // MARK: - Properties

    /// Center point of the detected bounding box in normalized image coordinates.
    public let anchorPoint: CGPoint

    /// Width and height of the bounding box in normalized image coordinates.
    public let size: CGSize

    /// Human-readable class label from the model (e.g., "chair", "door", "person").
    public let label: String

    /// Model confidence score in the range 0.0–1.0.
    public let confidence: Float

    /// Optional instance segmentation mask aligned to the bounding box region.
    /// Nil for detectors that produce only bounding boxes (v0.1 Vision placeholder).
    public let mask: LockingPixelBuffer?

    // MARK: - Init

    public init(
        anchorPoint: CGPoint,
        size: CGSize,
        label: String,
        confidence: Float,
        mask: LockingPixelBuffer? = nil
    ) {
        self.anchorPoint = anchorPoint
        self.size = size
        self.label = label
        self.confidence = confidence
        self.mask = mask
    }
}

// MARK: - Detector

/// Runs object detection on a captured frame and returns bounding-box results.
///
/// Implementer: `detector` spec (`VisionDetector` in v0.1; Falcon-Perception port post-v0.1)
/// Consumer: `scene-description` spec (drives template TTS from top detections)
///
/// Detection is synchronous from the caller's perspective but executes on the
/// actor's internal executor to avoid blocking the main actor.
public protocol Detector: Sendable {

    /// Runs inference on the given frame and returns all detections above threshold.
    ///
    /// - Parameter frame: The passthrough frame to analyze.
    /// - Returns: Array of `DetectionResult`, sorted by confidence descending.
    ///   Empty if no objects exceed the model's confidence threshold.
    /// - Throws: `EchoSightError.detectorUnavailable` if the model is not loaded,
    ///   or `EchoSightError.modelLoadFailed` if initialization failed.
    func detect(in frame: CapturedFrame) async throws -> [DetectionResult]

    /// Whether the underlying model is loaded and ready to process frames.
    var isReady: Bool { get async }

    /// Load the detection model. No-op if already loaded.
    func load() async throws

    /// Unload the model and free memory. Called by the fusion spec under
    /// low-memory conditions.
    func unload() async
}
