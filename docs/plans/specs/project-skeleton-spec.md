---
name: project-skeleton
description: Xcode project skeleton, SPM deps, entitlements, ImmersiveSpace scaffolding
phase: 1
sprint: 1
parent: root-spec
depends_on: [root, observability]
status: eng-reviewed
created: 2026-04-21
---

# Project Skeleton Spec

## Goal

Create the runnable visionOS SwiftUI app target. No features yet — just a blank `ImmersiveSpace` that launches, requests permissions correctly, and has every downstream SPM dependency declared.

## Requirements

- visionOS SwiftUI app target, deployment target visionOS 2.0
- Two SPM products: `EchoSightApp` (executable), `EchoSightCore` (library)
- Info.plist with `NSPhotoLibraryUsageDescription`, `NSWorldSensingUsageDescription`, `NSMicrophoneUsageDescription` (reserved for v1.0)
- ImmersiveSpace declared with `.mixed` immersion style
- SPM deps declared: PeekABoo, mlx-swift (placeholder), swift-log
- Launch screen + minimal WindowGroup for setup UI
- Unit test target (`EchoSightCoreTests`) with at least one placeholder test

## Acceptance Criteria

- [ ] `xcodebuild -scheme EchoSight -destination 'generic/platform=visionOS' build` succeeds
- [ ] `xcodebuild test -scheme EchoSight -destination 'platform=visionOS Simulator,name=Apple Vision Pro'` runs (may have zero tests)
- [ ] App launches in Apple Vision Pro simulator without crash
- [ ] Immersive space can be entered and exited
- [ ] All three usage descriptions show in Settings when permissions requested

## Technical Approach

Use Xcode visionOS template as starting point. Convert to SPM-first layout (Package.swift at root, Xcode project consumes package). This keeps `EchoSightCore` testable without the UI shell.

## Files

| File | Purpose |
|------|---------|
| `Package.swift` | SPM definition, both products |
| `EchoSight.xcodeproj` | Xcode target consuming the package |
| `Sources/EchoSightApp/EchoSightApp.swift` | `@main` App, WindowGroup + ImmersiveSpace |
| `Sources/EchoSightApp/Views/RootView.swift` | Minimal setup window |
| `Sources/EchoSightApp/Views/WorldImmersiveView.swift` | RealityView host for Layer 1 |
| `Sources/EchoSightApp/Info.plist` | Permissions + capabilities |
| `Tests/EchoSightCoreTests/PlaceholderTests.swift` | `XCTAssertTrue(true)` placeholder |

## Tasks

1. Initialize Xcode visionOS project + `Package.swift` two-product layout
2. Declare SPM dependencies (PeekABoo, mlx-swift, swift-log)
3. Wire Info.plist usage descriptions + capabilities
4. Implement minimal `EchoSightApp` with WindowGroup + ImmersiveSpace stub
5. Add `EchoSightCoreTests` target + placeholder test

## Dependencies

- **Needs from:** root (protocols), observability (bootstrap API)
- **Provides to:** capture, spatial-core, every spec with code

## Eng Review

- **Depth:** BIG
- **Scope additions:** `EchoSightApp.init` must call `ObservabilityBootstrap.install()` before any feature code runs. SPM deps gain `swift-log` (confirm already present from observability spec's dep list).
- **Acceptance additions:**
  - [ ] `ObservabilityBootstrap.install()` runs exactly once at app launch, before first `@main` body executes
  - [ ] Placeholder test asserts at least one log event fired under `echosight.app` category

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Build | CI | `xcodebuild build` succeeds on visionOS target | Missing SPM dep → build fails with clear message | Clean derived data → still builds |
| Launch | Simulator | App enters WindowGroup within 3 s | Info.plist missing usage desc → OS refuses permission → log under `echosight.app` warn | Cold launch vs warm launch |
| Bootstrap | Unit | `ObservabilityBootstrap.install()` idempotent | Double-install → warn, no-op | Install called from two threads |
| ImmersiveSpace | Simulator | Enter/exit without crash | RealityKit scene setup fails → fallback to WindowGroup only | Enter during onboarding → deferred until onboarding complete |

### Critical Paths

- SPM package resolves cleanly (PeekABoo, mlx-swift, swift-log, GRDB) — any version conflict blocks all downstream work
- Info.plist usage descriptions present or OS silently denies sensor access — catastrophic silent failure mode

### Observability

- **Log category:** `echosight.app` (same as root-spec, owned by this spec's bootstrap)
- **Key events:**
  - `app.bootstrap.start`
  - `app.bootstrap.observability.installed`
  - `app.bootstrap.complete(durationMs)`
  - `app.immersiveSpace.opened`
  - `app.immersiveSpace.closed`
