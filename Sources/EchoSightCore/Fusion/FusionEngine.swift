import ARKit
import Foundation
import Logging
import RealityKit
import simd

// MARK: - FusionEngine

/// Bridges pixel-space `DetectionResult` values to world-space `AnnotationCandidate` values.
///
/// **Two-tier design (Swift 6 concurrency):**
/// - Pure tier (actor background queue): `PixelToRay`, pose matrix math, `LabelReconciler`.
/// - RealityKit tier (main actor): `Scene.raycast` — required because `RealityKit.Scene`
///   is `@MainActor @preconcurrency` on visionOS 2.
///
/// **Clock domains:**
/// - `frame.machTimestamp` → `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)` (Mach time)
/// - `frame.shutterTimestamp` → `HeadPoseRingBuffer.pose(at:)` (wall-clock Date)
///
/// **Simulator guard:** `Scene.raycast` requires a populated mesh. When `scene` is nil
/// (simulator, unit tests) or mesh is empty, fusion falls back to the 3 m default distance.
public actor FusionEngine {

    // MARK: - Dependencies

    private let poseRingBuffer: HeadPoseRingBuffer
    private let logger = Logger(label: LogCategories.fusion)

    // MARK: - Init

    public init(poseRingBuffer: HeadPoseRingBuffer) {
        self.poseRingBuffer = poseRingBuffer
    }

    // MARK: - Main entry point

    /// Fuse a set of detections with current head pose and optional mesh scene.
    ///
    /// - Parameters:
    ///   - detections: `DetectionResult` values from `VisionDetector` or `FalconDetector`.
    ///   - frame: The source frame (provides timestamps for pose lookup).
    ///   - scene: The live `RealityKit.Scene` for mesh ray-casting, or nil in tests/simulator.
    ///   - hFovDeg: Horizontal FOV override. Defaults to `kAssumedHorizontalFov`.
    ///   - aspect: Image aspect ratio (width/height). Defaults to 1.0.
    /// - Returns: One `AnnotationCandidate` per detection.
    public func fuse(
        detections: [DetectionResult],
        frame: CapturedFrame,
        scene: RealityKit.Scene?,
        hFovDeg: Float = kAssumedHorizontalFov,
        aspect: Float = 1.0
    ) async -> [AnnotationCandidate] {
        guard !detections.isEmpty else { return [] }

        logger.info("fusion.fuse.started — detectionCount: \(detections.count)")
        let start = Date()

        // 1. Resolve head pose from ring buffer (Date-domain, wall clock)
        let (deviceToWorld, poseOutcome) = resolveHeadPose(at: frame.shutterTimestamp)

        // 2. For each detection, compute world-space position
        var candidates: [AnnotationCandidate] = []
        for detection in detections {
            let nx = Float(detection.anchorPoint.x)
            let ny = Float(detection.anchorPoint.y)

            // Head-local ray from normalized pixel coords
            let headRay = PixelToRay.ray(nx: nx, ny: ny, hFovDeg: hFovDeg, aspect: aspect)

            // Transform ray to world space
            let deviceOrigin = deviceToWorld.translation
            let worldDir = PixelToRay.worldRay(headLocalRay: headRay, deviceToWorld: deviceToWorld)
            let rayEnd = PixelToRay.rayEndPoint(origin: deviceOrigin, direction: worldDir)

            // 3. Raycast on main actor (RealityKit requirement)
            let (meshClass, meshDist): (String?, Float?) = await performRaycast(
                scene: scene,
                from: deviceOrigin,
                to: rayEnd
            )

            // 4. Log misses
            if meshClass == nil {
                logger.info("fusion.raycast.miss — label: \(detection.label)")
            }

            // 5. Reconcile label + distance
            let reconciled = LabelReconciler.reconcile(
                detectorLabel: detection.label,
                meshClassification: meshClass,
                meshDistance: meshDist
            )

            if let meshClass {
                let detLower = detection.label.lowercased()
                let meshLower = meshClass.lowercased()
                if detLower != meshLower {
                    logger.info("fusion.reconcile.disagree — detector: \(detection.label), mesh: \(meshClass), resolution: preferDetector")
                }
            }

            // 6. Compute world position along the ray at the resolved distance
            let worldPosition = deviceOrigin + worldDir * reconciled.distance

            // 7. Combine pose degradation with reconciler outcome
            let finalOutcome = combinedOutcome(poseOutcome: poseOutcome, reconcileOutcome: reconciled.outcome)

            candidates.append(AnnotationCandidate(
                label: reconciled.label,
                confidence: detection.confidence,
                worldPosition: worldPosition,
                distance: reconciled.distance,
                outcome: finalOutcome
            ))
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("fusion.fuse.completed — candidateCount: \(candidates.count), durationMs: \(durationMs)")
        return candidates
    }

    // MARK: - Private: Pose resolution

    private func resolveHeadPose(at date: Date) -> (simd_float4x4, AnnotationCandidate.Outcome?) {
        do {
            let pose = try poseRingBuffer.pose(at: date)
            return (pose, nil)
        } catch {
            // Ring buffer empty or underflow: use identity + log
            logger.warning("fusion.poseRing.underflow — error: \(error)")
            // Try to use oldest available sample
            let samples = poseRingBuffer.orderedSamples
            if let oldest = samples.first {
                let lagMs = Int(Date().timeIntervalSince(oldest.timestamp) * 1000)
                logger.warning("fusion.poseRing.underflow — lagMs: \(lagMs)")
                return (oldest.transform, .degraded(.poseExtrapolated))
            }
            // Truly empty — use identity transform (device at world origin)
            return (simd_float4x4(1), .degraded(.poseExtrapolated))
        }
    }

    // MARK: - Private: Main-actor raycast hop

    /// Performs Scene.raycast on the main actor.
    ///
    /// Returns (classification string, distance) or (nil, nil) on miss or when
    /// scene is nil (simulator/unit test path).
    private func performRaycast(
        scene: RealityKit.Scene?,
        from: SIMD3<Float>,
        to: SIMD3<Float>
    ) async -> (String?, Float?) {
        guard let scene else { return (nil, nil) }

        // Simulator guard: SceneReconstructionProvider is not supported in sim
        // SceneUnderstanding mesh may be empty; raycast returns [] — handled below
        let hopStart = Date()

        let result: (String?, Float?)? = await MainActor.run {
            let hit = scene.raycast(
                from: from,
                to: to,
                query: .nearest,
                mask: .sceneUnderstanding,
                relativeTo: nil
            ).first
            guard let hit else { return nil }
            // Classification extracted on main actor (SceneUnderstandingComponent is main-actor bound)
            let classString = classificationFromComponent(entity: hit.entity)
            return (classString, hit.distance)
        }

        let hopMs = Int(Date().timeIntervalSince(hopStart) * 1000)
        if hopMs > 20 {
            logger.warning("fusion.mainHop.slow — durationMs: \(hopMs)")
        }

        guard let (classString, dist) = result else { return (nil, nil) }
        return (classString, dist)
    }

    // MARK: - Private: Classification extraction

    /// Extracts a classification string from a RealityKit entity.
    ///
    /// Must be called on the main actor (component access is @MainActor).
    /// Returns nil in simulator (entity won't have SceneUnderstandingComponent attached).
    ///
    /// Classification granularity note:
    /// `SceneUnderstandingComponent` on visionOS 2.0 does not expose a
    /// per-entity `classifications` OptionSet at the RealityKit layer —
    /// per-face classification is available via `MeshAnchor.geometry.classifications`
    /// in the ARKit layer. For v0.1, we confirm the entity is an environment-mesh
    /// entity (has SceneUnderstandingComponent) and return "mesh" as a non-nil
    /// signal. LabelReconciler rule 5 then applies: prefer detector label,
    /// keep mesh distance. Post-v0.1: cross-reference hit entity UUID against
    /// MeshAnchorTracker for per-anchor dominant classification.
    @MainActor
    private func classificationFromComponent(entity: Entity) -> String? {
        guard entity.components.has(SceneUnderstandingComponent.self) else {
            return nil
        }
        // Entity is confirmed as a scene-understanding mesh entity.
        // Return a non-nil classification signal so the reconciler uses mesh distance
        // rather than the 3m default. Label comes from the detector (rule 5).
        return LabelReconciler.MeshClass.unknown
    }

    // MARK: - Private: Outcome combination

    /// Combine pose degradation with the reconciler outcome.
    /// Pose degradation takes precedence over reconciler outcome.
    private func combinedOutcome(
        poseOutcome: AnnotationCandidate.Outcome?,
        reconcileOutcome: AnnotationCandidate.Outcome
    ) -> AnnotationCandidate.Outcome {
        if let poseOutcome, case .degraded = poseOutcome {
            return poseOutcome
        }
        return reconcileOutcome
    }
}
