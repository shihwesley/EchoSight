---
name: spatial-core
description: Layer 1 foundation — ARKit scene mesh + head-pose ring buffer + spatial audio obstacle cues + world-anchor event stream
phase: 1
sprint: 1
parent: root-spec
depends_on: [root, observability]
status: eng-reviewed
created: 2026-04-21
---

# Spatial Core Spec (Layer 1)

## Goal

Deliver the shippable-on-its-own Layer 1: continuous spatial awareness with no ML inference. Mesh + head pose + obstacle ray-cast → spatialized audio cues. Additionally surface a **world-anchor event stream** so `ambient-announce` can react to anchor novelty without polling.

This spec is v0.0.1 alpha by itself — a BLV user gets obstacle audio cues and nothing else. That standalone-shippability is preserved by scoping the anchor-event stream as an opt-in subscription that does nothing if no consumer attaches.

**Scope change under CEO review (EXPANSION):** adds `AnchorChangeEvent` stream + `MeshClassificationSummary` snapshot. Does not alter the Layer 1 audio path.

## Requirements

- `SceneReconstructionProvider` stream wrapped as RealityKit collision entities with `SceneUnderstandingComponent`
- `WorldTrackingProvider` head pose at 100 Hz
- Head-pose ring buffer: 5 second window, timestamped, supports interpolation by arbitrary `Date`
- Forward ray-cast from head each frame (~10 Hz throttled) to detect obstacles within walking path
- Spatial audio cues via `SpatialAudioComponent` — pitch rises with proximity, pan reflects azimuth
- Mesh classification surfaced for walls/floors/ceilings/tables/seats/windows/doors
- All-day power budget (negligible continuous CPU)

**New under expansion:**
- `AnchorChangeEvent` — emitted when `WorldTrackingProvider` reports a new persistent world anchor or re-recognizes a previously-seen one. Shape: `(anchorId: UUID, kind: .new | .rerecognized | .sessionResumeRerecognized, timestamp: Date)`. The `.sessionResumeRerecognized` kind (pinned post-TLA 2026-04-21) specifically flags anchors re-emitted by `spatial-core` after an ARKit session interruption + resume, so `ambient-announce` can dampen chimes for these burst events (see ambient-announce spec's 3-s session-resume chime suppression). Organic re-recognition (user walks back into a room mid-session) continues to use `.rerecognized`.
- Consumed as an `AsyncStream<AnchorChangeEvent>` by `ambient-announce` spec and `annotation-store`'s `AnchorRehydrator`
- `MeshClassificationSummary` — on-demand snapshot of the current mesh classification distribution (wall% / floor% / seat% / etc.) used by `ambient-announce` for Gemma's room-label inference fallback
- Stream behavior: if no consumer attached, no cost — ARKit stream already running for Layer 1, anchor events are a free side-emit

**New under eng review (Gate 4):**
- `headPoseVariance(window: TimeInterval) -> Float` — cumulative angular rotation (radians) over the given window from the head-pose ring. Used by `ambient-announce` for its compound idle rule (gesture-idle AND head-motion-active). Zero new sensing; math on existing ring.

## Acceptance Criteria

- [ ] On device (or sim), walking toward a wall raises audio pitch
- [ ] Head-pose ring buffer returns pose within 1 ms for any `Date` in its window
- [ ] Mesh coverage appears within 3 s of surface entering FOV
- [ ] Ray-cast query <10 ms for nearest-hit within 10 m
- [ ] `AnchorChangeEvent` emits within 500 ms of ARKit anchor add / re-recognition
- [ ] `AnchorChangeEvent.kind` discriminates correctly: `.new` (no `AnchorMetadata` row), `.rerecognized` (organic mid-session re-entry), `.sessionResumeRerecognized` (re-emitted after ARKit session resume)
- [ ] `MeshClassificationSummary` returns current distribution within 20 ms
- [ ] No measurable Layer 1 power-budget regression with anchor-event stream consumers attached
- [ ] Unit tests for ring buffer interpolation (linear, edges, out-of-window) + anchor-event emission

## Technical Approach

Run both providers in an ARKit `Session`. Wrap mesh anchors into `ModelEntity`s with `CollisionComponent` so `Scene.raycast` works against them (RealityKit handles the spatial hash). Head pose ring buffer is a `CircularBuffer<(Date, simd_float4x4)>` with binary-search interpolation.

Anchor event stream: existing `WorldTrackingProvider` anchor updates are tapped and translated into `AnchorChangeEvent`. Per-session `Set<UUID>` tracks anchors already emitted in this session, so `.rerecognized` only fires on load-from-persistence, not on every frame update.

Mesh classification summary: iterate live mesh entities, aggregate classification counts by triangle area, return distribution dict. On-demand only (not streamed) because `ambient-announce` only needs it at the moment of novelty.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Spatial/SpatialSession.swift` | Owns ARKit providers, starts/stops |
| `Sources/EchoSightCore/Spatial/HeadPoseRingBuffer.swift` | 100 Hz ring + interpolation |
| `Sources/EchoSightCore/Spatial/MeshAnchorTracker.swift` | Stream → RealityKit entities |
| `Sources/EchoSightCore/Spatial/ObstacleRaycaster.swift` | Forward cast + proximity report |
| `Sources/EchoSightCore/Spatial/AnchorChangeEvent.swift` | Event payload (new) |
| `Sources/EchoSightCore/Spatial/AnchorEventStream.swift` | AsyncStream source, dedup by seen-this-session set (new) |
| `Sources/EchoSightCore/Spatial/MeshClassificationSummary.swift` | On-demand distribution snapshot (new) |
| `Sources/EchoSightCore/Spatial/HeadPoseVariance.swift` | Angular-rotation accumulator over ring window (new, Gate 4) |
| `Sources/EchoSightCore/Audio/SpatialCueRenderer.swift` | Distance → pitch/pan, SpatialAudioComponent |
| `Tests/EchoSightCoreTests/HeadPoseRingBufferTests.swift` | Ring buffer unit tests |
| `Tests/EchoSightCoreTests/AnchorEventStreamTests.swift` | Event emission + dedup |
| `Tests/EchoSightCoreTests/MeshClassificationSummaryTests.swift` | Distribution math |

## Tasks

1. Implement `HeadPoseRingBuffer` (unit-testable, no ARKit dep)
2. Implement `SpatialSession` wrapping ARKit providers + data room entitlement check
3. Implement `MeshAnchorTracker` converting mesh anchors → RealityKit entities with classification
4. Implement `ObstacleRaycaster` throttled forward cast
5. Implement `SpatialCueRenderer` with audio pitch/pan mapping
6. Implement `AnchorEventStream` tap on WorldTrackingProvider with session-dedup
7. Implement `MeshClassificationSummary` on-demand aggregation
8. Write `HeadPoseRingBufferTests` (interpolation edge cases)
9. Write `AnchorEventStreamTests` and `MeshClassificationSummaryTests`

## Dependencies

- **Needs from:** root, project-skeleton
- **Provides to:** fusion (mesh + head pose), ambient-announce (`AnchorChangeEvent` stream + `MeshClassificationSummary`), any downstream spec needing geometry

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** Added `AnchorChangeEvent` stream + `MeshClassificationSummary` on-demand snapshot. Both are zero-cost side-emissions from the already-running ARKit providers — no new ARKit session, no new power draw. The spec's "shippable on its own as Layer 1" property is preserved: both additions are opt-in consumer APIs that are dormant without a subscriber.
- **Premise validation:** Layer-1-as-standalone-v0.0.1-alpha held. In fact, CEO review made it sharper: the user explicitly chose to keep Layer 1 as a separate ship-point (Option 2 in Gate 1). This spec is now both "foundation for Feature 1+2+3" and "shippable alpha slice by itself."

### Dream State Delta
At 12-month ideal, spatial-core also exports a *motion-delta* stream (something moved in the scene), a *sound-source* stream (something made a sound), and *gaze-fixation* (where is the user looking). Each would plug into ambient-announce the same way `AnchorChangeEvent` does. Keep the stream pattern consistent so adding sources later is additive, not structural.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| Anchor stream | ARKit resets (session interruption) → all anchors re-emit as `.new` | Ambient announces everywhere | Partial — need session-reset handling | No |
| Mesh summary | Mesh still populating → distribution skewed toward early surfaces | Room-label inference wrong | `MeshClassificationSummary` returns confidence with distribution | No |
| Obstacle raycast | Performant-but-aggressive throttle drops cues | BLV user hits wall | Acceptance criterion #3 | Yes |
| Ring buffer | Out-of-window query (capture after buffer filled past it) | Pose returns extrapolated | Unit test | Yes |

### Deferred Work
- [ ] Motion-delta stream — v1.0 ambient perception
- [ ] Anchor-UUID coalescing (treat two close UUIDs as same place) — v1.0 usability
- [ ] Mesh classification confidence (per-triangle) — v1.0 when room-label inference needs sharper signals
- [ ] Layer 1 haptic cues (wrist tap on obstacle) — v1.0+ if AVP wearables ecosystem expands

## Eng Review

- **Depth:** BIG
- **Scope additions:**
  - Expose `headPoseVariance(window: TimeInterval) -> Float` helper on top of the existing ring buffer (per Gate 4; ambient-announce depends on it for its compound idle rule). Zero new sensing; ~1 ms of math over the last 30 s of poses.
  - `AnchorChangeEvent.kind` semantics pinned: `.new` = anchor not in `AnchorMetadata` table; `.rerecognized` = anchor exists in `AnchorMetadata`. Discrimination happens in the event source (spatial-core queries annotation-store's `anchorMetadata(anchorId:)` synchronously before emitting — this is the only place these two specs couple at the event layer).
  - Session-reset handling: on ARKit session interruption and resume, flush the seen-this-session set and re-emit all re-recognized anchors as `.sessionResumeRerecognized` (post-TLA 2026-04-21; previously `.rerecognized`). The distinct kind lets `ambient-announce` apply the 3-s chime-dampening window specifically for session-resume bursts while treating organic mid-session re-entry as normal `.rerecognized` traffic. Prevents the "anchor storm on resume" failure mode both at the chime layer (dampened) and at the novelty-detection layer (downstream).

### Data Flow

```
ARKit providers                spatial-core                  consumers
 │                              │                             │
 ├─ SceneReconstructionProvider→│ MeshAnchorTracker           │
 │                              │ → MeshClassificationSummary ├→ ambient-announce (on-demand)
 │                              │                             │
 ├─ WorldTrackingProvider ─────→│ HeadPoseRingBuffer (5 s)    │
 │                              │ → interpolate(Date)         ├→ fusion (pose at capture time)
 │                              │ → headPoseVariance(window)  ├→ ambient-announce (idle check)
 │                              │                             │
 │                              │ AnchorEventStream           │
 │                              │ (seen-this-session Set)     │
 │                              │ → query anchorMetadata      ├→ ambient-announce (novelty)
 │                              │ → emit .new / .rerecognized ├→ annotation-store (rehydrator)
 │                              │                             │
 │                              │ ObstacleRaycaster (10 Hz)   │
 │                              │ → SpatialCueRenderer        ├→ audio out (always-on)
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Ring buffer interp | Unit | <1 ms for any Date in window | Out-of-window Date → return nearest (oldest/newest) | Empty buffer at startup → throw |
| Head-pose variance | Unit | Returns cumulative angular delta over window | Window > buffer capacity → use whole buffer + log warn | Stationary head → variance ~0 |
| Raycast query | Integration (sim) | <10 ms for nearest-hit within 10 m | Mesh empty (just booted) → return .none | Many-mesh environment → still <10 ms |
| AnchorChangeEvent | Integration (sim) | Emit within 500 ms of anchor add/rerecognition | Session interruption → on resume, emit `.sessionResumeRerecognized` (distinct from organic `.rerecognized`) | Duplicate anchor UUIDs in single session → dedup |
| MeshClassificationSummary | Unit | <20 ms for typical room | Mesh still loading → confidence=low flag | Partial coverage → reflects only observed surfaces |
| Session resume | Integration (sim) | Re-emit all anchors as `.rerecognized` | Concurrent rehydrations don't double-load | Seen-this-session Set cleared cleanly |

### Critical Paths

- Head-pose interpolation at capture timestamp (fusion depends on this being fast + accurate)
- `headPoseVariance` accuracy (ambient-announce's idle rule depends on this)
- AnchorChangeEvent discrimination (.new vs .rerecognized) — wrong classification = wrong ambient speech

### Performance Notes

- Ring buffer interpolation is O(log N) binary search; N=500 (5 s × 100 Hz)
- `headPoseVariance` is O(N) accumulate; called at most once per ambient-announce evaluation (not per-frame)
- ARKit providers run on their own thread; spatial-core never blocks main actor

### Observability

- **Log category:** `echosight.spatial` (ARKit session + pose + mesh), `echosight.anchor` (anchor events)
- **Key events:**
  - `spatial.session.started` / `spatial.session.interrupted` / `spatial.session.resumed`
  - `spatial.mesh.coverage(percent, triangleCount)`
  - `spatial.raycast.hit(distance, classification)` / `spatial.raycast.miss`
  - `anchor.new(hashedId)` / `anchor.rerecognized(hashedId, ageDays)`
  - `anchor.session.seenSet.size`
