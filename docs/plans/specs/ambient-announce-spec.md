---
name: ambient-announce
description: Passive room-entry announce — world-anchor novelty detection, spatial chime always, idle-gated speech on cold anchors
phase: 3
sprint: 2
parent: root-spec
depends_on: [root, spatial-core, annotation-store, gemma-enrichment, modal-input, speech-out, observability]
status: tla-verified
created: 2026-04-21
---

# Ambient Announce Spec

## Goal

Make cross-session spatial memory palpable without requiring a gesture. When the user enters a place (world-anchor novelty), play a soft spatial chime. If the place is cold (first visit or not-seen-in-30-min) AND the user is idle (hasn't triggered a mode in 5 min), speak a short "you're in [room], last here N minutes ago, M annotations remembered" summary. Otherwise stay silent — chime only.

## Requirements

- Subscribe to world-anchor-change events from `spatial-core`
- Novelty rule: anchor is "cold" if not encountered in last 30 min (wall-clock) OR never before
- **Idle rule (Gate 4, compound):** user has published no `ModeFiredEvent` in last 5 min AND head-pose angular variance over last 30 s exceeds threshold (default: 5° cumulative rotation). The variance check uses `spatial-core`'s `headPoseVariance(window:)` helper. If device is stationary (variance below threshold), user is considered "device-put-down" and speech is suppressed regardless of gesture idleness. Chime always plays.
- On any novelty signal: play spatial chime via `SpatialAudioComponent` (non-speech, low cost, 300-500 ms)
- On cold + idle + head-motion: also speak "You're in [room label]. Last here N minutes ago. M annotations remembered." (or on first-ever: "This looks like a [room label]. I'll remember this place.")
- Room label inference: query `GemmaRunner.summarize` with annotation-store context + mesh classification distribution. Hedge language on first visit ("this looks like a kitchen"); confident on return visits if label persisted
- Persist user-confirmed room labels via `AnnotationStore` metadata keyed by anchor UUID
- Speak via `SpeechOut.speak(priority: .high)` — cold-anchor welcome-back preempts any in-flight `.normal` speech (scene/ocr). It does not preempt other `.high` (none defined today; recall's gestalt is the only other `.high`).
- Respect silent mode: chime plays, speech suppressed regardless of other gates. Silent-mode gating lives in this spec's coordinator, NOT inside `SpeechOut`, because `.high` bypasses `SpeechOut`'s silent-mode gate by design.
- **Silent-mid-flight cancellation (post-TLA, 2026-04-21):** `AmbientAnnounceCoordinator` subscribes to `ModeChangeEvent` (already subscribed for `IdleTracker`). When the new mode is `.silent` AND there is an in-flight ambient-initiated `.high` utterance, the coordinator calls `SpeechOut.cancel(speechToken)` on its own token. Rationale: ambient speech is **app-initiated** (unsolicited push). A silent toggle is an explicit "stop pushing things at me" signal — kill mid-utterance. Asymmetric with `.normal` speech by design: `.normal` is user-initiated and completes naturally; `.high` is app-initiated and is cancellable by silent toggle.
- Maximum speech rate: 1 full speech per 60 s wall-clock (spam guard)
- **Chime rate limit:** minimum 2 s between chimes, even across multiple anchor events. Prevents chime storm during ARKit session recovery when multiple anchors re-emit rapidly.
- **Session-resume chime suppression (post-TLA, 2026-04-21):** on receipt of `AnchorChangeEvent` with `kind = .sessionResumeRerecognized` from `spatial-core`, set `sessionResumeDampenUntil = now + 3s`. While the current timestamp is before `sessionResumeDampenUntil`, suppress **all** chimes (no rate-limit counter bump, no emitted chime). After expiry, resume normal 2-s rate-limited chime. The feature eliminates the single spurious chime that the 2-s rate limit alone would coalesce the session-resume anchor burst to.

## Acceptance Criteria

- [ ] Walking into a new world anchor triggers spatial chime within 200 ms
- [ ] Cold anchor + idle user → full speech with room label + annotation count + last-seen delta
- [ ] Hot anchor (re-entered within 30 min) → chime only, no speech
- [ ] Cold anchor + active user (pressed any button in last 5 min) → chime only, no speech
- [ ] Gemma room-label inference completes in ≤1.5 s p95 or falls back to mesh-classification-derived label ("large open space", "small enclosed area")
- [ ] Silent mode suppresses all speech, chime still audible
- [ ] Silent-mid-flight: in-flight ambient `.high` speech is cancelled within 100 ms of `ModeChangeEvent(to: .silent)` arrival (post-TLA 2026-04-21)
- [ ] Session-resume: `.sessionResumeRerecognized` anchor events suppress chimes entirely for 3 s; after 3 s, normal chime path resumes
- [ ] Integration test: synthetic anchor-change event stream validates all gate combinations including silent-mid-flight and session-resume dampening
- [ ] Unit tests for novelty rule, idle rule, rate limiter, silent-mid-flight cancel, session-resume dampen window

## Technical Approach

`AmbientAnnounceCoordinator` actor consumes three streams: anchor-change (from spatial-core), mode-fired (from modal-input, for idle tracking), and speech-state (from SpeechOut). Publishes announce decisions through a small state machine: receive anchor change → check novelty → emit chime → check idle + mode + rate → optionally emit speech.

Room label inference is a separate Gemma read path (like `spatial-recall`'s gestalt call): synchronous-for-user-wait, bounded ~30 tokens, 1.5 s timeout. Distinct from async annotation enrichment queue.

Chime synthesis: simple `AVAudioEngine` + `SpatialAudioComponent` attached to an entity roughly in front of user at 1 m. Spatialized so user perceives direction into the room.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift` | Actor, streams, gate state machine |
| `Sources/EchoSightCore/Ambient/NoveltyDetector.swift` | 30-min sliding window over anchor encounters |
| `Sources/EchoSightCore/Ambient/IdleTracker.swift` | 5-min sliding window over mode events |
| `Sources/EchoSightCore/Ambient/AnnounceRateLimiter.swift` | 60-s min-gap between full speeches |
| `Sources/EchoSightCore/Ambient/RoomLabelInferrer.swift` | Gemma prompt + fallback mesh-class label |
| `Sources/EchoSightCore/Ambient/ChimeRenderer.swift` | Spatial chime audio |
| `Sources/EchoSightCore/Ambient/SessionResumeDampener.swift` | 3-s chime suppression window post `.sessionResumeRerecognized` (new, post-TLA) |
| `Tests/EchoSightCoreTests/NoveltyDetectorTests.swift` | 30-min rule |
| `Tests/EchoSightCoreTests/IdleTrackerTests.swift` | 5-min rule |
| `Tests/EchoSightCoreTests/AmbientAnnounceCoordinatorTests.swift` | Gate state machine |

## Tasks

1. Implement `NoveltyDetector` (30-min anchor window) + tests
2. Implement `IdleTracker` (5-min mode-event window) + tests
3. Implement `AnnounceRateLimiter` (60-s speech gap) + tests
4. Implement `ChimeRenderer` (spatial audio asset + playback)
5. Implement `RoomLabelInferrer` (Gemma synchronous read path + mesh fallback)
6. Persist user-confirmed labels via `AnnotationStore` metadata extension
7. Implement `SessionResumeDampener` (3-s chime suppression window after `.sessionResumeRerecognized`)
8. Implement silent-mid-flight cancel: coordinator watches `ModeChangeEvent`, cancels own `.high` token on `.silent` transition
9. Implement `AmbientAnnounceCoordinator` composing all of the above
10. Integration test with synthetic event streams covering all gate combinations including silent-mid-flight and session-resume dampening

## Dependencies

- **Needs from:** root, spatial-core (anchor-change stream, mesh-classification distribution), annotation-store (per-anchor annotation count + last-seen timestamps, label metadata), gemma-enrichment (room label inference read path), modal-input (mode-event stream for idle tracking + silent mode signal)
- **Provides to:** none (terminal passive-surface feature)

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** New spec. Original plan had no passive surface — product was gesture-only lookup. Under expansion, passive announce is the feature that turns the product from "lookup tool" into "spatial companion." Specifically designed to make cross-session memory (the stated moat) palpable on room entry without requiring any user action.
- **Premise validation:** Two-tier escalation (chime always, speech only on cold + idle) resolves the accessibility tension between "ambient product" and "non-annoying product." VoiceOver itself uses a similar escalation pattern (silent navigation, speech only on focus change). BLV users recognize this idiom.

### Dream State Delta
At 12-month ideal, the product continuously narrates *changes* in the world — a person walking in, an object moving, a door opening — not just room entries. v0.1's anchor-change trigger is the narrowest possible version of "something happened worth mentioning." Keep the coordinator's input abstracted as a generic `AmbientEvent` stream so later event sources (motion detection, face-present, sound-source) slot in without touching the gate state machine.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| Novelty detection | Anchor jitter (same physical place, new UUID) | Duplicate cold-entry speech | Partially — acceptance criterion needs anchor-UUID-stability note | No |
| Room label | Gemma mislabels "office" as "bedroom" | User corrects mentally; repeated on re-entry | Hedged-language mitigation | No |
| Chime timing | Chime plays while user is in Feature 1 capture | Audio collision | Suppression rule via `AVSpeechSynthesizer.isSpeaking` | Yes |
| Rate limiter | User moves between rooms rapidly | Announces every 60 s feels robotic | Consider 120-s limit after alpha feedback | Yes |
| Idle tracker | User in silent mode but still active via passive listening | Incorrectly speaks | Silent-mode-suppresses-speech rule wins | Yes |

### Deferred Work
- [ ] User-editable room labels (spoken rename gesture) — v1.0 when voice lands
- [ ] Time-of-day-aware announces ("morning — you're in the kitchen") — v1.0 polish
- [ ] Ambient motion detection (person enters scene) — v1.0+, continuous perception
- [ ] Configurable novelty window (30-min default) — v1.0 settings UI
- [ ] On-head sensor / device-worn state signal as additional idle check (Gate 4 Option 3, deferred because API availability on visionOS 2 unconfirmed)

## Eng Review

- **Depth:** BIG
- **Scope changes:**
  - **Gate 4 idle rule:** compound. Speech fires only when (gesture-idle ≥5 min) AND (headPoseVariance(30s) > threshold). Chime always plays. Threshold: 5° cumulative rotation, tunable constant.
  - **Gate 2 speech routing:** `SpeechOut.speak(priority: .high)`. `.high` bypasses `SpeechOut`'s silent-mode gate, so this spec's `AmbientAnnounceCoordinator` owns the silent-mode check explicitly.
  - **Chime rate limit (new):** 2 s minimum between chimes. Protects against anchor-storm during ARKit session recovery.
  - **Anchor rehydration timing coordination:** ambient reads `annotationCount(anchorId:)` from annotation-store. `AnchorRehydrator` (annotation-store spec, Gate 5) populates the cache on `.rerecognized` before ambient's coordinator consumes the same event. Spec contract: ambient must tolerate reading `annotationCount == 0` if rehydration hasn't completed; rehydration typically finishes <200 ms, ambient's Gemma room-label call is ~1.5 s — so rehydration nearly always wins the race. If it loses, speech still fires with low count; acceptable for v0.1.

### State Diagram (announce gate)

```
  AnchorChangeEvent arrives
  │
  ▼
  chime rate-limit check (2 s since last chime?)
  │ yes, fire chime
  ▼
  is anchor cold? (not encountered in 30 min)
  │ no → stop (chime only)
  │ yes
  ▼
  is silent mode on?
  │ yes → stop (chime only, speech suppressed)
  │ no
  ▼
  is user gesture-idle ≥5 min?
  │ no → stop
  │ yes
  ▼
  is head-motion-active? (variance > threshold)
  │ no → stop (device-put-down case)
  │ yes
  ▼
  is speech rate-limit OK? (60 s since last speech)
  │ no → stop
  │ yes
  ▼
  Gemma inferRoomLabel (.high, 1.5 s budget)
  │ on timeout → mesh-classification fallback
  ▼
  SpeechOut.speak(welcome-back text, .high)
  │
  ▼
  record last-speech timestamp + anchor encounter
```

### Data Flow

```
spatial-core                 AmbientAnnounceCoordinator      annotation-store
 │                            (actor)                         │
 │ AnchorChangeEvent ────────→│                               │
 │                            │ chime.fire (rate-limited) ───→ │ (spatial audio)
 │                            │                               │
 │                            │ if .new / .rerecognized:      │
 │                            │   annotation-store.           │
 │                            │     lastSeenAnchorAt(id) ────→│
 │                            │   NoveltyDetector.isCold(...)  │
 │                            │                               │
modal-input                    │                               │
 │ ModeChangeEvent ──────────→│ IdleTracker update            │
 │ ModeFiredEvent ───────────→│ IdleTracker reset             │
 │                            │                               │
spatial-core                   │                               │
 │                            │ headPoseVariance(30 s) ─────→│ (spatial-core)
 │                            │                               │
 │                            │ all gates pass:                │
 │                            │   Gemma.inferRoomLabel ──────→│ gemma-enrichment
 │                            │   SpeechOut.speak(.high) ────→│ speech-out
 │                            │   annotation-store.           │
 │                            │     recordAnchorEncounter ───→│
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Chime on novelty | Integration | Chime within 200 ms of .new or .rerecognized event | Chime rate limit (within 2 s) → suppressed | Two anchors in burst → single chime |
| Cold + idle + head-motion | Integration | Full speech fires | Device stationary (variance below threshold) → speech suppressed | Threshold boundary → deterministic |
| Hot anchor | Integration | <30 min since last encounter → chime only | — | Exactly 30 min → cold |
| Gesture-active | Integration | Any ModeFiredEvent in last 5 min → speech suppressed | Mode fire at 4:59 → still active | Mode fire at 5:01 → idle |
| Silent mode | Integration | Speech suppressed, chime plays | Silent toggled mid-evaluation → use latest value at decision point | Silent → Recall → Silent fast cycling |
| Gemma timeout | Integration | .high call timeout → mesh-classification fallback speech | All gates pass but Gemma fails completely → mesh-class label speech | — |
| Chime rate limit | Unit | 2 s min between chimes | 5 anchor events in 1 s → only 1 chime | Session recovery storm → single chime, not 20 |
| Speech rate limit | Unit | 60 s min between speeches | User walks between rooms every 30 s → only every other gets speech | Edge: exactly 60 s → deterministic |
| Rehydration race | Integration | `.rerecognized` → rehydrate (200 ms) → ambient reads annotationCount correctly by time Gemma returns (1.5 s) | Rehydration slow → ambient may speak with count=0 (acceptable, logged) | — |
| Gate ordering | Unit | All gates evaluated in order; early exit on first fail | Deterministic | — |

### Critical Paths

- Chime ≤200 ms on anchor novelty — companion-feel requirement
- Full gate evaluation + Gemma + speech ≤2 s wall for typical cold anchor
- Silent-mode suppression: absolute guarantee that speech never fires in silent mode (this spec owns the check for `.high` path)
- Chime rate limit prevents session-recovery audio storm

### Observability

- **Log category:** `echosight.ambient`
- **Key events:**
  - `ambient.anchor.received(hashedId, kind)`
  - `ambient.chime.fired` / `ambient.chime.suppressed(reason=rateLimit)`
  - `ambient.novelty.evaluated(cold, lastSeenDelta)`
  - `ambient.idle.evaluated(gestureIdle, headMotion, variance)`
  - `ambient.silent.suppressed`
  - `ambient.speech.gated(passed, failedGate)`
  - `ambient.gemma.inferRoomLabel(outcome, durationMs)`
  - `ambient.speech.fired(roomLabel, wasPreempting)`
  - `ambient.rateLimiter.speech.suppressed(msSinceLast)`

## TLA Verification

- **Date:** 2026-04-21 (re-verified after gate decisions)
- **Tool:** TLC 2026.03.16.144735
- **Spec file:** `/tmp/echosight-tla/AmbientAnnounce.tla`
- **Result:** PASS (Gates 2 + 4 resolved: cancel-own-high on silent; 3-s session-resume chime dampening)
- **State space:** 14,817 states generated, 2,448 distinct, depth 18 (post-gate model — 19 actions, 11 state variables)

### Model

State variables:
- `chimeCooldown` / `speechCooldown`: 2-s and 60-s rate-limit flags
- `silentMode`, `gestureIdle`, `headMotionActive`: gate inputs
- `speechInFlight`, `gemmaInFlight`: output path liveness
- Counters: `anchorsSeen`, `chimes`, `speeches`

Gate evaluation ordering (structural):
1. Chime rate-limit
2. Novelty (cold vs hot)
3. Silent mode
4. Gesture-idle
5. Head-motion
6. Speech rate-limit
7. Gemma inferRoomLabel
8. SpeechOut.speak(.high)

### Invariants Verified

| Invariant | Status |
|-----------|--------|
| `TypeInvariant` — state variables within domain | PASS |
| `NeverSpeakInSilentMode` (state-level after Gate 2) — `~(speechInFlight /\ silentMode)` | PASS |
| `ChimePrecedesOrAccompaniesSpeech` — `speeches <= chimes` always | PASS |
| `NoGemmaAndSpeechTogether` — mutual exclusion on ambient's output path | PASS |
| `SpeechCooldownRespected` — structural guard on `GemmaCompletesAndSpeak` | PASS |

### Edge Cases Explored

- Anchor storm (5+ events in rate-limit window): only 1 chime fires. Confirmed.
- Cold anchor + silent mode: routes to chime-only path. Confirmed.
- Cold anchor + gesture-active: chime-only. Confirmed.
- Cold anchor + device-put-down (headMotionActive = FALSE): chime-only. Confirmed.
- Gemma timeout during silent-mode toggle mid-flight: ambient speech never starts.

### Gate Resolutions (2026-04-21)

- **Gate 2 — silent-mid-flight `.high` cancel:** adopted. Added `SilentTogglePreemptsHigh` action to model the coordinator's own-token cancel path. The in-flight speech transitions directly to `speechInFlight = FALSE` when `silentMode` toggles TRUE.
- **Gate 4 — session-resume chime dampening:** adopted. Added `sessionResumeDampen: BOOLEAN` variable and `SessionResumeTriggered` / `SessionResumeDampenExpires` actions. While `sessionResumeDampen = TRUE`, every anchor event (regardless of kind or rate-limit state) is routed to a no-op path; no chime fires.

### Invariants (Post-Gate)

| Invariant | Status |
|-----------|--------|
| `TypeInvariant` | PASS |
| `NeverSpeakInSilentMode` — now state-level: `~(speechInFlight /\ silentMode)` | PASS (enforced by `SilentTogglePreemptsHigh`) |
| `ChimePrecedesOrAccompaniesSpeech` — `speeches <= chimes` | PASS |
| `NoGemmaAndSpeechTogether` | PASS |
| `NoChimeDuringSessionResumeDampen` — `(chime fires) => ~sessionResumeDampen` (structural) | PASS |

### Counterexamples (resolved)

1. Initial: ambient `.high` continued past silent=ON toggle. Resolved by `SilentTogglePreemptsHigh` action. State-level `NeverSpeakInSilentMode` now holds.
2. Initial: single chime fired on session-resume burst (2-s rate limit coalesced but did not eliminate). Resolved by 3-s dampen window; every anchor event during the window routes to no-op.

### Open Items

- None. Gates 2 and 4 resolved.

### Notes

Bounded model-checked with `MaxEvents=4, MaxChimes=4, MaxSpeeches=2`. State space grew quickly (1,448 distinct states) because the six independent gate flags + two counters compose combinatorially. Increasing bounds to 6/6/3 was tried during iteration; no new reachable invariant violations. Current bounds cover all transition classes.
