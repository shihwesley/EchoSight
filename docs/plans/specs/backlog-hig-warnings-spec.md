---
name: backlog-hig-warnings
description: Clear deferred HIG items + eliminate the 3 build warnings carried from Sprint 3.2
phase: 4
sprint: 2
parent: root-spec
depends_on: [backlog-codereview, ambient-announce, onboarding-download, spatial-recall]
status: eng-reviewed
created: 2026-04-22
---

# HIG + Build-Warnings Cleanup (Sprint 4.2)

## Goal

Get `xcodebuild` back to a true **0 warnings, 0 errors** state and clear the 3 HIG P2/P3 accessibility deferrals that landed during Sprint 3.2's HIG audit. After this sprint, the project is warning-clean and every BLV-user-visible accessibility affordance meets the audit's P1/P2 bar.

## Requirements

- All 3 S3.2-CLEANUP-1 build warnings resolved
- All 3 deferred HIG items resolved (or marked "won't fix" with rationale if one is out of scope)
- Post-fix `xcodebuild -scheme EchoSight -destination 'generic/platform=visionOS' build` exits 0 with **0 new warnings** (and ideally 0 total; any remaining warnings must be audited and logged)
- HIG re-audit via `/hig-audit` on the onboarding + settings surfaces scores ≥ 82/100 (the Sprint 3.2 baseline)

## Acceptance Criteria

- [ ] `grep -c "warning:"` on `xcodebuild` output = 0
- [ ] `grep -c "error:"` on `xcodebuild` output = 0
- [ ] Tutorial step counter emits `.isStaticText` (verified by inspecting view hierarchy or manual VoiceOver walkthrough)
- [ ] Counterclockwise button in `HardwareDiagnosticView` has `accessibilityHint`
- [ ] Storage privacy copy rewritten in plain language (no "app's private storage" / developer jargon)
- [ ] `/hig-audit` re-run artifact committed at `.orchestrate/hig-audit-phase4.md`
- [ ] `progress.md` Sprint 4.2 entry documents before/after warning counts and HIG score

## Technical Approach

Five mechanical fixes + one audit:

1. `ChimeRenderer.swift:67` — `playerNode.scheduleBuffer(buffer, completionHandler: nil)` has an async alternative. Replace with `await playerNode.scheduleBuffer(buffer)` or appropriate Swift 6 pattern inside the existing async context.
2. `SpatialRecallOrchestrator.swift:256` + `:346` — unused `SpeechToken` return value from `speakAction(...)`. Either assign to `_ =` with an explanatory comment or track the token if its lifecycle matters for cancellation. Needs a sanity check: if the token is needed for `.cancel(ownToken)` per the speech-out priority contract, track it properly; otherwise `_ =` is fine.
3. Tutorial step counter — add `.accessibilityAddTraits(.isStaticText)` to the counter text view.
4. Counterclockwise button — add `.accessibilityHint("Reverses the last Crown rotation")` (or whatever matches the control's actual behavior).
5. Storage privacy copy — rewrite from "app's private storage" to plain-language alternative. Suggested: "Stays on your Vision Pro. Nothing is sent to servers." Keep under the existing character limit so layout doesn't shift.
6. Re-run `/hig-audit` on the changed surfaces; commit the artifact.

## Files

| File | Source |
|------|--------|
| `Sources/EchoSightCore/Audio/ChimeRenderer.swift` | S3.2-CLEANUP-1 (warning 1) |
| `Sources/EchoSightCore/Features/SpatialRecallOrchestrator.swift` | S3.2-CLEANUP-1 (warnings 2, 3) |
| `Sources/EchoSightApp/Onboarding/TutorialView.swift` (or similar) | S3.2-HIG-P2-3 |
| `Sources/EchoSightApp/Diagnostics/HardwareDiagnosticView.swift` | S3.2-HIG-P2-2 |
| `Sources/EchoSightApp/Onboarding/PrivacyStepView.swift` (or similar) | S3.2-HIG-P3-1 |
| `.orchestrate/hig-audit-phase4.md` | new artifact |

Exact file paths for the HIG-item targets may differ; search by view name if the initial guess misses.

## Tasks

1. Fix `ChimeRenderer.swift:67` async alternative warning
2. Fix `SpatialRecallOrchestrator.swift:256` + `:346` unused-return warnings (decide per call-site whether `_ =` or token-tracking is correct)
3. Verify warning count is now 0 via `xcodebuild … build 2>&1 | grep -c "warning:"`
4. Add `.isStaticText` trait to tutorial step counter
5. Add `accessibilityHint` to counterclockwise button
6. Rewrite Storage privacy copy in plain language
7. Run `/hig-audit` on onboarding + settings flows; commit artifact to `.orchestrate/hig-audit-phase4.md`
8. Update `progress.md` Sprint 4.2 entry with warning-count diff and HIG score comparison

## Dependencies

- **Needs from:** `backlog-codereview` (Sprint 4.1) — cleaner codebase to audit against
- **Provides to:** Sprint 4.3 (clean build + clean accessibility before `/test-review` and `/perf-review`)

## Notes for Phase-Runner

- The ChimeRenderer fix requires checking whether the enclosing function is already `async`. If not, the right fix is `_ = ` + a TODO for a full async migration in a later sprint; forcing async up the call stack is out of scope for housekeeping.
- If `/hig-audit` surfaces new P1 items, fix them before closing the sprint. New P2/P3 items get deferred and logged.
- Warning-count is measured via raw `xcodebuild` output parsing; do not trust `xcbeautify` summary counts — they collapse warnings across files.
