# Findings & Decisions

## Goal
Ship EchoSight v0.1 on Apple Vision Pro: always-on Layer 1 spatial awareness + gesture-triggered scene description with persistent spatial memory, fully on-device.

## Priority
Quality — accessibility app; half-working features are dangerous.

## Mode
spec-driven

## Project Type
Greenfield (visionOS SwiftUI app, fresh codebase; 2024 Flutter EchoSight is separate).

## Approach

Composition of six engine primitives assembled by thin feature pipelines:

1. **PassthroughCaptureSource** (protocol) — PhotosLibraryCaptureSource (PeekABoo removed in Sprint 4.5) today, `CameraFrameProvider` tomorrow.
2. **Detector** (protocol) — Vision/YOLO v0.1; Falcon-Perception mlx-swift drop-in later.
3. **Geometric fusion** — pixelToRay + PHAsset time-sync + `Scene.raycast` + mesh classification reconciliation.
4. **Annotation store** — `WorldAnnotation` + spatial hash + SQLite keyed by persistent world anchor.
5. **Async reasoner** — Gemma 4 E2B (mlx-swift), off the critical path.
6. **Speech out** — `AVSpeechSynthesizer` template speech (fast) + Gemma-enriched speech (slow).

v0.1 delivers Feature 1 (scene description) + Layer 1 ambient awareness. Voice router and OCR move to v1.0.

## Requirements (Validated)

- Layer 1 always-on spatial awareness (mesh + head pose + spatial audio cues)
- PhotosLibraryCaptureSource (PeekABoo removed in Sprint 4.5) capture + EchoSight dedicated album + clear-captures UX
- Vision detector placeholder behind `Detector` protocol
- Fusion pipeline (2D → 3D) with dev-only FOV calibration
- Feature 1: scene description (fast template + async Gemma)
- Persistent annotation set across sessions
- 2.6 GB first-launch model download with VoiceOver progress

## Spec Map
- Manifest: `docs/plans/manifest.md`
- Specs directory: `docs/plans/specs/`

### Dependency DAG
See manifest.md Mermaid graph. Summary: `root → {skeleton, spatial-core} → capture → {detector, fusion} → scene-description`; `fusion → annotation-store → gemma-enrichment`; `{detector, gemma} → onboarding-download`.

### Per-Spec Decisions

| Spec | Key Decision | Rationale | Affects |
|------|-------------|-----------|---------|
| capture | PhotosLibraryCaptureSource (PeekABoo removed in Sprint 4.5) behind `PassthroughCaptureSource` protocol | Lets us swap to `CameraFrameProvider` if Enterprise entitlement granted | detector, fusion |
| capture | Single capture gesture (no mode disambiguation) | Voice deferred; v0.1 is single-feature (Feature 1 only) | scene-description |
| detector | Vision placeholder first; Falcon port post-v0.1 | De-risk geometry/UX before 1-week Swift port | scene-description |
| fusion | Assume pinhole ~100° hFOV; empirical calibration in debug scene | Apple doesn't publish passthrough camera model | scene-description |
| annotation-store | SQLite keyed by visionOS world anchor UUID | Cross-session persistence is the moat feature | gemma-enrichment |
| gemma | E2B Q4 (not E4B) | Fits 6-9 GB foreground budget with margin | onboarding-download |
| onboarding | All models at first launch (not progressive) | Simpler code; one rough first-launch accepted | — |

## Sprint Grouping

| Sprint | Specs | Parallelize |
|--------|-------|-------------|
| 1-1 | root, project-skeleton, spatial-core | yes |
| 1-2 | capture | no |
| 2-1 | detector, fusion | yes |
| 2-2 | scene-description | no |
| 3-1 | annotation-store, gemma-enrichment | partial |
| 3-2 | onboarding-download | no |

## Research Context

| Topic | Expertise | Knowledge Store |
|-------|-----------|-----------------|
| visionos-development | ~/.claude/research/visionos-development/expertise.md | ~/.neo-research/knowledge/visionos-development.mv2 |
| ios-development | ~/.claude/research/ios-development/expertise.md | ~/.neo-research/knowledge/ios-development.mv2 |
| visionos-debugging | ~/.claude/research/visionos-debugging/ | — |
| liquid-glass-visionos | ~/.claude/research/liquid-glass-visionos/ | — |

Deep-dive queries:
- `rlm_search(query="SceneReconstructionProvider classification", project="visionos-development")`
- `rlm_search(query="persistent world anchor visionOS", project="visionos-development")`

## Available Skills (from Swift Skill Graph)

- `visionos-specialist` (agent) — deep visionOS implementation
- `visionos-development`, `visionos-spatial`, `realitykit-ecs` (skills) — RealityKit ECS, ImmersiveSpace, RealityView
- `on-device-ai` (skill) — Foundation Models / on-device ML; informs detector + gemma specs
- `swift-logging`, `ios26-swiftui` — cross-cutting
- `hig-audit`, `app-store-submit` — late-stage gates

## Research Findings
- ARKit `SceneReconstructionProvider` gives 8-class mesh classification (wall/floor/ceiling/table/seat/window/door/none) at ~3-8 cm edge length indoors with ~85-90% planar accuracy.
- `WorldTrackingProvider` head pose drift <1 cm over 10 min indoors.
- Passthrough screenshot via `PHPhotoLibraryChangeObserver` arrives 200-600 ms after shutter — must time-sync head pose via `PHAsset.creationDate`.
- visionOS 2+ supports persistent world anchors — the backbone of cross-session annotation recall.

## Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Gesture-only v0.1 | Voice router (WhisperKit + keyword match) deferred to v1.0; reduces ML surface and onboarding friction for alpha |
| Feature 1 only | Quality priority over breadth; OCR joins v1.0 alongside voice |
| `Detector` protocol + Vision impl | Validate geometry + ray-cast + TTS pipeline end-to-end before Falcon port |
| Async Gemma reasoning | Never on critical path; enriches annotations in background |
| SQLite over JSON | Spatial queries + merge operations benefit from indexed storage |

## Visual/Browser Findings
<!-- Update after every 2 view/browser operations -->
-

## CEO Review (2026-04-21)

**Lens:** Scope Expansion
**Outcome:** 10 -> 14 specs. v0.1 surface set expanded from "Feature 1 only, gesture-triggered" to four user surfaces + one passive surface + standalone Layer 1. Gates run interactively with per-gate user decisions.

### Gates Run

**Gate 1 — What is v0.1, really?**
Decision: ALL FOUR options accepted (Options 1+2+3+4 merged).
- Feature 1 scene description on primary gesture (held)
- Layer 1 shippable standalone as v0.0.1 alpha beat
- Spatial recall as a secondary surface (reads annotation store)
- Passive "what's new?" auto-announce on room-change
Rationale: The annotation store was write-only in the original plan despite being named as the product's moat. Exercising it via user-facing recall + passive room-entry made cross-session memory tangible.

**Gate 2 — How do users trigger three actions without voice?**
Decision: Option 4 — Crown-as-mode + Button-as-action.
Four modes: scene / recall / read / silent. Mode change speaks a short VoiceOver-style confirmation. Zero voice input in v0.1 (locked).
Implication accepted: open-vocab recall ("where is X") is impossible without voice; recall mode becomes structural-over-the-set instead of targeted-query.

**Gate 3 — What does recall mode do without a target noun?**
Decision: Options 1+2 composed into a two-press state machine.
- 1st press -> Gemma one-sentence room gestalt
- 2nd press within 5 s -> top-N nearest annotations with distance + direction
- 5 s timeout -> back to idle
Solves Tension 3 (two-voice): Gemma speaks only in recall; template speaks only in scene; they never collide.

**Gate 4 — How does passive announce stay invited?**
Decision: Options 1+3 composed into two-tier escalation.
- World-anchor novelty check on every new anchor
- Spatial chime always plays (low interruption cost)
- Full speech only on cold anchor (unseen >30 min) AND idle user (no gesture in last 5 min)
- 60-s rate limit between full speeches
- Silent mode suppresses speech; chime always plays

**Gate 5 — Does OCR belong back in v0.1?**
Decision: Option 2 — OCR as 4th Crown-cycle mode.
VNRecognizeTextRequest is OS-provided, zero model-download cost. Reading is the #1 unmet BLV need. Flutter predecessor shipped with text reading; omission would be regression. ~2-3 days of work for a table-stakes feature.

### Tensions

**Tension 1 — "Feature 1 only" vs. 12-month companion ideal.**
Resolved by Gate 1 + Gate 2 + Gate 5. v0.1 is now a four-surface product plus passive ambient. ~35% of 12-month ideal, up from ~15%.

**Tension 2 — Gesture-only lookup vs. ambient companion.**
70% resolved by passive ambient announce on room entry. Remaining 30% (continuous narration of world changes — person enters, object moves, door opens) is v1.0+ territory. Documented in root-spec's Dream State Delta.

**Tension 3 — Fast template + slow Gemma speaking contradicting versions.**
Fully resolved by Gate 3. Gemma owns the voice in recall + ambient modes; template owns the voice in scene mode. Modes never collide.

### New Specs Created

| Spec | Role | Depends On |
|------|------|-----------|
| modal-input | Crown-cycles-modes + Button-fire event bus | root, project-skeleton |
| spatial-recall | Recall mode state machine + Gemma gestalt + top-N | root, modal-input, annotation-store, gemma-enrichment |
| ocr | Read mode via VNRecognizeTextRequest | root, modal-input, capture |
| ambient-announce | Passive novelty announce (chime + speech) | root, spatial-core, annotation-store, gemma-enrichment, modal-input |

### Existing Specs Modified

| Spec | Change |
|------|--------|
| root-spec | Added surface map, dream-state delta, project-wide failure modes, deferred work |
| spatial-core | Added `AnchorChangeEvent` stream + `MeshClassificationSummary` snapshot for ambient-announce |
| scene-description | Removed gesture wiring (moved to modal-input); added subscription to `ModeFiredEvent(.scene)`; kept template-only voice |
| annotation-store | Added `AnchorMetadata` table (last-seen, visit count, labels) + 3 new queries for ambient + recall |
| gemma-enrichment | Added two synchronous read paths (`summarize`, `inferRoomLabel`) + priority queue with preemption |
| onboarding-download | Added mode tutorial screen (exercises real modal-input events before app entry) |

### Deferred Work (carried into v1.0)

- Voice router (WhisperKit + keyword spotter + target-noun extraction)
- Continuous text reading (passive OCR when text enters FOV)
- Motion-delta perception (something moved in the scene)
- Face recognition with BLV consent
- Translate (OCR -> target language)
- Predictive mode switching (no manual Crown cycle)
- Falcon-Perception mlx-swift port (replaces Vision detector) — post-v0.1, pre-v1.0

### Review Pipeline Status

- CEO Review: **complete** (2026-04-21, Scope Expansion)
- Eng Manager Review: **complete** (2026-04-21, BIG depth — see `## Eng Review (2026-04-21)` below)
- TLA Verification: **skipped per invocation flags**
- Orchestrate readiness: **CEO + Eng complete**; TLA still required before orchestrate

## Eng Review (2026-04-21)

**Depth:** BIG (interactive walkthrough)
**Outcome:** 14 → 16 specs. Two new infra specs carved out: `speech-out` and `observability`. Every spec touched received a `## Eng Review` block with test plan, data-flow diagram, observability subsection, and concrete failure-mode additions.

### Gates Run (7)

**Gate 1 — Review depth.** BIG (interactive, per-spec walk-through).

**Gate 2 — `SpeechOut` ownership.** OPTION 1: new `speech-out` spec as Phase 1 sibling. Rationale: four feature specs plus `modal-input` reference a shared `SpeechOut` wrapper; none pinned concurrency / priority / ducking contract. Contract: single `AVSpeechSynthesizer` owned by a `SpeechOut` actor. Two priority slots (`.high` for user-waiting recall + ambient cold-anchor; `.normal` for scene + OCR + mode-confirmation). `.high` preempts `.normal`; `.normal` drops if `.high` live. VoiceOver ducking via `.duckOthers`. Silent-mode gate inside `SpeechOut` for `.normal`; `.high` bypasses so ambient-announce owns its richer silent-mode policy. Every voice-producing spec's `depends_on` now includes `speech-out`.

**Gate 3 — Recall 2-press state home.** OPTION 1: `spatial-recall` owns the state machine. `modal-input` is a pure stateless event publisher. Removed the "5-second press-window state for Recall mode" line from `modal-input` Requirements. Added a second `ModeChangeEvent` stream on `modal-input` so recall, scene, ocr, and ambient can subscribe for mid-operation aborts. Recall's state enum: `.idle` | `.awaitingSecondPress(firstPressAt, windowTask)` | `.speakingDetail`. Race fix: second press arriving mid-Gemma queues detail speech behind gestalt via `SpeechOut` completion future. Stream buffering policy pinned at `.bufferingNewest(1)` to prevent backpressure queueing of stale events.

**Gate 4 — Ambient idle definition.** OPTION 2: compound idle = gesture-idle AND head-motion-active. Added `headPoseVariance(window:)` helper to `spatial-core`. Default threshold: 5° cumulative rotation over 30 s. Kills the worst failure mode (device on counter, speech into empty room) without depending on unconfirmed on-head sensor API.

**Gate 5 — World-anchor rehydration contract.** OPTION 1: Eager silent. `AnchorRehydrator` in `annotation-store` subscribes to `AnchorChangeEvent(.rerecognized)` from `spatial-core`, loads annotations into the in-memory spatial hash, emits no user-facing signal. User-facing "welcome back" is ambient-announce's existing cold-anchor path. `AnchorChangeEvent.kind` discrimination (`.new` vs `.rerecognized`) pinned: `spatial-core` queries `annotation-store.anchorMetadata(anchorId:)` before emitting. Snapshot pinning added to Gemma read paths: `summarize` and `inferRoomLabel` copy their inputs to immutable values at call entry, so concurrent rehydration doesn't mutate in-flight calls.

**Gate 6 — Observability.** OPTION 1: new `observability` spec as cross-cutting Phase 1 sibling. 15 log categories (one per functional area). `PipelineMetricsBuffer` actor (ring buffer, N=32 per category). `DebugConsoleView` SwiftUI (fully VoiceOver navigable, 5-tap-logo gesture to reveal in Release). `logExport()` writes sanitized 15-min log + metrics to a shareable file with hashed anchor UUIDs. `PrivacyFilter` strips content/text/frame/prompt keys from exported metadata. Every feature spec now has a `## Observability` subsection naming category + 3-5 key events.

**Gate 7 — Onboarding tutorial escape.** OPTION 2: tutorial non-gating. Hard gates: download + privacy disclosure + SHA verify only. "Skip tutorial and enter app" button is first VoiceOver focus target on tutorial entry. Hardware validation moved to Settings > Hardware Diagnostic view — live Crown + Button feedback, always reachable. Removed "must complete mode-switch cycle" acceptance criterion and the "tutorial stuck / locked out" failure mode.

### Direct-Fill Additions (no gate, spec-level clarifications)

- **Capture timestamp contract:** `CapturedFrame` carries both `shutterTimestamp` (from `PHAsset.creationDate`) and `deliveryTimestamp` (from delegate callback). Fusion uses shutter; both exposed so observability can measure PhotoKit delivery lag. Lag >3 s flags capture as `outcome=.degraded(.latePhotoKitDelivery)`.
- **Fusion thread-safety:** `FusionEngine` split into pure tier (background, any queue) and RealityKit tier (main actor for `Scene.raycast`). Contract: `fuse()` is async and internally awaits the main-actor hop for raycast; callers run on background Task.
- **Pose ring underflow:** if capture shutter timestamp is older than the 5-s ring's oldest entry, use oldest + mark candidate `outcome=.degraded(.poseExtrapolated)`. Annotation-store may choose to skip persistence.
- **Gemma preemption cadence:** `Task.isCancelled` check between each generated token. At ~20 ms/token on M2-class Neural Engine, worst-case preemption latency is ~20 ms — comfortably inside the 100 ms acceptance criterion.
- **Gemma re-enqueue position:** preempted enrichment re-enters queue at the **head**, not the tail. Prevents double-penalizing interrupted work and avoids enrichment starvation under recall-heavy usage.
- **Gemma token budgets:** enforced as hard limits (`enrich ≤40`, `summarize ≤30`, `inferRoomLabel ≤20`) via mlx-swift's `maxTokens` per call.
- **Ambient chime rate limit:** 2 s minimum between chimes. Protects against anchor-storm during ARKit session recovery.
- **Spatial-core session resume:** on ARKit interruption + resume, flush seen-this-session set and re-emit re-recognized anchors as `.rerecognized` (not `.new`). Prevents false novelty cascade.

### Specs Created

| Spec | Role | Depends On |
|------|------|-----------|
| speech-out | Single `AVSpeechSynthesizer` owner + priority slots + ducking + silent-mode gate | root |
| observability | swift-log taxonomy + metrics ring + `DebugConsoleView` + log export | root |

### Specs Touched (all 14 prior specs)

Every one of the 14 pre-existing specs received:
- Frontmatter `status: eng-reviewed`
- Updated `depends_on` where affected
- `## Eng Review` block with gate references, data-flow diagram, test plan table, critical paths, observability subsection
- Failure mode additions where specific to the gate decisions

Files table additions, new Requirements lines, and line deletions as driven by gates. No spec had its core scope changed beyond what the gates explicitly decided.

### Tensions Status

- **Tension 1** (v0.1 scope breadth): Already 70% resolved by CEO review. Eng review did not re-argue scope; it made the existing 14-spec scope buildable.
- **Tension 2** (ambient-companion vs lookup-tool): Unchanged. Eng review sharpened ambient's idle gate (Gate 4) to keep it invited rather than annoying.
- **Tension 3** (fast template vs slow Gemma two-voice): Already resolved at CEO review. Eng review formalized the resolution via `SpeechOut` priority slots — template is `.normal`, Gemma-backed gestalt / cold-anchor is `.high`, collision semantics explicit.

### Risks Remaining Heading Into Orchestrate

- **FOV calibration empirical:** `kAssumedHorizontalFov = 100` is a guess. The debug calibration scene (fusion spec) must be run on physical hardware before beta. If the true FOV is far from 100°, distances will be systematically off. Budget: 2 hours on-device.
- **Gemma timing on real device:** all latency budgets (enrichment <2 s, summarize <1.5 s, inferRoomLabel <1.5 s) are estimates from published mlx benchmarks. First real-device measurement could invalidate the recall / ambient latency budgets. Mitigation: template fallbacks already spec'd in both callers.
- **Anchor UUID stability:** ARKit anchor coalescing is unknown without on-device testing. Spec already flags this as a known issue in spatial-core's Failure Modes. If anchor jitter is severe, ambient's novelty detection will misfire; `.rerecognized` dedup helps but doesn't fully solve.
- **mlx-swift version lock:** Gemma 4 E2B Q4 on mlx-swift as of 2026-04 is assumed available. SPM dep declaration pinned to whatever version works for gemma-enrichment's acceptance tests on day of integration.
- **TLA verification pending:** the two specs with non-trivial state machines (`spatial-recall` 2-press state, `ambient-announce` gate state machine) are diagrammed but not formally verified. `/tla-spec` can extract these if desired; eng review deliberately stopped short of TLA work.

### Review Pipeline Status

- CEO Review: **complete** (2026-04-21, Scope Expansion)
- Eng Manager Review: **complete** (2026-04-21, BIG depth, 7 gates, 16 specs all eng-reviewed)
- TLA Verification: **complete** (2026-04-21) — see `## TLA Verification (2026-04-21)` below
- Orchestrate readiness: **ready for `/orchestrate`** — all 4 gates resolved 2026-04-21; all 4 stateful specs re-verified PASS under post-gate semantics

## TLA Verification (2026-04-21)

**Tool:** TLC 2026.03.16.144735 (tla2tools.jar)
**Scope:** 4 stateful specs — `spatial-recall`, `ambient-announce`, `modal-input`, `speech-out`
**Result:** all four PASS under post-gate semantics. Four product questions surfaced as gates; all resolved the same day.

### Gate Decisions (2026-04-21)

| # | Spec | Question | Decision | Architectural home |
|---|------|----------|----------|--------------------|
| 1 | speech-out | `.normal` mid-flight silent toggle | **Let finish** | `SpeechOut` silent gate is new-request-only; does not watch `ModeChangeEvent`. |
| 2 | ambient-announce | `.high` mid-flight silent toggle | **Cancel now** | `AmbientAnnounceCoordinator` subscribes to `ModeChangeEvent`; on `.silent` transition, calls `SpeechOut.cancel(ownToken)`. Cancellation logic lives at feature layer, not infra. |
| 3 | spatial-recall | gestalt speech on window expiry | **Let finish** | Window expiry is a timing-gate (does next press count as 2nd?), not a speech-lifecycle gate. Mode-change abort DOES call `cancelAll()`. |
| 4 | ambient-announce | ARKit session-resume chime storm | **3-s session-resume silence** | `spatial-core` emits new `.sessionResumeRerecognized` kind; `AmbientAnnounceCoordinator` sets `sessionResumeDampenUntil = now + 3s` and suppresses all chimes until expiry. |

**Design principle surfaced by the gate split:** "Finish what the user asked for; drop what the app was pushing." User-initiated `.normal` speech (scene / OCR / mode confirmation) completes naturally past silent toggle. App-initiated `.high` speech (ambient cold-anchor welcome-back) is cancelled by silent toggle because the toggle IS the user's "stop pushing" signal.

### State-Space Coverage (Final Run, Post-Gate)

| Spec | States Explored (distinct) | Depth | Result |
|------|----------------------------|-------|--------|
| spatial-recall | 58 | 8 | PASS |
| ambient-announce | 2,448 | 18 | PASS (state-level `NeverSpeakInSilentMode` now holds) |
| modal-input | 189 | 9 | PASS |
| speech-out | 70 | 10 | PASS |

### Invariants Held (Final)

- **SpatialRecall:** TypeInvariant, WindowOnlyInAwaiting, GemmaOnlyInAwaiting, DetailOnlyInSpeakingDetail, IdleIsClean + liveness `EventuallyIdle`.
- **AmbientAnnounce:** TypeInvariant, **`NeverSpeakInSilentMode` (state-level: `~(speechInFlight /\ silentMode)`)** — upgraded from action-structural after Gate 2. Plus `NoChimeDuringSessionResumeDampen`, `ChimePrecedesOrAccompaniesSpeech`, `NoGemmaAndSpeechTogether`.
- **ModalInput:** TypeInvariant, ModeIsValid, BufferingPolicy, SilentButtonIsNoOp + liveness `PendingFireEventuallyDrained` and `PendingChangeEventuallyDrained`.
- **SpeechOut:** TypeInvariant, AtMostOneSpeaking, RequestsAccounted, PriorityMonotonic (structural), `NoNewNormalStartedInSilent` (action-level structural — the "Let finish" semantics forbid a stronger state-level form, by design).

### Counterexamples Caught (All Resolved)

1. **SpeechOut mid-flight silent toggle** — `.normal` continues past silent=ON. Gate 1: resolved as "Let finish." Invariant reformulated to action-level `NoNewNormalStartedInSilent`. User-initiated utterance completes naturally.
2. **AmbientAnnounce mid-flight silent toggle (`.high`)** — cold-anchor speech continued past silent=ON. Gate 2: resolved as "Cancel now." Added `SilentTogglePreemptsHigh` action. State-level `NeverSpeakInSilentMode` now holds.
3. **AmbientAnnounce session-resume chime** — 2-s rate limit coalesced storm to 1 chime, but even 1 is spurious. Gate 4: resolved with 3-s dampen window. Added `sessionResumeDampen` variable + `SessionResumeTriggered` / `SessionResumeDampenExpires` actions.
4. **ModalInput apparent deadlock** — model-bound artifact; resolved by `Stutter` action. Not a spec bug.
5. **Invariant formulation errors** — `SpeechCooldownAfterSpeech` and initial `NeverSpeakInSilentMode` were over-strong; reformulated to match spec guard semantics.

### Architectural Consequences (from gate decisions)

Key architectural observation: the Gate-1/Gate-2 split is **not** an inconsistency — it's a deliberate distinction between user-initiated vs app-initiated speech. This drives clean separation of concerns in the Swift code:

- `speech-out`: generic arbitrator. Silent-mode gate is **new-request-only**. Does not subscribe to `ModeChangeEvent`. Does not know about mid-flight cancel policies.
- `ambient-announce`: feature-level owner of its own `.high` token. Subscribes to `ModeChangeEvent` (already subscribed for `IdleTracker`). Cancels own token on `.silent` transition. Also owns 3-s `sessionResumeDampen` window.
- `scene-description` / `ocr`: no new behavior on silent-mid-flight. In-flight `.normal` completes naturally. No new `ModeChangeEvent` subscription needed for this path.
- `spatial-recall`: gestalt speech completes even if 5-s window expires mid-speech. Window expiry does NOT call `cancelAll()`. Mode-change abort DOES (separate mechanism).
- `spatial-core`: new `AnchorChangeEvent.kind` value `.sessionResumeRerecognized` distinct from organic `.rerecognized`. Only emitted after ARKit session interrupt+resume.

### TLA Spec Artifacts

Spec files at `/tmp/echosight-tla/`:
- `SpatialRecall.tla` / `SpatialRecall.cfg`
- `AmbientAnnounce.tla` / `AmbientAnnounce.cfg` (post-gate: 11 state vars, 19 actions, 2,448 distinct states)
- `ModalInput.tla` / `ModalInput.cfg`
- `SpeechOut.tla` / `SpeechOut.cfg`

Re-runnable: `java -cp /usr/local/lib/tla2tools.jar tlc2.TLC -config <NAME>.cfg <NAME>.tla`.

### Residual Risks

- State-space bounds chosen for completeness of transition classes, not user-session length. A real-world session with thousands of anchor events was not exhaustively modeled — but the per-transition invariants hold, so longer sessions compose.
- TLC covers reachable state combinations; it does not prove real-time latency budgets (2-s p95 recall, 200 ms chime, etc.). Those remain empirical acceptance criteria.
- The model treats each action as atomic. In Swift, an `actor` provides the atomicity guarantee required to match this model. The Gate 2 `SilentTogglePreemptsHigh` action assumes `AmbientAnnounceCoordinator`'s `ModeChangeEvent` handler runs fully before any other anchor/speech work — a direct property of actor serialization. Implementation must not leak out of actor isolation.

## Phase 2 Execution Findings (2026-04-21 / 2026-04-22)

Cross-spec decisions that emerged during Sprint 2.1 (detector + fusion) and Sprint 2.2 (modal-input + scene-description + ocr), beyond what the planning-era specs captured. Recorded here so they survive into Phase 3 and later.

### Input Layer — Crown API scope change

The TLA `modal-input` spec assumed `digitalCrownRotation` was available. It is not — the modifier ships in visionOS but is **private / system-reserved**, not part of the public SDK surface for third-party apps. Sprint 2.2 pivoted the hardware-event layer onto `SpatialTapGesture` as a proxy:

- **Single tap** → `ModeFiredEvent(mode: currentMode)` (equivalent to Capture Button press)
- **Double tap** → `ModeChangeEvent(from: …, to: nextMode)` (equivalent to Crown step)

The `ModalInputCoordinator` contract and both `AsyncStream<*Event>` shapes are unchanged — only the hardware bridge (`HardwareEventBridge` ViewModifier) differs from the TLA assumption. The two-stream event bus is what downstream specs (`spatial-recall`, `ambient-announce`, `scene-description`, `ocr`) subscribe to, so their TLA assumptions hold. When Apple opens the Crown API (or if the app runs on a future hardware input), the bridge can swap back with no ripple.

Device-Button remains reserved for v1.0 gestures that currently conflict with double-tap semantics.

### Vision Framework ↔ Swift 6 Concurrency Patterns

Vision framework types (`VNRecognizedObjectObservation`, `VNRecognizedTextObservation`, `VNCoreMLModel`, `VNCoreMLRequest`) are not `Sendable`. Two patterns emerged for crossing them into `async` / actor contexts:

1. **Value-type extraction inside the Vision callback.** Before the continuation resumes, copy the needed fields into a local Sendable value type. Used by Sprint 2.2 OCR:

   ```swift
   struct RawTextObservation: Sendable {
       let text: String
       let confidence: Float
       let boundingBox: CGRect
   }
   // Inside handler.perform callback, before continuation.resume:
   let raws = observations.map { RawTextObservation(
       text: $0.topCandidates(1).first?.string ?? "",
       confidence: $0.confidence,
       boundingBox: $0.boundingBox
   )}
   continuation.resume(returning: raws)
   ```

   Downstream sorting, filtering, and TTS operate on the Sendable `Raw*` type. The Vision observation never escapes the callback.

2. **`@preconcurrency import Vision`** for actor-owned models that must stay on the actor's heap. Applied to `VisionDetector` (Sprint 2.1 P2 cleanup, 2026-04-22). The actor owns `VNCoreMLModel` / `VNCoreMLRequest` lifetime; the preconcurrency demotion reflects the invariant that these never cross the actor boundary unprotected.

Either path works. Prefer (1) for pipelines (clean Sendable-by-default). Prefer (2) for long-lived heap-resident framework objects where extracting would require copying megabytes on every call.

### Actor + DispatchQueue Bridging

When an actor must call a synchronous framework API (Vision, Core ML, Speech), allocate the `DispatchQueue` **once** as an instance `let` on the actor, not per-call. `withCheckedThrowingContinuation { queue.async { … } }` is the standard bridge. Sprint 2.1's initial implementation allocated a fresh queue per `detect(in:)`; corrected in 2026-04-22 close-out.

### Vision Pixel-to-Ray Math

- **Bounding-box Y-flip** — Vision emits `origin.y` in **bottom-left** normalized space. `DetectionResult` (and everything downstream) uses **top-left**. Convention: `topLeftY = 1.0 - bbox.origin.y - bbox.height`. Lock this at the Vision boundary; never propagate bottom-left coordinates past the detector.
- **vFOV from hFOV + aspect** — operate on **tangents**, not radians: `tanV = tan(hFovRad / 2) / aspect`. Dividing radians directly (`vFov = hFov / aspect`) is wrong except at `aspect = 1.0` — a latent bug until a real 16:9 device capture exercised it (Sprint 2.1 review finding).

### RealityKit Raycast Mask

`Scene.raycast` with default collision mask silently misses mesh entities created by `SceneReconstructionProvider`. Always pass `mask: .sceneUnderstanding` when raycasting against the world mesh. Lives in `FusionEngine` — do not lift the mask up to callers.

### Simulator Compatibility Guards

- `SceneReconstructionProvider.isSupported` must gate `arkitSession.run([.sceneReconstruction, …])`. The visionOS simulator crashes otherwise. `SpatialSession` logs a warning and drops the `sceneReconstruction` provider when running in simulator.
- Simulator boot for `xcodebuild test` exceeds the phase-runner's 600 s stream watchdog. Sprint tests are run manually on device. Build-only verification is the CI gate until a device-attached test lane exists.

### SpeechOut Call-Site Convention

`SpeechOut.speak(_:priority:)` is synchronous and non-throwing — it returns a `SpeechToken` whose `.completion` is the sole `async` surface. Call sites **must not** wrap it in `try`/`do-catch`. Correct pattern:

```swift
let token = await speechOut.speak(utterance, priority: .normal)   // actor-isolated, non-throwing
let outcome = await token.completion                               // async
```

(Scene-description shipped with redundant `try/catch` in Sprint 2.2; fixed on close-out.)

### Sendable Static Locks

`NSLock`, `DispatchQueue`, and most `final` types from Foundation/Dispatch conform to `Sendable` with internal synchronization. Do not mark these with `nonisolated(unsafe)` — use that modifier only on genuinely non-Sendable mutable static state (e.g., a `static var installed = false` Bool protected by an external lock).

## Phase 4 Execution Findings (2026-04-22)

### Won't-fix items

**Sprint 2.1 P2#2 — VisionDetector timeout rewrite.**
- Location: `Sources/EchoSightCore/Detector/VisionDetector.swift:detect(in:)`.
- Original finding (Sprint 2.1 code review): the `DispatchWorkItem` + `NSLock` + `didResume` race-guard pattern for the 2-second timeout should be rewritten with `withThrowingTaskGroup`.
- Decision: **accept as-is**. Rationale: `handler.perform` (Vision's request dispatch) is synchronous and cannot be interrupted either way. The `withThrowingTaskGroup` rewrite is stylistic only — it produces the same runtime behavior. Deferring until sim test coverage exists to verify race semantics on the ANE path. Inline note remains in `VisionDetector.swift:detect(in:)`.
- Re-open trigger: device tests running routinely in CI, since the rewrite's benefit is test-time inspectability, not production behavior.

### Execution notes

**`roundedDistance` float-equality fix uses integer buckets.** `DescriptionTemplateFormatter.roundedDistance(_:)` now works in half-metre integer buckets (`Int((clamped / 0.5).rounded())`) instead of comparing rounded Floats with `==`. Keeps the rounding intent, eliminates the float-equality hazard, and the `halfBuckets.isMultiple(of: 2)` check makes the whole-metre vs half-metre branching explicit.

**`[weak self]` removal in actor-owned Tasks (OcrPipeline).** Three instances in `OcrPipeline` used `Task { [weak self] in guard let self else { return } … }` inside an actor — an anti-pattern (actors are reference types, and the Task loop can silently fail to start if the actor deallocates before first suspension). Replaced with direct `self` capture; `stop()` handles cancellation via `currentTask?.cancel()`. Same pattern now consistent with SpeechOut and GemmaPriorityQueue.

**`MeshClassificationSummary.topClasses(_:)` relocated.** Was declared as a module-crossing extension inside `Reasoning/RoomLabelPromptBuilder.swift`. Moved to `Spatial/MeshClassificationSummary.swift` alongside the type it extends. P3-DEFERRED comment removed.

**`AnnotationStore.load` CQS split.** `load()` previously mutated the in-memory cache as a side effect of a named query, violating CQS. Split into a pure `fetch(...)` for reads and a dedicated cache-loading path; existing callers updated.

**`SummarizePromptBuilder` distance now user-relative.** `buildPrompt(from:headPose:)` takes a `SIMD3<Float>` head pose; distances are computed relative to head position rather than world origin. `GemmaRunner.summarize(annotations:headPose:)` defaults `headPose` to `.zero` for back-compat with call sites that have not yet been updated to pass a live head pose.

**Phase-runner partial completion.** The phase-runner agent executing Sprint 4.1 hit Claude usage limits after landing all 5 fix commits but before running `/code-review-pro` on the diff, writing the findings.md won't-fix entry, or updating progress.md. Close-out was completed from the main orchestrator context. `/code-review-pro` on the Sprint 4.1 diff is logged as **S4.1-FOLLOWUP-1** for Sprint 4.3 or pre-release manual invocation.

---

## Phase 4 Post-Audit Backlog (2026-04-22)

Findings from Sprint 4.3 audits (code-review-pro on Sprint 4.1 diff,
test-review on Sprint 3.2 tests, perf-review on v0.1 latency budgets).
All P2/P3 items below. Rationale for deferral: none affect correctness
for v0.1 shipping behavior; all are API hygiene, test coverage gaps,
or instrumentation improvements.

### Pre-existing Warnings (potential Sprint 4.4)

17 pre-existing build warnings were surfaced during Sprint 4.2's warning-count
measurement. They were outside Sprint 4.2's scope (HIG fixes + warning baseline
measurement) and outside Sprint 4.3's scope (audits + P0/P1 fixes).

Files with pre-existing warnings:
- `VisionDetector.swift`, `OcrPipeline.swift`, `SceneDescriptionPipeline.swift`
- `ModalInputCoordinator.swift`, `PipelineMetricsBuffer.swift`
- `AnchorEventStream.swift`, `SpeechOut.swift`
- 2 non-Swift tool warnings (Xcode toolchain)

Suggested Sprint 4.4 before v0.1 ships: one session clearing all 17 warnings
to arrive at a 0-warning baseline for the release build.

---

### From /code-review-pro on Sprint 4.1 diff (6d9f48a..9e80f05)

**P2-CR41-1** — `ModelDownloader.handleDirectoryError` is `public` but has
only one caller (`DownloadProgressView`). Could be `internal`.  
File: `Sources/EchoSightCore/Download/ModelDownloader.swift:195`  
Deferral: no safety risk; API surface hygiene; single caller; v0.1 scope.

**P2-CR41-2** — The "self-removal" Task inside `AmbientAnnounceCoordinator.handleModeChange`
(cleans up `pendingCancelTasks`) is itself untracked. Under rapid silent-toggles it
produces O(N) untracked cleanup tasks; each is trivially short so no observable
side-effect exists, but the oversight is worth noting.  
File: `Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift:387`  
Deferral: sub-millisecond window, no observable side-effect; P2 housekeeping.

**P2-CR41-3** — `AnchorRehydrator.failureCounts` is cleared by `reset()` (on session
interruption). The retry cap is per-session, not per-anchor lifetime; a persistently
broken anchor gets 5 new attempts per session restart.  
File: `Sources/EchoSightCore/Memory/AnchorRehydrator.swift:30`  
Deferral: real-world DB corruption that survives relaunch warrants a user-facing
error path, not just a retry cap. Post-v0.1.

**P3-CR41-1** — `OnboardingCoordinator.markOnboardingComplete` logs `durationSec: -1`
as a sentinel for mid-flow relaunches. A typed flag (`isRestored: Bool`) would be
cleaner for analytics dashboards.  
File: `Sources/EchoSightApp/Onboarding/OnboardingCoordinator.swift:112`  
Deferral: no user impact; analytics schema concern; post-v0.1.

**P3-CR41-2** — `AmbientAnnounceCoordinator.resolveNovelty` returns `Date??`
(optional-optional). A named enum (`NoveltyResult`) would be more readable.  
File: `Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift:246`  
Deferral: semantically correct; readability concern only.

---

### From /test-review on Sprint 3.2 test files

**P2-TR32-1** — `SpatialRecallOrchestratorTests.makeOrchestrator`'s `gemmaSummarize`
closure discards the annotations array. Template-path tests (`gemmaFailureFallsBackToTemplate`)
cannot verify that the correct annotations are passed through.  
File: `Tests/EchoSightCoreTests/SpatialRecallOrchestratorTests.swift:47`  
Deferral: existing check is not wrong; improving it requires factory changes post-v0.1.

**P2-TR32-2** — `AmbientAnnounceCoordinatorTests` never verifies chime count.
If `ChimeRenderer.play()` silently fails (audio session unavailable in tests),
no test would catch it. Recommend mocking `chimeRenderer` with a closure.  
File: `Tests/EchoSightCoreTests/AmbientAnnounceCoordinatorTests.swift:72`  
Deferral: hot-anchor and silent suppression tests cover speech gating; chime path
less critical for v0.1.

**P2-TR32-3** — Two `makeAnnotation` factories exist for `WorldAnnotation`
(`TestSupport/Annotations.swift` and `SpatialRecallOrchestratorTests.swift`),
diverging in parameter names and defaults.  
File: `Tests/EchoSightCoreTests/SpatialRecallOrchestratorTests.swift:326`  
Deferral: both compile; cosmetic friction; consolidate post-v0.1.

**P2-TR32-4** — `ModelDownloaderTests.resumeDataPersistedOnPause` test name
doesn't match what it tests (it checks the completed flag starts false, not
resume-data persistence).  
File: `Tests/EchoSightCoreTests/ModelDownloaderTests.swift:88`  
Deferral: the assertion is correct; the name is misleading; rename post-v0.1.

**P3-TR32-1** — Typo: `gestureActiveSuppreshesSpeech` (should be "Suppresses").  
File: `Tests/EchoSightCoreTests/AmbientAnnounceCoordinatorTests.swift`  
Deferral: cosmetic; no correctness impact.

**P3-TR32-2** — Typo: `devicePutDownSuppreshesSpeech` (same typo).  
File: `Tests/EchoSightCoreTests/AmbientAnnounceCoordinatorTests.swift`  
Deferral: cosmetic; no correctness impact.

---

### From /perf-review on v0.1 latency budgets

**P2-PR32-1** — `SpatialRecallOrchestrator.fetchGestalt` has no orchestrator-level
timeout. `GemmaPriorityQueue` enforces a per-item timeout, but a congested queue
means the orchestrator waits for a queue slot before that timeout starts. Under
heavy `EnrichmentOrchestrator` load, the 2 s recall-gestalt budget could be breached.  
File: `Sources/EchoSightCore/Features/SpatialRecallOrchestrator.swift` — `fetchGestalt`  
Deferral: `.high` priority preemption limits queue wait in practice; full timeout
instrumentation is post-v0.1.

**P2-PR32-2** — `SceneDescriptionPipeline.runPipeline` passes `scene: nil` (v0.1
defers live `RealityKit.Scene` raycast). The v1.0 path will require a `@MainActor`
hop inside `FusionEngine.fuse`, adding latency to the ≤1.5 s scene budget.  
File: `Sources/EchoSightCore/Features/SceneDescriptionPipeline.swift:153`  
Deferral: v0.1 avoids the hop entirely; design attention required pre-v1.0.

**P3-PR32-1** — Silent-mid-flight cancel latency is not instrumented.
`PipelineMetricsBuffer` doesn't capture cancel-to-silence timing; worst-case
under heavy actor contention is unverified against the ≤100 ms budget.  
File: `Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift:380`  
Deferral: structural risk low for v0.1; add `PipelineMetricsBuffer` event post-v0.1.

---

### Phase 4 → v0.1 Release Readiness

**Phase 4 is complete.** All four Phase 4 sprints have landed on main:
- Sprint 4.1: backlog-codereview (5 P2/P3 fix groups)
- Sprint 4.2: backlog-hig-warnings (build warning cleanup + HIG deferrals)
- Sprint 4.3: quality-audits (code-review-4.1 + test-review + perf-review)
- Sprint 4.4: backlog-pre-existing-warnings (17 warnings → 0, merge `39c9ddc`)

**Remaining blockers for v0.1 ship:**

1. ~~**17 pre-existing build warnings**~~ — **RESOLVED** by Sprint 4.4 merge `39c9ddc`.
   Clean build now produces 0 Swift compiler warnings (excluding 2 `appintentsmetadataprocessor`
   tool-chain warnings which are outside Swift-compiler scope). Three fix patterns applied:
   7 redundant `await` drops, 5 `try/catch` unwraps on non-throwing calls, and
   `@preconcurrency import Dispatch` + `_ResumeFlag` class for VisionDetector Dispatch/Sendable
   warnings (preserves Sprint 2.1 P2#2 won't-fix timeout pattern decision).

2. **P2/P3 audit backlog** — all 11 items above are deferred by policy. None are
   correctness bugs; all are hygiene, coverage gaps, or instrumentation work.

3. **Manual device validation** — tests are written but not executed (visionOS
   sim-boot exceeds CI watchdog). A test session on AVP hardware before tagging
   v0.1 is the recommended final gate.

**No P0 or P1 items remain open.** The codebase is structurally sound for v0.1.

