---
name: modal-input
description: Crown-as-mode + Button-as-action input layer — cycles between Scene / Recall / Read / Silent, dispatches to feature pipelines
phase: 2
sprint: 2
parent: root-spec
depends_on: [root, project-skeleton, speech-out, observability]
status: tla-verified
created: 2026-04-21
---

# Modal Input Spec

## Goal

Own all user-initiated input for v0.1. Digital Crown rotation cycles through modes; Capture Button fires the current mode. No voice, no gaze. Mode changes are spoken via VoiceOver-style confirmation. Every feature pipeline subscribes to a dispatch event for its mode.

## Requirements

- `Mode` enum: `.scene`, `.recall`, `.read`, `.silent` (4th reserved / user-default-off position)
- Crown rotation quantized to mode steps with haptic tick per step
- On mode change, speak short confirmation via `SpeechOut.speak(priority: .normal)` (e.g. "describe mode", "recall mode", "read mode", "silent")
- Capture Button press publishes `ModeFiredEvent(mode: Mode, timestamp: Date)` onto a shared event bus
- Mode-change publishes `ModeChangeEvent(from: Mode, to: Mode, timestamp: Date)` onto a separate event stream — consumed by `spatial-recall` (for mid-window abort), `ambient-announce` (for silent-mode gating), and `scene-description` / `ocr` (for in-flight cancellation)
- Mode persists across app backgrounding
- VoiceOver-only navigation of mode set must work (mode enumerable via VoiceOver rotor as a fallback for users who prefer not to use Crown rotation)

## Acceptance Criteria

- [ ] Crown rotation cycles through 4 modes with audible confirmation at each step
- [ ] Holding current mode + pressing Capture Button publishes a `ModeFiredEvent` within 50 ms of button-up
- [ ] Mode change during an in-flight Feature 1 pipeline does NOT interrupt the in-flight pipeline's speech — next firing uses new mode
- [ ] Silent mode publishes no events on Button press (button is a no-op in silent)
- [ ] VoiceOver rotor fallback reachable via standard accessibility gesture
- [ ] Unit tests for Crown step quantization, event bus publishing, silent-mode no-op

## Technical Approach

Pure input layer. No feature logic — only publishes events. No per-mode state buffering. Feature pipelines (`scene-description`, `spatial-recall`, `ocr`, `ambient-announce`) subscribe. This keeps input decoupled from features: changing mode semantics later (adding modes, reassigning buttons) touches only this spec.

Two `AsyncStream`s owned by a `ModalInputCoordinator` actor:
- `firedEvents: AsyncStream<ModeFiredEvent>` — emitted on Capture Button press
- `changeEvents: AsyncStream<ModeChangeEvent>` — emitted on Crown rotation mode step

Both streams use `.bufferingNewest(1)` buffering policy — if a consumer stalls, only the newest event is retained (never queue old presses behind backpressure).

Mode confirmation speech routed through `SpeechOut.speak(SpeechUtterance(text: "..."), priority: .normal)` with elevated rate so it doesn't feel like a pause. Silent mode confirmation speaks via `.high` priority once to announce the mode switch itself, then `SpeechOut`'s silent-mode gate takes over for subsequent `.normal` calls.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Input/Mode.swift` | Enum + user-facing labels |
| `Sources/EchoSightCore/Input/ModalInputCoordinator.swift` | Actor, event stream, mode state |
| `Sources/EchoSightCore/Input/ModeFiredEvent.swift` | Event payload |
| `Sources/EchoSightCore/Input/CrownQuantizer.swift` | Rotation → discrete mode-step mapping with haptic tick |
| `Sources/EchoSightApp/Input/HardwareEventBridge.swift` | Binds Digital Crown + Capture Button to coordinator |
| `Tests/EchoSightCoreTests/ModalInputCoordinatorTests.swift` | Mode cycling + event publishing |
| `Tests/EchoSightCoreTests/CrownQuantizerTests.swift` | Step quantization math |

## Tasks

1. Define `Mode` enum + user-facing label strings (localizable)
2. Implement `CrownQuantizer` (rotation delta → step, with tick threshold)
3. Implement `ModalInputCoordinator` actor with `AsyncStream<ModeFiredEvent>` output
4. Implement mode-change speech confirmation via lightweight `AVSpeechUtterance`
5. Bridge hardware events (Digital Crown, Capture Button) in app target
6. Wire VoiceOver rotor fallback for accessibility equivalence
7. Unit tests for quantizer, coordinator, no-op silent mode

## Dependencies

- **Needs from:** root (shared protocols), project-skeleton (app target for hardware bridge)
- **Provides to:** scene-description (fires on `.scene`), spatial-recall (fires on `.recall`), ocr (fires on `.read`), ambient-announce (nothing direct — passive path, but subscribes to mode to suppress speech when non-silent mode is firing)

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** New spec created. This spec did not exist in the original 10-spec plan. Carved out of the original `scene-description` spec's `CaptureGestureBinding.swift` file — gesture wiring moves here because v0.1 now has 4 modes, not 1.
- **Premise validation:** The "gesture-only, no voice" decision from interactive-planning held under scope expansion. Open-vocabulary anything (recall target nouns, read-this-specifically) would have required voice; the Crown-as-mode pattern avoids it entirely while matching how VoiceOver rotor already works on Apple platforms, which BLV users know.

### Dream State Delta
At 12-month ideal, modes are probably *predictive* (the app guesses what mode you want based on head pose + scene), not *manually cycled*. This spec is the scaffolding for that later intelligence — keep the event bus shape so a future `ModePredictor` can publish `ModeFiredEvent` without user input.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| Crown rotation | Skipped step (fast rotation) | Lands on wrong mode | Unit test `CrownQuantizerTests` | Yes |
| Button press | Race with mode change during rotation | Fires stale mode | Integration test with synthetic events | Yes |
| Mode speech | Speech collides with Feature 1 in-flight utterance | Two voices overlap | Acceptance criterion #3 | Yes |
| VoiceOver rotor | Rotor disabled by OS accessibility setting | No fallback access | Manual audit during BLV alpha | No |

### Deferred Work
- [ ] Predictive mode switching — v1.0 candidate, hooks into head pose + scene classification
- [ ] Customizable mode order (user drags to reorder in settings) — v1.0 usability polish

## Eng Review

- **Depth:** BIG
- **Scope changes:**
  - Gate 3: deleted the "5-second press-window state for Recall mode" line from Requirements. `modal-input` is now strictly stateless per-mode — it publishes events, it does not buffer press history. `spatial-recall` owns its own 2-press state machine.
  - Gate 2: mode-confirmation speech now routes through `speech-out` (the new Phase 1 spec), not a direct `AVSpeechSynthesizer`. Added `speech-out` to `depends_on`.
  - New: `ModeChangeEvent` stream emitted on Crown rotation. Consumed by `spatial-recall` for mid-window abort, `ambient-announce` for silent-mode gating, and `scene-description` / `ocr` for in-flight cancellation. Stream policy: `.bufferingNewest(1)` on both streams.

### Data Flow

```
Hardware                ModalInputCoordinator          consumers
  │                      (actor)
  │ Crown rotation ────→│ quantize to step             │
  │                      │ ├─ emit ModeChangeEvent ───→│ spatial-recall (abort)
  │                      │ │                           ├→ ambient-announce (silent gate)
  │                      │ │                           └→ scene/ocr (cancel in-flight)
  │                      │ └─ SpeechOut.speak(.normal, "recall mode")
  │                      │
  │ Button press ───────→│ if currentMode == .silent: no-op
  │                      │ else: emit ModeFiredEvent ──→│ scene-description (on .scene)
  │                      │                             ├→ spatial-recall (on .recall)
  │                      │                             └→ ocr (on .read)
```

### State Diagram (Crown quantization)

```
  .silent ←──tick──→ .scene ←──tick──→ .recall ←──tick──→ .read ←──tick──→ .silent (wraparound)
```

Each tick corresponds to a Crown rotation delta exceeding the quantization threshold. Haptic feedback fires on each tick.

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Crown rotate | Unit | Delta > threshold → step + tick + confirmation speech | Delta < threshold → ignored | Fast spin → multiple steps; no stale confirmations |
| Button press | Unit | `ModeFiredEvent` published with current mode | Silent mode → no event published | Button press during mode change mid-speech → event still fires |
| Stream buffering | Unit | `.bufferingNewest(1)` drops stale events when consumer stalls | Two events arrive fast → only newest delivered | Consumer resumes → sees newest only |
| ModeChangeEvent | Unit | Published on every mode step | No-op if mode didn't change | Wraparound silent→scene emits one event |
| VoiceOver rotor fallback | Manual | VO user can cycle mode via rotor | Rotor disabled → fall back to Crown | — |
| Background/foreground | Integration | Mode persists across backgrounding | App killed + relaunch → mode restored | Mid-press backgrounding → press cancelled |

### Critical Paths

- `ModeFiredEvent` publishes within 50 ms of button-up (acceptance criterion holds)
- Mode confirmation speech (via SpeechOut) does not collide with feature speech (same SpeechOut handles priority)
- `ModeChangeEvent` → recall abort path is the key concurrency correctness check (tested in spatial-recall)

### Observability

- **Log category:** `echosight.modal`
- **Key events:**
  - `modal.mode.changed(from, to)`
  - `modal.mode.fired(mode, suppressed)` (suppressed=true if silent mode)
  - `modal.crown.tick(delta, newMode)`
  - `modal.confirmation.spoken(mode)`
  - `modal.rotor.fallback.used`

## TLA Verification

- **Date:** 2026-04-21
- **Tool:** TLC 2026.03.16.144735
- **Spec file:** `/tmp/echosight-tla/ModalInput.tla`
- **Result:** PASS
- **State space:** 467 states generated, 189 distinct, depth 9

### Model

State variables:
- `mode`: `"silent" | "scene" | "recall" | "read"` (cyclic via NextMode function)
- `pendingChange` / `pendingFire`: BOOLEAN flags modeling the `bufferingNewest(1)` slot per stream
- Counters: `firesPublished`, `changesPublished`, `firesSuppressed`

Actions modeled:
- `CrownTick` — rotation delta > threshold -> NextMode + publish ModeChangeEvent
- `ButtonPressFires` / `ButtonPressSuppressed` — button in active / silent mode
- `ConsumerDrainsChange` / `ConsumerDrainsFire` — downstream subscriber consumption
- `Stutter` — budget cap to avoid spurious deadlock at bound

### Invariants Verified

| Invariant | Status |
|-----------|--------|
| `TypeInvariant` — state variables within domain | PASS |
| `ModeIsValid` — mode in {silent, scene, recall, read} always | PASS |
| `BufferingPolicy` — at most one pending event per stream | PASS |
| `SilentButtonIsNoOp` — button in silent never increments firesPublished | PASS |
| `PendingFireEventuallyDrained` (liveness) — every pending fire is eventually consumed | PASS |
| `PendingChangeEventuallyDrained` (liveness) — every pending change is eventually consumed | PASS |

### Edge Cases Explored

- Rapid Crown rotation with stalled consumer: `bufferingNewest(1)` drops intermediate events; consumer sees only the newest mode. Confirmed.
- Button press during mode change: mode is atomically updated before the press guard checks; no torn reads possible because `ModalInputCoordinator` is an actor and the model treats each action as atomic.
- Silent-mode button: no event published. Confirmed structurally via `ButtonPressSuppressed` action having no impact on `firesPublished`.
- Wraparound cycle (read -> silent): emits one ModeChangeEvent, confirmed via `CrownTick`.

### Initial Finding (Resolved)

First TLC run reported a deadlock reachable by pressing the button 6 times in silent mode (exhausting the ops budget with no other action enabled). Resolution: this is a model-bound artifact, not a real deadlock — the real system is an infinite loop. Added a `Stutter` action that is enabled once `ops = MaxOps` so the state machine does not falsely appear to terminate.

### Notes

No open items. State machine is structurally sound: deterministic, bounded, and the buffering policy is respected under every reachable interleaving of producer and consumer.
