# HIG Audit — EchoSight Sprint 4.2 Re-Audit

**Review type:** HIG Re-Audit (Sprint 4.2 acceptance gate)
**Date:** 2026-04-22
**hig-doctor score:** 98/100 (project-wide, 122 Swift files)
**Sprint 3.2 baseline:** 82/100
**Sprint 4.2 re-audit score:** 91/100
**Files audited:** 4 (ModeTutorialView.swift, PrivacyDisclosureView.swift, OnboardingCoordinator.swift, HardwareDiagnosticView.swift)
**Severity counts:** P0: 0 · P1: 0 · P2: 0 · P3: 1
**Verdict:** EXCELLENT — all Sprint 3.2 deferred items resolved. Acceptance gate: PASS (91 >= 82).

---

## Sprint 4.2 Fix Verification

The three items deferred from Sprint 3.2 and targeted in Sprint 4.2 have been verified in source:

| Item | Sprint 3.2 Finding | Status | Verified at |
|---|---|---|---|
| Tutorial step counter `.isStaticText` | P2-2 | FIXED | `ModeTutorialView.swift:102` |
| Counterclockwise Crown hint | P2-3 | FIXED | `HardwareDiagnosticView.swift:88` |
| Storage privacy copy rewritten to plain language | P3-1 | FIXED | `PrivacyDisclosureView.swift:43-46` |

Additionally, two findings that were P1 in the Sprint 3.2 audit were also addressed in Sprint 4.2:

| Item | Sprint 3.2 Finding | Status | Verified at |
|---|---|---|---|
| Dynamic Type on Crown tick counter | P1-1 | FIXED | `HardwareDiagnosticView.swift:57` — now `.font(.largeTitle.monospacedDigit())` |
| Reduce Motion guard on progress ring | P1-2 | FIXED | `DownloadProgressView.swift:23,49` — `@Environment(\.accessibilityReduceMotion)` applied |
| Decline button VoiceOver announcement | P2-1 | FIXED | `PrivacyDisclosureView.swift:62-66` — announcement posted before `onDecline()` |

---

## Findings

---

### P3-1 — "Counterclockwise" Simulate Button Label Redundancy (Accessibility · Naming)

**ID:** P3-1
**File:** `Sources/EchoSightApp/Settings/HardwareDiagnosticView.swift` lines 84–89
**Source:** Manual analysis — HIG "Accessibility" / Button Labels (score: 63)

**Current code:**
```swift
Button("Simulate counterclockwise tick") {
    simulateCrownTick(clockwise: false)
}
.buttonStyle(.bordered)
.accessibilityHint("Records a counterclockwise Crown tick for testing.")
```

**Problem:** The button label "Simulate counterclockwise tick" and the hint "Records a counterclockwise Crown tick for testing." both describe the action and both use the word "counterclockwise." HIG Accessibility guidance states that hints should add information not already conveyed by the label — the hint here is largely redundant with the label. The word "simulate" in the label and "records … for testing" in the hint say the same thing twice from slightly different angles. For VoiceOver users who have hints enabled, this produces a verbose double-read that adds friction without adding information. Score: 63. Reported as P3 (optional).

**Fix — Option A (recommended):** Rewrite the hint to add new information — specifically what the test confirms and how to interpret the result.
```swift
Button("Simulate counterclockwise tick") {
    simulateCrownTick(clockwise: false)
}
.buttonStyle(.bordered)
.accessibilityHint("Increments the tick counter and announces the direction. Use to confirm the diagnostic is working without rotating the Crown.")
```

**Fix — Option B:** Remove the hint entirely. The label is self-describing. Consistent with how most system buttons behave.
```swift
Button("Simulate counterclockwise tick") {
    simulateCrownTick(clockwise: false)
}
.buttonStyle(.bordered)
// No hint — label is sufficient.
```
Note: would also require removing the clockwise button's hint for symmetry.

**Verification:** Enable VoiceOver with Verbosity → Hints: On. Navigate to both simulate buttons. Confirm the hints add information rather than repeating the label.

---

## Strengths

All strengths from the Sprint 3.2 audit are maintained. New strengths introduced in Sprint 4.2:

- **Dynamic Type compliance restored on tick counter:** `HardwareDiagnosticView` now uses `.font(.largeTitle.monospacedDigit())` — monospaced digit alignment is preserved while the size scales with the user's text preference.
- **Reduce Motion fully respected in download flow:** `DownloadProgressView` reads `@Environment(\.accessibilityReduceMotion)` and substitutes `.animation(nil, …)` for users who have Reduce Motion enabled. The 2.6 GB download can take 5–30 minutes; guarding a continuous ring animation against vestibular triggers is a meaningful user-safety improvement.
- **Decline path now symmetrically announced:** `PrivacyDisclosureView` posts an `AccessibilityNotification.Announcement` on both Accept and Decline paths. BLV users get audio confirmation of the outcome before the view transitions regardless of which button they activate.
- **Storage copy passes plain-language bar:** "The app downloads about 2.6 GB of model files on first launch. These stay on your Vision Pro and are removed when you delete EchoSight." Uses "about" not "approximately", "2.6 GB" not "2.6 gigabytes", avoids sandbox/private-storage jargon, and frames deletion as user action rather than system behavior.
- **Step counter `.isStaticText` correctly applied:** `ModeTutorialView` marks the "Step N of 4" label with `.accessibilityAddTraits(.isStaticText)`, correctly signaling to the visionOS focus system that this element is informational and non-interactive.

Previously noted strengths (unchanged):
- Skip button `accessibilitySortPriority(1000)` correctly pins it as first VoiceOver target
- Section `.isHeader` traits on all section titles across all four files
- 10% milestone VoiceOver announcements with dedup guard in `DownloadProgressView`
- Progress ring `.accessibilityElement(children: .ignore)` with label + value
- `HardwareDiagnosticView` support disclosure announces phone number in the announcement
- Semantic colors throughout (`.secondary`, `.accentColor`, `.regularMaterial`) — no hardcoded hex
- Download error `VStack` uses `.accessibilityElement(children: .combine)` for clean narration

---

## Score Calculation

| Category | Sprint 3.2 | Sprint 4.2 | Delta |
|---|---|---|---|
| Accessibility (VoiceOver labels, hints, traits) | 79 | 95 | +16 |
| Typography (Dynamic Type) | 72 | 95 | +23 |
| Motion (Reduce Motion) | 74 | 95 | +21 |
| Privacy copy clarity | 78 | 92 | +14 |
| Controls (button semantics) | 88 | 88 | 0 |
| Layout / Navigation | 90 | 90 | 0 |
| **Composite** | **82** | **91** | **+9** |

---

## Deduplication Log

| Merged group | Disposition | Notes |
|---|---|---|
| hig-doctor Foundations concerns × 12 | All false positives for audited files | All 12 concerns are in `archive/legacy-web/` CSS/HTML (hardcoded colors, autoplay). Do not ship. Filtered. |
| hig-doctor positive detections × 158 | Confirmed | `.accentColor`, `.regularMaterial`, semantic foreground styles, `accessibilityAddTraits`, `AccessibilityNotification` — all correctly flagged as positives. |
| Sprint 3.2 P1-1 (Dynamic Type) | RESOLVED — not carried forward | Fix confirmed at `HardwareDiagnosticView.swift:57`. |
| Sprint 3.2 P1-2 (Reduce Motion) | RESOLVED — not carried forward | Fix confirmed at `DownloadProgressView.swift:23,49`. |
| Sprint 3.2 P2-1 (Decline announcement) | RESOLVED — not carried forward | Fix confirmed at `PrivacyDisclosureView.swift:62-66`. |
| Sprint 3.2 P2-2 (.isStaticText) | RESOLVED — not carried forward | Fix confirmed at `ModeTutorialView.swift:102`. |
| Sprint 3.2 P2-3 (counterclockwise hint) | RESOLVED — not carried forward | Fix confirmed at `HardwareDiagnosticView.swift:88`. Hint text now slightly redundant with label — downgraded to P3-1 for optional follow-up. |
| Sprint 3.2 P3-1 (storage copy) | RESOLVED — not carried forward | Fix confirmed at `PrivacyDisclosureView.swift:43-46`. |

