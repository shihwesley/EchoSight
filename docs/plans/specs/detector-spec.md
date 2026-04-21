---
name: detector
description: Detector protocol impl — Vision placeholder for v0.1, Falcon-Perception drop-in slot
phase: 2
sprint: 1
parent: root-spec
depends_on: [root, capture, observability]
status: eng-reviewed
created: 2026-04-21
---

# Detector Spec

## Goal

Deliver a working object detector behind the `Detector` protocol so fusion + scene-description can build against it today. v0.1 ships a Vision-framework placeholder. Falcon-Perception mlx-swift port lands post-v0.1 as a drop-in `FalconDetector`.

## Requirements

- `VisionDetector: Detector` using `VNRecognizeObjectsRequest` (if available) or a Core ML YOLOv8n
- Input: `CapturedFrame` (UIImage + metadata)
- Output: `[DetectionResult]` with `(normalizedXY, normalizedHW, label, confidence, mask: nil)` for Vision path
- `FalconDetector: Detector` — stub only in v0.1 (throws `.unavailable` or returns `[]`)
- Detector loading happens on a background queue; warm-up before first capture
- Default query set hardcoded for "describe scene" (chair, door, wall, person, table, stairs, step, window)

## Acceptance Criteria

- [ ] `VisionDetector.detect(frame:)` returns ≥1 detection on sample indoor scene test image
- [ ] Inference <500 ms on Apple Vision Pro (measured in perf test)
- [ ] Bounds are normalized [0,1], image-origin-agnostic
- [ ] Unit test with fixture image asserts expected label class presence
- [ ] `FalconDetector` compiles and throws `.unavailable` cleanly

## Technical Approach

Prefer a small Core ML YOLO (YOLOv8n or YOLO11n converted via `coremltools`) — gives open-ish vocabulary with a reasonable label set for indoor scenes. `VNRecognizeObjectsRequest` is a fallback if coreml conversion is blocked. Warm detector at app launch to eliminate first-inference stall.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Detector/VisionDetector.swift` | Core ML YOLO-backed impl |
| `Sources/EchoSightCore/Detector/FalconDetector.swift` | mlx-swift stub |
| `Sources/EchoSightCore/Detector/DetectionResult.swift` | Output struct (already in root) |
| `Sources/EchoSightCore/Detector/DefaultQuerySet.swift` | Indoor query labels |
| `Resources/Models/yolo11n.mlpackage` | (or whichever CoreML model chosen) |
| `Tests/EchoSightCoreTests/VisionDetectorTests.swift` | Fixture-image assertions |

## Tasks

1. Select + convert Core ML detector model (YOLO11n or similar)
2. Implement `VisionDetector` with warm-up, async detect
3. Implement `DefaultQuerySet` (8-10 indoor labels)
4. Stub `FalconDetector` (protocol conformance only)
5. Add fixture image + `VisionDetectorTests`
6. Add perf test asserting <500 ms on sim

## Dependencies

- **Needs from:** root (`Detector` protocol, `CapturedFrame`), capture (input frames), observability (logging)
- **Provides to:** scene-description (detections), gemma-enrichment (detections as context), onboarding-download (model file bundled/downloaded)

## Eng Review

- **Depth:** BIG
- **Scope additions:**
  - Warm-up contract: `VisionDetector.warmUp()` runs on a dedicated serial queue at app launch after download completes; emits `detector.warmedUp(durationMs)` when done. Scene-description pipeline checks `isWarm` before first detection call; if cold, logs a warning and still proceeds (Vision can load on-demand, just slower).
  - Detection time-out: wrap each `detect(frame:)` in a 2-s budget; on exceed, return `[]` and log `detector.timeout`. Fusion + scene-description already handle the empty-detection path; this keeps the pipeline deadline intact.
  - Concurrency: `VisionDetector` is an `actor`; simultaneous calls serialize naturally. `FalconDetector` stub conforms but immediately throws, so no concurrency concern yet.
- **Falcon drop-in slot:** the Falcon port (post-v0.1) will be another `actor` satisfying the same protocol. No interface changes needed in scene-description or fusion.

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Warm-up | Unit | <500 ms cold start on sim | Model file missing → `.modelLoadFailed` error surfaces | Double warm-up → idempotent |
| Detect fixture | Unit | ≥1 detection on sample indoor image | Zero detections on blank image → `[]` returned cleanly | Tiny (10×10) input → still no crash |
| Bounds normalization | Unit | All bounds in [0,1] | CoreML returns pixel coords → converter fixes | Model output orientation inverted → caught by test fixtures |
| Timeout | Unit | <500 ms typical | Synthetic 3-s hang → returns [] at 2 s | Cancellation mid-inference → propagates |
| Falcon stub | Unit | Throws `.unavailable` | — | — |

### Critical Paths

- Warm-up completes before scene-mode first-fire (if cold, first user action adds ~500 ms latency)
- Detection time ≤500 ms — the hard SLA for scene-mode's 1.5 s p95

### Performance Notes

- YOLO11n Core ML: ~15 MB, ~30-80 ms inference on M2 (visionOS uses the same Neural Engine family)
- Warm-up at launch hides this cost; deferred warm-up would put it on the critical path

### Observability

- **Log category:** `echosight.detector`
- **Key events:**
  - `detector.warmUp.started` / `detector.warmUp.completed(durationMs)`
  - `detector.detect.started(frameId)`
  - `detector.detect.completed(frameId, count, durationMs)`
  - `detector.timeout(frameId)`
  - `detector.error(reason)`
