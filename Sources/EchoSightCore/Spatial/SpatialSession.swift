import ARKit
import RealityKit
import QuartzCore
import Logging
import Foundation

// MARK: - SpatialSession

/// Owns the ARKit session and coordinates all Layer 1 spatial providers.
///
/// Manages `WorldTrackingProvider` (head pose + world anchors) and
/// `SceneReconstructionProvider` (mesh). Feeds `HeadPoseRingBuffer`,
/// `AnchorEventStream`, and `MeshAnchorTracker`. Obstacle raycasting
/// is initiated externally by `ObstacleRaycaster` through the `RealityView` scene.
///
/// Layer 1 runs continuously. All downstream specs access data through
/// the public async properties and streams rather than directly touching ARKit.
@MainActor
public final class SpatialSession {

    // MARK: - Properties

    private let log = Logger(label: "echosight.spatial")

    /// The running ARKit session.
    private let arkitSession = ARKitSession()

    /// 100 Hz head-pose ring; 5-second window.
    public let headPoseRing = HeadPoseRingBuffer()

    /// World-anchor event stream for `ambient-announce` and `AnchorRehydrator`.
    public let anchorEventStream: AnchorEventStream

    /// Mesh anchor tracker that converts mesh anchors into RealityKit entities.
    public let meshTracker = MeshAnchorTracker()

    private let worldTracking = WorldTrackingProvider()
    // SceneReconstructionProvider.Mode is an enum, not an OptionSet.
    // Pass [.classification] array to enable per-face mesh classification.
    private let sceneReconstruction = SceneReconstructionProvider(modes: [.classification])

    private var runningTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameter anchorMetadataQuery: Injected by `EchoSightApp`. Bridges to
    ///   `annotation-store`'s `anchorMetadata(anchorId:)` lookup.
    public init(anchorMetadataQuery: @escaping AnchorEventStream.AnchorMetadataQuery) {
        self.anchorEventStream = AnchorEventStream(anchorMetadataQuery: anchorMetadataQuery)
    }

    // MARK: - Lifecycle

    /// Start the ARKit session and all Layer 1 providers.
    public func start() async throws {
        log.info("spatial.session.started")

        // SceneReconstructionProvider is unsupported on the visionOS Simulator and
        // crashes the process if registered. Gate on `isSupported` so the rest of
        // Layer 1 (world tracking + Date-domain pose ring) still runs in CI.
        var providers: [any DataProvider] = [worldTracking]
        if SceneReconstructionProvider.isSupported {
            providers.append(sceneReconstruction)
        } else {
            log.warning("spatial.session.sceneReconstruction.unsupported — running without mesh")
        }

        do {
            try await arkitSession.run(providers)
        } catch {
            log.error("spatial.session.start.failed", metadata: ["error": .string(error.localizedDescription)])
            throw EchoSightError.meshNotReady
        }

        runningTask = Task { [weak self] in
            await self?.processARKitEvents()
        }
    }

    /// Stop the ARKit session and cancel all running tasks.
    public func stop() {
        runningTask?.cancel()
        runningTask = nil
        log.info("spatial.session.stopped")
    }

    // MARK: - Head Pose

    /// Returns the interpolated head-pose transform at the given timestamp.
    public func headPose(at date: Date) throws -> simd_float4x4 {
        try headPoseRing.pose(at: date)
    }

    /// Cumulative angular rotation (radians) over the given window.
    /// Used by `ambient-announce` for the compound idle rule.
    public func headPoseVariance(window: TimeInterval) -> Float {
        headPoseRing.headPoseVariance(window: window)
    }

    // MARK: - Mesh Classification

    /// On-demand snapshot of the current mesh classification distribution.
    public func meshClassificationSummary() -> MeshClassificationSummary {
        meshTracker.currentSummary()
    }

    // MARK: - Private: ARKit Event Loop

    private func processARKitEvents() async {
        // Process WorldTracking anchor updates.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.processWorldTrackingUpdates()
            }
            group.addTask { [weak self] in
                await self?.processSceneReconstructionUpdates()
            }
            group.addTask { [weak self] in
                await self?.processSessionEvents()
            }
        }
    }

    private func processWorldTrackingUpdates() async {
        for await update in worldTracking.anchorUpdates {
            let anchor = update.anchor
            switch update.event {
            case .added, .updated:
                let isNew = update.event == .added
                await anchorEventStream.handleAnchorUpdate(
                    anchorId: anchor.id,
                    isNewFromARKit: isNew
                )
            case .removed:
                break
            }

            // Update head pose ring if device pose is available.
            if let transform = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform {
                headPoseRing.append(transform: transform)
                log.debug("spatial.pose.updated")
            }
        }
    }

    private func processSceneReconstructionUpdates() async {
        for await update in sceneReconstruction.anchorUpdates {
            await meshTracker.handleMeshUpdate(update)
        }
    }

    private func processSessionEvents() async {
        for await event in arkitSession.events {
            switch event {
            case .authorizationChanged(let type, let status):
                log.info("spatial.session.auth", metadata: [
                    "type": .string("\(type)"),
                    "status": .string("\(status)"),
                ])
            case .dataProviderStateChanged(_, let newState, let error):
                if let error {
                    log.error("spatial.session.providerError", metadata: ["error": .string(error.localizedDescription)])
                }
                if newState == .paused {
                    await anchorEventStream.handleSessionInterrupted()
                } else if newState == .running {
                    await anchorEventStream.handleSessionResumed()
                }
                log.info("spatial.session.stateChanged", metadata: ["state": .string("\(newState)")])
            @unknown default:
                break
            }
        }
    }
}
