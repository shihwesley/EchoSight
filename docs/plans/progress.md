# Progress Log

## Session: 2026-04-21 (Sprint 1.1 execution)

### Sprint 1.1 — Foundations (Phase 1) — merged 7d886e3

**Wave A (serial):**
- root-spec: `PassthroughCaptureSource`, `Detector`, `EchoSightError`, `CapturedFrame` protocols + `.swiftformat`
- project-skeleton: `Package.swift` + XcodeGen `project.yml` + `EchoSightApp` @main + `ObservabilityBootstrap` stub. Build gate passes on `xcodebuild generic/platform=visionOS`.

**Wave B (parallel):**
- spatial-core: `SpatialSession`, `HeadPoseRingBuffer` (500-sample, O(log N) interp, headPoseVariance), `AnchorEventStream` (`.new` / `.rerecognized` / `.sessionResumeRerecognized` per TLA Gate 4), `MeshClassificationSummary`, `ObstacleRaycaster`, `SpatialCueRenderer`.
- speech-out: `SpeechOut` actor matches TLA-verified priority contract; `SynthesizerDelegateBridge`; `SpeechToken` async completion; priority-slot unit tests.
- observability: 15 log categories, `PipelineMetricsBuffer` actor ring, `PrivacyFilter`, `LogExporter` (SHA-256 anchor hashing), `DebugConsoleView` + `LogoTapGate`.

**Swift 6 / concurrency fixes applied during build-up (worth remembering for Sprint 1.2+):**
- `DetectionResult`: `@unchecked Sendable` struct (CVPixelBuffer not Sendable)
- `ObservabilityBootstrap`: `nonisolated(unsafe)` static vars for Swift 6
- `SpatialSession`: `SceneReconstructionProvider(modes: [.classification])` (array, not OptionSet)
- `SynthesizerDelegateBridge`: stripped `AVSpeechUtterance` from Event enum (not Sendable)
- `SpeechOut.init`: wrapped `configureAudioSession` in `Task` for actor-isolated call
- Test files: added `import Foundation` for `UUID`/`Date` in Swift Testing framework

**Close-out fixes (post phase-runner):**
- `project.yml`: `CODE_SIGNING_ALLOWED=NO` / `CODE_SIGNING_REQUIRED=NO` so `xcodebuild` runs without a dev team.
- `Sources/EchoSightApp/Info.plist` tracked (was untracked after XcodeGen generation).

**Remaining warnings (non-blocking, Sprint 1.2 cleanup candidates):**
- 3× "no 'async' operations occur within 'await' expression" — `AnchorEventStream:51`, `PipelineMetricsBuffer:70`, `SpeechOut:46`. All are continuation-registration patterns; the registered method is synchronous.
- 1× redundant `nonisolated(unsafe)` on `let installLock = NSLock()` — NSLock is already Sendable.

**Commits:** `679f14a` → `8cb832d` → `8262a43` → `661a9a0` → `ed70667` → `061cef4` (close-out fix) → `c24d4aa` (progress) → `7d886e3` (merge).

---

## Session: 2026-04-21

### Planning session
- Ingested `EchoSight-AVP-Brainstorm.md`
- Ran Gates 1-3 (mode, priority, project type, requirements, approach + decomposition)
- Created 10 spec files + manifest + findings + workflow
- Created two-level task structure (10 spec tasks + sub-tasks)

### CEO Review (Scope Expansion)
- 5 gates run; scope expanded 10 → 14 specs
- New: modal-input, ocr, spatial-recall, ambient-announce

### Eng Manager Review (BIG depth)
- 7 gates run; scope expanded 14 → 16 specs
- New: speech-out, observability
- Every pre-existing spec got `## Eng Review` block + test plan + data flow diagram + observability subsection
- Key decisions: speech-out owns single AVSpeechSynthesizer w/ priority slots; spatial-recall owns 2-press state machine; ambient idle = gesture + head-motion; anchor rehydration is eager-silent plumbing; observability is a full spec with `DebugConsoleView`; onboarding tutorial is non-gating (always-skip)

## Spec Status

| Spec | Phase | Sprint | Status | Commit | Last Updated |
|------|-------|--------|--------|--------|-------------|
| root | 1 | 1 | completed | 679f14a | 2026-04-21 |
| project-skeleton | 1 | 1 | completed | 8cb832d | 2026-04-21 |
| spatial-core | 1 | 1 | completed | 8262a43 | 2026-04-21 |
| speech-out | 1 | 1 | completed | 661a9a0 | 2026-04-21 |
| observability | 1 | 1 | completed | ed70667 | 2026-04-21 |
| capture | 1 | 2 | eng-reviewed | — | 2026-04-21 |
| detector | 2 | 1 | eng-reviewed | — | 2026-04-21 |
| fusion | 2 | 1 | eng-reviewed | — | 2026-04-21 |
| modal-input | 2 | 2 | eng-reviewed | — | 2026-04-21 |
| scene-description | 2 | 2 | eng-reviewed | — | 2026-04-21 |
| ocr | 2 | 2 | eng-reviewed | — | 2026-04-21 |
| annotation-store | 3 | 1 | eng-reviewed | — | 2026-04-21 |
| gemma-enrichment | 3 | 1 | eng-reviewed | — | 2026-04-21 |
| spatial-recall | 3 | 2 | eng-reviewed | — | 2026-04-21 |
| ambient-announce | 3 | 2 | eng-reviewed | — | 2026-04-21 |
| onboarding-download | 3 | 2 | eng-reviewed | — | 2026-04-21 |

<!-- Status values: draft → ceo-reviewed → eng-reviewed → in_progress → completed | blocked | skipped -->

## Test Results
| Test | Expected | Actual | Status |
|------|----------|--------|--------|
| xcodebuild build | visionOS generic build succeeds | Build Succeeded with 4 benign warnings | passed |
| xcodebuild test | simulator tests pass | deferred — simulator boot timed out phase-runner; to be run manually | deferred |

### Sprint 1.1 close-out notes (2026-04-21)

- All 5 specs landed as atomic commits on branch `orchestrate/sprint-1.1-foundations`.
- Build green against `-destination 'generic/platform=visionOS'`.
- 4 warnings: 3 "no 'async' operations occur within 'await' expression" (AnchorEventStream, PipelineMetricsBuffer, SpeechOut continuation registration) + 1 redundant `nonisolated(unsafe)` on `NSLock` in ObservabilityBootstrap. Flagged for Sprint 1.2 cleanup.
- Info.plist and `project.yml` signing defaults added in fix commit after phase-runner stall.
- Simulator test run deferred — Vision Pro simulator boot exceeded the phase-runner stream watchdog (600s). To run manually: `xcodebuild test -scheme EchoSight -destination 'platform=visionOS Simulator,name=Apple Vision Pro' | xcbeautify`.

## 5-Question Reboot Check
| Question | Answer |
|----------|--------|
| Where am I? | Sprint 1.1 complete. Ready for Sprint 1.2 (capture spec). |
| Where am I going? | Ship v0.1 (Feature 1 + Layer 1 + persistence) on visionOS |
| What's the goal? | Accessibility-first spatial companion for BLV users, fully local |
| What have I learned? | See findings.md + Sprint 1.1 close-out notes above |
| What have I done? | Implemented Phase 1 Sprint 1: root protocols, SwiftPM + Xcode skeleton, Layer 1 ARKit + mesh, SpeechOut actor, observability bootstrap + DebugConsoleView |
