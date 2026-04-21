---
name: speech-out
description: Single-owner AVSpeechSynthesizer wrapper — cancel semantics, VoiceOver ducking, priority slots, contract for scene / ocr / recall / ambient / modal-input consumers
phase: 1
sprint: 1
parent: root-spec
depends_on: [root]
status: tla-verified
created: 2026-04-21
---

# Speech Out Spec

## Goal

Own the one and only `AVSpeechSynthesizer` session in EchoSight. Expose a tiny surface (`speak`, `cancel`, state) with a pinned contract that every voice-producing spec binds to: `modal-input` (mode confirmations), `scene-description` (template description), `ocr` (read-aloud text), `spatial-recall` (Gemma gestalt + template detail), `ambient-announce` (cold-anchor speech).

Without this spec, four feature specs each reach for `AVSpeechSynthesizer` directly and collide — two voices overlap, VoiceOver ducking is inconsistent, and no spec owns "cancel current speech on mode switch." This spec makes the contract explicit.

## Requirements

- Single process-wide `AVSpeechSynthesizer` instance, owned by `SpeechOut` actor
- Public API (async):
  - `speak(_ utterance: SpeechUtterance, priority: SpeechPriority) async throws -> SpeechToken`
  - `cancel(_ token: SpeechToken)` — cancels that utterance if still speaking or queued
  - `cancelAll()` — cancels every in-flight and queued utterance
  - `var state: AsyncStream<SpeechState>` — emits `.idle | .speaking(token) | .ducking`
- `SpeechPriority` enum: `.high` (user-waiting: recall gestalt, ambient cold-anchor speech), `.normal` (scene description, OCR read-aloud, mode confirmations)
- Priority semantics:
  - `.high` arriving while `.normal` is speaking → cancel in-flight `.normal`, start `.high` immediately
  - `.normal` arriving while `.high` is speaking → drop the `.normal` (never queue behind `.high`); emit `.dropped(reason: .preemptedByHigh)` via the returned token's completion
  - Same-priority arrival (`.normal` while `.normal`) → cancel in-flight, start new (most recent wins; matches the "rapid-fire presses" cancellability contract in scene-description)
- VoiceOver coexistence:
  - If VoiceOver is speaking when `speak` is called, set `AVAudioSession` category `.playback` with `.duckOthers` option so VoiceOver ducks audibly but resumes after EchoSight finishes
  - Never call `AVSpeechSynthesizer.stopSpeaking` during a VoiceOver utterance (would leave VoiceOver muted)
- Silent-mode gate: `SpeechOut` accepts a `silentModeProvider: @Sendable () -> Bool` injected at init. Semantics (pinned post-TLA, 2026-04-21): **new-request gate only**. When silent mode is on at the moment `speak(.normal)` is called, the request is dropped (`.dropped(reason: .silentMode)`). An in-flight `.normal` utterance that started while silent=FALSE is **allowed to finish** even if silent toggles ON mid-utterance. Rationale: `.normal` is user-initiated (scene / OCR / mode confirmation) — user explicitly pressed a button, cutting mid-sentence is hostile to an explicit request. `.high` priority calls bypass this gate entirely (ambient-announce owns its own silent policy; see below).
- Token lifecycle: `SpeechToken` is a lightweight UUID; caller can `await token.completion` to learn outcome (`.finished | .cancelled | .dropped(reason)`)
- State stream is hot (late subscribers see current state; not replay)

## Acceptance Criteria

- [ ] Only one `AVSpeechSynthesizer` reachable across the module (unit-testable via reflection or sentinel)
- [ ] `.high` preempts `.normal` within 100 ms (measured: `cancel` issued → synthesizer `didCancel` delegate fired)
- [ ] `.normal` arriving during `.high` is dropped, not queued; token completion is `.dropped(.preemptedByHigh)`
- [ ] Same-priority rapid fire: N=10 `.normal` calls in 500 ms results in only the last one speaking to completion; tokens 1-9 complete with `.cancelled`
- [ ] VoiceOver ducks audibly during EchoSight speech, resumes within 200 ms of EchoSight completion
- [ ] Silent mode: `.normal` call arriving while silent=TRUE drops silently; simultaneous `.high` call speaks
- [ ] Silent-mid-flight: `.normal` that started while silent=FALSE finishes naturally even if silent toggles ON mid-utterance (pinned post-TLA 2026-04-21)
- [ ] `cancelAll()` called mid-utterance returns within 100 ms; `state` stream emits `.idle`
- [ ] Unit tests cover: priority preemption, same-priority cancellation, silent-mode drop, state stream ordering, token completion outcomes
- [ ] Memory: no utterance retained after its token completes (leak test)

## Technical Approach

`SpeechOut` is an `actor` holding one `AVSpeechSynthesizer`, a `currentToken: SpeechToken?`, and a `currentPriority: SpeechPriority?`. Each `speak` call runs the priority comparison against `currentPriority` synchronously (actor-isolated), then either cancels-and-replaces or drops.

`AVSpeechSynthesizer`'s delegate callbacks (`didStart`, `didFinish`, `didCancel`) drive the state stream and token completion. Delegate is a small `@unchecked Sendable` bridge because `AVSpeechSynthesizerDelegate` isn't sendable-safe; the bridge enqueues onto the actor.

Silent-mode gate sits *inside* `SpeechOut` for `.normal` calls because every `.normal` consumer would otherwise re-implement the same check. `.high` bypasses this gate because ambient-announce owns a richer silent-mode rule (chime still plays, speech suppressed) that `SpeechOut` shouldn't duplicate; ambient-announce simply doesn't call `SpeechOut` when silent mode is on. Scene, OCR, recall use `.normal` and get the automatic gate.

**Silent-mid-flight semantics (pinned post-TLA, 2026-04-21):** the silent-mode gate checks `silentModeProvider()` only at the moment `speak(.normal)` is invoked. The gate does **not** hook `ModeChangeEvent` and does **not** cancel in-flight utterances when silent toggles on. Product rule: "finish what the user asked for; drop what the app was pushing." `.normal` is always a direct response to a user action, so completing what the user asked for is the right default. Per-feature cancellation lives at the feature layer: `ambient-announce` owns the cancel-own-`.high`-on-silent path because ambient speech is app-initiated and a silent toggle is an explicit "stop pushing things at me" signal. If a consumer ever wants `.normal` to abort on silent toggle, it subscribes to `ModeChangeEvent` itself and calls `SpeechOut.cancel(token:)`.

Audio session management: configure once at init with category `.playback`, mode `.spokenAudio`, options `.duckOthers`. This is the recommended config for accessibility speech on iOS/visionOS per Apple's AVFoundation docs — lets the app speak over background audio (music, video) without stopping it, and ducks rather than fighting VoiceOver.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Speech/SpeechOut.swift` | Actor, public API, priority logic |
| `Sources/EchoSightCore/Speech/SpeechUtterance.swift` | Text + rate + pitch + voice override |
| `Sources/EchoSightCore/Speech/SpeechPriority.swift` | Enum + priority rules |
| `Sources/EchoSightCore/Speech/SpeechToken.swift` | UUID + completion future |
| `Sources/EchoSightCore/Speech/SpeechState.swift` | State stream payload |
| `Sources/EchoSightCore/Speech/SynthesizerDelegateBridge.swift` | Sendable bridge over AVSpeechSynthesizerDelegate |
| `Tests/EchoSightCoreTests/SpeechOutTests.swift` | Priority, ducking, silent-mode, cancellation |

## Tasks

1. Define `SpeechUtterance`, `SpeechPriority`, `SpeechToken`, `SpeechState` value types
2. Implement `SynthesizerDelegateBridge` with actor hop
3. Implement `SpeechOut` actor with priority-state machine
4. Configure audio session once at init (playback + spokenAudio + duckOthers)
5. Wire `silentModeProvider` injection point (closure reading `ModalInputCoordinator.currentMode == .silent`)
6. Unit tests: priority preemption, drop, same-priority, silent-mode, VoiceOver ducking (integration with VoiceOver simulator check)
7. Leak test for token retention

## Dependencies

- **Needs from:** root (shared protocols, error type)
- **Provides to:** modal-input (mode-confirmation speech), scene-description (template TTS), ocr (text TTS), spatial-recall (gestalt + detail TTS), ambient-announce (cold-anchor speech). Five consumers.

## Eng Review

- **Depth:** BIG
- **Scope decision:** New spec carved out per Gate 2. Four feature specs plus `modal-input` referenced a `SpeechOut` wrapper that only `scene-description` listed in its Files table, and none of them pinned concurrency / interruption / priority contract. Promoted to Phase 1 so every feature spec can depend on a fixed contract.
- **Gate alignment:**
  - Gate 2 (SpeechOut ownership) → new spec, contract defined here
  - Gate 3 (recall 2-press state home) → recall's mode-switch abort uses `cancelAll()` through this spec
  - Gate 4 (ambient idle = gesture + head motion) → ambient's speech call uses `.high` priority through this spec
  - Gate 6 (observability) → state stream + token completion events logged under `echosight.speech` category

### Data Flow

```
consumer                    SpeechOut (actor)                AVSpeechSynthesizer
 │                           │                                │
 ├─ speak(utt, .high) ─────→ │                                │
 │                           │ compare vs currentPriority     │
 │                           │ if .normal speaking → cancel   │
 │                           ├────── stopSpeaking ───────────→│
 │                           │ ← didCancel ──────────────────┤
 │                           │ emit state=.idle               │
 │                           │ start new utterance            │
 │                           ├────── speak(utt) ─────────────→│
 │                           │ ← didStart ───────────────────┤
 │                           │ emit state=.speaking(token)    │
 │ ← token (UUID) ─────────── │                                │
 │                           │ ← didFinish ──────────────────┤
 │                           │ emit state=.idle               │
 │                           │ token.completion = .finished   │
 │ ← token.completion ─────── │                                │
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| `.normal` speak | Unit | Speaks to completion, token=.finished | VoiceOver interrupt → ducks audibly | Empty string utterance |
| `.high` preempts `.normal` | Unit | in-flight `.normal` cancels <100 ms, `.high` speaks | `didCancel` delayed by AVSpeechSynthesizer → still <100 ms median | `.high` arrives during `.normal` final syllable |
| `.normal` during `.high` | Unit | `.normal` token=.dropped(.preemptedByHigh) | `.high` already completing when `.normal` arrives → `.normal` could race | Actor serialization guarantees no race |
| Silent mode gate | Unit | `.normal` drops silently; `.high` speaks through | Silent mode toggled mid-utterance → current continues, new call checks at entry | Silent mode toggled while `.normal` queued (cannot queue; see rules) |
| Rapid-fire same priority | Unit | Only last `.normal` completes; N-1 cancelled | Cancellation delegate coalescing → tokens still resolve distinctly | 100 calls in 100 ms stress |
| VoiceOver ducking | Integration (VO on) | Duck during EchoSight speech, un-duck <200 ms post-completion | VoiceOver speaking when `speak` fires → both ducked briefly | AVSpeechSynthesizer session lost (phone call) → graceful .cancelled |
| `cancelAll` | Unit | All tokens complete with `.cancelled` within 100 ms | State stream emits `.idle` exactly once | Empty state (nothing speaking) → no-op |
| Token completion | Unit | Every token resolves to one of `.finished / .cancelled / .dropped` | Leak: token discarded without await → no retention | Actor deinit mid-speak → tokens resolve `.cancelled` |

### Critical Paths

- Mode-switch abort (recall / scene / ocr) → `cancelAll` → consumer sees speech cut clean
- `.high` preemption (ambient cold-anchor fires during scene description) → `.high` wins, scene's `.normal` drops with token completion
- VoiceOver ducking → never stop VoiceOver mid-utterance

### Failure Modes

| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|--------------|-----------|---------|---------|
| AVSpeechSynthesizer stop | `didCancel` delegate not fired (iOS quirk) | Speech hangs | Timeout fallback: if no `didCancel` within 500 ms, force state reset | `echosight.speech` warn |
| Audio session loss | Phone call / Siri steal session | Silent | State stream emits `.idle`; token completes `.cancelled` | `echosight.speech` info |
| VoiceOver collision | EchoSight speaks during VoiceOver focus announcement | Overlap | Duck via `.duckOthers`; not a hard mute | `echosight.speech` debug |
| Silent-mode gate | Provider closure returns stale value | Spoken when shouldn't | Closure invoked per-call, not cached | — |
| Delegate bridge | Bridge actor-hop backpressure | Token resolution delayed | Unit test with synthetic delays | — |

### Observability

- **Log category:** `echosight.speech`
- **Key events:**
  - `speak.accepted(token, priority, silentMode)`
  - `speak.preempted(tokenDropped, tokenStarted, reason)`
  - `speak.dropped(token, reason)`
  - `speak.finished(token, durationMs)`
  - `speak.cancelled(token, source)`
- **Metric:** `PipelineMetricsBuffer` records per-utterance `{priority, durationMs, outcome}` — surfaces in `DebugConsoleView` under "Speech"

### Deferred Work
- [ ] Custom voice selection per mode (v1.0 personalization)
- [ ] Speech speed/pitch user controls (v1.0 settings)
- [ ] Multi-language voice switching (v1.0 i18n)
- [ ] Bone-conduction / hearing-aid routing hints (v1.0+ when AVP audio ecosystem matures)

## TLA Verification

- **Date:** 2026-04-21 (re-verified after gate decisions)
- **Tool:** TLC 2026.03.16.144735
- **Spec file:** `/tmp/echosight-tla/SpeechOut.tla`
- **Result:** PASS (Gate 1 resolved: "Let finish" — user-initiated `.normal` completes past silent toggle)
- **State space:** 269 states generated, 70 distinct, depth 10

### Model

State variables:
- `slot`: `"idle" | "high" | "normal"` (single-slot arbitrator)
- `silentMode`: BOOLEAN
- Counters: `requests`, `drops`, `finishes`

Actions modeled (11 total):
- `RequestNormalIdle` — accepts .normal from idle
- `RequestNormalSilentDrop` — .normal drops when silent=TRUE
- `RequestNormalDuringHigh` — .normal drops (preempted-by-high)
- `RequestNormalDuringNormal` — same-priority replace (most recent wins)
- `RequestHighIdle` / `RequestHighPreemptsNormal` / `RequestHighDuringHigh`
- `FinishNormal` / `FinishHigh`
- `CancelAll`
- `ToggleSilent`

### Invariants Verified

| Invariant | Status |
|-----------|--------|
| `TypeInvariant` — state variables within domain | PASS |
| `AtMostOneSpeaking` — single-slot invariant (no two utterances concurrent) | PASS |
| `RequestsAccounted` — requests = drops + finishes + (1 if speaking else 0) | PASS |
| `PriorityMonotonic` — .high is never preempted by .normal (structural, verified by action enumeration) | PASS |
| `NoNewNormalStartedInSilent` — every action transitioning slot to "normal" requires silentMode=FALSE (structural action-level guard) | PASS |

### Edge Cases Explored

- Rapid-fire same-priority .normal calls: every call except the last completes with `.cancelled` outcome. Confirmed: 4 `RequestNormalDuringNormal` actions in a row increment `drops` each time.
- `.high` preempts `.normal`: `RequestHighPreemptsNormal` is the only path slot: normal -> high. Confirmed.
- `.normal` arriving during `.high`: dropped, not queued. Confirmed.
- Silent mode toggled between two `.normal` calls: first completes, second is dropped at entry. Confirmed.
- `cancelAll` from every reachable state: returns slot to `"idle"`, drop counter increments only if something was speaking. Confirmed.

### Counterexample (resolved)

TLC initially caught: `.normal` in-flight, user toggles silent=ON mid-utterance, speech continues. The original state-level invariant `~(slot = "normal" /\ silentMode)` was too strong. Reformulated as action-level `NoNewNormalStartedInSilent` — every action transitioning slot to `"normal"` requires `silentMode = FALSE` at the guard.

**Gate 1 resolution (2026-04-21):** "Let finish." `.normal` is user-initiated (scene / OCR / mode confirmation). Cutting mid-sentence is hostile to an explicit user request. Silent-mode gate is new-request-only: checks `silentModeProvider()` at `speak()` entry, does not watch `ModeChangeEvent`, does not cancel in-flight utterances. Model matches spec; invariant holds.

### Open Items

- None. Gate 1 resolved.

### Notes

The state space is small because the arbitrator carries minimal state (one slot, one boolean). The priority-ordering invariant is proven structurally — no action transitions slot to "normal" from a non-idle/non-normal state — so any violation would require a spec change, not an implementation bug. TLC enumerated every reachable interleaving of the 11 actions and found no temporal inconsistency under the spec-as-written semantics.
