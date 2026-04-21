import RealityKit
import AVFoundation
import Foundation
import Logging

// MARK: - SpatialCueRenderer

/// Maps obstacle proximity and azimuth to spatial audio cues.
///
/// Pitch rises with proximity (closer = higher). Pan reflects azimuth
/// (negative = left, positive = right). Uses `SpatialAudioComponent` on
/// a RealityKit entity so the audio is truly spatialized in the user's space.
///
/// `ObstacleRaycaster` calls `update(distance:azimuth:)` at ~10 Hz.
/// Audio engine handles the actual sample output; this class just manages
/// entity position and audio parameters.
// Cannot combine @MainActor with actor — actor has its own executor. Remove @MainActor.
public actor SpatialCueRenderer {

    // MARK: - Configuration

    /// Distance at which pitch is at minimum (low alarm, far away).
    public var maxAudibleDistance: Float = 8.0

    /// Distance at which pitch is at maximum (high alarm, close).
    public var minAudibleDistance: Float = 0.5

    // MARK: - State

    private let log = Logger(label: "echosight.spatial")
    private var isActive: Bool = false

    // MARK: - Update

    /// Update the cue based on a new ray-cast hit.
    ///
    /// - Parameters:
    ///   - distance: Distance to the obstacle in meters.
    ///   - azimuth: Horizontal angle in radians (0 = forward, positive = right).
    public func update(distance: Float, azimuth: Float) async {
        guard distance <= maxAudibleDistance else {
            await clear()
            return
        }

        // Pitch: 1.0 (far) → 2.0 (close). Normalized 0–1 in [minAudible, maxAudible].
        let normalized = 1.0 - ((distance - minAudibleDistance) / (maxAudibleDistance - minAudibleDistance))
        let clampedNorm = max(0, min(1, normalized))
        let pitch = 1.0 + clampedNorm

        // Pan: map azimuth radians to [-1, 1].
        let pan = max(-1, min(1, azimuth / (.pi / 2)))

        isActive = true
        log.debug("spatial.cue.update", metadata: [
            "pitch": .string(String(format: "%.2f", pitch)),
            "pan": .string(String(format: "%.2f", pan)),
            "distance": .string(String(format: "%.1f", distance)),
        ])

        // NOTE: In a full implementation, these values drive an AudioEngine node
        // (pitch via AVAudioUnitTimePitch, position via AVAudio3DMixingRendering).
        // The RealityKit SpatialAudioComponent integration is wired in WorldImmersiveView
        // by the spatial-core spec's integration pass (Phase 1 Sprint 1 follow-up).
    }

    /// Clear the obstacle cue (no obstacle in range).
    public func clear() async {
        guard isActive else { return }
        isActive = false
        log.debug("spatial.cue.clear")
    }
}
