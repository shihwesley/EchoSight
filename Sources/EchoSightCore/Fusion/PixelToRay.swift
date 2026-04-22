import Foundation
import simd

// MARK: - PixelToRay

/// Pure pixel-space to head-local ray conversion.
///
/// All math is framework-free and fully unit-testable without a device.
/// Assumes a rectilinear (pinhole) lens model.
///
/// Coordinate conventions:
/// - Input `nx`, `ny`: normalized pixel coords in [0, 1], origin top-left.
/// - Output: normalized direction vector in head-local space.
///   - +X is right, +Y is up, -Z is forward (right-handed, same as RealityKit).
///
/// Consumers:
/// - `FusionEngine`: converts each `DetectionResult.anchorPoint` to a head-local ray
///   before transforming to world space via the head-pose matrix.
public enum PixelToRay {

    // MARK: - Main conversion

    /// Convert a normalized pixel coordinate to a head-local unit ray.
    ///
    /// - Parameters:
    ///   - nx: Normalized horizontal coordinate, 0 (left) to 1 (right).
    ///   - ny: Normalized vertical coordinate, 0 (top) to 1 (bottom).
    ///   - hFovDeg: Horizontal field of view in degrees (default: `kAssumedHorizontalFov`).
    ///   - aspect: Image aspect ratio (width / height). Default 1.0 is square.
    /// - Returns: A normalized direction vector in head-local space.
    ///   Returns `SIMD3<Float>(0, 0, -1)` for exact center input.
    /// - Note: Returns `(0, 0, -1)` if inputs are NaN; callers should guard upstream.
    public static func ray(nx: Float, ny: Float, hFovDeg: Float = kAssumedHorizontalFov, aspect: Float = 1.0) -> SIMD3<Float> {
        // Guard against degenerate FOV
        guard hFovDeg > 0, hFovDeg < 180, aspect > 0 else {
            return SIMD3<Float>(0, 0, -1)
        }

        let hFovRad = hFovDeg * .pi / 180.0
        // Rectilinear derivation: vertical FOV follows from dividing tangents,
        // not radians. tan(vFov/2) = tan(hFov/2) / aspect.
        let tanH = tan(hFovRad / 2.0)
        let tanV = tanH / aspect

        // Center-relative normalized device coords
        let cx: Float = nx - 0.5            // [-0.5, 0.5], +X = right
        let cy: Float = 0.5 - ny            // [-0.5, 0.5], +Y = up (screen Y is down)

        // Ray in head-local space (-Z forward, right-handed)
        let x = cx * 2.0 * tanH
        let y = cy * 2.0 * tanV
        let z: Float = -1.0

        let raw = SIMD3<Float>(x, y, z)

        // Guard NaN (e.g. from NaN input)
        guard raw.x.isFinite, raw.y.isFinite, raw.z.isFinite else {
            return SIMD3<Float>(0, 0, -1)
        }

        return normalize(raw)
    }

    // MARK: - Helpers

    /// Transform a head-local ray into world space using the device-to-world matrix.
    ///
    /// - Parameters:
    ///   - headLocalRay: Normalized direction in head space (from `ray(nx:ny:hFovDeg:aspect:)`).
    ///   - deviceToWorld: 4×4 transform from `WorldTrackingProvider.queryDeviceAnchor`
    ///     or from `HeadPoseRingBuffer.pose(at:)`.
    /// - Returns: Normalized direction in world space.
    public static func worldRay(headLocalRay: SIMD3<Float>, deviceToWorld: simd_float4x4) -> SIMD3<Float> {
        // Extract the rotation part (upper-left 3×3) and apply it
        let rotated = deviceToWorld.upperLeft3x3 * headLocalRay
        return normalize(rotated)
    }

    /// Compute the world-space end point of a ray for use with `Scene.raycast(from:to:...)`.
    ///
    /// - Parameters:
    ///   - origin: Ray origin in world space (typically device position from the pose matrix).
    ///   - direction: Normalized world-space ray direction (from `worldRay`).
    ///   - length: Ray length in meters. Default 10 m covers typical indoor scenes.
    /// - Returns: End point for the `to:` parameter of `Scene.raycast`.
    public static func rayEndPoint(origin: SIMD3<Float>, direction: SIMD3<Float>, length: Float = 10.0) -> SIMD3<Float> {
        origin + direction * length
    }
}

// MARK: - simd_float4x4 helpers

extension simd_float4x4 {
    /// The origin (translation) of the transform.
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    /// The upper-left 3×3 rotation/scale sub-matrix.
    var upperLeft3x3: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z),
            SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z),
            SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
        )
    }
}
