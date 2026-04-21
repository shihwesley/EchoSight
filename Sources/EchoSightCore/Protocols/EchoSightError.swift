import Foundation

// MARK: - EchoSightError

/// Shared error type for all EchoSight features.
///
/// Thrown by protocols defined in `EchoSightCore` (capture, detector, spatial session)
/// and caught at the feature-coordinator layer in `EchoSightApp`.
public enum EchoSightError: Error, LocalizedError {

    // MARK: - Cases

    /// The passthrough camera or photo library is unavailable.
    ///
    /// Associated value carries the underlying system error, if any.
    case captureFailed(Error?)

    /// The object detector is not ready (model not loaded or failed to load).
    case detectorUnavailable

    /// The spatial mesh has not yet populated enough to satisfy the caller.
    ///
    /// Typically thrown by the fusion spec when `MeshClassificationSummary`
    /// confidence is below the minimum threshold.
    case meshNotReady

    /// A required model file could not be loaded from disk.
    ///
    /// The associated `String` is the file path or model identifier that failed.
    case modelLoadFailed(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .captureFailed(let underlying):
            if let underlying {
                return "Capture failed: \(underlying.localizedDescription)"
            }
            return "Capture failed: camera or photo library unavailable."
        case .detectorUnavailable:
            return "Object detector is not loaded or unavailable."
        case .meshNotReady:
            return "Spatial mesh is not yet ready. Move the device to scan the environment."
        case .modelLoadFailed(let identifier):
            return "Failed to load model '\(identifier)'. Check that model files are present."
        }
    }
}
