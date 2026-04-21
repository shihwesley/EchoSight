---
name: scene-description
description: Scene mode — capture → detect → fuse → fast-path template TTS (Gemma enrichment async). Gesture wiring moved to modal-input spec.
phase: 2
sprint: 2
parent: root-spec
depends_on: [root, modal-input, detector, fusion, speech-out, observability]
status: eng-reviewed
created: 2026-04-21
---

# Scene Description Spec (Scene Mode)

## Goal

Scene-mode pipeline: when user fires `.scene` via `modal-input`, capture → detect → fuse → spoken description within ~1.2 s using template formatting over detection + distance. Gemma enrichment happens asynchronously (handled by `gemma-enrichment` spec) — scene mode itself never awaits Gemma. Template owns the voice for this mode; Gemma speech lives in `spatial-recall` and `ambient-announce` specs, resolving the two-voice tension surfaced in CEO review.

**Scope change under CEO review (EXPANSION):** this spec no longer owns gesture wiring. All Crown + Button handling moved to `modal-input` spec. This spec subscribes to `ModeFiredEvent(.scene)` events.

## Requirements

- Subscribe to `ModeFiredEvent(.scene)` from `modal-input`
- `SceneDescriptionPipeline` orchestrator: capture → detect → fuse → speak
- Template formatter: `"<label> <distance> <cardinal direction>"` per top-N candidates
- Cardinal direction derived from ray azimuth (ahead / left / right / behind)
- Distance rounded to nearest 0.5 m
- Top 3-5 candidates by salience (close + central + high-confidence weighted)
- `SpeechOut` wrapper over `AVSpeechSynthesizer` using user's configured VoiceOver voice (shared with `ocr`, `spatial-recall`, `ambient-announce`)
- Pipeline time budget: ≤1.5 s p95 from mode-fire event to first syllable
- Graceful degradation: zero detections → "I don't detect anything in front of you"
- Emits annotation candidates onto a queue consumed by annotation-store
- `DescriptionTemplateFormatter` kept as a public pure function within `EchoSightCore` so `spatial-recall` can reuse it for its top-N detail list
- Fast path stays template-only — never awaits Gemma. Gemma-voice output in v0.1 happens only in recall and ambient specs.

## Acceptance Criteria

- [ ] Physical-device round-trip measured ≤1.5 s p95 on Apple Vision Pro from `ModeFiredEvent(.scene)` to first syllable
- [ ] Sample indoor scene yields plausible phrase ("chair 2 m ahead, doorway 4 m right")
- [ ] Empty-detection case speaks graceful fallback
- [ ] VoiceOver voice respected (via shared `SpeechOut`)
- [ ] Pipeline is cancellable (user fires scene again → previous speech cut short; mode switch → aborted cleanly)
- [ ] Integration test mocks detector + fusion and asserts speech string
- [ ] `DescriptionTemplateFormatter` unit-tested in isolation; reused by `spatial-recall` spec's detail list

## Technical Approach

Orchestrator consumes `PassthroughCaptureSource`, `Detector`, `FusionEngine`, `SpeechOut` via dependency injection. Subscribes to `modal-input`'s `AsyncStream<ModeFiredEvent>` and reacts only to `.scene` events. Salience scoring: `score = confidence * centralityBias / max(distance, 0.5)` — tuneable. Fast path never awaits Gemma — Gemma enrichment runs off the critical path via `gemma-enrichment`'s async queue.

Gesture wiring lives entirely in `modal-input` and `project-skeleton` — removed from this spec.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Features/SceneDescriptionPipeline.swift` | Orchestrator subscribing to `.scene` events |
| `Sources/EchoSightCore/Features/DescriptionTemplateFormatter.swift` | Phrase synthesis (shared with spatial-recall) |
| `Sources/EchoSightCore/Features/SalienceScorer.swift` | Candidate ranking |
| `Sources/EchoSightCore/Speech/SpeechOut.swift` | `AVSpeechSynthesizer` wrapper (shared across scene / recall / ocr / ambient) |
| `Tests/EchoSightCoreTests/SceneDescriptionPipelineTests.swift` | Integration test with mocks |
| `Tests/EchoSightCoreTests/DescriptionTemplateFormatterTests.swift` | Phrase coverage |
| `Tests/EchoSightCoreTests/SalienceScorerTests.swift` | Ranking correctness |

**Removed from this spec (moved to `modal-input`):**
- `Sources/EchoSightApp/Input/CaptureGestureBinding.swift` — gesture wiring now owned by `modal-input`'s `HardwareEventBridge.swift`

## Tasks

1. Implement `SpeechOut` wrapper over `AVSpeechSynthesizer` (shared; also consumed by `ocr`, `spatial-recall`, `ambient-announce`)
2. Implement `DescriptionTemplateFormatter` + tests (shared with `spatial-recall`)
3. Implement `SalienceScorer` + tests
4. Implement `SceneDescriptionPipeline` orchestrator subscribing to `ModeFiredEvent(.scene)`
5. Integration test with mocked detector/fusion and mocked `modal-input` event stream
6. Perf measurement on device; record p95 in progress.md

## Dependencies

- **Needs from:** root, modal-input (`ModeFiredEvent(.scene)` events), detector, fusion
- **Provides to:** annotation-store (candidate queue), gemma-enrichment (description context), spatial-recall (reuses `DescriptionTemplateFormatter`)

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** Gesture wiring removed (moved to new `modal-input` spec). Pipeline logic unchanged. Template formatter elevated to shared API so `spatial-recall` can reuse it for its second-press detail list. Two-voice tension (Tension 3) resolved at spec-boundary level: this spec owns template voice, Gemma speech lives in recall and ambient specs, never collides.
- **Premise validation:** "Scene description on press" held. Expansion moved the *trigger* to `modal-input` and kept the *pipeline* unchanged. This spec got smaller and sharper; input layer got its own home.

### Dream State Delta
At 12-month ideal, scene mode is predictive (fires automatically when user pauses in a new view) rather than gesture-triggered. The `ModeFiredEvent` abstraction lets a future `ModePredictor` in `modal-input` drive this pipeline without change here.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| Mode subscription | Event bus dropped / coordinator deallocated | Silent on press — no speech | Integration test with injected stream failure | Partial |
| Salience scoring | All candidates score equal | Non-deterministic ranking | Tiebreaker by insertion order | Yes |
| SpeechOut race | Rapid-fire presses | Overlapping speech | Cancellability acceptance criterion | Yes |
| Empty detection | Detector returns zero | Graceful fallback | Acceptance criterion | Yes |

### Deferred Work
- [ ] Spoken confidence hedging ("I think that's a chair") — v1.0 polish
- [ ] Scene-mode-predictive trigger — v1.0, belongs in `modal-input`
- [ ] Multi-sentence rich descriptions — intentionally not here; Gemma-rich speech lives in `spatial-recall`

## Eng Review

- **Depth:** BIG
- **Scope changes (gates applied):**
  - Gate 2: `SpeechOut.speak(priority: .normal)` replaces direct `AVSpeechSynthesizer`. `SpeechOut` removed from Files table (moved to `speech-out-spec`). Template TTS is `.normal` priority — will be preempted by ambient-announce's `.high` cold-anchor speech.
  - Gate 3 adjacent: pipeline subscribes to both `ModeFiredEvent(.scene)` AND `ModeChangeEvent` for self-abort. When mode changes to anything non-scene mid-pipeline, in-flight capture / detect / fuse / speak is cancelled via structured Task cancellation.
  - Gate 6: every pipeline stage emits metrics under `echosight.scene`.

### Data Flow

```
modal-input                  SceneDescriptionPipeline         downstream specs
 │                            (actor, background Task)
 │ ModeFiredEvent(.scene) ──→│                                │
 │                            │ Task { ... }                   │
 │                            ├─ capture.request() ───────────→│ capture
 │                            │ ← CapturedFrame ──────────────│
 │                            │                                │
 │                            ├─ detector.detect(frame) ─────→│ detector
 │                            │ ← [DetectionResult] ───────────│
 │                            │                                │
 │                            ├─ fusion.fuse(detections,       │ fusion
 │                            │   pose, scene) ───────────────→│
 │                            │ ← [AnnotationCandidate] ───────│
 │                            │                                │
 │                            ├─ salience score + top-N        │
 │                            ├─ template format string        │
 │                            │                                │
 │                            ├─ SpeechOut.speak(              │ speech-out
 │                            │   text, .normal) ─────────────→│
 │                            │                                │
 │                            ├─ annotation-store.enqueue ────→│ annotation-store
 │                            │   (candidates for persistence)
 │                            │                                │
 │ ModeChangeEvent ──────────→│ cancel current Task            │
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Fire → speak | Integration | ≤1.5 s p95 end-to-end | Capture fails → graceful speech "couldn't capture" | 0 detections → "don't detect anything" |
| Mode-switch abort | Integration | Pipeline cancels cleanly on `ModeChangeEvent` | In-flight speech aborts via `SpeechOut.cancelAll` | Mode switch during template computation → cancels before speech starts |
| `.high` preemption | Integration | Ambient `.high` preempts scene `.normal` → scene token completes `.dropped(.preemptedByHigh)` | Scene pipeline catches dropped outcome + logs | Rapid-fire scene presses cancel prior pipeline's speech |
| Salience ranking | Unit | Close + confident + central ranked highest | Ties → insertion-order tiebreak | All-same-confidence → deterministic order |
| Template format | Unit | "chair 2m ahead" | Unknown label → "something" | Missing distance → omit from phrase |

### Critical Paths

- End-to-end latency ≤1.5 s p95 — the headline scene-mode metric
- Mode-switch abort must never leave orphaned speech (SpeechOut's cancelAll handles)
- Annotation candidate enqueue must not block speech (fire-and-forget to annotation-store queue)

### Observability

- **Log category:** `echosight.scene`
- **Key events:**
  - `scene.fire.received(timestamp)`
  - `scene.capture.complete(durationMs)`
  - `scene.detect.complete(detectionCount, durationMs)`
  - `scene.fuse.complete(candidateCount, durationMs)`
  - `scene.speak.started` / `scene.speak.finished(durationMs)` / `scene.speak.dropped(reason)`
  - `scene.cancelled(reason, stage)`
  - `scene.pipeline.total(durationMs, outcome)`
