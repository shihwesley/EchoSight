---
name: onboarding-download
description: First-launch 2.6 GB model download with VoiceOver progress + privacy disclosure + mode tutorial
phase: 3
sprint: 2
parent: root-spec
depends_on: [root, detector, gemma-enrichment, modal-input, observability]
status: eng-reviewed
created: 2026-04-21
---

# Onboarding Download Spec

## Goal

First-launch onboarding flow that downloads all v0.1 model weights, discloses privacy posture (Photos album pollution, on-device inference), and gates app entry behind successful download. Accessible entirely via VoiceOver.

## Requirements

- Download targets: Gemma 4 E2B Q4 (~2 GB), Core ML YOLO (~30 MB), WhisperKit small-multi placeholder (~240 MB reserved for v1.0)
- `NSURLSession` background download with resume support
- VoiceOver-announced progress at 10% increments
- WiFi-only option (default on, user can override)
- Retry + resume on network failure
- Privacy disclosure screen explains:
  - Screenshots go into "EchoSight Captures" album; user can clear anytime
  - All inference on-device, zero network calls after download
  - Models occupy ~2.6 GB of device storage
- Cannot enter main app until download complete + privacy accepted
- Downloaded models verified by SHA-256 before first use

**New under CEO review expansion (revised in Eng Review Gate 7):**
- Mode tutorial screen (post-download, pre-app-entry) that teaches the Crown-cycles-modes + Button-fires model:
  - Demonstrates each mode (scene / recall / read / silent) with an example spoken prompt
  - **Non-gating:** persistent "Skip tutorial and enter app" button is the first VoiceOver focus target on screen entry. Skip is always available.
  - Uses real `modal-input` events so successful completion validates the hardware chain, but successful completion is not required to proceed
  - Same tutorial reachable from Settings for refresh
  - Eng-review rationale: an accessibility product must never trap its user. Forced-learning UX is anti-accessibility-ethos. Users with cognitive / memory accommodations may fail the sequence repeatedly.

**New under Eng Review Gate 7:**
- Settings > Hardware Diagnostic view — exercises Crown rotation + Capture Button with live feedback. Not required to enter the app. Escape hatch for users who suspect hardware failure.

## Acceptance Criteria

- [ ] Clean install → user walks through onboarding with VoiceOver only, no sighted help
- [ ] Download resumes across app kill + relaunch
- [ ] SHA-256 mismatch deletes partial file + restarts download
- [ ] WiFi-only toggle respected (no cellular download when enabled)
- [ ] Privacy copy reviewed against HIG accessibility guidance
- [ ] Progress announcements fire at 10/20/.../100%
- [ ] Tutorial Skip button is the first VoiceOver focus target and is available from tutorial entry
- [ ] Skipping tutorial enters the app immediately; tutorial is accessible from Settings > Tutorial
- [ ] Settings > Hardware Diagnostic view exercises Crown + Button with live feedback

## Technical Approach

Custom `URLSessionConfiguration.background(withIdentifier:)` session with `URLSessionDownloadTask`. Resume data persisted between launches. Model manifest (URLs + expected SHAs) ships in the app bundle. VoiceOver announcements via `UIAccessibility.post(notification: .announcement, argument:)`.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Download/ModelManifest.swift` | URLs, SHAs, sizes |
| `Sources/EchoSightCore/Download/ModelDownloader.swift` | Background URLSession, resume |
| `Sources/EchoSightCore/Download/ModelVerifier.swift` | SHA-256 check |
| `Sources/EchoSightApp/Onboarding/DownloadProgressView.swift` | VoiceOver-first progress UI |
| `Sources/EchoSightApp/Onboarding/PrivacyDisclosureView.swift` | Accessible disclosure copy |
| `Sources/EchoSightApp/Onboarding/ModeTutorialView.swift` | Mode tutorial (non-gating; Skip button first focus) |
| `Sources/EchoSightApp/Onboarding/OnboardingCoordinator.swift` | Screen flow: disclosure → download → verify → tutorial (optional) → enter app |
| `Sources/EchoSightApp/Settings/HardwareDiagnosticView.swift` | Live Crown + Button feedback (new, Eng Review Gate 7) |
| `Sources/EchoSightApp/Settings/TutorialRefreshView.swift` | Tutorial reachable from Settings (new) |
| `Tests/EchoSightCoreTests/ModelDownloaderTests.swift` | Resume + retry behavior |
| `Tests/EchoSightCoreTests/ModelVerifierTests.swift` | SHA checks |

## Tasks

1. Define `ModelManifest` with v0.1 model URLs + expected SHAs
2. Implement `ModelDownloader` background session + resume
3. Implement `ModelVerifier`
4. Build `PrivacyDisclosureView` with BLV-audited copy
5. Build `DownloadProgressView` with VoiceOver announcements
6. Build `ModeTutorialView` exercising all 4 modes (new)
7. Wire `OnboardingCoordinator` (gate → disclosure → download → verify → tutorial → enter app)
8. VoiceOver walk-through audit including tutorial
9. Unit tests for downloader + verifier

## Dependencies

- **Needs from:** root, detector (YOLO model path expectations), gemma-enrichment (Gemma weight path expectations), modal-input (tutorial drives real mode events)
- **Provides to:** none (terminal spec for v0.1)

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** Added mode tutorial screen to onboarding flow. v0.1 now has four distinct user-triggered modes plus a passive surface — users cannot be expected to discover Crown-cycles-modes without explicit instruction. Tutorial uses real `modal-input` events (not a simulation), so successful completion proves the hardware input chain works end-to-end before the user hits feature code.
- **Premise validation:** 2.6 GB first-launch download held. SHA verification held. WiFi-only default held. Adding the tutorial stretches "onboarding" but not by much — it's ~2-3 screens and one gesture-exercise loop.

### Dream State Delta
At 12-month ideal, there's no tutorial — mode switching is predictive. For v0.1, the tutorial is scaffolding. Design the tutorial as a *retired-in-v1.0* screen rather than a permanent fixture (i.e., don't build deep customization into it; it will be replaced).

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| Download | Cellular trickle when user forgot WiFi-only | 4+ hours to complete | WiFi-only default | Yes |
| SHA mismatch | Model file corrupt at source | Loop restart | Verifier tests | Yes |
| Resume | Background session dies mid-download | Retry from zero | Acceptance criterion | Partial |
| Hardware non-responsive | Crown / Button unresponsive in diagnostic | Printed / spoken support contact + escape to Settings always available | Diagnostic view test | Yes |
| Gemma manifest | Weight URL 404s on day of launch | Cannot onboard | Manifest hosting plan needed (ops concern) | No |

### Deferred Work
- [ ] Progressive download (Layer 1 + YOLO on first launch; Gemma on-demand) — v1.0 bandwidth-friendly mode
- [ ] Over-the-air model updates post-install — v1.0+ when model iteration cadence matters
- [ ] Multi-language privacy / tutorial copy — v1.0 internationalization

## Eng Review

- **Depth:** BIG
- **Scope changes (Gate 7):**
  - Tutorial is non-gating. Hard gates: download + privacy + SHA verify only.
  - Persistent "Skip tutorial and enter app" button is first VoiceOver focus target on screen entry.
  - Hardware validation moved to Settings > Hardware Diagnostic view (not part of onboarding flow).
  - Removed acceptance criteria: "must complete mode-switch + button-press cycle"; "rotor-skip gesture documented/testable"
  - Added acceptance criteria for tutorial skip + diagnostic view.
  - Failure mode "Tutorial stuck / locked out" deleted — architecturally eliminated by non-gating design.

### Data Flow

```
 First launch
  │
  ▼
 OnboardingCoordinator
  │
  ├─ Privacy disclosure (HARD GATE) ───── accepted? yes → continue
  │                                        no → cannot proceed
  │
  ├─ Download (HARD GATE) ──────────────── SHA verified? yes → continue
  │                                         no → restart download
  │
  ├─ Tutorial (SOFT, non-gating)
  │   │ Skip button = first VO focus
  │   │ Live modal-input events exercised
  │   │ User can skip at any time
  │   │
  │   ├─ Skip → app entry
  │   └─ Complete → app entry
  │
  ▼
 App main experience
  │
  └─ Settings available anytime:
     ├─ Re-run Tutorial
     ├─ Hardware Diagnostic (Crown + Button live feedback)
     └─ Re-read Privacy Disclosure
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Fresh install | Manual (BLV tester) | VO-only walk: privacy → download → tutorial (skip or complete) → app | Download fails → retry; privacy declined → cannot proceed | Cellular-only device + WiFi-only on → clear message |
| Download resume | Integration | Kill app mid-download → relaunch → resumes | Background session dies → retry from zero | 100 MB in, network changes WiFi→cellular with WiFi-only on → pause |
| SHA verify | Unit | Match → proceed | Mismatch → delete + retry | Partial file on disk → restart cleanly |
| Tutorial skip | UI test | Skip button VO-focused first; tap → enter app | Skip during speech demo → cancels speech + enters | Tap Skip immediately on tutorial entry → works |
| Tutorial complete | Integration | Mode-switch + button-press cycle → speech confirmation → enter app | User struggles → Skip always visible | — |
| Hardware diagnostic | UI test | Crown rotation shows live tick count; Button press logs timestamp | Non-responsive hardware → printed support info + escape to Settings | Diagnostic accessible regardless of onboarding state |
| Privacy decline | UI test | Cannot proceed; can quit app | — | Accept after decline → resumes |

### Critical Paths

- SHA verification prevents corrupted-weight app start (avoids downstream Gemma failures that would look like app bugs)
- Tutorial non-gating eliminates the "user trapped" failure mode
- Hardware Diagnostic in Settings is always reachable (belt-and-suspenders over tutorial)

### Observability

- **Log category:** `echosight.download`
- **Key events:**
  - `download.started(targetBytes)` / `download.progress(pct, ageSec)`
  - `download.paused` / `download.resumed`
  - `download.completed(totalDurationSec)`
  - `download.shaVerify.success(fileName)` / `download.shaVerify.failed(fileName)`
  - `privacy.accepted` / `privacy.declined`
  - `tutorial.entered` / `tutorial.skipped` / `tutorial.completed(durationSec)`
  - `tutorial.mode.demonstrated(mode)`
  - `hardware.diagnostic.entered`
  - `hardware.diagnostic.crown.tick(count)` / `hardware.diagnostic.button.pressed`
