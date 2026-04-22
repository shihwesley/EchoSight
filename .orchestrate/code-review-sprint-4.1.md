<!-- HEADER
P0: 0 | P1: 0 | P2: 3 | P3: 2
Sprint: 4.1 | Diff: 6d9f48a..9e80f05 | Closes: S4.1-FOLLOWUP-1
Auditor: /code-review-pro | Date: 2026-04-22
-->

# Code Review — Sprint 4.1 Diff (S4.1-FOLLOWUP-1)

Diff range: `6d9f48a..9e80f05` (5 fix groups, 22 files, +307/-144 lines)  
Merged into main at `144d15b`.

## Summary

No P0 or P1 issues found. The five fix groups are mechanically correct and safe
to ship. Three P2 and two P3 items follow; all are deferred to post-v0.1.

---

## File-by-File Findings

### HardwareEventBridge.swift — ExclusiveGesture fix

**Change:** Replaced two parallel `.gesture()` modifiers with a single
`ExclusiveGesture(double, single)` to prevent double-tap being recognised
as two singles.

**Verdict:** Correct. `ExclusiveGesture` is the right primitive here.
No issues.

---

### DownloadProgressView.swift + ModelDownloader.swift — directory error propagation

**Change:** `startDownloads()` now `throws`, `ensureDirectoryExists()` throws
`DownloadError.directoryCreateFailed`, and the call site wraps with
`do/catch` → `handleDirectoryError`.

**P2-CR41-1** (P2) — `handleDirectoryError` is `public` but its only caller is
`DownloadProgressView`. Exposing it publicly widens the API surface without need.
It could be `internal` or the error could be returned from `startDownloads`
as a typed `DownloadError` directly.
`Sources/EchoSightCore/Download/ModelDownloader.swift:195`  
Rationale for deferral: no safety risk; API hygiene only; v0.1 has one caller.

---

### OnboardingCoordinator.swift — onboarding duration telemetry

**Change:** Added `onboardingStartedAt: Date?` to compute real duration in
`markOnboardingComplete`; logs `-1` for mid-flow app relaunches.

**P3-CR41-1** (P3) — The `-1` sentinel mixes type intent: a duration field
that can carry a sentinel value makes dashboards brittle. A `Bool` flag
(`isRestored: true`) alongside the duration would be cleaner. Low urgency
— this is an observability nicety, not a correctness issue.
`Sources/EchoSightApp/Onboarding/OnboardingCoordinator.swift:112`  
Rationale for deferral: no user impact; analytics schema cleanup is post-v0.1.

---

### AmbientAnnounceCoordinator.swift — gate refactor + cancel-task tracking

**Change:** 9-gate monolith split into `shouldChime`, `resolveNovelty`,
`passesSpeechGates`, `performSpeech`. `pendingCancelTasks: Set<Task<Void,Never>>`
tracks fire-and-forget cancel tasks; `stop()` cancels them.

**P2-CR41-2** (P2) — The "self-removal" Task inside `handleModeChange`:
```swift
Task {
    _ = await cancelTask.value
    pendingCancelTasks.remove(cancelTask)
}
```
This second Task is itself untracked. Under a long sequence of rapid
silent-toggles it produces O(N) untracked cleanup tasks. The set cannot
grow without bound (each cancelTask completes quickly), but the oversight
is worth noting: the outer `stop()` cancels `cancelTask` but not the
inner cleanup Task.  
`Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift:387`  
Rationale for deferral: the cleanup Task is trivially short; the race window
is sub-millisecond and has no observable side-effect. P2 housekeeping.

**P3-CR41-2** (P3) — `resolveNovelty` returns `Date??` (optional-optional)
to distinguish "gated (nil)" from "first visit (some(nil))" from
"returning visit (some(date))". This is semantically valid but unusual.
A named enum (`NoveltyResult`) would be more readable.
`Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift:246`  
Rationale for deferral: no correctness risk; readability concern only.

---

### OcrPipeline.swift / SceneDescriptionPipeline.swift — weak-self removal

**Change:** Removed `[weak self]` from actor-owned Tasks, replacing with
direct `self` capture. Comment explains the reasoning.

**Verdict:** Correct fix. `[weak self]` in actor-owned Tasks is an anti-pattern:
the optional bind can silently no-op if the actor deallocates before first
suspension. Direct capture is correct here; cancellation-on-stop handles lifecycle.

---

### SpatialRecallOrchestrator.swift — head-pose threading

**Change:** `gemmaSummarize` closure now threads `headPoseProvider()` into
`gemmaRunner.summarize(annotations:headPose:)`.

**Verdict:** Correct. The provider is sampled at summarise time (user-relative
distances), not at fire time. No issues.

---

### CrownQuantizer.swift — floor vs truncation

**Change:** `Int(accumulator / threshold)` → `Int(floor(accumulator / threshold))`.

**Verdict:** Correct. `Int()` truncates toward zero; `floor()` truncates toward
negative infinity. For negative deltas near the boundary this is the right fix.

---

### AnchorRehydrator.swift — retry cap

**Change:** Added `maxRetries = 5` cap with `failureCounts: [UUID: Int]`.
Exceeded anchors are skipped with an error log.

**P2-CR41-3** (P2) — `failureCounts` is never persisted across actor resets
(the `reset()` call clears it). If a session is interrupted and resumed,
a persistently-broken anchor gets 5 more attempts. This is acceptable
for v0.1 (persistent DB corruption is unlikely), but the cap is effectively
per-session, not per-anchor lifetime.
`Sources/EchoSightCore/Memory/AnchorRehydrator.swift:30`  
Rationale for deferral: the real-world risk is minimal; database corruption
that survives a relaunch warrants a different recovery path (user-facing error).

---

### AnnotationStore.swift — CQS split: fetch / rehydrate / deprecated load

**Change:** Renamed `load` → `fetch` (pure read) and `rehydrate` (read + hash).
`load` kept as deprecated redirect.

**Verdict:** Clean CQS fix. Deprecated API with `renamed:` is the right bridge.

---

### GemmaPriorityQueue.swift — dead enum removed

**Change:** Removed `QueueError` (was P3 dead code).

**Verdict:** Correct. No call sites used it.

---

### RoomLabelPromptBuilder.swift / MeshClassificationSummary.swift — extension moved

**Change:** `topClasses(limit:)` extension moved from Reasoning/ to Spatial/.

**Verdict:** Correct. Module-ownership is now consistent.

---

### EnrichmentOrchestrator.swift — CancellationError isolation

**Change:** `catch is CancellationError` branch logs at `.info`; remaining
errors log at `.error`.

**Verdict:** Correct. Preemption is normal in a priority queue; it should not
be an error log.

---

### GemmaRunner.swift / SummarizePromptBuilder.swift — headPose parameter

**Change:** `buildPrompt(from:headPose:)` now uses `simd_distance` from head
position rather than `simd_length` from world origin.

**Verdict:** Correct fix for the P2 distance bug. No issues.

---

### VisionDetectorTests.swift — meaningful assertions

**Change:** Two `#expect(Bool(true), ...)` no-op assertions replaced with
`await detector.isReady == false` checks.

**Verdict:** Correct improvement. The new assertions test a real pre-condition.

---

## Finding Index

| ID | Severity | File | Line | Description |
|----|----------|------|------|-------------|
| P2-CR41-1 | P2 | ModelDownloader.swift | 195 | `handleDirectoryError` unnecessarily `public` |
| P2-CR41-2 | P2 | AmbientAnnounceCoordinator.swift | 387 | Cleanup Task inside `handleModeChange` is itself untracked |
| P2-CR41-3 | P2 | AnchorRehydrator.swift | 30 | `failureCounts` reset per-session, not per-anchor lifetime |
| P3-CR41-1 | P3 | OnboardingCoordinator.swift | 112 | `-1` sentinel duration value mixes type intent |
| P3-CR41-2 | P3 | AmbientAnnounceCoordinator.swift | 246 | `Date??` return type is unusual; named enum would be clearer |

## Verdict

**clean (no P0/P1)**. All five fix groups are correct and safe to merge.
Five deferred items (3×P2, 2×P3) logged for post-v0.1 backlog.
