---
name: annotation-store
description: WorldAnnotation persistence — SQLite keyed by visionOS world anchor, spatial hash for O(1) queries, anchor-metadata for ambient announce
phase: 3
sprint: 1
parent: root-spec
depends_on: [root, fusion, spatial-core, observability]
status: eng-reviewed
created: 2026-04-21
---

# Annotation Store Spec

## Goal

Persist `WorldAnnotation`s across sessions, keyed by visionOS persistent world anchor. Fast spatial queries ("what's within N meters of my head pose") via in-memory spatial hash. Merge duplicate annotations within 30 cm threshold. Under CEO review expansion, the store gains **anchor-metadata** tracking (last-seen timestamp, visit count, user-confirmed room label) to serve `ambient-announce`'s novelty detection and `spatial-recall`'s cross-session rehydration.

**Scope change under CEO review (EXPANSION):** store goes from write-only (v0.1 had no reader) to three-consumer read surface:
- `spatial-recall` reads via `nearestAnnotations` + `loadByAnchor`
- `ambient-announce` reads via new `lastSeenAnchorAt` + `anchorMetadata`
- `gemma-enrichment` reads via existing write-target interface for inferRoomLabel context

## Requirements

- `WorldAnnotation` struct per brainstorm section 7 (id, worldPosition, worldAnchor, falconLabel, meshClassification, confidence, description?, createdAt, lastSeenAt, captureCount)
- SQLite store via GRDB (or plain SQLite3) — one row per annotation
- Cross-session persistence keyed by `worldAnchor: UUID`
- Spatial hash (uniform grid, 1 m cells) indexed by world position for nearby queries
- `merge(existing:, incoming:)` within 30 cm: increment `captureCount`, update `lastSeenAt`, keep higher confidence label
- `nearestAnnotations(to: headPose, radius: 5m) -> [WorldAnnotation]`
- `load(worldAnchor:)` rehydrates annotation set when anchor recognized next session
- `purge(olderThan: Date)` for decay policy (open question — default off for v0.1)

**New under expansion:**
- `AnchorMetadata` table: `(anchorId UUID PRIMARY KEY, firstSeenAt Date, lastSeenAt Date, visitCount Int, userLabel String?, inferredLabel String?)`
- `lastSeenAnchorAt(anchorId:) -> Date?` — used by ambient-announce's 30-min novelty rule
- `recordAnchorEncounter(anchorId:)` — updates lastSeenAt and visitCount atomically
- `setAnchorLabel(anchorId:, userLabel:)` and `setAnchorInferredLabel(anchorId:, inferredLabel:)` — separate fields so user corrections override inferred labels
- `annotationCount(anchorId:) -> Int` — used by ambient-announce's speech content ("M annotations remembered")

## Acceptance Criteria

- [ ] Write 100 annotations, relaunch app, confirm all present with identical world positions
- [ ] Spatial query returns ≤5 ms for 1000-annotation store
- [ ] Merge test: two captures of "blue chair" within 20 cm collapse to single annotation with `captureCount == 2`
- [ ] World-anchor re-recognition triggers annotation load (integration test on sim)
- [ ] `lastSeenAnchorAt` returns correct Date after `recordAnchorEncounter` with concurrent writes
- [ ] `setAnchorLabel` overrides `inferredLabel` in read queries (user label wins)
- [ ] `annotationCount(anchorId:)` returns correct count for anchors with 0 / 1 / 100 annotations
- [ ] Unit tests cover merge thresholds, spatial hash cell coverage, SQLite round-trip, anchor-metadata CRUD

## Technical Approach

GRDB gives type-safe SQLite with migrations. Spatial hash is `[GridCell: Set<UUID>]`; each annotation update re-indexes its cell. Persistence keyed by both primary UUID and foreign world-anchor UUID. Decoupled from fusion: fusion writes candidates onto a queue, this spec drains the queue.

New `AnchorMetadata` table uses `anchorId` as primary key; foreign key from `WorldAnnotation.worldAnchor` to `AnchorMetadata.anchorId`. `recordAnchorEncounter` is an UPSERT: insert if first visit (visitCount = 1), update lastSeenAt + visitCount++ if existing.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Memory/WorldAnnotation.swift` | Domain model |
| `Sources/EchoSightCore/Memory/AnchorMetadata.swift` | Per-anchor metadata domain model (new) |
| `Sources/EchoSightCore/Memory/AnnotationStore.swift` | GRDB-backed store + queries (expanded API) |
| `Sources/EchoSightCore/Memory/SpatialHash.swift` | Uniform grid index |
| `Sources/EchoSightCore/Memory/AnnotationMerger.swift` | 30 cm merge rule |
| `Sources/EchoSightCore/Memory/AnchorRehydrator.swift` | World-anchor → annotation load |
| `Tests/EchoSightCoreTests/AnnotationStoreTests.swift` | CRUD + migration |
| `Tests/EchoSightCoreTests/SpatialHashTests.swift` | Query correctness |
| `Tests/EchoSightCoreTests/AnnotationMergerTests.swift` | Threshold rules |
| `Tests/EchoSightCoreTests/AnchorMetadataTests.swift` | Anchor metadata UPSERT + label precedence |

## Tasks

1. Add GRDB SPM dep
2. Implement `WorldAnnotation` + GRDB migrations
3. Implement `AnchorMetadata` + migration (new table)
4. Implement `AnnotationStore` CRUD + radius query + anchor-metadata API
5. Implement `SpatialHash` grid
6. Implement `AnnotationMerger` (30 cm threshold)
7. Implement `AnchorRehydrator` world-anchor load path
8. Comprehensive unit tests including anchor-metadata precedence

## Dependencies

- **Needs from:** root, fusion (candidate queue)
- **Provides to:** gemma-enrichment (annotations + room-label context), spatial-recall (`nearestAnnotations` + anchor rehydration), ambient-announce (`lastSeenAnchorAt`, `annotationCount`, `AnchorMetadata`), future v1.0 spatial-memory-query feature

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** Added `AnchorMetadata` table + three new public queries (`lastSeenAnchorAt`, `annotationCount`, `setAnchorLabel`/`setAnchorInferredLabel`). Original plan had annotations as terminal storage; under expansion, anchor-level metadata unlocks ambient-announce's novelty rule and gives the store a proper read surface. The "moat is cross-session persistence" claim now has three user-visible exercise points, not zero.
- **Premise validation:** SQLite-via-GRDB holds — no shift to a different backend needed. 30-cm merge threshold holds. Decay-policy-off-for-v0.1 holds.

### Dream State Delta
At 12-month ideal, the store is a *spatial-temporal* memory — annotations evolve over time, room labels get learned from repeated visits, decay policies clean stale entries. The `AnchorMetadata` model here is the seed of that evolution. Keep `visitCount` + `firstSeenAt` even though v0.1 only reads `lastSeenAt`; those fields enable future decay-by-frequency policies without a migration.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| UPSERT race | Concurrent `recordAnchorEncounter` from two threads | Visit count under-incremented | Acceptance criterion #5 | Yes |
| Anchor UUID instability | ARKit assigns new UUID to same physical place | Novelty triggers incorrectly | Flagged for ambient-announce to handle | No |
| Label precedence | User sets label, later Gemma inference overrides | Wrong label spoken | Acceptance criterion #6 | Yes |
| Migration | v0.1 → v0.2 schema change without anchor-metadata back-fill | Missing data on upgrade | Migration test needed (v0.2 concern) | Partial |

### Deferred Work
- [ ] Anchor UUID stability heuristics (merge anchors within 1 m) — v1.0
- [ ] Decay policy (default off in v0.1) — v1.0 when storage concerns emerge
- [ ] Full-text search on annotation descriptions — v1.0 voice-query feature
- [ ] Annotation export (CSV / JSON) for user backups — v1.0+

## Eng Review

- **Depth:** BIG
- **Scope changes (Gate 5):**
  - `AnchorRehydrator` subscribes to `AnchorChangeEvent(.rerecognized)` from `spatial-core`. On each `.rerecognized`, load that anchor's annotations from SQLite into the in-memory spatial hash. No user-facing signal. Plumbing-only.
  - Public API addition: `isRehydrated(anchorId:) -> Bool` so consumers (spatial-recall) can know the cache is warm.
  - `AnchorChangeEvent.kind` discrimination: spatial-core checks `anchorMetadata(anchorId:)` before emitting (see spatial-core's Eng Review). `.new` = no row; `.rerecognized` = row exists.
  - Snapshot pinning: `summarize(annotations:)` and other Gemma read paths receive an immutable snapshot of annotations; concurrent rehydration mid-call cannot mutate the snapshot. Enforced by copying to an immutable array at call entry.

### Data Flow

```
 spatial-core                 annotation-store
  │                            │
  ├─ AnchorChangeEvent          │
  │  (.new / .rerecognized) ──→│ AnchorRehydrator subscriber
  │                            │
  │                            │ if .rerecognized:
  │                            │   load annotations from SQLite
  │                            │   insert into SpatialHash
  │                            │   mark anchorId rehydrated=true
  │                            │   emit metric
  │                            │
 fusion ─── candidates queue ─→│ drain queue
                                │ merge within 30 cm
                                │ write to SQLite + SpatialHash
                                │
 spatial-recall ── nearestAnnotations(pose, 5m) ──┐
 ambient-announce ── lastSeenAnchorAt / annotationCount ──┤
 gemma-enrichment ── snapshot for summarize / inferRoomLabel ──┘
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Write + relaunch | Integration | 100 annotations persist, rehydrate on app restart | SQLite corrupted → restore from last good state + log | Empty DB on fresh install |
| Merge 30 cm | Unit | Two captures of same label within 20 cm → count=2 | Exactly at 30 cm boundary → deterministic merge/no-merge | 30-cm neighbors with different labels → no merge |
| Spatial query | Unit | <5 ms for 1000 annotations | Empty cache → [] | Radius=0 → only exact-pose matches |
| AnchorRehydrator | Integration | `.rerecognized` event → `isRehydrated(anchorId)=true` within 200 ms | Rehydrate called twice → idempotent | `.rerecognized` arrives during another rehydrate → queued |
| Snapshot pinning | Integration | Summarize sees immutable snapshot even while rehydrate mutates cache | Concurrent write during summarize → summarize snapshot unaffected | 100 concurrent nearestAnnotations calls |
| UPSERT race | Integration | 10 threads call `recordAnchorEncounter` → visitCount increments atomically | Serialization via single write transaction | — |
| Label precedence | Unit | `setAnchorLabel` overrides `setAnchorInferredLabel` in reads | User-set label persists across app restart | Both set → user wins deterministically |

### Critical Paths

- Rehydration completes before spatial-recall's first query after re-entry (tight; tests must cover the race)
- Merge threshold deterministic at boundary values
- Snapshot immutability (Swift value-type arrays handle this naturally, but spec it explicitly)

### Performance Notes

- SQLite with GRDB is O(log N) for indexed queries; N for v0.1 expected ~100-500 annotations per user
- Spatial hash adds O(1) amortized radius queries at the cost of ~N bytes of index
- Rehydration load for typical anchor (tens to low-hundreds of annotations) is <200 ms including SQLite read + spatial hash insert

### Observability

- **Log category:** `echosight.store`
- **Key events:**
  - `store.write(annotationId, merged)` — merged=true if collapsed into existing
  - `store.query.nearest(pose, radius, resultCount, durationMs)`
  - `store.query.anchorMetadata(hashedAnchorId, hit)`
  - `store.rehydrate.started(hashedAnchorId)`
  - `store.rehydrate.completed(hashedAnchorId, annotationCount, durationMs)`
  - `store.anchorEncounter.recorded(hashedAnchorId, visitCount)`
  - `store.migration.applied(fromVersion, toVersion)`
