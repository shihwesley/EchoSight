# Code Review — EchoSight Sprint 3.2
**Date:** 2026-04-22
**Type:** New-file review (17 files, ~900 LOC)
**Verdict:** REQUEST CHANGES
**Severity counts:** P0: 2 | P1: 3 | P2: 4 | P3: 3

---

## P0 — Critical (2)

---

**ID:** P0-1
**File:** `Sources/EchoSightCore/Download/ModelDownloader.swift` — line 280-291
**Source:** Security + Race Condition Hunter; Swift 6 Concurrency Specialist
**Confidence:** 97

**Current code:**
```swift
nonisolated public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL      // valid only during this call
) {
    Task { @MainActor in                      // ← async hop
        // ...
        try FileManager.default.moveItem(at: location, to: destURL)  // location may be gone
    }
}
```

**Problem:** `URLSessionDownloadDelegate.urlSession(_:downloadTask:didFinishDownloadingTo:)` documents that the `location` URL is a **temporary file that is only guaranteed to exist for the duration of the synchronous delegate callback**. URLSession moves or deletes it as soon as the method returns. The code wraps the file move in `Task { @MainActor in ... }`, which defers execution to the next main-actor turn. By that point, URLSession has already reclaimed the temp file. The `moveItem` call will throw `NSCocoaErrorDomain / NSFileNoSuchFileError`, which is caught and transitions state to `.failed`. Every completed download is therefore classified as an error, and the code re-queues the download — producing an infinite retry loop.

**Fix — Option A (recommended):** Copy the file synchronously inside the delegate callback before dispatching to @MainActor.

```swift
nonisolated public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
) {
    // location is only valid synchronously — capture data before any async hop.
    let capturedLocation = location
    let capturedEntryId: String?
    // We need the entry id lookup; copy activeTasks snapshot.
    // Instead, use a temp copy approach: move to a stable temp path NOW.
    let tempDest = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    do {
        try FileManager.default.copyItem(at: capturedLocation, to: tempDest)
    } catch {
        Task { @MainActor in
            self.log.error("download.tempCopyFailed",
                           metadata: ["error": .string(error.localizedDescription)])
            self.state = .failed(DownloadError.sessionError(error))
            self.onFailure?(error)
        }
        return
    }

    Task { @MainActor in
        guard let entryId = self.entryId(for: downloadTask),
              let entry = self.manifest.entries.first(where: { $0.id == entryId })
        else {
            try? FileManager.default.removeItem(at: tempDest)
            return
        }
        let destURL = self.destinationDirectory.appendingPathComponent(
            entry.url.lastPathComponent
        )
        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.moveItem(at: tempDest, to: destURL)
        } catch {
            self.log.error("download.moveFailed",
                           metadata: ["id": .string(entryId),
                                      "error": .string(error.localizedDescription)])
            self.state = .failed(DownloadError.sessionError(error))
            self.onFailure?(error)
            return
        }
        self.state = .verifying
        let result = await Task.detached(priority: .utility) {
            ModelVerifier.verify(fileURL: destURL,
                                 expectedSHA256: entry.expectedSHA256)
        }.value
        // ... rest of switch unchanged
    }
}
```

**Fix — Option B:** Switch from background URLSession to a foreground session for onboarding. This eliminates the nonisolated delegate problem at the cost of not surviving app kill.

**Verification:** Add a test that exercises `didFinishDownloadingTo` with a URL pointing to a file that is immediately removed after the call returns. Confirm the download completes (not fails).

---

**ID:** P0-2
**File:** `Sources/EchoSightCore/Download/ModelDownloader.swift` — line 303-307
**Source:** Code Quality + Boundary Conditions; Swift 6 Concurrency Specialist
**Confidence:** 92

**Current code:**
```swift
// SHA-256 verification.
self.state = .verifying
let result = ModelVerifier.verify(
    fileURL: destURL,
    expectedSHA256: entry.expectedSHA256
)
```

**Problem:** `ModelVerifier.verify` reads the entire file synchronously using an `InputStream`. For the Gemma model at ~2 GB, this blocks the `@MainActor` for an estimated 10–30 seconds on typical hardware while hashing. During this time, SwiftUI cannot render updates, VoiceOver milestone announcements are silenced, and the app is effectively frozen. On Apple Vision Pro, where spatial continuity and audio responsiveness are primary UX pillars, this is a P0 for accessibility/performance. Additionally, `self.state = .verifying` is set just before the blocking call, so the UI shows the verifying indicator but never updates until the freeze ends.

**Fix — Option A (recommended):** Run verification on a detached background task.

```swift
self.state = .verifying
let capturedURL = destURL
let capturedSHA = entry.expectedSHA256
let result = await Task.detached(priority: .utility) {
    ModelVerifier.verify(fileURL: capturedURL,
                         expectedSHA256: capturedSHA)
}.value
// switch result { ... } — unchanged
```

**Fix — Option B:** Use `async let` if multiple entries could be verifying simultaneously (not needed for current serial logic).

**Verification:** Instrument with a `CFAbsoluteTimeGetCurrent()` timestamp before and after the verify call on @MainActor. Confirm the delta is <16 ms. Alternatively, run with the Thread Performance Checker in Instruments to confirm no main-thread disk I/O.

---

## P1 — High (3)

---

**ID:** P1-1
**File:** `Sources/EchoSightCore/Download/ModelManifest.swift` — lines 73-91
**Source:** Security + Race Condition Hunter
**Confidence:** 88

**Current code:**
```swift
ModelEntry(
    id: "gemma-4-e2b-q4",
    expectedSHA256: "PLACEHOLDER_SHA256_GEMMA_4_E2B_Q4",
    ...
),
ModelEntry(
    id: "yolo11n-int8",
    expectedSHA256: "PLACEHOLDER_SHA256_YOLO11N_INT8",
    ...
),
```

**Problem:** The SHA-256 values are placeholder strings that will never match any real file digest. The downloader checks `entry.url.pathComponents.contains("placeholder")` to skip placeholder entries — but this check only skips the `whisperkit-placeholder` entry (whose URL path contains the word "placeholder"). The Gemma and YOLO entries have production URLs but placeholder SHAs. When those downloads complete, `ModelVerifier.verify` will always return `.mismatch`, causing the downloader to delete the file and immediately re-queue the download. The result is an infinite download-verify-fail-retry loop that consumes ~2 GB of bandwidth repeatedly and never advances onboarding. This will ship if the placeholder SHAs are not replaced before the release build and there is no CI check preventing it.

**Fix — Option A (recommended):** Add a compile-time or runtime assertion that placeholder SHAs are not shipped to production.

```swift
// In ModelManifest, add a validation method:
public func assertNoPlaceholderSHAs(file: StaticString = #file, line: UInt = #line) {
    for entry in entries {
        precondition(
            !entry.expectedSHA256.hasPrefix("PLACEHOLDER"),
            "Entry '\(entry.id)' has a placeholder SHA-256. Replace before release.",
            file: file, line: line
        )
    }
}

// Call in ModelDownloader.startDownloads():
manifest.assertNoPlaceholderSHAs()
```

**Fix — Option B:** Gate in CI with a script that greps for `PLACEHOLDER_SHA256` in the manifest and fails the build.

**Verification:** Add a unit test `testNoPlaceholderSHAsInV01Manifest()` that calls `assertNoPlaceholderSHAs()` — it will fail until real SHAs are populated, blocking the build as intended.

---

**ID:** P1-2
**File:** `Sources/EchoSightCore/Features/SpatialRecallOrchestrator.swift` — lines 138-140
**Source:** Swift 6 Concurrency Specialist; SOLID + Architecture
**Confidence:** 82

**Current code:**
```swift
listenTask = Task { [weak self] in
    await self?.runEventLoop(firedEvents: firedEvents, changeEvents: changeEvents)
}
```

**Problem:** Using `[weak self]` inside an actor-hosted Task creates a silent failure mode. If the actor is deallocated between task creation and the first suspension point (uncommon in production but routine in unit tests where the orchestrator is created and immediately released), `self` is nil, and `runEventLoop` is never called. The task completes silently. Callers observing state via the event streams will receive no events — the system appears to work (no crash) but is completely deaf to mode inputs. This is an actor retain semantics bug: actors are reference types that should not use `[weak self]` inside their own Tasks unless there is an explicit deinit-and-cancel contract. The `stop()` method cancels `listenTask`, which is the correct way to break the lifecycle — `[weak self]` adds a parallel (and weaker) shutdown path that conflicts with the canonical one.

**Fix — Option A (recommended):** Remove `[weak self]`; rely on `stop()` / task cancellation.

```swift
listenTask = Task {
    await runEventLoop(firedEvents: firedEvents, changeEvents: changeEvents)
}
```

Note: `listenTask` holding a strong reference to `self` is intentional. The actor will not be deallocated while the event loop is running, which is the correct lifecycle (stop() must be called explicitly).

**Fix — Option B:** Keep `[weak self]` but add a `guard let self` with an assertion/log on nil so silent failure is visible.

**Verification:** Write a test that creates `SpatialRecallOrchestrator`, calls `start()`, immediately releases all strong references, then injects a fired event and confirms the loop is still processing (for Option A) or that a log warning fires (for Option B).

Note: The same pattern appears at line 157 in `AmbientAnnounceCoordinator.swift` (`listenTask = Task { [weak self] in ...}`) — apply the same fix there.

---

**ID:** P1-3
**File:** `Sources/EchoSightCore/Download/ModelDownloader.swift` — line 119-120
**Source:** Code Quality + Boundary Conditions
**Confidence:** 80

**Current code:**
```swift
let appSupport = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
).first!
```

**Problem:** Force-unwrapping `FileManager.urls(for:in:).first` will crash in any environment where Application Support is not available. While this is rare on a shipping device, it can happen in unit test environments run without a host app (the search path returns an empty array), causing every test that instantiates `ModelDownloader()` with the default `destinationDirectory: nil` to crash rather than fail gracefully. On visionOS, Application Support is always available for a sandboxed app, so this is not a production crash risk — but it is a P1 for test infrastructure reliability.

**Fix — Option A (recommended):**
```swift
guard let appSupport = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
).first else {
    // Fall back to temp directory in test/headless environments.
    self.destinationDirectory = destinationDirectory
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoSight/Models")
    return  // Must restructure init if using guard
}
self.destinationDirectory = destinationDirectory
    ?? appSupport.appendingPathComponent("EchoSight/Models")
```

Or simpler: always require callers to provide `destinationDirectory` in tests.

**Fix — Option B:** Inject the directory in the initializer and eliminate the default — make the force-unwrap only happen in the app target's root wiring.

**Verification:** Run `ModelDownloaderTests` in a bare `swift test` environment without a host app. Confirm no crash.

---

## P2 — Medium (4)

---

**ID:** P2-1
**File:** `Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift` — line 341-349
**Source:** SOLID + Architecture; Swift 6 Concurrency Specialist
**Confidence:** 76

**Current code:**
```swift
if event.to == .silent, let token = currentSpeechToken {
    let tokenRef = token
    let cancelAction = cancelToken
    Task {
        await cancelAction(tokenRef)
    }
    currentSpeechToken = nil
```

**Problem:** The fire-and-forget `Task { await cancelAction(tokenRef) }` is created inside a synchronous actor-isolated function. If multiple `.silent` mode changes arrive in rapid succession (e.g., a mode flicker), each creates an independent unstructured Task. These tasks are not tracked, cannot be cancelled, and their execution order is not guaranteed relative to subsequent anchor events processed by the actor. While `cancelAction` targeting a specific token should be idempotent, the untracked nature means there is no way to await or cancel these tasks in `stop()`. More concretely: after `stop()` returns, in-flight cancel tasks may still be executing and calling into `SpeechOut`. This is the same pattern as `Task { await self.cancelAllAction() }` in `SpatialRecallOrchestrator.handleModeChange` (line 374).

**Fix — Option A (recommended):** Use `async` cancellation if mode handling can be made async, or store cancel tasks in a set.

```swift
// In AmbientAnnounceCoordinator:
private var cancelTasks: Set<Task<Void, Never>> = []

private func handleModeChange(_ event: ModeChangeEvent) {
    idleTracker.recordModeFired(at: event.timestamp)
    if event.to == .silent, let token = currentSpeechToken {
        let tokenRef = token
        let cancelAction = cancelToken
        let t = Task { await cancelAction(tokenRef) }
        cancelTasks.insert(t)
        // Prune completed tasks periodically to avoid unbounded growth.
        cancelTasks = cancelTasks.filter { !$0.isCancelled }
        currentSpeechToken = nil
        log.info("ambient.speech.cancelledBysilentToggle")
    }
}

public func stop() {
    listenTask?.cancel()
    listenTask = nil
    cancelTasks.forEach { $0.cancel() }
    cancelTasks.removeAll()
}
```

**Fix — Option B:** Make `handleModeChange` async and await the cancel directly. Requires restructuring the merged-stream loop to accept async handlers.

**Verification:** Log a count of in-flight cancel tasks at `stop()` time and assert it is 0 in a test.

---

**ID:** P2-2
**File:** `Sources/EchoSightCore/Download/ModelDownloader.swift` — line 232-236
**Source:** Code Quality + Boundary Conditions
**Confidence:** 75

**Current code:**
```swift
private func ensureDirectoryExists() {
    try? FileManager.default.createDirectory(
        at: destinationDirectory,
        withIntermediateDirectories: true
    )
}
```

**Problem:** Silent failure via `try?`. If the Application Support directory cannot be created (sandboxing issue, full disk, permission error), the download tasks start normally but every `moveItem` call will fail. The move failure IS caught (line 291-299), but only after the ~2 GB download completes. The user waits for the full download only to encounter a failure that could have been reported immediately.

**Fix — Option A (recommended):** Surface the error early.
```swift
private func ensureDirectoryExists() throws {
    try FileManager.default.createDirectory(
        at: destinationDirectory,
        withIntermediateDirectories: true
    )
}

// In startDownloads():
do {
    try ensureDirectoryExists()
} catch {
    log.error("download.directoryCreationFailed",
               metadata: ["error": .string(error.localizedDescription)])
    state = .failed(DownloadError.sessionError(error))
    onFailure?(error)
    return
}
```

**Verification:** Test with `destinationDirectory` set to a read-only path. Confirm state immediately transitions to `.failed`.

---

**ID:** P2-3
**File:** `Sources/EchoSightCore/Features/RecallGestaltFormatter.swift` — line 43-46
**Source:** Code Quality + Boundary Conditions
**Confidence:** 73

**Current code:**
```swift
if enumerated.isEmpty {
    return countPhrase(count) + "."
}
let labelList = enumerated.map { "a \($0)" }.joined(separator: ", ")
```

**Problem 1:** If `count == 0` (caller violates the documented precondition), `countPhrase(0)` hits the `default` case and returns `"0 things around you"` — a grammatically wrong VoiceOver phrase. No assertion or precondition protects against this.

**Problem 2:** If any `annotation.falconLabel` is an empty string (a realistic edge case if the detector returns a low-confidence empty label), the lowercased value is `""`, which passes the `seen.contains` check and produces `"a "` (label with trailing space) in the joined phrase. TTS reads this as an awkward pause mid-sentence.

**Fix — Option A (recommended):**
```swift
public static func format(annotations: [WorldAnnotation]) -> String {
    precondition(!annotations.isEmpty,
                 "RecallGestaltFormatter.format called with empty annotations")
    let count = annotations.count
    var seen = Set<String>()
    let uniqueLabels: [String] = annotations.compactMap { annotation in
        let label = annotation.falconLabel.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !label.isEmpty, !seen.contains(label) else { return nil }
        seen.insert(label)
        return label
    }
    // ... rest unchanged
}
```

**Verification:** Unit test with an annotation whose `falconLabel` is `""` and confirm no `"a "` appears in output. Test with an empty array and confirm the precondition fires in debug builds.

---

**ID:** P2-4
**File:** `Sources/EchoSightApp/Onboarding/DownloadProgressView.swift` — line 65-78
**Source:** Code Quality + Boundary Conditions
**Confidence:** 72

**Current code:**
```swift
if case .downloading(let progress) = downloader.state {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(progress.values), id: \.id) { entry in
```

**Problem:** `Dictionary.values` has undefined iteration order. The `ForEach` over `progress.values` will render rows in a non-deterministic order that changes each time the `@Published state` updates (which happens on every `didWriteData` delegate callback — potentially hundreds of times per second during download). This produces visible row-reordering jitter in the per-entry progress list, which is particularly jarring under VoiceOver where focus position can shift unexpectedly.

**Fix — Option A (recommended):** Sort by a stable key before iterating.
```swift
ForEach(Array(progress.values).sorted(by: { $0.id < $1.id }), id: \.id) { entry in
```

Or match manifest order:
```swift
// In DownloadProgressView, receive manifest reference or use a hardcoded stable order
let sortedEntries = downloader.manifest.entries
    .compactMap { progress[$0.id] }
```

**Fix — Option B:** Replace `[String: EntryProgress]` with an `OrderedDictionary` (from swift-collections).

**Verification:** Run the download in the simulator and inspect the per-entry rows with VoiceOver enabled. Confirm focus does not jump between entries.

---

## P3 — Low (3)

---

**ID:** P3-1
**File:** `Sources/EchoSightCore/Ambient/AmbientAnnounceCoordinator.swift` — line 210 (`handleAnchorEvent`)
**Source:** SOLID + Architecture
**Confidence:** 68

**Current code:** `handleAnchorEvent` is approximately 120 lines, contains all 10 gate checks inline, and performs logging, rate limit checking, novelty detection, speech rendering, and encounter recording in a single method.

**Problem:** Violates SRP — the method is responsible for gate evaluation logic, side effects (chime, speech, encounter record), and logging. Adding a new gate requires editing this method. The method also exceeds the 30-line threshold significantly, making it harder to follow the gate order documented in the header comment.

**Fix — Option A (recommended):** Extract gate evaluations into private helper methods that return early with a log. The header already documents the 10-gate pipeline — each gate should map to a named predicate.

```swift
private func handleAnchorEvent(_ event: AnchorChangeEvent) async {
    let now = Date()
    if event.kind == .sessionResumeRerecognized { sessionResumeDampener.trigger(now: now) }
    guard !sessionResumeDampener.isSuppressing(now: now)   else { return logGateFail("sessionResume") }
    guard rateLimiter.canChime(now: now)                   else { return }
    await fireChime(now: now)
    guard try await isNovel(anchorId: event.anchorId, now: now) else { return }
    guard !silentMode()                                    else { return logGateFail("silentMode") }
    guard idleTracker.isIdle(now: now)                     else { return logGateFail("gestureActive") }
    guard isHeadMoving(now: now)                           else { return logGateFail("headMotion") }
    guard rateLimiter.canSpeak(now: now)                   else { return logGateFail("speechRate") }
    await fireAnnouncement(for: event.anchorId, now: now)
}
```

**Verification:** No behavior change. Confirm all 14,817-state TLA model assertions still hold by re-running the spec checker.

---

**ID:** P3-2
**File:** `Sources/EchoSightApp/Settings/HardwareDiagnosticView.swift` — lines 197-205
**Source:** Code Quality + Boundary Conditions
**Confidence:** 65

**Current code:**
```swift
private final class HardwareDiagnosticLog {
    func record(_ event: String, count: Int? = nil) {
        if let count {
            print("[echosight.diagnostic] \(event)(count=\(count))")
        } else {
            print("[echosight.diagnostic] \(event)")
        }
    }
}
```

**Problem:** `HardwareDiagnosticLog` uses `print` rather than `swift-log` or `OSLog`, inconsistent with all other files in this sprint (which use `Logger(label:)`). The comment acknowledges this is a TODO but it was left in a mergeable file. Additionally, `private let log = HardwareDiagnosticLog()` in a SwiftUI View struct will be re-allocated on every view update. `Logger` from swift-log is a struct and carries negligible overhead; `HardwareDiagnosticLog` is a class allocation.

**Fix — Option A (recommended):**
```swift
// Remove HardwareDiagnosticLog entirely. Replace with:
private let log = Logger(label: "echosight.diagnostic")

// In simulateCrownTick:
log.info("hardware.diagnostic.crown.tick", metadata: ["count": .string("\(crownTicks)")])
```

**Verification:** Confirm no `print(` calls remain in `HardwareDiagnosticView.swift`.

---

**ID:** P3-3
**File:** `Sources/EchoSightApp/Onboarding/OnboardingCoordinator.swift` — line 96
**Source:** Code Quality + Boundary Conditions
**Confidence:** 62

**Current code:**
```swift
log.info("tutorial.completed", metadata: ["durationSec": "0"])
```

**Problem:** Hardcoded `"0"` for tutorial duration. This produces misleading telemetry in production (every tutorial completion appears instant). Should track actual elapsed time from when the tutorial step is entered.

**Fix — Option A (recommended):**
```swift
// In OnboardingCoordinator, add:
private var tutorialStartedAt: Date?

public func downloadCompleted() {
    defaults.set(true, forKey: Keys.downloadCompleted)
    tutorialStartedAt = Date()  // start timer when tutorial begins
    step = .tutorial
}

private func markOnboardingComplete() {
    defaults.set(true, forKey: Keys.onboardingCompleted)
    let duration = tutorialStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
    log.info("tutorial.completed", metadata: ["durationSec": .string("\(duration)")])
    step = .completed
}
```

**Verification:** Run through tutorial, confirm log output shows a non-zero duration.

---

## Non-Issues (Investigated and Cleared)

- **`@unchecked Sendable` on `ModelDownloader`**: Justified. All mutable state (`activeTasks`, `progressByEntry`, etc.) is gated behind `@MainActor`. The `@unchecked` suppresses the conformance error caused by `URLSessionDownloadDelegate` being ObjC, not because mutable state is unprotected.

- **`@unchecked Sendable` on `SynthesizerDelegateBridge`**: Justified. The bridge receives AVFoundation callbacks on arbitrary threads and forwards them only through an `AsyncStream.Continuation`, which is itself `Sendable`. No mutable state is shared.

- **`[weak self]` in `windowTask`** (`SpatialRecallOrchestrator` line 265): Unlike the listenTask case (P1-2), this is safer because `windowTask` is immediately stored in the actor state. If the actor is deallocated, the window expiry simply does nothing — which is correct (the state machine no longer exists). However it is also unnecessary since `stop()` cancels the task explicitly. Could remove `[weak self]` here too for symmetry, but the risk is lower. Marked P3 was considered and set below threshold.

- **Infinite retry on SHA mismatch (non-placeholder)**: If a real download produces a mismatch (network corruption), the code retries once. This is intentional behavior — not a loop, because on a successful retry the SHA will match. Only a bug if the SHAs are wrong (see P1-1).

- **`NoveltyDetector` not being an actor**: Correct — it is owned exclusively by `AmbientAnnounceCoordinator` (an actor) and has value semantics. No concurrent access is possible.

- **`RecallGestaltFormatter` switch cases 1-5 hardcoded**: This is intentional (Siri-style verbal counting for common cases). Not an OCP violation — the spoken phrase format is a product decision, not a point of extension.

- **`AVAudioSession.sharedInstance()` on visionOS**: On visionOS, `AVAudioSession` is available with some limitations. For a non-critical chime renderer where errors are logged and skipped, this is acceptable. No API violation.

- **Force-unwrap `AVAudioFormat`**: While noted, `AVAudioFormat(standardFormatWithSampleRate:channels:)` with well-known values (44100 Hz, 2 channels) will not fail in practice. Below P3 threshold.

---

## Deduplication Log

| Merged Finding | Source Agents | Kept Version |
|---|---|---|
| `didFinishDownloadingTo` temp URL race | Security Hunter + Concurrency Specialist | Concurrency Specialist (more precise) |
| SHA verification blocking @MainActor | Quality Analyst + Concurrency Specialist | Quality Analyst (broader context) |
| `[weak self]` in listenTask | Concurrency Specialist + SOLID | Concurrency Specialist (more detail) |
| `ensureDirectoryExists` silent failure | Quality Analyst (solo) | Quality Analyst |
| Placeholder SHAs | Security Hunter (solo) | Security Hunter |

Total raw findings: 14. After deduplication: 12. After <60 confidence filter: 12. Final published: 12 (P0:2, P1:3, P2:4, P3:3).
