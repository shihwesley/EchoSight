import RealityKit
import ARKit
import Foundation
import Logging

// MARK: - ObstacleRaycaster

/// Throttled forward ray-cast from head position for obstacle detection.
///
/// Fires at ~10 Hz. On hit within `maxDistance`, notifies `SpatialCueRenderer`
/// with distance and estimated azimuth. Never blocks the main actor for longer
/// than one ray-cast query (<10 ms per spec acceptance criterion).
@MainActor
public final class ObstacleRaycaster {

    // MARK: - Configuration

    /// Maximum detection range in meters.
    public var maxDistance: Float = 10.0

    /// Ray-cast interval (10 Hz = every 100 ms).
    private let interval: TimeInterval = 0.1

    // MARK: - Dependencies

    private let log = Logger(label: "echosight.spatial")
    private let cueRenderer: SpatialCueRenderer

    // MARK: - State

    private var task: Task<Void, Never>?
    private var lastFireTime: Date = .distantPast

    // MARK: - Init

    public init(cueRenderer: SpatialCueRenderer) {
        self.cueRenderer = cueRenderer
    }

    // MARK: - Lifecycle

    public func start(in scene: RealityKit.Scene) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fire(in: scene)
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            }
        }
        log.info("spatial.raycast.started")
    }

    public func stop() {
        task?.cancel()
        task = nil
        log.info("spatial.raycast.stopped")
    }

    // MARK: - Ray-Cast

    private func fire(in scene: RealityKit.Scene) async {
        // Cast a ray forward from the scene origin (head-aligned in mixed immersion).
        let origin = SIMD3<Float>(0, 0, 0)
        let direction = SIMD3<Float>(0, 0, -1) // forward in camera space

        let hits = scene.raycast(
            origin: origin,
            direction: direction,
            length: maxDistance,
            query: .nearest,
            mask: .sceneUnderstanding,
            relativeTo: nil
        )

        if let hit = hits.first {
            let distance = hit.distance
            let azimuth = atan2(hit.position.x, -hit.position.z) // radians
            await cueRenderer.update(distance: distance, azimuth: azimuth)
            log.debug("spatial.raycast.hit", metadata: [
                "distance": .string(String(format: "%.2f", distance)),
            ])
        } else {
            await cueRenderer.clear()
            log.debug("spatial.raycast.miss")
        }
    }
}
