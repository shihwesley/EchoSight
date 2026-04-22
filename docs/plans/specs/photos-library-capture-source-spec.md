---
name: photos-library-capture-source
description: Remove PeekABoo dependency, reimplement screenshot-observation internally, wire the capture flow that was never bound, rename PeekABooSource → PhotosLibraryCaptureSource
phase: 4
sprint: 5
parent: root-spec
depends_on: [capture, backlog-pre-existing-warnings]
status: eng-reviewed
created: 2026-04-22
---

# Photos-Library Capture Source (Sprint 4.5)

## Goal

Two deliverables:

1. **Fix a latent P0 from the Phase 4 PeekABoo audit:** `PeekABooSource.handleCapture(_:)` has zero callers. The documented `.onCapture { image in ... }` SwiftUI modifier was never attached to any view. The v0.1 scene-description flow cannot actually run end-to-end from a screenshot gesture — the capture layer is unreachable. This sprint wires the observer internally so the pipeline works for the first time in code.
2. **Remove the PeekABoo third-party dependency.** PeekABoo's contribution to this codebase is a single call to `PeekABoo.requestAccess()` plus a documented-but-unused `.onCapture` modifier. Both replaceable with ~60 lines of standard PhotoKit code. We credit PeekABoo in the README for the mechanism inspiration.

After this sprint, the capture flow is self-contained in `EchoSightCore` + `EchoSightApp` using only Apple's Photos framework.

## Requirements

- `PeekABoo.requestAccess()` call at `CapturePrivacyOnboardingView.swift:110` replaced with direct `PHPhotoLibrary.requestAuthorization(for: .readWrite)`
- `import PeekABoo` at `CapturePrivacyOnboardingView.swift:3` removed
- `PeekABooSource` class and file renamed to `PhotosLibraryCaptureSource`
- Internal `PHPhotoLibraryChangeObserver` implementation watches for new `.photoScreenshot` assets and calls `handleCapture(_:)` automatically — no view-layer binding needed
- `project.yml` PeekABoo package declaration (`:20-21`) and target link (`:57-58`) removed
- `.xcodeproj` regenerated via `xcodegen`; `Package.resolved` no longer references PeekABoo
- `Package.swift` gains a top-of-file comment explaining its role vs `project.yml` (cleanup option X)
- `README.md` gains a credit section for PeekABoo (mechanism inspiration)
- All doc references to PeekABoo in active planning files (`findings.md`, `manifest.md`, `specs/capture-spec.md`, `.claude/handoff.md`) updated to reflect the new source name and the fact that we're not using the library. `EchoSight-AVP-Brainstorm.md` is a historical snapshot and is left untouched.
- Build green, 0 Swift warnings preserved, Sprint 4.4's warning gate still holds

## Acceptance Criteria

- [ ] `grep -rn "PeekABoo\|peekaboo" Sources/ Tests/ Package.swift project.yml` returns zero matches (outside of possibly a credit line in code comments)
- [ ] `grep -rn "PeekABoo" docs/plans/` returns matches only in `progress.md` historical entries (pre-4.5 sessions)
- [ ] `xcodebuild -scheme EchoSight -destination 'generic/platform=visionOS' clean build` exits 0
- [ ] `xcodebuild … build 2>&1 | grep "warning:" | grep -v appintentsmetadataprocessor | wc -l` = 0 (Sprint 4.4 gate preserved)
- [ ] `Package.resolved` has no `peekaboo` identity
- [ ] `PhotosLibraryCaptureSource.handleCapture(_:)` is called at runtime by the internal observer — verify via a test (new or updated) that observes a simulated screenshot notification
- [ ] README.md has a credit section: "EchoSight's screenshot-capture mechanism is inspired by PeekABoo (https://github.com/OmChachad/PeekABoo) by Om Chachad."
- [ ] `Package.swift` has a top-of-file comment explaining it describes `EchoSightCore` as a library; the shipping app is defined in `project.yml`

## Technical Approach

### Piece 1: Replace `PeekABoo.requestAccess()` (one file)

`CapturePrivacyOnboardingView.swift:3` — remove `import PeekABoo`.
`CapturePrivacyOnboardingView.swift:110`:

```swift
// Before
let granted = await PeekABoo.requestAccess()

// After
let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
let granted = (status == .authorized)
```

`.limited` stays denied for our purposes (the existing `start()` in the Core source already rejects `.limited`). No other behavior change.

### Piece 2: Internal screenshot observer in `PhotosLibraryCaptureSource`

Replace the documented-but-unused `.onCapture` binding with a self-contained observer. Register in `start()`, deregister in `stop()`. On library change, fetch the latest `.photoScreenshot`; if its `localIdentifier` differs from the last-seen, load the image and call `handleCapture(_:)`.

Skeleton:

```swift
private final class ScreenshotObserver: NSObject, PHPhotoLibraryChangeObserver {
    private weak var source: PhotosLibraryCaptureSource?
    private var lastSeenLocalIdentifier: String?
    init(source: PhotosLibraryCaptureSource) { self.source = source }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Fetch latest screenshot; if new, load image and deliver.
        // Runs on a background queue (PhotoKit contract).
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(
            format: "mediaSubtype == %d", PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = result.firstObject else { return }
        guard asset.localIdentifier != lastSeenLocalIdentifier else { return }
        lastSeenLocalIdentifier = asset.localIdentifier
        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isSynchronous = false
        manager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            options: requestOptions
        ) { [weak self] image, _ in
            guard let self, let image, let source = self.source else { return }
            Task { @MainActor in await source.handleCapture(image) }
        }
    }
}
```

Observer owned by the source; registered via `PHPhotoLibrary.shared().register(observer)` in `start()`, unregistered in `stop()`. The observer runs on PhotoKit's background queue; `handleCapture` is `@MainActor` so the Task hop lands it correctly.

Minor edit to `handleCapture`: since the observer already has the asset, passing the asset directly would skip the redundant fetch at `handleCapture` line 163-170. Optional optimization — keep the existing fetch for simplicity unless the inline check is cleaner. Spec-wise: either is acceptable, prefer simpler diff.

### Piece 3: Rename `PeekABooSource` → `PhotosLibraryCaptureSource`

- `git mv Sources/EchoSightCore/Capture/PeekABooSource.swift Sources/EchoSightCore/Capture/PhotosLibraryCaptureSource.swift`
- `class PeekABooSource` → `class PhotosLibraryCaptureSource` inside the file
- Doc comments updated (remove "PeekABoo monitors..." narrative; replace with "Observes the Photos library for new screenshots...")
- `Sources/EchoSightApp/Views/ClearCapturesButton.swift:127` — `PeekABooSource.firstCaptureNotification` → `PhotosLibraryCaptureSource.firstCaptureNotification`
- `Tests/EchoSightCoreTests/CaptureTests.swift:226` — `// MARK: - PeekABooSource concurrency guard tests` → `// MARK: - PhotosLibraryCaptureSource concurrency guard tests`
- `Tests/EchoSightCoreTests/CaptureTests.swift:229` — `struct PeekABooSourceConcurrencyTests` → `struct PhotosLibraryCaptureSourceConcurrencyTests`
- `Tests/EchoSightCoreTests/CaptureTests.swift:235` — `let source = PeekABooSource()` → `let source = PhotosLibraryCaptureSource()`

### Piece 4: Remove the dependency

- `project.yml:20-21`: delete the PeekABoo package declaration (`PeekABoo:\n url: https://github.com/OmChachad/PeekABoo.git`)
- `project.yml:57-58`: delete the target link (`- package: PeekABoo\n product: PeekABoo`)
- `xcodegen generate` — regenerate `.xcodeproj`
- Verify `Package.resolved` no longer has the `peekaboo` identity (it regenerates on next build)

### Piece 5: Package.swift explanatory comment (option X)

Prepend this to `Package.swift`:

```swift
// swift-tools-version: 6.0
//
// This manifest describes `EchoSightCore` as a reusable Swift library.
// The shipping visionOS app (`EchoSightApp` target, Info.plist, capabilities,
// signing) is defined in `project.yml` via XcodeGen, which generates the
// `EchoSight.xcodeproj` used for Xcode builds and TestFlight submissions.
//
// Scope of this file: Core's own dependencies (swift-log, GRDB, mlx-swift).
// Do not add App-layer dependencies here — add them to `project.yml`.
```

### Piece 6: README credit

Add to `README.md`:

```markdown
## Credits

EchoSight's screenshot-based capture mechanism is inspired by
[PeekABoo](https://github.com/OmChachad/PeekABoo) by Om Chachad — specifically
the pattern of observing the Photos library for new screenshots to work around
the lack of a direct camera API on visionOS. We reimplemented the mechanism
internally to keep our dependency surface minimal, but the architectural idea
is theirs.
```

### Piece 7: Doc updates

Active planning files to update:
- `docs/plans/findings.md:19`, `:31`, `:49` — replace "PeekABoo" references with "PhotosLibraryCaptureSource" / "Photos-library polling"; note in the per-spec decisions that v0.1 ships without the dependency
- `docs/plans/manifest.md:118` — capture spec Role column: "PeekABoo-backed capture source" → "Photos-library-backed capture source"
- `docs/plans/specs/capture-spec.md` — rewrite any PeekABoo mentions to reflect the internal implementation (spec is frozen as `eng-reviewed`, so this is a minor annotation rather than a rewrite)
- `.claude/handoff.md:20, 27` — update to current Phase 4 state; remove "PeekABoo" from the SPM deps list; "capture spec (PeekABoo + album + gesture trigger)" → "capture spec (Photos library + album + gesture trigger)"
- `EchoSight-AVP-Brainstorm.md` — **left untouched**. Historical planning snapshot; editing would rewrite history. Add a one-line note at the top of the file: "Historical planning doc from 2026-04-11. Some decisions have changed — see `docs/plans/findings.md` for current state."

## Files

| File | Change |
|------|--------|
| `Sources/EchoSightCore/Capture/PeekABooSource.swift` → `PhotosLibraryCaptureSource.swift` | Rename + internal observer + class rename |
| `Sources/EchoSightApp/Views/CapturePrivacyOnboardingView.swift` | Drop `import PeekABoo`, replace `requestAccess` |
| `Sources/EchoSightApp/Views/ClearCapturesButton.swift` | Update `PeekABooSource.firstCaptureNotification` reference |
| `Tests/EchoSightCoreTests/CaptureTests.swift` | Update struct names + new test for observer-driven capture |
| `project.yml` | Remove PeekABoo package + target link |
| `EchoSight.xcodeproj/` | Regenerate via `xcodegen` |
| `Package.swift` | Add explanatory comment at top |
| `README.md` | Add Credits section for PeekABoo inspiration |
| `docs/plans/findings.md` | Update Approach + Requirements + Per-Spec Decisions sections |
| `docs/plans/manifest.md` | Update capture spec Role column |
| `docs/plans/specs/capture-spec.md` | Annotate PeekABoo mentions with current state |
| `.claude/handoff.md` | Refresh Phase + references |
| `EchoSight-AVP-Brainstorm.md` | Top-of-file "historical snapshot" note |

## Tasks

1. `feat(sprint-4.5): replace PeekABoo.requestAccess with PHPhotoLibrary` — Piece 1 (1 file, 2 edits)
2. `feat(sprint-4.5): wire internal screenshot observer` — Piece 2 (PhotosLibraryCaptureSource gains ScreenshotObserver + register/unregister in start/stop)
3. `refactor(sprint-4.5): rename PeekABooSource → PhotosLibraryCaptureSource` — Piece 3 (file + class + 3 call-site updates)
4. `chore(sprint-4.5): remove PeekABoo dependency + regenerate xcodeproj` — Piece 4 (project.yml + xcodegen run)
5. `docs(sprint-4.5): Package.swift explanatory comment` — Piece 5
6. `docs(sprint-4.5): README credit + doc refresh` — Pieces 6 + 7 combined
7. Build verification: `clean build` green, 0 warnings
8. Run `/code-review-pro` on full diff; fix any P0/P1
9. Merge worktree → main with `--no-ff`
10. Update `progress.md` Sprint 4.5 session log + Spec Status table row
11. End with PHASE_RESULT block

## Dependencies

- **Needs from:** `backlog-pre-existing-warnings` (Sprint 4.4) — 0-warnings baseline to preserve
- **Provides to:** v0.1 release pipeline — capture flow now actually works end-to-end

## Notes for Phase-Runner

- This sprint fixes a latent capture-flow bug AND removes a dependency. Both are happening in one sprint because they're coupled through the same source file. Do not split them across sprints.
- If any piece requires Apple frameworks that visionOS doesn't support (unlikely — PHPhotoLibraryChangeObserver is iOS 8+ / visionOS 1+), escalate via `needs_user_input`.
- The observer runs on PhotoKit's background queue. The `Task { @MainActor in await source.handleCapture(image) }` hop is non-negotiable — `handleCapture` is `@MainActor`.
- `.xcodeproj` regeneration may reshuffle UUIDs in `project.pbxproj`. That's expected; just commit the regenerated file.
- Test changes: add one new test that registers the observer, posts a fake `PHChange` notification (or uses PhotoKit test fakes if available), and verifies `handleCapture` is invoked. If PhotoKit isn't easily testable in isolation, document the gap in the session log and rely on manual device verification.
- After all fixes, push the final main branch to origin. Verify remote is reachable before pushing; if it fails (no remote, auth error), stop and escalate — do NOT force-push or rewrite history.
