# HIG Audit — EchoSight visionOS 2.0 Onboarding + Settings

**Review type:** HIG Audit (Accessibility · Layout · Privacy Copy · visionOS HIG)
**Date:** 2026-04-22
**hig-doctor score:** 98/100 (project-wide); target-file score after manual analysis: **82/100**
**Files audited:** 4
**Severity counts:** P0: 0 · P1: 2 · P2: 3 · P3: 1
**Verdict:** GOOD — solid accessibility foundation, two high-priority gaps that should ship fixed.

---

## Findings

---

### P1-1 — Fixed Font Size on Crown Tick Counter (Typography · Accessibility)

**ID:** P1-1
**File:** `Sources/EchoSightApp/Settings/HardwareDiagnosticView.swift` line 55
**Source:** hig-doctor — Foundations / Typography (flagged as `⚠ concern`)

**Current code:**
```swift
Text("\(crownTicks)")
    .font(.system(size: 48, weight: .bold, design: .monospaced))
    .contentTransition(.numericText())
    .accessibilityLabel("Crown rotation ticks")
    .accessibilityValue("\(crownTicks) ticks, \(crownDirection)")
```

**Problem:** `.font(.system(size: 48, …))` hard-codes the point size instead of using a Dynamic Type text style. On visionOS, users with larger accessibility text sizes configured in Accessibility Settings will not see this label scale. HIG "Typography" requires that all user-facing text participate in Dynamic Type unless it is purely decorative. The tick counter is a live, meaningful value — a user who relies on large text to read the Apple Vision Pro display cannot use this diagnostic screen effectively. This is a real-user impact gap (score: 83).

**Fix — Option A (recommended):** Replace with a Dynamic Type style and use a `monospacedDigit()` trait to preserve the numeric alignment without fixing the size.
```swift
Text("\(crownTicks)")
    .font(.largeTitle.monospacedDigit())
    .fontWeight(.bold)
    .contentTransition(.numericText())
    .accessibilityLabel("Crown rotation ticks")
    .accessibilityValue("\(crownTicks) ticks, \(crownDirection)")
```
`.largeTitle` is the closest semantic equivalent at ~34 pt default. The `.monospacedDigit()` modifier retains fixed-width digit rendering (same visual character as `.design: .monospaced`) without locking the size.

**Fix — Option B:** Keep `.font(.system(size: 48, …))` but add `.dynamicTypeSize(.accessibility5)` support via `@ScaledMetric`:
```swift
@ScaledMetric(relativeTo: .largeTitle) private var tickFontSize: CGFloat = 48
// then:
.font(.system(size: tickFontSize, weight: .bold, design: .monospaced))
```
More verbose but preserves the exact monospaced design token. Requires `@ScaledMetric` declared in the View struct.

**Verification:** Open Accessibility Settings on visionOS simulator → Larger Text → drag to maximum. Verify the tick counter scales. VoiceOver reads the value via `accessibilityValue` regardless — confirm it announces "X ticks, Clockwise" correctly.

---

### P1-2 — Progress Ring Animation Not Guarded by Reduce Motion (Accessibility · Motion)

**ID:** P1-2
**File:** `Sources/EchoSightApp/Onboarding/DownloadProgressView.swift` line 47
**Source:** Manual analysis — HIG "Motion" / visionOS Accessibility

**Current code:**
```swift
Circle()
    .trim(from: 0, to: downloader.overallProgress)
    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
    .rotationEffect(.degrees(-90))
    .animation(.linear(duration: 0.5), value: downloader.overallProgress)
```

**Problem:** The `DownloadProgressView` is displayed for the entire 2.6 GB download — potentially 5-30 minutes of continuous animation for users on slow connections. The progress ring uses `.animation(.linear(duration: 0.5), …)` with no Reduce Motion check. Apple HIG (visionOS Motion) states: "Avoid continuous animations that play throughout an extended experience." For users with vestibular disorders who enable Reduce Motion, the persistent circular animation is a known trigger. Score: 81.

**Fix — Option A (recommended):** Read `@Environment(\.accessibilityReduceMotion)` and substitute an instant snap when Reduce Motion is on.
```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// In the Circle trim:
Circle()
    .trim(from: 0, to: downloader.overallProgress)
    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
    .rotationEffect(.degrees(-90))
    .animation(
        reduceMotion ? .none : .linear(duration: 0.5),
        value: downloader.overallProgress
    )
```

**Fix — Option B:** Replace the ring entirely with a system `ProgressView(value:)` when Reduce Motion is enabled. System progress views automatically respect Reduce Motion.
```swift
if reduceMotion {
    ProgressView(value: downloader.overallProgress)
        .progressViewStyle(.linear)
        .padding(.horizontal, 32)
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(downloader.overallProgress * 100)) percent downloaded")
} else {
    // existing ZStack ring
}
```

**Verification:** Enable Settings → Accessibility → Motion → Reduce Motion on the visionOS simulator. Run the download flow. Confirm the ring snaps to new values rather than animating continuously. VoiceOver announcement of milestones should be unaffected.

---

### P2-1 — Decline Button Missing Announcement on Activation (Accessibility · Privacy)

**ID:** P2-1
**File:** `Sources/EchoSightApp/Onboarding/PrivacyDisclosureView.swift` lines 61-67
**Source:** Manual analysis — HIG "Accessibility" / Privacy Decline Path

**Current code:**
```swift
Button("Decline") {
    onDecline()
}
.buttonStyle(.bordered)
.accessibilityLabel("Decline")
.accessibilityHint("You cannot use EchoSight without accepting these terms.")
```

**Problem:** The Accept button correctly posts an `AccessibilityNotification.Announcement` ("Privacy accepted. Download starting.") before calling `onAccept()`. The Decline button fires `onDecline()` with no announcement. For a BLV user, after activating Decline, the flow transitions (app stays in onboarding state, view is dismissed) with no audio confirmation that the action completed. The privacy decline path is a critical accessibility escape — the user must be able to confirm they successfully declined, especially since the consequence (app stays locked) is significant. Score: 74.

**Fix — Option A (recommended):** Add an `AccessibilityNotification.Announcement` before calling `onDecline()`, mirroring the Accept button pattern.
```swift
Button("Decline") {
    AccessibilityNotification.Announcement(
        "Privacy terms declined. EchoSight will not download models. You can accept next time you open the app."
    ).post()
    onDecline()
}
.buttonStyle(.bordered)
.accessibilityLabel("Decline privacy terms")
.accessibilityHint("EchoSight requires these terms to function. You can accept on next launch.")
```
Note: also improves `accessibilityLabel` from bare "Decline" to "Decline privacy terms" for rotor-navigation disambiguation.

**Fix — Option B:** Do nothing. The transition itself may generate a VoiceOver focus change announcement, but it is platform-specific and unpredictable across visionOS versions. Not recommended.

**Verification:** Enable VoiceOver. Navigate to the Decline button. Activate it. VoiceOver should announce the message before the view transitions. Confirm the next focus target is appropriate (onboarding root, or whatever `onDecline()` surfaces).

---

### P2-2 — Step Progress Dots Inaccessible to Sighted Keyboard / Focus Navigation (Accessibility · visionOS Focus)

**ID:** P2-2
**File:** `Sources/EchoSightApp/Onboarding/ModeTutorialView.swift` lines 145-153
**Source:** Manual analysis — HIG "Focus System" / visionOS Input

**Current code:**
```swift
// Step progress dots
HStack(spacing: 8) {
    ForEach(0..<steps.count, id: \.self) { i in
        Circle()
            .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
    }
}
.accessibilityHidden(true)
```

**Problem:** The progress dots are correctly `accessibilityHidden(true)` for VoiceOver (they'd be noise). However, the step counter `Text("Step \(currentStep + 1) of \(steps.count)")` at line 98-101 provides the same information in text form and is also VoiceOver-exposed. This is good. The gap is that neither the dots nor the step counter has an `accessibilityElement(children: .combine)` group, so as a user navigates the tutorial with eye-and-pinch focus, the "Step 1 of 4" text is exposed as a focusable element that has no interactive affordance — it's purely status. On visionOS this can produce a focus stop with no action and a generic highlight. Score: 71.

**Fix — Option A (recommended):** Mark the step counter as non-interactive by adding `.accessibilityElement(children: .ignore)` is wrong here (it'd hide the text). Instead mark it with `.accessibilityAddTraits(.isStaticText)` so the focus system treats it as informational and may skip it in sequential focus:
```swift
Text("Step \(currentStep + 1) of \(steps.count)")
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Step \(currentStep + 1) of \(steps.count)")
    .accessibilityAddTraits(.isStaticText)
```
The `.isStaticText` trait is the correct HIG signal for non-interactive status labels.

**Fix — Option B:** Group the step label and dots into a single accessibility element using `.accessibilityElement(children: .combine)` on the VStack that contains them. Simpler but combines unrelated views.

**Verification:** On visionOS simulator with VoiceOver off, test eye-and-pinch navigation through the tutorial. Confirm the step counter does not consume a focus stop with a confusing highlight. With VoiceOver on, confirm it reads "Step 1 of 4" exactly once, not duplicated.

---

### P2-3 — "Counterclockwise" Simulate Button Missing accessibilityHint (Accessibility · Controls)

**ID:** P2-3
**File:** `Sources/EchoSightApp/Settings/HardwareDiagnosticView.swift` lines 81-85
**Source:** Manual analysis — HIG "Accessibility" / Controls

**Current code:**
```swift
Button("Simulate counterclockwise tick") {
    simulateCrownTick(clockwise: false)
}
.buttonStyle(.bordered)
```

**Problem:** The "Simulate clockwise tick" button at line 75-80 has `.accessibilityHint("Records a clockwise Crown tick for testing.")`. The adjacent "Simulate counterclockwise tick" button has no hint at all. Both buttons have identical visible labels except for the direction word. Without a matching hint, a VoiceOver user who has hints enabled (the default for new users) gets inconsistent behavior — one button reads its hint, the other does not. Score: 72.

**Fix — Option A (recommended):** Add the matching hint.
```swift
Button("Simulate counterclockwise tick") {
    simulateCrownTick(clockwise: false)
}
.buttonStyle(.bordered)
.accessibilityHint("Records a counterclockwise Crown tick for testing.")
```

**Fix — Option B:** Remove the hint from the clockwise button so both are consistent (bare label only). Less informative but at least symmetric.

**Verification:** Enable VoiceOver with hints turned on (Settings → Accessibility → VoiceOver → Verbosity → Hints: On). Navigate to both simulate buttons. Both should announce their respective hints after a pause.

---

### P3-1 — Privacy Copy Uses Technical Storage Framing (Privacy Copy Clarity)

**ID:** P3-1
**File:** `Sources/EchoSightApp/Onboarding/PrivacyDisclosureView.swift` lines 43-46
**Source:** Manual analysis — HIG "Privacy" / Copy Clarity (score: 62)

**Current code:**
```swift
privacySection(
    heading: "Storage",
    body: "The app downloads approximately 2.6 gigabytes of model files on first launch. These are stored in the app's private storage and can be removed by deleting EchoSight."
)
```

**Problem:** "app's private storage" is developer terminology. A user unfamiliar with sandboxing may not understand what this means or how it relates to their device storage. HIG Privacy guidance recommends "plain, direct language people can understand" and specifically flags jargon like "private storage," "sandbox," and "application bundle." The phrase "can be removed by deleting EchoSight" also implies the only way to reclaim space is full app deletion, which is accurate but may alarm users unnecessarily. Score: 62 — below the P2 threshold, reported as P3.

**Fix — Option A (recommended):** Rewrite to plain language that names the storage location users are familiar with.
```swift
privacySection(
    heading: "Storage",
    body: "EchoSight downloads about 2.6 GB of AI model files the first time you open it. These files are stored on your Apple Vision Pro and count toward your device storage. To free the space, delete EchoSight from your device."
)
```
Changes: "approximately 2.6 gigabytes" → "about 2.6 GB" (numerals + abbreviation match HIG style); "app's private storage" → "on your Apple Vision Pro"; "removing EchoSight" rephrased as "delete EchoSight from your device" (action-oriented).

**Fix — Option B:** Do nothing. The current copy is accurate and not incorrect — just slightly technical. Will not affect App Store review.

**Verification:** Read the copy aloud. Confirm a non-technical user understands: (a) how much space is used, (b) where it lives, (c) how to recover it.

---

## Strengths

- **Skip button VoiceOver priority:** `ModeTutorialView` implements `accessibilitySortPriority(1000)` on the skip button correctly. This is the required pattern for pinned eng-review gate. The skip button is the first element in the VoiceOver swipe order and posts an `AccessibilityNotification.Announcement` before transitioning.
- **Section headings throughout:** All four files use `.accessibilityAddTraits(.isHeader)` on every section title. This enables VoiceOver rotor "Headings" navigation across all onboarding screens — a strong BLV UX signal.
- **10% milestone announcements:** `ModelDownloader` correctly computes `lastMilestonePercent` using integer division (10% granularity) and `DownloadProgressView` wires `downloader.onProgressMilestone` in `.onAppear` to post `AccessibilityNotification.Announcement` with the entry display name and milestone percentage. The `lastAnnouncedMilestone` dedup guard is in place.
- **Progress ring accessibility element:** The `ZStack` progress ring correctly applies `.accessibilityElement(children: .ignore)` with `.accessibilityLabel` and `.accessibilityValue`, preventing VoiceOver from reading the interior `Text` children separately.
- **Hardware diagnostic escape path:** `HardwareDiagnosticView` is reachable from Settings at all times, does not gate on any state, provides both simulate buttons and a "Show support information" disclosure. The `AccessibilityNotification.Announcement` on support disclosure includes the support phone number directly. The escape path is fully VoiceOver-accessible.
- **Semantic colors used consistently:** All four files use `.foregroundStyle(.secondary)`, `.accentColor`, and `.regularMaterial` — no hardcoded hex colors in the audited Swift files. (Legacy web CSS concerns from hig-doctor are correctly scoped to `archive/` and do not ship.)
- **Download error state combined:** The failure `VStack` uses `.accessibilityElement(children: .combine)` — the error icon + message are read as a single unit, preventing choppy VoiceOver narration.
- **Privacy accept announcement:** `PrivacyDisclosureView` posts "Privacy accepted. Download starting." before calling `onAccept()`, giving the BLV user context before the view transitions to `DownloadProgressView`.

---

## Deduplication Log

| Merged group | Representative finding | Count | Notes |
|---|---|---|---|
| hig-doctor hardcoded color — CSS | Not promoted | 7 | All in `archive/legacy-web/`. Does not ship. Filtered as false positive (platform exclusion: web archive). |
| hig-doctor video autoplay — HTML | Not promoted | 1 | `archive/legacy-web/`. Does not ship. Filtered. |
| hig-doctor `.font(.system(size:))` | P1-1 | 1 | Only one instance in audited files. `HardwareDiagnosticView.swift:55`. |
| Multiple `foregroundStyle(.secondary)` detections | Not promoted | ~30 | All correct semantic color usage. True positives for the pattern, false positives for concerns. Filtered. |

