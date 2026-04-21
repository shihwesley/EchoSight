---
name: capture
description: PassthroughCaptureSource protocol + PeekABoo impl + EchoSight photo album management
phase: 1
sprint: 2
parent: root-spec
depends_on: [root, project-skeleton, observability]
status: eng-reviewed
created: 2026-04-21
---

# Capture Spec

## Goal

Deliver a working `PeekABoo`-backed `PassthroughCaptureSource` that produces time-stamped `CapturedFrame` records, manages a dedicated EchoSight Photos album, and surfaces a clear-captures UX. Single-gesture model for v0.1 (Feature 1 only).

## Requirements

- Implement `PeekABooSource: PassthroughCaptureSource`
- Full Photo Library access requested on first capture (with clear onboarding copy)
- Screenshots moved into "EchoSight Captures" album via `PHAssetChangeRequest`
- `CapturedFrame` emits with `PHAsset.creationDate` as truth-of-capture timestamp
- "Clear Captures" action deletes all assets in album (user confirms)
- Stub `CameraFrameProviderSource: PassthroughCaptureSource` for future Enterprise entitlement path (compiles, throws `.unavailable`)
- Gesture: Digital Crown + Capture Button fires Feature 1 (scene description). No mode disambiguation in v0.1.

## Acceptance Criteria

- [ ] Fresh app install → first capture prompts Full Photo Library access
- [ ] Captured screenshot appears in "EchoSight Captures" album within 1 s
- [ ] `CapturedFrame.timestamp == PHAsset.creationDate` (not delivery time)
- [ ] "Clear Captures" deletes all assets after user confirms in VoiceOver-friendly alert
- [ ] `PeekABooSource.requestCapture()` completes <800 ms on device
- [ ] Protocol conformance tests pass for both `PeekABooSource` and `CameraFrameProviderSource` (stub returns unavailable cleanly)

## Technical Approach

PeekABoo ships as a Swift Package; integrate and wrap its `.onCapture { image, asset in ... }` closure. Maintain album identifier in `UserDefaults` after first creation. Since OS cannot silently delete screenshots, onboarding must disclose the pollution clearly before first capture.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Capture/PeekABooSource.swift` | Primary impl |
| `Sources/EchoSightCore/Capture/CameraFrameProviderSource.swift` | Enterprise fallback stub |
| `Sources/EchoSightCore/Capture/EchoSightAlbum.swift` | Album create/find + move + clear |
| `Sources/EchoSightApp/Views/CapturePrivacyOnboardingView.swift` | Full-access consent copy |
| `Sources/EchoSightApp/Views/ClearCapturesButton.swift` | Confirmation alert + batch delete |
| `Tests/EchoSightCoreTests/EchoSightAlbumTests.swift` | Album management tests (mocks Photos) |

## Tasks

1. Add PeekABoo SPM dep
2. Implement `PeekABooSource` conforming to `PassthroughCaptureSource`
3. Implement `EchoSightAlbum` (create, move asset, clear)
4. Build `CapturePrivacyOnboardingView` with accessible copy
5. Build `ClearCapturesButton` with VoiceOver-friendly confirmation
6. Stub `CameraFrameProviderSource` (returns `.unavailable`)
7. Unit-test album logic with mocked PhotoKit

## Dependencies

- **Needs from:** root (protocol), project-skeleton (app target + Info.plist), observability (logging)
- **Provides to:** detector (`CapturedFrame` input), fusion (timestamp for pose lookup)

## Eng Review

- **Depth:** BIG
- **Scope additions:**
  - Timestamp ring-edge handling: `CapturedFrame.timestamp == PHAsset.creationDate` is truth, but PhotoKit delivery can be 200-600 ms late (per findings.md). If `fusion` later asks the head-pose ring for an interpolation older than `ringBuffer.oldest()`, ring returns `ringBuffer.oldest()` and logs a warning. This spec defines the contract: `CapturedFrame` carries both `shutterTimestamp` (from PHAsset.creationDate) and `deliveryTimestamp` (from the capture delegate callback) so fusion can measure PhotoKit delivery lag and decide whether to degrade confidence.
  - Album pollution mitigation: once per session on first capture, speak a one-time reminder ("EchoSight capture saved to EchoSight Captures album, you can clear captures from Settings"). Disclosure copy in onboarding already covers the expectation; the reminder protects against user forgetting between onboarding and first real use.
  - Single-gesture-only note stands for v0.1; `modal-input` fires the capture call based on current mode, not `capture-spec` directly.
- **Acceptance additions:**
  - [ ] `CapturedFrame.shutterTimestamp != CapturedFrame.deliveryTimestamp` in most real captures (assert non-zero delta)
  - [ ] If `deliveryTimestamp - shutterTimestamp > 3 s`, capture is logged as `outcome=.degraded(.latePhotoKitDelivery)` and downstream can choose to skip or warn

### Data Flow

```
 modal-input                 capture                       PhotoKit
  │                           │                             │
  ├─ ModeFiredEvent(.scene/ocr)                             │
  │  listener                 │                             │
  │                           ├─ requestCapture() ─────────→│
  │                           │                             │
  │                           │     (200-600 ms later)      │
  │                           │ ← PHAssetChange delegate ───┤
  │                           │   (shutter + delivery ts)   │
  │                           │                             │
  │                           ├─ move to EchoSight Album ──→│
  │                           │                             │
  │                           ├─ CapturedFrame emitted ──┐
  │                                                      │
  ▼                                                      ▼
 (nothing; fire-and-forget)            detector / fusion / ocr
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| First-capture consent | Integration | Prompt → granted → capture proceeds | Denied → `EchoSightError.captureUnavailable(.photosDenied)` | Limited Photos access → cannot move to album, log + fallback to in-memory frame |
| Capture → album | Integration | Asset moved within 1 s | Move fails → log, keep asset in default Photos | Album deleted by user in Photos app → recreate on next capture |
| Timestamp contract | Unit | shutter < delivery | Delivery missing → use best-effort current Date + warn | Delivery lag >3 s → outcome=.degraded |
| Clear captures | UI | Confirm → batch delete | User cancels → no delete | Album empty → no-op, "nothing to clear" speech |
| CameraFrameProvider stub | Unit | Conforms, throws `.unavailable` | — | — |

### Critical Paths

- Timestamp accuracy is the ONLY source of truth for fusion's pose interpolation. Wrong timestamp = wrong 3D position = wrong annotation.
- Photos full-access permission must be granted; no graceful local fallback for v0.1 (Enterprise CameraFrameProvider path is stubbed)

### Failure Modes (additions)

| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|--------------|-----------|---------|---------|
| PhotoKit delivery | `PHAsset` lag >3 s under memory pressure | Annotation lands at wrong world position | Acceptance criterion (degraded outcome) | `echosight.capture` warn |
| Album move | User manually deleted album from Photos | Captures fall into default Photos | Recreate on next capture + log | `echosight.capture` info |
| Limited Photos | User granted "Add only" not "Full access" | Cannot move to album | Log + fallback to in-memory frame path | `echosight.capture` warn |
| Capture timeout | PeekABoo capture hangs >800 ms | User waits | Timeout → `.failed(.timeout)`, speak "capture didn't complete" | `echosight.capture` warn |

### Observability

- **Log category:** `echosight.capture`
- **Key events:**
  - `capture.requested(mode)`
  - `capture.shutter(shutterMs)`
  - `capture.delivered(deliveryMs, lagMs)`
  - `capture.album.moved(assetId)` / `capture.album.moveFailed(reason)`
  - `capture.degraded(reason)` / `capture.failed(reason)`
  - `capture.clearCaptures.confirmed(count)`
