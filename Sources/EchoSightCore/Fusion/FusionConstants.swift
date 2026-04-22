import Foundation

// MARK: - FusionConstants

/// Project-wide constants for the fusion pipeline.
///
/// `kAssumedHorizontalFov` should be empirically measured using `FovCalibrationView`
/// (DEBUG only) and updated here once the device value is confirmed.

/// Assumed horizontal field of view of the passthrough camera in degrees.
/// Empirical calibration pending — use the debug FovCalibrationView to refine.
public let kAssumedHorizontalFov: Float = 100

/// Approximate shoulder height above floor in meters.
/// Used for the person-bypass heuristic when mesh ray-cast is skipped.
public let kPersonShoulderHeightM: Float = 1.4

/// Default distance in meters when a ray-cast returns no mesh hits.
/// Applied to annotation candidates marked `.degraded(.raycastMiss)`.
public let kDefaultRaycastDistanceM: Float = 3.0
