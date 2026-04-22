---
name: backlog-pre-existing-warnings
description: Eliminate the 17 pre-existing compiler warnings surfaced by Sprint 4.2's warning-count discipline
phase: 4
sprint: 4
parent: root-spec
depends_on: [backlog-codereview, backlog-hig-warnings, quality-audits]
status: eng-reviewed
created: 2026-04-22
---

# Pre-Existing Warnings Cleanup (Sprint 4.4)

## Goal

Drive the absolute Swift compiler warning count to **0**. Sprint 4.2 eliminated the 3 S3.2-CLEANUP-1 warnings but surfaced 17 pre-existing warnings that had accreted across Phases 1–3 while prior close-outs measured only *new* warnings, not the *absolute* count. This sprint closes that debt before v0.1 ships.

## Requirements

- All 12 "no async operations" / "try on non-throwing" / "unreachable catch" warnings resolved
- 4 VisionDetector Dispatch/Sendable warnings silenced via `@preconcurrency import Dispatch` — preserves the Sprint 2.1 P2#2 won't-fix decision on the underlying timeout pattern
- `xcodebuild -scheme EchoSight -destination 'generic/platform=visionOS' build 2>&1 | grep "warning:" | grep -v appintentsmetadataprocessor | wc -l` must be **0** after the sprint
- Build remains green (0 errors)
- No behavioral changes — this sprint is cosmetic only, no logic edits

## Acceptance Criteria

- [ ] Raw Swift compiler warning count = 0 (filtered by `grep -v appintentsmetadataprocessor`)
- [ ] `xcodebuild build` exits 0
- [ ] No functional changes in the diff (verify by reading each edit — all should be keyword removals + `do`/`catch` unwrapping, or the single `@preconcurrency` annotation)
- [ ] `/code-review-pro` on the diff returns 0 P0/P1
- [ ] Manifest Spec Status updated to `completed` with merge SHA
- [ ] findings.md notes the Sprint 4.4 resolution under Phase 4 Post-Audit Backlog

## Technical Approach

### Pattern 1: "no 'async' operations occur within 'await' expression" (7 fixes)

All 7 are continuation-registration patterns where the registered method is synchronous. Fix: remove the `await` keyword. Same pattern as the Sprint 1.1 close-out note flagging these as Sprint 1.2 cleanup candidates — the cleanup slipped and carried forward.

Locations:
- `Sources/EchoSightCore/Features/OcrPipeline.swift:97` and `:104`
- `Sources/EchoSightCore/Features/SceneDescriptionPipeline.swift:78` and `:85`
- `Sources/EchoSightCore/Observability/PipelineMetricsBuffer.swift:70`
- `Sources/EchoSightCore/Spatial/AnchorEventStream.swift:51`
- `Sources/EchoSightCore/Speech/SpeechOut.swift:46`

For each: inspect the call site. If the method being `await`-ed is synchronous (no `async` marker, no suspension), drop the `await`. If it's legitimately async but the compiler is confused, investigate — this would be a P1 to escalate, not a cosmetic fix.

### Pattern 2: `try/catch` on non-throwing calls (5 fixes)

Locations:
- `Sources/EchoSightCore/Features/OcrPipeline.swift:194, 207` and `:312, 316`
- `Sources/EchoSightCore/Input/ModalInputCoordinator.swift:158, 160`

Same as the Sprint 2.2 Scene-Description fix documented in `findings.md ## SpeechOut Call-Site Convention`. The method being called is non-throwing; the `try` and surrounding `do`/`catch` are vestigial. Fix: drop `try`, drop the `do` wrapper, drop the `catch` block.

Each pair (194+207, 312+316, 158+160) is one call-site with `try <call>` + `catch {}`. Net edit per pair: remove 3–4 lines.

### Pattern 3: VisionDetector Dispatch/Sendable warnings (4 silenced)

Locations: `Sources/EchoSightCore/Detector/VisionDetector.swift:1, 180, 181, 183`.

All four trace to the `DispatchWorkItem + NSLock + didResume` timeout pattern that Sprint 2.1 P2#2 accepted as won't-fix (per `findings.md ## Phase 4 Execution Findings — Won't-fix items`). Fix: apply the compiler's own line-1 suggestion — annotate the Dispatch import as `@preconcurrency`:

```swift
@preconcurrency import Dispatch
```

This silences all 4 warnings. The underlying pattern is unchanged. When the timeout rewrite eventually happens (post-v0.1, when device CI exists), the `@preconcurrency` annotation can be removed.

## Files

| File | Fix |
|------|-----|
| `Sources/EchoSightCore/Detector/VisionDetector.swift` | `@preconcurrency import Dispatch` on line 1 |
| `Sources/EchoSightCore/Features/OcrPipeline.swift` | 2 `await` drops + 2 `try/catch` unwraps |
| `Sources/EchoSightCore/Features/SceneDescriptionPipeline.swift` | 2 `await` drops |
| `Sources/EchoSightCore/Observability/PipelineMetricsBuffer.swift` | 1 `await` drop |
| `Sources/EchoSightCore/Spatial/AnchorEventStream.swift` | 1 `await` drop |
| `Sources/EchoSightCore/Speech/SpeechOut.swift` | 1 `await` drop |
| `Sources/EchoSightCore/Input/ModalInputCoordinator.swift` | 1 `try/catch` unwrap |

## Tasks

1. `fix(sprint-4.4): drop redundant await on sync continuation registrations` — Pattern 1, one commit across all 5 files (OcrPipeline, SceneDescriptionPipeline, PipelineMetricsBuffer, AnchorEventStream, SpeechOut). Verify each removal is correct by inspecting the method signature of whatever is being awaited.
2. `fix(sprint-4.4): drop try/catch on non-throwing calls` — Pattern 2, one commit across OcrPipeline + ModalInputCoordinator.
3. `fix(sprint-4.4): silence Dispatch Sendable warnings in VisionDetector timeout path` — Pattern 3, one commit, single-line annotation. Commit message documents that this preserves the Sprint 2.1 P2#2 won't-fix decision.
4. Build verification: `xcodebuild … build 2>&1 | grep "warning:" | grep -v appintentsmetadataprocessor | wc -l` → expect `0`
5. Run `/code-review-pro` on the full Sprint 4.4 diff; fix any P0/P1
6. Merge worktree → main with `--no-ff`
7. Update `progress.md` Sprint 4.4 session entry + Spec Status row
8. Update `findings.md` Phase 4 Post-Audit Backlog — mark the "17 pre-existing warnings" entry as resolved, link to merge SHA

## Dependencies

- **Needs from:** `backlog-codereview` (4.1), `backlog-hig-warnings` (4.2), `quality-audits` (4.3) — 4.4 is the final sprint of Phase 4
- **Provides to:** v0.1 release readiness (Phase 5 / TestFlight / App Store submission)

## Notes for Phase-Runner

- This is cosmetic/compiler-hygiene work. There should be NO logic changes.
- If any `await` drop causes a build error, that means the underlying method IS actually async — do NOT drop the `await`; escalate via `needs_user_input` instead. The warning may be misleading.
- If the `@preconcurrency import Dispatch` doesn't silence all 4 VisionDetector warnings, investigate before forcing other changes — it's possible the compiler wants the annotation on a specific usage rather than the import itself.
- The 2 `appintentsmetadataprocessor` tool warnings are outside Swift-compiler scope and are NOT addressed in this sprint. Filter them out of the gate count.
- Commit messages should make clear that the VisionDetector change preserves the won't-fix decision and does NOT rewrite the timeout pattern.
