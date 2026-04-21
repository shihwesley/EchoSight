---
name: root
description: Project-wide decisions, shared protocols, cross-spec constants for EchoSight v0.1
phase: 1
sprint: 1
parent: null
depends_on: []
status: eng-reviewed
created: 2026-04-21
---

# Root Spec — EchoSight v0.1

## Goal

Establish project-wide constants, shared Swift protocols, and cross-spec conventions. This spec is code-light; it anchors decisions every downstream spec depends on.

## Requirements

- Define `PassthroughCaptureSource` protocol (capture spec implements; fusion spec consumes)
- Define `Detector` protocol (detector spec implements; scene-description consumes)
- Define `EchoSightError` (shared error type across features)
- Lock module boundaries: `EchoSightCore` (engine) vs `EchoSightApp` (UI/glue)
- Document world-anchor persistence strategy (visionOS 2+)
- Document privacy posture: zero network inference, Photos full access required, mic usage deferred

## Acceptance Criteria

- [ ] `Sources/EchoSightCore/Protocols/` contains `PassthroughCaptureSource.swift`, `Detector.swift`, `EchoSightError.swift`
- [ ] Each protocol has docstring naming consumers and implementers
- [ ] `README.md` at repo root explains the two-module split
- [ ] `.clang-format` / SwiftFormat config committed (team style)

## Technical Approach

Protocols-first. No feature spec may start until its upstream protocol exists here. Keeps fusion-spec and detector-spec buildable in parallel during Phase 2 Sprint 1.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Protocols/PassthroughCaptureSource.swift` | Capture abstraction |
| `Sources/EchoSightCore/Protocols/Detector.swift` | Object detection abstraction |
| `Sources/EchoSightCore/Protocols/EchoSightError.swift` | Shared error type |
| `Sources/EchoSightCore/Model/CapturedFrame.swift` | `(UIImage, Date, [String:Any])` record |
| `README.md` | High-level architecture + privacy posture |

## Tasks

1. Draft `PassthroughCaptureSource` protocol with `CapturedFrame` return type
2. Draft `Detector` protocol with `DetectionResult` struct (xy, hw, label, confidence, optional mask)
3. Draft `EchoSightError` enum (captureFailed, detectorUnavailable, meshNotReady, modelLoadFailed)
4. Write README covering two-module split + privacy posture

## Dependencies

- **Needs from:** none (root)
- **Provides to:** all downstream specs

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** v0.1 surface set expanded from "Feature 1 only, gesture-triggered" to four surfaces:
  1. Scene mode (was Feature 1) — capture → detect → fuse → template TTS
  2. Recall mode (new) — Gemma room gestalt on 1st press, top-N annotation list on 2nd press
  3. Read mode (new, OCR) — VNRecognizeTextRequest → TTS
  4. Ambient announce (new, passive) — world-anchor novelty → chime always, speech on cold + idle

  Plus Layer 1 standalone (spatial-core) shippable as v0.0.1 alpha. Trigger model: Crown-cycles-modes + Button-fires-current-mode, no voice in v0.1.
- **Premise validation:** "Gesture-only, no voice" held under expansion by adopting the modal Crown-cycler pattern. OCR came back from v1.0 because `VNRecognizeTextRequest` is OS-provided with zero model download cost, and the Flutter predecessor shipped with text reading — omitting it in the rebirth would be a regression. Annotation store moves from write-only to three-consumer read surface, finally exercising cross-session memory (the stated moat) as user-visible value.

### Dream State Delta — 12-month Ideal
The product at 12 months is an **ambient spatial companion** that:
- Narrates *changes* in the world continuously (person entering, object moving, door opening) — not just on gesture
- Predicts the right mode from head pose + scene context — manual Crown-cycling deprecated
- Answers open-vocabulary queries ("where is my phone") — voice router live
- Reads any text that looks intentional (signs, screens, mail) continuously — not just on gesture
- Recognizes recurring people + places by name with consent — cross-session memory gets faces

v0.1 delivers ~30-40% of that ideal. The expansion gates added here bring it from ~15% (gesture-only single-feature) to the current ~35%. The remaining 65% is v1.0+ work, intentionally scoped out.

**Tension 2 (ambient-companion vs lookup-tool) resolution:** 70% resolved by passive ambient announce. The remaining 30% (world-aware interruption, continuous narration) is explicitly v1.0 territory — continuous perception burns battery and needs a privacy-review pass that's out of scope for v0.1 alpha.

### Surface Map (for downstream specs)

```
 Always-on (no ML)
 └── spatial-core: obstacle audio cues, head pose, mesh, anchor events

 User-triggered (Crown mode + Button fire)
 ├── scene mode       → scene-description (template TTS)
 ├── recall mode      → spatial-recall (Gemma gestalt + top-N)
 ├── read mode        → ocr (VNRecognizeTextRequest + TTS)
 └── silent mode      → no-op

 Passive (no gesture)
 └── ambient-announce: anchor novelty → chime (always) + speech (cold + idle)

 Reasoning backbone
 └── gemma-enrichment: async writer + sync readers (recall, ambient)
                       priority queue serves all three consumers

 Memory
 └── annotation-store: spatial + anchor-metadata read/write
```

### Failure Modes (project-wide)
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| All speech | `AVSpeechSynthesizer` session conflict with VoiceOver | Silent user action | Must be integration-tested | No |
| Permissions | Photos full access denied mid-session | Capture fails silently | Spec'd in capture + onboarding | Partial |
| Model files | Downloaded weights corrupted on-disk | App unusable | SHA-256 check in onboarding | Yes |
| ARKit session | Interruption + resume → anchor UUIDs churn | Ambient announces flood | Open issue flagged in spatial-core | No |
| Memory | Gemma + YOLO + Vision + RealityKit compete for 10-16 GB | OS evicts | Memory stress test in gemma spec | Partial |

### Deferred Work (project-wide)
- [ ] Voice router (WhisperKit + keyword spotter + target-noun extraction) — v1.0
- [ ] Continuous text reading (passive OCR when text enters FOV) — v1.0
- [ ] Motion-delta perception (something moved) — v1.0
- [ ] Face recognition (BLV-consented person identification) — v1.0+
- [ ] Translate (OCR → target language) — v1.0+
- [ ] Predictive mode switching (no manual Crown cycle) — v1.0+
- [ ] Falcon-Perception mlx-swift port (replaces Vision detector) — post-v0.1, pre-v1.0

## Eng Review

- **Depth:** BIG (interactive, 7 gates)
- **Scope additions:** Two new Phase 1 specs carved out of cross-cutting references that previously had no home — `speech-out` (owns the sole `AVSpeechSynthesizer`) and `observability` (log taxonomy + `DebugConsoleView` + metrics ring). Total spec count 14 → 16.
- **Key boundary decisions locked:**
  - `SpeechOut` is a Phase 1 sibling with priority-preemption semantics (`.high` preempts `.normal`; `.normal` drops if `.high` live)
  - `spatial-recall` owns the 2-press state machine and 5-s timer; `modal-input` is a pure event publisher
  - Ambient idle = gesture-idle AND head-motion-active (compound rule using `spatial-core`'s head-pose ring)
  - Anchor rehydration = eager silent plumbing; user-facing "welcome back" lives in ambient-announce cold-anchor path only
  - Observability is mandatory, not deferred — BLV alpha cannot screenshot silent failures
  - Onboarding tutorial is non-gating; hardware validation moved to a Settings diagnostic

### Surface Map (updated)

```
 Always-on (no ML)
 └── spatial-core: obstacle audio cues, head pose, mesh, anchor events, head-pose variance

 Cross-cutting infra (Phase 1)
 ├── speech-out: single AVSpeechSynthesizer, priority slots, ducking, silent-mode gate (NEW)
 └── observability: swift-log categories, metrics ring, DebugConsoleView, log export (NEW)

 User-triggered (Crown mode + Button fire)
 ├── scene mode       → scene-description  (speech-out .normal)
 ├── recall mode      → spatial-recall     (speech-out .high for Gemma gestalt)
 ├── read mode        → ocr                (speech-out .normal)
 └── silent mode      → no-op

 Passive (no gesture)
 └── ambient-announce: anchor novelty → chime (always) + speech (cold + idle + head-motion, via .high)

 Reasoning backbone
 └── gemma-enrichment: async writer + sync readers (recall, ambient)
                       priority queue with per-token cancellation check

 Memory
 └── annotation-store: spatial + anchor-metadata read/write + AnchorRehydrator
```

### Test Plan (project-wide)

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Mode cycle → feature fire | Integration | Crown → Button → speech within budget | Mode change mid-fire → previous aborts cleanly | Rapid cycling (Crown spam) |
| Cold-anchor welcome-back | Integration (sim) | New world entered → chime + Gemma-labeled speech | Device stationary → chime only | Anchor UUID jitter suppressed by AnchorRehydrator |
| Silent-mode compliance | Integration | All 4 modes + ambient suppress speech in silent | Chime still plays | Silent toggled mid-speech → current finishes, next drops |
| Cross-session memory | Integration (sim) | Prior-session annotations surface in recall after .rerecognized | Rehydration in progress when recall fires → snapshot pinned | No prior annotations → graceful "don't remember" |
| Observability export | Manual | 15-min session produces <1 MB file, anchor UUIDs hashed | Content never leaks in export | Export during active mode fire → no deadlock |

### Critical Paths

- Download + SHA verify + app entry (only hard gate from onboarding)
- Layer 1 spatial audio always on (power budget, no ML)
- Scene-mode round-trip ≤1.5 s p95 (single most visible latency metric)
- Ambient chime ≤200 ms on anchor novelty (non-optional for "companion feel")

### Observability

- **Log category:** `echosight.app` for project-wide lifecycle (install, bootstrap, session start/end)
- **Key events:**
  - `app.launch`
  - `app.bootstrap.complete(durationMs)`
  - `app.enteredBackground`
  - `app.enteredForeground`
  - `app.lowMemoryWarning`
