---
name: quality-audits
description: Run /test-review on Sprint 3.2 tests + /perf-review on v0.1 latency budgets, then fix any P0/P1 findings
phase: 4
sprint: 3
parent: root-spec
depends_on: [backlog-codereview, backlog-hig-warnings]
status: eng-reviewed
created: 2026-04-22
---

# Quality Audits (Sprint 4.3)

## Goal

Close the two audit gaps surfaced at the Phase 3 gate (S3.2-CLEANUP-2 and S3.2-CLEANUP-3). Produce two committed review artifacts that independently audit test quality and synthetic-workload performance against the v0.1 latency budgets. Fix any P0/P1 items the audits surface; defer P2/P3 to a post-v0.1 backlog.

## Requirements

- `/test-review` run against the 39 Sprint 3.2 tests (7 test files). Artifact committed at `.orchestrate/test-review.md`.
- `/perf-review` run against Sprint 3.2 pipelines with the v0.1 latency budgets as the pass threshold. Artifact committed at `.orchestrate/perf-review.md`.
- Any P0/P1 findings from either audit are fixed inside this sprint
- P2/P3 findings are logged in `findings.md` under a `## Phase 4 Post-Audit Backlog` subsection with rationale for deferral
- Build remains green throughout

## Latency Budgets (from manifest.md Success Criteria)

| Flow | Budget | Measured Where |
|------|--------|----------------|
| Chime on world-anchor novelty | ≤200 ms p95 | `AmbientAnnounceCoordinator` → `ChimeRenderer` |
| Recall gestalt (1st press) | ≤2 s p95 | `SpatialRecallOrchestrator` fire → gestalt speech start |
| Recall detail (2nd press) | ≤800 ms p95 | Gestalt completion → detail speech start |
| Silent-mid-flight cancel | ≤100 ms | Mode change during recall → all speech stopped |
| Scene description (fast path) | ≤1.5 s | Capture gesture → scene template speech |
| OCR (read mode) | ≤1.5 s p95 | Button press → first syllable |

`/perf-review` should synthesize representative fixtures for each flow and either measure or symbolically verify (via code inspection where fixtures can't be built) whether each budget holds.

## Acceptance Criteria

- [ ] `.orchestrate/test-review.md` committed; covers all 7 Sprint 3.2 test files (39 tests)
- [ ] `.orchestrate/perf-review.md` committed; covers all 6 latency budgets above
- [ ] All P0/P1 findings fixed with individual commits
- [ ] P2/P3 findings documented in `findings.md` Phase 4 Post-Audit Backlog section
- [ ] Build green after all fixes (0 warnings, 0 errors)
- [ ] `progress.md` Sprint 4.3 entry summarizes audit findings + fix commits

## Technical Approach

Two audits in sequence (test-review first — it often surfaces coverage gaps that influence perf-review fixture choices):

**Step 1 — `/test-review` on Sprint 3.2:**
- Target files: `SpatialRecallOrchestratorTests.swift`, `RecallGestaltFormatterTests.swift`, `NoveltyDetectorTests.swift`, `IdleTrackerTests.swift`, `AmbientAnnounceCoordinatorTests.swift`, `ModelVerifierTests.swift`, `ModelDownloaderTests.swift`
- Focus: assertion strength, failure-mode coverage, untested edge cases, overspecified tests that lock implementation
- Known gap: tests are written but never executed (visionOS sim-boot watchdog). Audit treats them as code-only; behavioral verification is out of scope here.
- Output: `.orchestrate/test-review.md` with per-file findings + severity levels

**Step 2 — `/perf-review` on Sprint 3.2 pipelines:**
- Target flows: the 6 latency budgets above
- Where real fixtures can't be built (chime audio dispatch, recall with ARKit anchors), use symbolic analysis: count sync operations on the critical path, flag any `@MainActor` blocks on non-trivial work, flag missing `Task.detached` for large I/O
- Code-review already caught the two P0 perf bugs (temp URL reclamation, 2 GB SHA on @MainActor) — audit should verify those fixes are complete and look for remaining patterns
- Output: `.orchestrate/perf-review.md` with per-flow budget assessment + findings

**Step 3 — Fix P0/P1 findings:**
- Each fix is its own commit with `fix(sprint-4.3): <area> — <short description>` message
- Any fix requiring architectural change escalates via `needs_user_input`; don't expand scope silently

**Step 4 — Defer P2/P3:**
- Add `## Phase 4 Post-Audit Backlog` to `findings.md` listing each P2/P3 with file:line + rationale for deferral to post-v0.1

## Files

| File | Purpose |
|------|---------|
| `.orchestrate/test-review.md` | new artifact (audit output) |
| `.orchestrate/perf-review.md` | new artifact (audit output) |
| `docs/plans/findings.md` | Phase 4 Post-Audit Backlog section |
| `Tests/EchoSightCoreTests/*.swift` | may be modified if audit finds P0/P1 test gaps |
| `Sources/EchoSightCore/**/*.swift` | may be modified if audit finds P0/P1 perf issues |

## Tasks

1. Run `/test-review` on 7 Sprint 3.2 test files; commit artifact
2. Triage test-review findings into P0/P1/P2/P3
3. Fix all P0/P1 test-review items with individual commits
4. Run `/perf-review` on 6 latency budgets + critical paths; commit artifact
5. Triage perf-review findings into P0/P1/P2/P3
6. Fix all P0/P1 perf-review items with individual commits
7. Update `findings.md` with Phase 4 Post-Audit Backlog (P2/P3 deferrals)
8. Re-run `xcodebuild build` to confirm still green
9. Update `progress.md` Sprint 4.3 entry

## Dependencies

- **Needs from:** `backlog-codereview` (Sprint 4.1) — audit on clean code
- **Needs from:** `backlog-hig-warnings` (Sprint 4.2) — warning-free baseline so audit output isn't noisy
- **Provides to:** Phase 4 close-out gate → ready for v0.1 release pipeline

## Notes for Phase-Runner

- `/test-review` and `/perf-review` are slash-command skills; invoke them via the Skill tool from the phase-runner context
- If the audit tools aren't available as skills in the phase-runner's environment, fall back to a subagent dispatch with an explicit prompt that mirrors the skill's intent
- Don't let audits spiral: the deliverable is two artifacts + P0/P1 fixes. Scope creep into P2/P3 fixes turns this sprint into v0.2 groundwork.
- If either audit surfaces a P0 that implies a design bug (not a code bug), escalate via `needs_user_input` — design changes don't belong in housekeeping
