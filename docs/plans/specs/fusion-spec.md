---
name: fusion
description: 2D detection → 3D world ray-cast, mesh classification reconciliation, FOV calibration scene
phase: 2
sprint: 1
parent: root-spec
depends_on: [root, capture, spatial-core, observability]
status: eng-reviewed
created: 2026-04-21
---

# Fusion Spec

## Goal

Bridge pixel-space detections (from detector) to world-space annotations (in spatial-core's mesh). Time-sync head pose to capture instant, ray-cast through mesh, reconcile Falcon/Vision label with mesh classification. Includes dev-only FOV calibration scene.

## Requirements

- `pixelToRay(nx, ny, hFovDeg, aspect) -> SIMD3<Float>` — head-local ray
- Transform ray to world space using head pose at `CapturedFrame.timestamp` (via ring buffer interpolation)
- `Scene.raycast` into mesh with `SceneUnderstandingComponent`
- Reconcile detector label with mesh classification:
  - Agreement → high-confidence
  - Disagreement on "small object + supporting surface" → prefer detector label, keep mesh distance
  - Detector = person → bypass mesh, use shoulder-height heuristic
- Output: `WorldAnnotation` candidates (final persistence happens in annotation-store)
- Dev-only FOV calibration `DebugFovCalibrationView` behind `#if DEBUG`
- Constant `kAssumedHorizontalFov: Float = 100` — tunable once empirical measurement done

## Acceptance Criteria

- [ ] `pixelToRay` matches expected direction within 1° for cardinal test points (center, corners)
- [ ] Time-sync test: pose interpolation error <1 mm over 300 ms pose drift synthesis
- [ ] Raycast into known-geometry sim scene returns correct classification for chair/wall/floor fixtures
- [ ] Person-class bypass returns shoulder-height distance heuristic without mesh dependency
- [ ] Debug FOV scene hidden from Release build
- [ ] Unit tests for projection math, reconciliation rules, person bypass

## Technical Approach

Keep fusion a pure function of `(detections, headPose, mesh) -> [AnnotationCandidate]`. No ARKit calls — consumes pre-materialized inputs from spatial-core. This keeps fusion testable without a device.

Calibration scene: place a physical chair at a tape-measured distance, capture, sweep `hFovDeg` from 90° to 110° at 2° steps, print raycast distance. Update constant, commit.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Fusion/PixelToRay.swift` | Pure projection math |
| `Sources/EchoSightCore/Fusion/FusionEngine.swift` | Ties pose + raycast + reconciliation |
| `Sources/EchoSightCore/Fusion/AnnotationCandidate.swift` | Pre-persistence record |
| `Sources/EchoSightCore/Fusion/LabelReconciler.swift` | Rules for label ↔ classification |
| `Sources/EchoSightApp/Debug/FovCalibrationView.swift` | `#if DEBUG` sweep UI |
| `Sources/EchoSightCore/Fusion/FusionConstants.swift` | `kAssumedHorizontalFov`, person shoulder height |
| `Tests/EchoSightCoreTests/PixelToRayTests.swift` | Projection correctness |
| `Tests/EchoSightCoreTests/LabelReconcilerTests.swift` | Rule coverage |

## Tasks

1. Implement `PixelToRay` pure function + tests
2. Implement `LabelReconciler` with documented rules + tests
3. Implement `FusionEngine.fuse(detections:pose:scene:)`
4. Build DEBUG-only `FovCalibrationView` with sweep sliders
5. Calibrate FOV empirically on device, update constant
6. Perf-test full fusion <10 ms for 8 detections

## Dependencies

- **Needs from:** root (protocols), capture (`CapturedFrame` timestamp), spatial-core (mesh + pose ring), observability (logging)
- **Provides to:** scene-description (annotation candidates), annotation-store (candidates to persist)

## Eng Review

- **Depth:** BIG
- **Scope additions (thread safety):**
  - `FusionEngine` split into two tiers:
    - **Pure tier (background):** `pixelToRay` + `LabelReconciler` + person-bypass math. Runs on any queue. `actor FusionEngine`.
    - **RealityKit tier (main actor):** `Scene.raycast` call hops to `@MainActor`. RealityKit scene APIs are main-actor-bound on visionOS 2.
  - Contract: `FusionEngine.fuse(detections:pose:scene:)` is async and internally awaits the main-actor hop for the raycast portion. Callers (scene-description pipeline) run the whole call on a background Task; the actor serialization plus the main-hop prevents re-entrancy.
  - Ring-edge handling per Gate 5-adjacent: if `CapturedFrame.shutterTimestamp` is older than `HeadPoseRingBuffer.oldest()`, use oldest pose + log `fusion.poseRing.underflow`; mark candidate with `outcome=.degraded(.poseExtrapolated)`. annotation-store can choose to skip persistence.
  - No ARKit calls in fusion — confirmed; inputs are pre-materialized (head-pose ring buffer and live mesh entities already exist in spatial-core's scene).

### Data Flow

```
scene-description                 fusion                           RealityKit (main actor)
 (background Task)                (actor, background)
  │                                │                                 │
  ├─ fuse(detections, pose, scene)→│                                 │
  │                                │ pixelToRay(normCoord)            │
  │                                │ transform ray to world           │
  │                                │                                 │
  │                                ├─ await MainActor.run {          │
  │                                │     scene.raycast(from:to:) ──→ │
  │                                │ ← RaycastResult ───────────────│
  │                                │   }                              │
  │                                │                                 │
  │                                │ reconcile label ↔ classification│
  │                                │ apply person shoulder-height     │
  │                                │ bypass if needed                 │
  │                                │                                 │
  │ ← [AnnotationCandidate] ───────│                                 │
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| pixelToRay | Unit | Cardinal points within 1° | NaN input → throws | Edge of FOV (0, 1) |
| LabelReconciler | Unit | Chair-on-floor: agree | Detector says chair, mesh says wall → prefer detector, keep mesh distance | Person detected: bypass mesh entirely |
| Raycast hop | Integration (sim) | Main-actor hop completes <5 ms | Main actor busy → hop queues but eventually runs | Concurrent fuse() calls serialize through actor |
| Pose ring underflow | Unit | Use oldest pose + degraded outcome | Ring empty → throw `.poseNotReady` | Timestamp from future → use newest + log |
| Full fuse() | Integration | 8 detections → 8 candidates, <10 ms wall (excluding main-hop queueing) | Empty detections → [] | Mesh partial → candidates marked degraded |

### Critical Paths

- Main-actor raycast hop is a hard constraint — if RealityKit scene changes main-actor requirements in visionOS 3+, spec must be revisited
- Pose-ring alignment to capture timestamp (inherited from capture-spec timestamp contract)
- 10 ms fusion budget holds total scene-mode latency under 1.5 s

### Performance Notes

- Main-actor hop for raycast is ~0-3 ms typical; worst-case queueing if UI animation is running concurrently
- Reconciler rules are table-driven (no ML); negligible CPU
- FOV constant will be updated once on physical device via debug calibration scene; no runtime cost

### Failure Modes (additions)

| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|--------------|-----------|---------|---------|
| Main-hop queueing | UI thread busy (SwiftUI animation) | Fusion latency spikes | Acceptance criterion measures p95 | `echosight.fusion` warn on >20 ms hop |
| Pose underflow | Capture delivery lag >5 s (ring window) | Annotation lands at approximate world position | Marked degraded, annotation-store may skip | `echosight.fusion` warn |
| FOV mis-calibration | Dev forgot to recalibrate on real device | Distances consistently off by ~10% | Debug calibration view catches in dev | — |
| Raycast zero-hit | Detection at window / sky / unmeshed area | Heuristic: use 3 m default distance + mark low-confidence | Failure mode covered; Gate 1 person-bypass same pattern | `echosight.fusion` info |

### Observability

- **Log category:** `echosight.fusion`
- **Key events:**
  - `fusion.fuse.started(detectionCount)`
  - `fusion.fuse.completed(candidateCount, durationMs)`
  - `fusion.poseRing.underflow(lagMs)` / `fusion.poseRing.overflow(lagMs)`
  - `fusion.raycast.miss(detectionLabel)`
  - `fusion.reconcile.disagree(detectorLabel, meshClass, resolution)`
  - `fusion.mainHop.slow(durationMs)` — when >20 ms
