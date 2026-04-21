#if DEBUG
import SwiftUI
import EchoSightCore

// MARK: - FovCalibrationView

/// Debug-only view for empirical horizontal FOV calibration.
///
/// ## Usage
/// 1. Place a chair at a known distance (e.g. 2.0 m) from the device.
/// 2. Open this view in a Debug build.
/// 3. Sweep `hFov` from 90° to 110° in 2° steps.
/// 4. Capture a frame and compare the reported raycast distance to the tape measure.
/// 5. The `hFov` value where the distances agree is the device's true horizontal FOV.
/// 6. Update `kAssumedHorizontalFov` in `FusionConstants.swift` with the result.
///
/// This view is excluded from Release builds via `#if DEBUG`.
struct FovCalibrationView: View {

    // MARK: - State

    @State private var hFov: Double = Double(kAssumedHorizontalFov)
    @State private var lastRaycastDistance: Float? = nil
    @State private var aspect: Double = 1.0

    // MARK: - Body

    var body: some View {
        VStack(spacing: 20) {
            Text("FOV Calibration")
                .font(.headline)

            Divider()

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("How to calibrate:")
                    .font(.subheadline)
                    .bold()
                Text("1. Place a chair at a measured distance (e.g. 2.0 m).")
                Text("2. Point the device directly at the chair.")
                Text("3. Sweep the slider until the raycast distance matches the tape measure.")
                Text("4. Record the hFov value and update kAssumedHorizontalFov.")
            }
            .font(.caption)
            .padding()
            .background(Color.yellow.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Divider()

            // hFov slider: 90° to 110° in 2° visual steps
            VStack(alignment: .leading) {
                Text("Horizontal FOV: \(hFov, format: .number.precision(.fractionLength(1)))°")
                    .monospacedDigit()
                Slider(value: $hFov, in: 90...110, step: 2)
            }

            // Aspect ratio input
            VStack(alignment: .leading) {
                Text("Aspect ratio (w/h): \(aspect, format: .number.precision(.fractionLength(2)))")
                    .monospacedDigit()
                Slider(value: $aspect, in: 0.5...2.0, step: 0.01)
            }

            Divider()

            // Computed ray for center pixel
            let centerRayX = PixelToRay.ray(nx: 0.5, ny: 0.5, hFovDeg: Float(hFov), aspect: Float(aspect)).x
            let centerRayY = PixelToRay.ray(nx: 0.5, ny: 0.5, hFovDeg: Float(hFov), aspect: Float(aspect)).y
            let centerRayZ = PixelToRay.ray(nx: 0.5, ny: 0.5, hFovDeg: Float(hFov), aspect: Float(aspect)).z

            VStack(alignment: .leading, spacing: 4) {
                Text("Center ray (head-local):")
                    .font(.caption)
                    .bold()
                Text("x: \(centerRayX, format: .number.precision(.fractionLength(4)))")
                    .monospacedDigit()
                    .font(.caption)
                Text("y: \(centerRayY, format: .number.precision(.fractionLength(4)))")
                    .monospacedDigit()
                    .font(.caption)
                Text("z: \(centerRayZ, format: .number.precision(.fractionLength(4)))")
                    .monospacedDigit()
                    .font(.caption)
            }

            if let dist = lastRaycastDistance {
                Text("Last raycast distance: \(dist, format: .number.precision(.fractionLength(2))) m")
                    .font(.title3)
                    .bold()
                    .foregroundStyle(.green)
            } else {
                Text("No raycast result yet.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("DEBUG BUILD ONLY — Not included in Release")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Helper

    /// Called externally when a fusion result arrives during calibration sweep.
    func updateRaycastDistance(_ distance: Float) {
        lastRaycastDistance = distance
    }
}

// MARK: - Preview

#Preview {
    FovCalibrationView()
        .frame(width: 400, height: 600)
}
#endif
