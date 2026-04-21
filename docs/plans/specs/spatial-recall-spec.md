---
name: spatial-recall
description: Recall mode — 1st press = Gemma room gestalt; 2nd press within 5s = top-N nearest annotations
phase: 3
sprint: 2
parent: root-spec
depends_on: [root, modal-input, annotation-store, gemma-enrichment, speech-out, observability]
status: tla-verified
created: 2026-04-21
---

# Spatial Recall Spec

## Goal

When user is in recall mode and presses the Capture Button, speak the room as remembered. First press: Gemma one-sentence gestalt. Second press within 5 s: top-N nearest annotations with distance + cardinal direction. This is the surface that makes cross-session spatial memory (the moat) tangible to the user.

## Requirements

- Subscribe to `ModeFiredEvent(.recall)` from `modal-input`
- State machine: `idle → gestaltSpoken → detailSpoken` with 5-second timeout back to `idle`
- First press (`idle → gestaltSpoken`):
  - Query `AnnotationStore.nearestAnnotations(headPose, radius: 5m)`
  - If empty: speak "I don't remember anything around you yet"
  - Else: call `GemmaRunner.summarize(annotations:)` with a 1.5 s timeout
  - Speak returned gestalt ("You're in a living room with a chair and a doorway")
- Second press within 5 s (`gestaltSpoken → detailSpoken`):
  - Speak top-N detail list: `"<label> <distance> <direction>"` for 3-5 nearest
  - Same formatter reuse from `scene-description` spec's `DescriptionTemplateFormatter`
- Timeout (`gestaltSpoken → idle` after 5 s without second press): silent reset. **Window expiry does not cancel an in-flight gestalt speech** (pinned post-TLA 2026-04-21). If the 5-s window fires while gestalt speech is still speaking, state transitions to `.idle` but `SpeechOut.cancel` is NOT called — the user hears the complete gestalt sentence and the next press starts fresh as a new first-press. Rationale: cutting a Gemma-generated sentence mid-utterance over a 5-s timing boundary is hostile to comprehension; the timing is purely a "does this count as the 2nd press?" gate, not a speech-lifecycle gate.
- Any mode switch during 5 s window aborts the state machine (this DOES call `SpeechOut.cancelAll()` — mode change is an explicit user signal, window expiry is not)
- Cancellable if user fires scene mode mid-recall

## Acceptance Criteria

- [ ] First press after entering recall mode speaks Gemma gestalt within 2 s p95
- [ ] Second press within 5 s speaks top-N detail list within 800 ms
- [ ] Second press >5 s after first press is treated as a new first press (gestalt again)
- [ ] Empty annotation set speaks graceful fallback without invoking Gemma
- [ ] Mode-switch mid-window aborts cleanly — no stray speech (mode change calls `SpeechOut.cancelAll()`)
- [ ] Window-expiry-during-gestalt-speech: state returns to `.idle` but gestalt speech finishes naturally; next press is treated as a new first press (pinned post-TLA 2026-04-21; contrast with mode-switch which cancels speech)
- [ ] World-anchor rehydration integration test: prior-session annotations surface when anchor re-recognized
- [ ] Unit tests for state machine transitions + timeout behavior

## Technical Approach

State machine lives in a `SpatialRecallOrchestrator` actor. It consumes `ModeFiredEvent` from the modal-input event bus and owns a `Task` that resets state after the 5 s window. Reuses `DescriptionTemplateFormatter` from `scene-description` — the only new formatting logic is the Gemma gestalt pass, which is a thin wrapper calling `GemmaRunner.summarize(annotations:)`.

Gemma summarize path is distinct from the async enrichment queue: it's synchronous-for-user (user waits), bounded to ~30 tokens, 1.5 s latency budget, single-shot. If Gemma exceeds budget, fall back to template gestalt from annotation counts ("Three things around you: a chair, a table, a doorway").

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Features/SpatialRecallOrchestrator.swift` | State machine + event subscription |
| `Sources/EchoSightCore/Features/RecallGestaltFormatter.swift` | Template fallback when Gemma times out |
| `Tests/EchoSightCoreTests/SpatialRecallOrchestratorTests.swift` | State machine transitions |
| `Tests/EchoSightCoreTests/RecallGestaltFormatterTests.swift` | Fallback phrase coverage |

## Tasks

1. Implement `RecallGestaltFormatter` (template fallback for Gemma-timeout path)
2. Implement `SpatialRecallOrchestrator` state machine (idle / gestalt-spoken / detail-spoken)
3. Wire subscription to `modal-input` event bus for `.recall` events
4. Wire `AnnotationStore.nearestAnnotations` query
5. Wire `GemmaRunner.summarize(annotations:)` call with 1.5 s timeout + fallback
6. Integration test with mocked annotation store + mocked Gemma + real state machine
7. On-device test exercising prior-session annotation rehydration via world anchor

## Dependencies

- **Needs from:** root, modal-input (`ModeFiredEvent` stream), annotation-store (`nearestAnnotations`), gemma-enrichment (`summarize` read path)
- **Provides to:** none (terminal user-facing feature for recall surface)

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** New spec created. The original plan had annotation-store as write-only for v0.1 — Gemma enriched annotations but nothing read them back. Under expansion, recall mode surfaces the annotation store as user-visible value. Without this spec, the stated moat ("cross-session persistence is the moat feature") would have zero v0.1 user-facing exercise.
- **Premise validation:** The 1st-press-gestalt / 2nd-press-detail pattern solves the two-voice problem (Tension 3 from review): Gemma owns the voice in recall mode, template owns the voice in scene mode, they never collide.

### Dream State Delta
At 12-month ideal, recall supports open-vocabulary target queries ("where is my keys"), which requires voice input. This spec's state machine is built so a future voice target can slot in as an alternate entry point to the same formatters/query paths. Keep Gemma's summarize-annotations path independent of the user's target so it composes naturally with a later target-filter layer.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| Gemma summarize | Exceeds 1.5 s timeout | Silent delay, then template fallback | Integration test with injected delay | Yes |
| Empty annotation set | User in unfamiliar place | Graceful "don't remember" speech | Acceptance criterion #4 | Yes |
| Anchor rehydrate | Anchor re-recognized mid-recall | Annotations appear "from nowhere" (intended, but could confuse) | Manual alpha note | Yes |
| State machine | Race: second press arrives while first is still in Gemma | Detail fires before gestalt finishes | Unit test needs to cover | Partial |

### Deferred Work
- [ ] Target-noun filtering ("where is the chair") — v1.0 when voice lands
- [ ] Recall-by-time ("what did I see yesterday") — v1.0+, requires session-scoped query
- [ ] Visual recall UI for sighted caregivers — v1.0+, out of scope for BLV alpha

## Eng Review

- **Depth:** BIG
- **Scope changes (Gate 3 — this spec OWNS the 2-press state):**
  - This spec owns the 2-press state machine and 5-s timer. `modal-input` is purely stateless event publisher.
  - `SpatialRecallOrchestrator` is an `actor` with state enum: `.idle` | `.awaitingSecondPress(firstPressAt: Date, windowTask: Task<Void, Never>)` | `.speakingDetail`.
  - Merged subscription to BOTH `ModeFiredEvent(.recall)` AND `ModeChangeEvent`. Single `for await` loop multiplexes via `AsyncStream.merge`-equivalent pattern.
  - Mode-change events abort: cancel `windowTask`, cancel in-flight Gemma call via Task cancellation, cancel in-flight speech via `SpeechOut.cancelAll()`. State returns to `.idle`.
  - Gemma gestalt speech uses `SpeechOut.speak(priority: .high)` — it's user-waiting voice output, so preempts any in-flight `.normal` speech (ambient's non-cold-anchor pretty-much-doesn't-exist case).
  - Top-N detail speech uses `SpeechOut.speak(priority: .normal)` — not user-waiting after the gestalt.
  - **Race fix (failure mode 4):** second press arriving while first is still in Gemma → queue the detail speech behind the gestalt speech using `SpeechOut`'s completion future. Specifically: await gestalt token completion BEFORE dispatching detail. If gestalt cancelled (.high preempted by ambient), detail is also cancelled.

### State Diagram

```
  ┌─────────┐
  │  .idle  │
  └────┬────┘
       │ ModeFiredEvent(.recall)
       │  & annotations non-empty
       ▼
  ┌─────────────────────┐     5-s windowTask fires     ┌──────────┐
  │ .awaitingSecondPress│ ─────────────────────────→ │  .idle   │
  │   firstPressAt      │                              └──────────┘
  │   windowTask        │
  └─────────┬───────────┘
            │ ModeFiredEvent(.recall) within 5 s
            ▼
  ┌─────────────────────┐
  │   .speakingDetail   │
  │ (top-N annotations) │──── completion ────→ .idle
  └─────────────────────┘

  ModeChangeEvent from any state → cancel windowTask, cancel Gemma, cancelAll speech → .idle
  Empty annotations on first press → skip Gemma, graceful speech, stay .idle
```

### Data Flow

```
modal-input                 SpatialRecallOrchestrator        downstream
 │                           (actor)                          │
 │ ModeFiredEvent(.recall)→│                                 │
 │                           │ annotation-store.             │
 │                           │   nearestAnnotations ────────→│ annotation-store
 │                           │ ← [WorldAnnotation] ──────────│
 │                           │                                │
 │                           │ if empty:                      │
 │                           │   SpeechOut.speak(             │
 │                           │     "don't remember", .normal)
 │                           │   stay .idle                   │
 │                           │                                │
 │                           │ else:                          │
 │                           │   transition .awaitingSecondPress
 │                           │   start windowTask (5 s)       │
 │                           │   Gemma.summarize(             │ gemma-enrichment
 │                           │     annotations) ────────────→│
 │                           │   ← gestalt or .timeout       │
 │                           │   SpeechOut.speak(             │ speech-out
 │                           │     gestalt, .high) ──────────→│
 │                           │                                │
 │ ModeFiredEvent(.recall)→│ (within 5 s)                    │
 │                           │ await gestalt completion       │
 │                           │ format top-N detail via        │
 │                           │   DescriptionTemplateFormatter │ (reused from scene)
 │                           │ SpeechOut.speak(               │
 │                           │   detail, .normal)             │
 │                           │                                │
 │ ModeChangeEvent ─────────→│ cancel windowTask + Gemma     │
 │                           │ + SpeechOut.cancelAll          │
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| 1st press gestalt | Integration | ≤2 s p95 Gemma summarize + speak | Gemma timeout → template fallback | Empty annotations → "don't remember" |
| 2nd press within 5 s | Integration | Detail speech within 800 ms | Gestalt still in Gemma when 2nd press arrives → detail awaits gestalt completion | 2nd press arrives 4999 ms after 1st → still counts |
| 5-s timeout | Unit | No 2nd press → return to .idle silently | windowTask cancelled by mode change → also returns to .idle | Timeout firing during speech → speech completes, state is already .idle |
| Mode-change abort | Integration | In-flight Gemma cancels, speech cancels | Mode change during gestalt Gemma call → `.timeout` in caller never fires; Task cancellation propagates | Mode change during 2nd press speak → speech cuts clean |
| Race (2nd press during Gemma) | Unit | Detail queues behind gestalt | Both complete in order | Gestalt cancelled → detail also cancelled (coherent) |
| Anchor rehydrate timing | Integration | Prior-session annotations surface after .rerecognized → first recall query includes them | `.rerecognized` arrives during recall query → use pre-rehydration snapshot (annotation-store snapshot pinning) | Rehydrate in progress at recall time → consumer may see partial cache (acceptable, logged) |
| Back-to-back recall modes | Integration | User fires recall twice in different rooms → state machine resets cleanly between | First room's gestalt interrupted by mode-change → second room starts fresh | — |

### Critical Paths

- 1st press → speak ≤2 s p95 (Gemma summarize budget is 1.5 s + ~500 ms framing)
- 2nd press → detail speech within 800 ms after completion of first
- Mode-change abort cuts all three streams (timer, Gemma, speech) atomically

### Observability

- **Log category:** `echosight.recall`
- **Key events:**
  - `recall.fire.received`
  - `recall.state.transition(from, to)`
  - `recall.annotations.queried(count, durationMs)`
  - `recall.gemma.started` / `recall.gemma.completed(durationMs, outcome)`
  - `recall.fallback.template.used`
  - `recall.window.expired`
  - `recall.abort(reason)`
  - `recall.pipeline.total(path=gestalt|detail, durationMs)`

## TLA Verification

- **Date:** 2026-04-21
- **Tool:** TLC 2026.03.16.144735
- **Spec file:** `/tmp/echosight-tla/SpatialRecall.tla`
- **Result:** PASS
- **State space:** 171 states generated, 58 distinct, depth 8

### Model

State variables:
- `state`: `"idle" | "awaiting" | "speakingDetail"`
- `gemmaInFlight`: BOOLEAN (Gemma.summarize call outstanding)
- `speechSlot`: `"none" | "gestalt" | "detail"` (models SpeechOut slot from recall's perspective)
- `windowActive`: BOOLEAN (5-s window task live)

Actions modeled:
- `FirstPressNonEmpty` / `FirstPressEmpty`
- `GemmaCompletes` / `GemmaTimeout`
- `GestaltSpeechFinishes`
- `SecondPressDuringGemma` / `SecondPressAfterGemma` (race fix: 2nd press mid-Gemma)
- `DetailSpeechStarts` / `DetailSpeechFinishes`
- `WindowExpires`
- `ModeChangeAbort` / `ModeChangeFromIdle`

### Invariants Verified

| Invariant | Status |
|-----------|--------|
| `TypeInvariant` — state variables within domain | PASS |
| `WindowOnlyInAwaiting` — windowActive => state = "awaiting" | PASS |
| `GemmaOnlyInAwaiting` — gemmaInFlight => state = "awaiting" | PASS |
| `DetailOnlyInSpeakingDetail` — speechSlot="detail" => state="speakingDetail" | PASS |
| `IdleIsClean` — state="idle" => (windowActive=FALSE AND gemmaInFlight=FALSE) | PASS |
| `EventuallyIdle` (liveness) — every non-idle state eventually returns to idle | PASS |

### Edge Cases Explored

- Second press arriving during Gemma mid-flight: detail transitions correctly; Gemma cancelled; window cancelled.
- Second press arriving after gestalt speech completed: detail queues cleanly.
- Mode-change from every reachable state: all three side-effect variables reset atomically.
- 5-s window expires while gestalt speech is live: state returns to idle, speech allowed to finish (this is intentional per spec test table; flagged via Gate 3 in TLA review).

### Open Items Surfaced by Verification

- **Gate 3 (window-expire during speech):** resolved (2026-04-21). Confirmed: let gestalt finish if window expires mid-speech. Added explicit Requirement and Acceptance Criterion lines to remove ambiguity. Window expiry is a timing-gate (does this count as 2nd press?) not a speech-lifecycle gate. Contrast with mode-change abort which DOES call `cancelAll()`.

### Notes

State space is small enough that exhaustive model checking is trivial. The model bounds `presses <= 4` and `windows <= 2` cover all novel reachable transitions; the state machine's behavior is deterministic in its response to input permutations beyond these bounds.
