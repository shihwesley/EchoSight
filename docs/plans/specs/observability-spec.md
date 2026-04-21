---
name: observability
description: swift-log categories, pipeline metrics ring buffer, in-app DebugConsoleView, log export — cross-cutting Phase 1 spec
phase: 1
sprint: 1
parent: root-spec
depends_on: [root]
status: eng-reviewed
created: 2026-04-21
---

# Observability Spec

## Goal

Own logging taxonomy, pipeline metrics, and an in-app debug surface so a BLV alpha tester can diagnose silent failures without a tethered Mac. Every feature spec binds to this spec's categories and records timing into a shared ring buffer that a `DebugConsoleView` renders accessibly.

Silent failures are a quality issue in this product (mode fires but no speech; ambient suppresses when it shouldn't; rehydration misses). Zero specs currently address observability — this spec fills the gap.

## Requirements

- Single `swift-log` bootstrap at app launch (`project-skeleton` calls into this spec)
- One log category per functional area:
  - `echosight.scene`, `echosight.recall`, `echosight.ambient`, `echosight.read` (OCR)
  - `echosight.fusion`, `echosight.gemma`, `echosight.detector`, `echosight.capture`
  - `echosight.anchor`, `echosight.modal`, `echosight.store`, `echosight.speech`
  - `echosight.download`, `echosight.spatial`, `echosight.app`
- `OSLogHandler` backend (writes to `os_log`, visible in Console.app and Instruments); dev builds also mirror to an in-memory ring for `DebugConsoleView`
- `PipelineMetricsBuffer` — actor-backed ring buffer, `N=32` per category
  - Event shape: `{timestamp: Date, category: String, event: String, durationMs: Double?, outcome: Outcome, metadata: [String: String]}`
  - `Outcome` enum: `.ok | .degraded(reason) | .cancelled | .failed(reason) | .dropped(reason)`
  - Public API: `record(_ event: PipelineEvent)`, `recent(category:) -> [PipelineEvent]`, `recentAll() -> [PipelineEvent]`
- `DebugConsoleView` — SwiftUI, fully VoiceOver navigable
  - Sections: per-category last-N event log, priority queue depth (Gemma), pose ring fullness (spatial-core), anchor metadata summary (annotation-store), speech state, current mode
  - Live-updating via `AsyncStream` from metrics buffer
  - Reachable from Settings; in Release builds, gated behind a 5-tap-on-logo easter egg (standard iOS debug pattern) so it doesn't clutter production UX
- `logExport()` — writes last 15 min of logs + metrics to a shareable file in the app's Documents directory, opens standard iOS share sheet
  - Anchor UUIDs hashed (not raw) in exports for privacy
  - File includes: app version, model versions, OS version, session start time, full log tail, metrics buffer snapshot
- All feature specs gain a `## Observability` subsection naming their category + 3-5 key events
- Privacy: exported logs never contain raw captured frames or OCR'd text content (only event types + durations)

## Acceptance Criteria

- [ ] Each of the 15 categories fires at least one log event per user-observable action (validated by integration test suite)
- [ ] `PipelineMetricsBuffer.record` is non-blocking from caller's perspective (actor hop is fire-and-forget internally)
- [ ] `DebugConsoleView` first-load renders <100 ms with 32-entry-per-category buffer populated
- [ ] VoiceOver navigation of `DebugConsoleView` reads: section header → last event type → duration → outcome
- [ ] `logExport()` produces a file <1 MB for a typical 15-min session
- [ ] Exported file is plain-text readable (no binary blobs)
- [ ] Anchor UUIDs in exports are SHA-256-hashed, not raw
- [ ] No captured frame bytes, no OCR'd text content, no Gemma prompt text in exports
- [ ] Release build: `DebugConsoleView` reachable only via 5-tap-logo gesture
- [ ] Unit tests: ring buffer overwrite, category isolation, export file privacy filter, metrics-record non-blocking assertion

## Technical Approach

`PipelineMetricsBuffer` is an `actor` with a `[String: [PipelineEvent]]` dict keyed by category, each value a fixed-capacity deque (overwrite-oldest at capacity 32). `record` is `nonisolated` and enqueues onto a detached Task; caller never awaits.

Log bootstrap in `project-skeleton`'s `EchoSightApp.init` calls `ObservabilityBootstrap.install()` which:
1. Sets `LoggingSystem.bootstrap` to a multiplex handler (os_log + in-memory ring)
2. Creates the shared `PipelineMetricsBuffer` instance
3. Exposes both via a `DependencyContainer` / environment injection

`DebugConsoleView` subscribes to a filtered `AsyncStream<PipelineEvent>` for live tail, plus pulls `recentAll()` on first render.

Log export: compose a text buffer in a background Task, write to a temp file, return URL; UIActivityViewController does the rest.

Privacy filter is a single function `sanitize(event: PipelineEvent) -> PipelineEvent` that strips any metadata key matching `/content|text|frame|prompt|transcript/i`; tested exhaustively.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Observability/ObservabilityBootstrap.swift` | LoggingSystem.bootstrap, metrics buffer singleton |
| `Sources/EchoSightCore/Observability/PipelineMetricsBuffer.swift` | Actor ring buffer |
| `Sources/EchoSightCore/Observability/PipelineEvent.swift` | Event value type + Outcome enum |
| `Sources/EchoSightCore/Observability/LogCategories.swift` | All 15 category constants |
| `Sources/EchoSightCore/Observability/LogExporter.swift` | Compose + sanitize + write shareable file |
| `Sources/EchoSightCore/Observability/PrivacyFilter.swift` | Sanitize event metadata |
| `Sources/EchoSightApp/Debug/DebugConsoleView.swift` | SwiftUI accessible view |
| `Sources/EchoSightApp/Debug/DebugConsoleSection.swift` | Per-category collapsible section |
| `Sources/EchoSightApp/Debug/LogoTapGate.swift` | 5-tap-logo gesture to reveal in Release |
| `Tests/EchoSightCoreTests/PipelineMetricsBufferTests.swift` | Ring buffer, category isolation |
| `Tests/EchoSightCoreTests/PrivacyFilterTests.swift` | Sanitize coverage |
| `Tests/EchoSightCoreTests/LogExporterTests.swift` | File contents, size, anchor hashing |

## Tasks

1. Define `PipelineEvent` + `Outcome` value types
2. Implement `PipelineMetricsBuffer` actor with overwrite-oldest semantics
3. Implement `ObservabilityBootstrap.install()` wiring swift-log multiplex
4. Define `LogCategories` constants
5. Implement `PrivacyFilter` sanitize + unit tests
6. Implement `LogExporter` composing text file
7. Build `DebugConsoleView` SwiftUI with accessible sections
8. Implement `LogoTapGate` 5-tap reveal for Release builds
9. Add `## Observability` subsection to every feature spec (bookkeeping, done in eng review pass)
10. Integration test: each category fires ≥1 event on user action

## Dependencies

- **Needs from:** root
- **Provides to:** every other spec (logging + metrics); `project-skeleton` calls `ObservabilityBootstrap.install()` in app init

## Eng Review

- **Depth:** BIG
- **Scope decision:** New spec per Gate 6. Silent failures are correctness for a BLV accessibility alpha. `DebugConsoleView` + `logExport` are ~1-2 days of work for a disproportionate quality return.
- **Gate alignment:**
  - Gate 6 (observability) → this spec exists
  - Indirectly supports all other gates by making their failure modes diagnosable from a device

### Data Flow

```
feature spec code           ObservabilityBootstrap        PipelineMetricsBuffer
 │                           (installed at app init)       (actor, ring per category)
 │                           │                              │
 ├─ log.info("event") ─────→ │ os_log + in-memory ring      │
 │                           │                              │
 ├─ metrics.record(event) ──→ │                              │
 │                           │                              ├── append to [category]
 │                           │                              ├── evict if len > 32
 │                           │                              │
                                                            │
 DebugConsoleView ←─ recent(category:) ───────────────────── │
                  ←─ AsyncStream<PipelineEvent> ───────────── │
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Bootstrap | Integration | Install once, all categories reachable | Install called twice → idempotent | Pre-install log calls → buffered or dropped cleanly |
| Metrics record | Unit | Event appears in `recent(category:)` | Category typo → lands in its own bucket (silent) | 1000 events/sec → no backpressure on caller |
| Ring overwrite | Unit | 33rd event evicts 1st | Buffer capacity configurable per category? (no, fixed 32) | Simultaneous record from two tasks → both preserved |
| Privacy filter | Unit | `content`/`text`/`frame`/`prompt` keys stripped | Mixed-case key "Content" → also stripped | Nested metadata dict → recursive sanitize |
| Log export | Unit | <1 MB file, anchor UUIDs hashed | >1 MB session → truncate oldest, log warning | Zero events → file still produced with header only |
| DebugConsoleView | UI test | Loads <100 ms with full buffer | VoiceOver traversal reads in section order | Empty category → section shows "no events" |
| Release reveal | Manual | 5-tap logo reveals in Release | Release build without DEBUG → view still available behind gate | Accidental 4-tap → no reveal |

### Critical Paths

- App launch bootstrap completes before any feature code logs (blocks on bootstrap)
- Every log call sanitized through privacy filter before export (never raw content in file)
- Metrics record never blocks feature code critical path

### Failure Modes

| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|--------------|-----------|---------|---------|
| Bootstrap | `LoggingSystem.bootstrap` called twice (iOS lifecycle quirk) | Second install no-op with warning | Idempotency test | `echosight.app` warn |
| Ring overwrite | Category typo creates phantom bucket | Event lost from intended category | Code review + category constants enum | — |
| Privacy filter | Key name not matched by regex | Content leaks to export | Allowlist mode considered; deferred | Audit required before each release |
| Export size | 15-min session >1 MB | Truncation warning in exported file | Truncate + log warning test | `echosight.app` warn |
| DebugConsoleView | Buffer churn during render | UI jitters | AsyncStream debounce 100 ms | — |
| Release reveal | Gesture fires during normal use | User confused | 5-tap with <400 ms between taps required | — |

### Observability

Meta-observability: this spec logs its own bootstrap + export events under `echosight.app`.

### Deferred Work
- [ ] Remote crash / metrics pipeline (v1.0 when beta moves to wider testing)
- [ ] Per-user opt-in telemetry (v1.0, privacy review required)
- [ ] Metrics export to Instruments (v1.0+ developer polish)
- [ ] Log level override from DebugConsoleView (v1.0 dev QoL)
