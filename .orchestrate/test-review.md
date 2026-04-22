<!-- HEADER
P0: 1 | P1: 1 | P2: 3 | P3: 2
Sprint: 3.2 | Files: 6 (+ RecallGestalt embedded in SpatialRecall file) | Closes: S3.2-CLEANUP-2
Auditor: /test-review | Date: 2026-04-22
Note: "RecallGestaltFormatterTests" is embedded in SpatialRecallOrchestratorTests.swift, not a separate file.
-->

# Test Review — Sprint 3.2 Test Suite (S3.2-CLEANUP-2)

Target: 7 test suites across 6 files (RecallGestaltFormatter tests are in
`SpatialRecallOrchestratorTests.swift`, not a separate file as the spec named).
Total: 39 tests across the combined files (including RecallGestaltFormatter suite).

Execution: deferred per project policy (visionOS sim-boot exceeds watchdog).
Audit is code-only — no behavioral execution.

---

## File: SpatialRecallOrchestratorTests.swift

9 tests in `SpatialRecallOrchestratorTests` + 4 tests in `RecallGestaltFormatterTests`.

### SpatialRecallOrchestratorTests (9 tests)

**`secondPressAfterWindowExpiry`** — **P0-TR32-1 (P0)**

This test calls `Task.sleep(for: .seconds(6))` to wait for the 5-second
recall window to expire, then fires a second press and asserts it is treated
as a new first press. Two problems:

1. The test takes ~6 seconds to run, but the `SpatialRecallOrchestrator` init
   hardcodes `Constants.windowDuration = 5.0`. The test cannot inject a shorter
   duration, so any CI run pays a mandatory 6+ second cost per test invocation.
2. Worse: the test assertion is wrong. The mock `gemmaSummarize` closure in
   `makeOrchestrator` captures `gemmaResult` but ignores the `headPoseProvider`
   properly — the second press after window expiry would be a fresh first press,
   which requires Gemma to complete before speech fires. With a 100 ms sleep
   after the second press and real async Gemma (even mocked), there is a race:
   the assertion `spoken.count == 2` can fail if the second Gemma hasn't finished
   in 100 ms on a loaded CI runner.

**Fix required:** Add a `windowDuration` parameter to `SpatialRecallOrchestrator`'s
testability init (defaulting to 5.0) and inject a short window (e.g. 0.1 s) in
tests that exercise expiry. This eliminates the 6-second wall-clock penalty and
removes the race. The `Constants.windowDuration` remains 5.0 for production.

`Tests/EchoSightCoreTests/SpatialRecallOrchestratorTests.swift` — `secondPressAfterWindowExpiry` test

---

**`windowExpiryDoesNotCancelSpeech`** — **P1-TR32-1 (P1)**

Same root cause as P0-TR32-1. This test also sleeps 6 seconds to verify that
window expiry does not call `cancelAll`. It is semantically correct (the
pinned behavior is right) but takes 6+ seconds and has the same race on
`cancelAllCount`. Once the `windowDuration` injection is in place, this test
can use a 0.1 s window and a 0.2 s wait, cutting its cost to ~300 ms.

`Tests/EchoSightCoreTests/SpatialRecallOrchestratorTests.swift` — `windowExpiryDoesNotCancelSpeech` test

---

**`makeOrchestrator` — gemmaSummarize closure ignores `headPose`** — **P2-TR32-1 (P2)**

The helper builds `gemmaSummarize: { _ in try gemmaResult.get() }`, dropping
the annotation array. This means the formatter fallback tests (`gemmaFailureFallsBackToTemplate`)
cannot verify that labels from the passed annotations appear in the template phrase —
the closure discards them. The test checks `spoken[0].text.contains("around you")`,
which is correct, but it cannot catch a regression where the wrong annotations
are passed.

Recommendation: keep the current closure for gestalt tests, but add a variant
that captures and returns `annotations` for template-path tests.  
`Tests/EchoSightCoreTests/SpatialRecallOrchestratorTests.swift:47`  
Rationale for deferral: existing check is not wrong, just less precise. P2.

---

**`newAnchorFiresChime`** — **P2-TR32-2 (P2)**

The test comment says "we can't easily intercept AVAudioEngine in tests, so we
verify speech fires instead." The chime count (`state.chimeCount`) is never
checked — only `state.speechCount`. Chime-only behavior (hot-anchor) is tested
in `hotAnchorNoSpeech`, but there is no test that verifies the chime count
increments on any path. If `ChimeRenderer.play()` silently fails (audio session
unavailable in tests), no test would catch it.

Recommendation: mock `chimeRenderer` via the testability init with a closure
that increments a counter (same pattern as `speakAction`). Add one test that
asserts `chimeCount >= 1` on a new cold anchor.  
`Tests/EchoSightCoreTests/AmbientAnnounceCoordinatorTests.swift:72`  
Rationale for deferral: hot-anchor / silent suppression tests cover the
speech-gating logic; the chime path is less critical for v0.1.

---

**`gestureActiveSuppreshesSpeech`** — **P3-TR32-1 (P3)** — typo in function name

`gestureActiveSuppreshesSpeech` — "Suppreshes" should be "Suppresses".
No correctness impact; cosmetic only.  
`Tests/EchoSightCoreTests/AmbientAnnounceCoordinatorTests.swift:128`  
Rationale for deferral: test name typo; cosmetic.

---

**`devicePutDownSuppreshesSpeech`** — **P3-TR32-2 (P3)** — same typo

`Tests/EchoSightCoreTests/AmbientAnnounceCoordinatorTests.swift:154`  
Rationale for deferral: test name typo; cosmetic.

---

**`silentMidFlightCancelsToken`** — no issue

The test wires a custom `speakAction` that returns an unresolved `SpeechToken`,
then fires a silent-mode change event and checks `cancelCount >= 1`. This
correctly exercises the `pendingCancelTasks` tracking added in Sprint 4.1.
No issues.

---

**`sessionResumeDampensSuppresses`** — no issue

Timing assumption: 100 ms after the session-resume event, two new events fire
and the test asserts 0 speeches. The 3-second dampener window is much larger
than the 100 ms sleep, so this is safe. No issues.

---

### RecallGestaltFormatterTests (4 tests) — embedded in same file

All 4 tests are structurally clean. The private `makeAnnotation` helper at
the bottom of the file differs from the shared `TestSupport/Annotations.swift`
`makeAnnotation` factory (different signature: `label:` vs `falconLabel:`,
different defaults). Both are valid but divergence creates maintenance friction.

**P2-TR32-3 (P2)** — Two `makeAnnotation` factories for `WorldAnnotation` exist:
`TestSupport/Annotations.swift::makeAnnotation(id:worldPosition:worldAnchorId:...)` and
`SpatialRecallOrchestratorTests.swift::makeAnnotation(label:pos:)`. The private
one uses a different init signature (positional-unlabeled fields on `WorldAnnotation`)
while the shared one uses labeled parameters. Neither is wrong, but the divergence
will cause confusion when callers need to mix factories.  
`Tests/EchoSightCoreTests/SpatialRecallOrchestratorTests.swift:326`  
Rationale for deferral: both compile; cosmetic friction only; consolidation is
post-v0.1 housekeeping.

---

## File: NoveltyDetectorTests.swift (5 tests)

All 5 tests are clean. Boundary conditions (`nil`, `==threshold`, `>threshold`)
are covered correctly with fixed `now` parameters. No issues.

---

## File: IdleTrackerTests.swift (5 tests)

**`firedAtThresholdIsNotIdle`** — minor documentation inconsistency

The test name says "is not idle" but the `#expect` asserts `isIdle == true`,
and the comment correctly explains the boundary semantics (elapsed >= threshold
→ idle). The test is correct; the name is misleading. This is P3 cosmetic —
same pattern as the typos above but it is more confusing because the assertion
contradicts the name.

All 5 tests are otherwise clean. Boundary coverage is good. No P0/P1 issues.

---

## File: AmbientAnnounceCoordinatorTests.swift (8 tests)

See findings above (P2-TR32-2, P3-TR32-1, P3-TR32-2). All other tests are clean.
The gate-gating coverage is comprehensive: hot-anchor, silent, gesture-active,
head-motion-below, session-resume-dampen, silent-mid-flight-cancel all have
dedicated tests.

---

## File: ModelVerifierTests.swift (6 tests)

Clean. Six tests cover: correct SHA, mismatch-with-delete, mismatch-without-delete,
non-existent file, empty file, and case-insensitive SHA comparison. The case-insensitive
test (`shaComparisonCaseInsensitive`) is a good edge case. No issues.

---

## File: ModelDownloaderTests.swift (7 tests)

**`resumeDataPersistedOnPause`** — **P2 (included in P2-TR32-2 count as separate item)**

The test name claims "resume data persisted on pause" but the test body only
creates a downloader and checks that the `completed` flag starts `false`. It does
not call `pause()`, does not start any downloads, and does not check resume data.
The assertion is correct (completed flag starts false) but the test name is
seriously misleading — a reader expecting "resume data persisted" behavior will
find no such verification.

This is a P2 naming/coverage gap. The test should either:  
(a) be renamed to `completedFlagInitiallyFalse`, or  
(b) actually test resume-data persistence by faking a `URLSessionDownloadTask`
    with resume data (deferred to post-v0.1 since it requires deeper mock infra).

`Tests/EchoSightCoreTests/ModelDownloaderTests.swift:88`  
Rationale for deferral: the test as written is not wrong — it tests something
real. The gap is the missing resume-data behavioral test. v0.1 ships without it.

The remaining 6 tests (`manifestTotalBytes`, `placeholderEntriesSkipped`,
`v01ManifestEntryCount`, `entryProgressFractionBounded`, `milestoneDetection`,
`v01ManifestEntryCount`) are all clean. `milestoneDetection` covers the
10-percent boundary correctly.

---

## Finding Index

| ID | Severity | File | Line | Description |
|----|----------|------|------|-------------|
| P0-TR32-1 | P0 | SpatialRecallOrchestratorTests.swift | `secondPressAfterWindowExpiry` | 6-second wall-clock sleep + race on assertion; inject `windowDuration` |
| P1-TR32-1 | P1 | SpatialRecallOrchestratorTests.swift | `windowExpiryDoesNotCancelSpeech` | Same 6-second sleep root cause; fix via `windowDuration` injection |
| P2-TR32-1 | P2 | SpatialRecallOrchestratorTests.swift | 47 | `gemmaSummarize` closure discards annotations; template-path test is under-specified |
| P2-TR32-2 | P2 | AmbientAnnounceCoordinatorTests.swift | 72 | Chime count never verified; `ChimeRenderer.play()` failures would be silent |
| P2-TR32-3 | P2 | SpatialRecallOrchestratorTests.swift | 326 | Two `makeAnnotation` factories diverge in signature |
| P2-TR32-4 | P2 | ModelDownloaderTests.swift | 88 | Test name "resumeDataPersistedOnPause" doesn't match what the test actually verifies |
| P3-TR32-1 | P3 | AmbientAnnounceCoordinatorTests.swift | `gestureActiveSuppreshesSpeech` | Typo in function name ("Suppreshes") |
| P3-TR32-2 | P3 | AmbientAnnounceCoordinatorTests.swift | `devicePutDownSuppreshesSpeech` | Typo in function name ("Suppreshes") |

## Verdict

**P0 and P1 found — fixes required before merge.**

- P0-TR32-1: `secondPressAfterWindowExpiry` — inject `windowDuration` parameter
- P1-TR32-1: `windowExpiryDoesNotCancelSpeech` — same fix

Four P2 and two P3 items deferred to Phase 4 Post-Audit Backlog.
