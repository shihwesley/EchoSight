---
name: backlog-codereview
description: Clear all P2/P3 code-review deferrals from Sprints 1.1, 2.1, 2.2, 3.1, 3.2
phase: 4
sprint: 1
parent: root-spec
depends_on: [root, project-skeleton, spatial-core, speech-out, observability, capture, detector, fusion, modal-input, scene-description, ocr, annotation-store, gemma-enrichment, spatial-recall, ambient-announce, onboarding-download]
status: eng-reviewed
created: 2026-04-22
---

# Code-Review Backlog Cleanup (Sprint 4.1)

## Goal

Resolve every P2/P3 code-review item logged as deferred during Phases 1–3. Each item either lands a fix commit or is explicitly marked "won't fix" in `findings.md` with rationale. Build stays green throughout; no new warnings introduced.

## Requirements

- Address all 23 deferred items enumerated in the Tasks section below
- Each fix is a minimum-surgical change (touch only what's needed; match existing style)
- Where a "won't fix" is justified, add an entry to `findings.md` under a new `## Phase 4 Execution Findings` section with the file:line reference and the reason
- After all fixes, `xcodebuild -scheme EchoSight -destination 'generic/platform=visionOS' build` must exit 0 with no new warnings (existing S3.2-CLEANUP-1 warnings may remain — those belong to Sprint 4.2)
- Prefer a single fix commit per sprint-of-origin (5 sprint-grouped commits) over 23 tiny commits — keeps the diff reviewable
- Tests: if a deferred item has an obvious behavioral consequence (e.g., CQS violation in `AnnotationStore.load`), add a minimal test. Otherwise rely on existing coverage.

## Acceptance Criteria

- [ ] All 23 items resolved or documented as "won't fix"
- [ ] `xcodebuild … build` exits 0 (warning count unchanged or lower)
- [ ] `findings.md` Phase 4 section lists every won't-fix with rationale
- [ ] No regression in existing test files
- [ ] `progress.md` Sprint 4.1 entry documents which items were fixed vs deferred

## Technical Approach

Items group naturally by sprint-of-origin and often share surrounding code, so group the commits:

1. `fix(sprint-1.1): clear P3 deferreds` — SAFETY comment + dead state removal + LockingPixelBuffer wrapper
2. `fix(sprint-2.1): clear P3 + accepted P2 deferreds` — doc comment dedup + test expectation + (VisionDetector P2#2 won't-fix note)
3. `fix(sprint-2.2): clear P2 deferreds` — CrownQuantizer + roundedDistance + actor Tasks + gesture priority + nil-scene
4. `fix(sprint-3.1): clear P2/P3 deferreds` — 4 P2 + 3 P3 items
5. `fix(sprint-3.2): clear P2/P3 deferreds` — 3 P2 + 3 P3 items

Each commit runs `xcodebuild … build` to confirm green before the next commit.

## Files

| File | Source |
|------|--------|
| `Sources/EchoSightCore/SpatialCore/HeadPoseRingBuffer.swift` | Sprint 1.1 P3-1 |
| `Sources/EchoSightCore/SpatialCore/ObstacleRaycaster.swift` | Sprint 1.1 P3-2 |
| `Sources/EchoSightCore/Detector/DetectionResult.swift` | Sprint 1.1 P3-3 |
| `Sources/EchoSightCore/Detector/VisionDetector.swift` | Sprint 2.1 P2#2 (won't-fix) + P3 |
| `Tests/EchoSightCoreTests/VisionDetectorTests.swift` | Sprint 2.1 P3 |
| `Sources/EchoSightCore/Input/CrownQuantizer.swift` | Sprint 2.2 P2 |
| `Sources/EchoSightCore/Features/SceneDescriptionPipeline.swift` | Sprint 2.2 P2 (nil-scene) |
| `Sources/EchoSightCore/Features/*.swift` | Sprint 2.2 P2 (actor Tasks, roundedDistance, gesture priority — exact files TBD by search) |
| `Sources/EchoSightCore/Enrichment/EnrichmentOrchestrator.swift` | Sprint 3.1 P2-1 |
| `Sources/EchoSightCore/Persistence/AnchorRehydrator.swift` | Sprint 3.1 P2-2 |
| `Sources/EchoSightCore/Enrichment/SummarizePromptBuilder.swift` | Sprint 3.1 P2-3 |
| `Sources/EchoSightCore/Persistence/AnnotationStore.swift` | Sprint 3.1 P2-6 |
| `Sources/EchoSightCore/Enrichment/QueueError.swift` | Sprint 3.1 P3-1 |
| `Sources/EchoSightCore/SpatialCore/MeshClassificationSummary.swift` | Sprint 3.1 P3-2 |
| `Tests/EchoSightCoreTests/TestSupport/Annotations.swift` | Sprint 3.1 P3-3 (new file) |
| `Sources/EchoSightCore/Features/AmbientAnnounceCoordinator.swift` | Sprint 3.2 P2-1, P3-1 |
| `Sources/EchoSightCore/Features/SpatialRecallOrchestrator.swift` | Sprint 3.2 P2-1 |
| `Sources/EchoSightCore/Onboarding/*.swift` | Sprint 3.2 P2-2, P3-3 (ensureDirectoryExists, markOnboardingComplete) |
| `Sources/EchoSightCore/Features/RecallGestaltFormatter.swift` | Sprint 3.2 P2-3 |
| `Sources/EchoSightCore/Observability/HardwareDiagnosticLog.swift` | Sprint 3.2 P3-2 |
| `docs/plans/findings.md` | Phase 4 Execution Findings section |

## Tasks

### Sprint 1.1 P3 items (3)

1. **HeadPoseRingBuffer SAFETY comment** — `HeadPoseRingBuffer` is `@unchecked Sendable` but has no `// SAFETY:` call-site explaining the invariant. Add one documenting the ring-buffer's lock-free read discipline.
2. **ObstacleRaycaster dead state** — `lastFireTime` is never read or written after declaration. Remove it.
3. **DetectionResult.mask LockingPixelBuffer wrapper** — Wrap `CVPixelBuffer?` in a `LockingPixelBuffer` type that holds the base-address lock for the lifetime of the wrapper. Required before Phase 2 segmentation work extends this.

### Sprint 2.1 items (2)

4. **VisionDetector P2#2 (won't fix)** — Log in `findings.md` that the `DispatchWorkItem` + `NSLock` timeout pattern is accepted over the spec-recommended `withThrowingTaskGroup` rewrite. Rationale (per `progress.md:173`): `handler.perform` is synchronous and cannot be interrupted either way; refactor is stylistic only and deferred until sim test coverage can verify race semantics on the ANE path.
5. **VisionDetector P3** — Remove duplicate doc comment at `VisionDetector.detect()` lines 93–95. Remove tautological `#expect(Bool(true), …)` in `VisionDetectorTests.swift:193` (replace with meaningful assertion or delete).

### Sprint 2.2 P2 items (5)

6. **CrownQuantizer sign-boundary truncation** — current quantization truncates toward zero; at the sign boundary this produces off-by-one on negative rotations. Fix with `floor` semantics or equivalent.
7. **roundedDistance float equality** — replace `==` on rounded `Double` with an epsilon-based comparison or hoist to an integer bucket.
8. **`[weak self]` in actor-owned Tasks** — actors are reference types; the weak capture is an anti-pattern. Remove from all actor-owned Tasks (search `[weak self]` in actor methods).
9. **Single/double tap gesture priority arbitration** — SpatialTapGesture proxy currently has no explicit priority, causing double-tap to sometimes register as two singles. Use `ExclusiveGesture` or equivalent.
10. **SceneDescriptionPipeline nil-scene handling** — pipeline currently force-unwraps the scene. Add guard with graceful fallback speech.

### Sprint 3.1 items (7)

11. **P2-1: EnrichmentOrchestrator log level** — preemption cancellations log at error level; demote to `.info` or `.debug`. Cancellation is expected under preemption cadence, not an error.
12. **P2-2: AnchorRehydrator retry cap** — currently retries forever on persistent DB error. Add retry-count cap (e.g., 5) with exponential backoff and a terminal error log.
13. **P2-3: SummarizePromptBuilder distance** — distance is computed from world origin. Should be from head pose for user-relative semantics.
14. **P2-6: AnnotationStore.load CQS violation** — `load()` currently mutates internal cache as a side effect of a named query. Split into pure `fetch(…)` + cache update, or rename to `loadAndCache(…)`.
15. **P3-1: QueueError dead code** — unused cases in `QueueError` enum; remove.
16. **P3-2: MeshClassificationSummary extension location** — extension lives in the wrong file; move to the type's owning file.
17. **P3-3: shared makeAnnotation() factory** — tests duplicate annotation construction. Introduce `Tests/EchoSightCoreTests/TestSupport/Annotations.swift` with `makeAnnotation(…)` defaults; update existing tests to use it.

### Sprint 3.2 items (6)

18. **P2-1: Untracked fire-and-forget cancel Tasks** — mode-change handlers spawn `Task { cancellable.cancel() }` without storing the Task reference. If the mode changes rapidly, these accumulate. Store as a tracked property or use `withTaskCancellationHandler`.
19. **P2-2: ensureDirectoryExists silent swallow** — wrap thrown errors in a typed `OnboardingError.directoryCreateFailed(path, underlying:)` and surface to the caller.
20. **P2-3: Empty falconLabel trailing space** — `RecallGestaltFormatter` produces `"a "` when the label is empty. Guard with non-empty check or use `String.filter(\.isEmpty == false).joined(…)`.
21. **P3-1: handleAnchorEvent overlong** — extract sub-handlers for `.new` / `.rerecognized` / `.sessionResumeRerecognized` into private methods.
22. **P3-2: HardwareDiagnosticLog print→Logger** — replace `print(…)` with `Logger(subsystem:category:)`.
23. **P3-3: markOnboardingComplete() durationSec** — currently logs `durationSec=0` hardcoded. Measure actual elapsed time from the onboarding start marker.

## Dependencies

- **Needs from:** Phases 1–3 (all 16 specs merged; current state is `c6131bc`)
- **Provides to:** Sprint 4.2 (warnings cleanup + HIG), Sprint 4.3 (quality audits)

## Notes for Phase-Runner

- No new architectural decisions — every item has a clear resolution path
- If a file referenced above doesn't exist at the expected path, search by class name before creating — spec paths are best-effort guesses based on the Phase 1–3 execution record
- If an item proves harder than expected (e.g., `LockingPixelBuffer` wrapper surfaces API ripple), escalate via `needs_user_input` rather than expanding scope silently
- Won't-fix items must be logged in `findings.md` with the exact file:line reference
