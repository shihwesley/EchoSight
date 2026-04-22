import Foundation
import Testing
import simd
@testable import EchoSightCore

// MARK: - PixelToRay Tests

struct PixelToRayTests {

    // MARK: - Cardinal direction tests

    /// Center pixel (0.5, 0.5) must point along -Z in head space.
    /// x and y should be essentially 0 (within float precision).
    @Test
    func centerPixelPointsAlongNegativeZ() {
        let ray = PixelToRay.ray(nx: 0.5, ny: 0.5, hFovDeg: 90, aspect: 1.0)
        #expect(abs(ray.x) < 1e-5, "Center ray x should be ~0, got \(ray.x)")
        #expect(abs(ray.y) < 1e-5, "Center ray y should be ~0, got \(ray.y)")
        #expect(ray.z < -0.99, "Center ray z should be ~-1, got \(ray.z)")
    }

    /// Top of image (ny=0) should produce positive Y in head space.
    /// (Screen Y down → head space Y up)
    @Test
    func topOfImageHasPositiveY() {
        let ray = PixelToRay.ray(nx: 0.5, ny: 0.0, hFovDeg: 90, aspect: 1.0)
        #expect(ray.y > 0, "Top of image should have positive head-space Y, got \(ray.y)")
    }

    /// Bottom of image (ny=1) should produce negative Y in head space.
    @Test
    func bottomOfImageHasNegativeY() {
        let ray = PixelToRay.ray(nx: 0.5, ny: 1.0, hFovDeg: 90, aspect: 1.0)
        #expect(ray.y < 0, "Bottom of image should have negative head-space Y, got \(ray.y)")
    }

    /// Left edge (nx=0) should produce negative X in head space.
    @Test
    func leftEdgeHasNegativeX() {
        let ray = PixelToRay.ray(nx: 0.0, ny: 0.5, hFovDeg: 90, aspect: 1.0)
        #expect(ray.x < 0, "Left edge should have negative head-space X, got \(ray.x)")
    }

    /// Right edge (nx=1) should produce positive X in head space.
    @Test
    func rightEdgeHasPositiveX() {
        let ray = PixelToRay.ray(nx: 1.0, ny: 0.5, hFovDeg: 90, aspect: 1.0)
        #expect(ray.x > 0, "Right edge should have positive head-space X, got \(ray.x)")
    }

    // MARK: - Angular accuracy tests

    /// For a 90° horizontal FOV, the corner pixel angle from center should be ≤ 45°.
    @Test
    func cornerAngleWithin45DegreesFor90DegFov() {
        let center = PixelToRay.ray(nx: 0.5, ny: 0.5, hFovDeg: 90, aspect: 1.0)
        let corner = PixelToRay.ray(nx: 0.0, ny: 0.5, hFovDeg: 90, aspect: 1.0)

        // Angle between rays via dot product
        let dotProduct = simd_dot(center, corner)
        let clampedDot = min(max(dotProduct, -1.0), 1.0)
        let angleDeg = acos(clampedDot) * 180.0 / .pi

        // For 90° hFov, horizontal half-angle is 45°. Allow 1° tolerance for float math.
        #expect(angleDeg <= 46.0, "Corner angle should be ≤ 46° for 90° FOV, got \(angleDeg)°")
        #expect(angleDeg >= 44.0, "Corner angle should be ≥ 44° for 90° FOV, got \(angleDeg)°")
    }

    /// At 16:9 aspect with 90° hFov, the top-edge ray's vertical angle must follow
    /// `tanV = tanH / aspect`, not `vFov = hFov / aspect` (a prior bug that zeroed
    /// out for square frames but under-tilted on real device captures).
    @Test
    func verticalAngleFollowsTangentRatioForNonSquareAspect() {
        let topEdge = PixelToRay.ray(nx: 0.5, ny: 0.0, hFovDeg: 90, aspect: 16.0 / 9.0)

        // Expected: tanH = tan(45°) = 1.0 → tanV = 1.0 / (16/9) = 0.5625
        // Top-edge angle from -Z center = atan(tanV) ≈ 29.358°
        // Y component of unit ray = sin(29.358°) ≈ 0.4903
        let expectedY: Float = 0.4903

        #expect(topEdge.y > 0, "Top-edge ray should point upward (+Y)")
        #expect(abs(topEdge.y - expectedY) < 0.01,
                "Top-edge Y should be ≈ \(expectedY) for 16:9 + 90° hFov, got \(topEdge.y)")
    }

    /// Result must be a unit vector (length ≈ 1.0).
    @Test
    func outputIsUnitVector() {
        let testPoints: [(Float, Float)] = [
            (0.5, 0.5), (0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0)
        ]
        for (nx, ny) in testPoints {
            let ray = PixelToRay.ray(nx: nx, ny: ny, hFovDeg: 90, aspect: 1.0)
            let length = simd_length(ray)
            #expect(abs(length - 1.0) < 1e-5, "Ray should be unit length, got \(length) for (\(nx), \(ny))")
        }
    }

    // MARK: - NaN / edge case tests

    /// NaN input should return the safe fallback (0, 0, -1) without crashing.
    @Test
    func nanInputReturnsSafeFallback() {
        let ray = PixelToRay.ray(nx: .nan, ny: .nan, hFovDeg: 90, aspect: 1.0)
        #expect(ray.x.isFinite, "NaN input should produce finite ray.x, got \(ray.x)")
        #expect(ray.y.isFinite, "NaN input should produce finite ray.y, got \(ray.y)")
        #expect(ray.z.isFinite, "NaN input should produce finite ray.z, got \(ray.z)")
    }

    /// Infinity input should not crash.
    @Test
    func infinityInputReturnsSafeFallback() {
        let ray = PixelToRay.ray(nx: .infinity, ny: .infinity, hFovDeg: 90, aspect: 1.0)
        #expect(ray.x.isFinite)
        #expect(ray.y.isFinite)
        #expect(ray.z.isFinite)
    }

    /// Zero FOV returns safe fallback.
    @Test
    func zeroFovReturnsFallback() {
        let ray = PixelToRay.ray(nx: 0.5, ny: 0.5, hFovDeg: 0, aspect: 1.0)
        // Should not crash; returns (0, 0, -1)
        #expect(ray.z == -1.0)
    }

    // MARK: - worldRay tests

    /// worldRay with identity matrix should match the input head-local ray.
    @Test
    func worldRayWithIdentityMatchesHeadLocalRay() {
        let headRay = PixelToRay.ray(nx: 0.5, ny: 0.5, hFovDeg: 90, aspect: 1.0)
        let identity = simd_float4x4(1)
        let worldRay = PixelToRay.worldRay(headLocalRay: headRay, deviceToWorld: identity)
        #expect(abs(worldRay.x - headRay.x) < 1e-5)
        #expect(abs(worldRay.y - headRay.y) < 1e-5)
        #expect(abs(worldRay.z - headRay.z) < 1e-5)
    }
}

// MARK: - FusionConstants Tests

struct FusionConstantsTests {

    @Test
    func assumedHorizontalFovIsPositive() {
        #expect(kAssumedHorizontalFov > 0)
        #expect(kAssumedHorizontalFov < 180)
    }

    @Test
    func personShoulderHeightIsReasonable() {
        // Should be between 1.0 m and 2.0 m for typical shoulder height
        #expect(kPersonShoulderHeightM > 1.0)
        #expect(kPersonShoulderHeightM < 2.0)
    }

    @Test
    func defaultRaycastDistanceIsPositive() {
        #expect(kDefaultRaycastDistanceM > 0)
    }
}
