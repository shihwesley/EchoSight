---
name: gemma-enrichment
description: Gemma 4 E2B on mlx-swift — async enrichment write path + synchronous read paths for recall gestalt and ambient room labels
phase: 3
sprint: 1
parent: root-spec
depends_on: [root, detector, annotation-store, observability]
status: eng-reviewed
created: 2026-04-21
---

# Gemma Enrichment Spec

## Goal

Run Gemma 4 E2B (Q4) via mlx-swift as the reasoning backbone for three v0.1 consumers:

1. **Async enrichment (write path)** — background queue enriches `WorldAnnotation.description` off the critical path. Never blocks scene mode.
2. **Recall gestalt (synchronous read path, new)** — `summarize(annotations:) -> String` called by `spatial-recall` on first-press. User waits; 1.5 s budget.
3. **Ambient room label (synchronous read path, new)** — `inferRoomLabel(anchor:, annotations:, meshClassification:) -> String` called by `ambient-announce` on cold-anchor detection. 1.5 s budget.

The single `GemmaRunner` must serve all three consumers through a priority queue so user-waiting calls (recall / ambient) preempt background enrichment.

**Scope change under CEO review (EXPANSION):** this spec grew from "async enrichment writer" to "Gemma backbone with three consumers." Priority queue + concurrency model is new.

## Requirements

- mlx-swift Gemma 4 E2B Q4 weight loading + warm-up on first launch (after download)
- **`GemmaRunner`** public API:
  - `enrich(context:) -> String` (async, low priority, used by enrichment queue)
  - `summarize(annotations:) -> String` (async, high priority, 1.5 s timeout, used by spatial-recall)
  - `inferRoomLabel(anchor:annotations:meshClassification:) -> String` (async, high priority, 1.5 s timeout, used by ambient-announce)
- **Priority queue in `GemmaRunner`**: user-waiting calls (summarize, inferRoomLabel) preempt in-flight enrichment; enrichment call in progress is cancelled, high-priority call runs, enrichment re-queued
- Token budgets: enrichment ≤40, summarize ≤30, inferRoomLabel ≤20
- Enrichment queue: max queue depth 8, drop oldest; enrichment write-back to `WorldAnnotation.description`
- Enrichment speak rule unchanged: speak only IF user is still listening AND hasn't moved >0.5 m since capture AND current mode is scene (not recall/read/silent)
- Memory: verify <2.5 GB resident after warmup
- Callers ALWAYS receive a response within budget — high-priority calls MUST have a template fallback if model times out (fallback composition lives in caller's spec, not here)

## Acceptance Criteria

- [ ] Cold launch → Gemma ready within 5 s after model download complete
- [ ] Enrichment generation <2 s wall-clock p95 on Apple Vision Pro
- [ ] `summarize(annotations:)` returns within 1.5 s p95 for 5-annotation input
- [ ] `inferRoomLabel(...)` returns within 1.5 s p95
- [ ] Priority preemption test: enrichment mid-flight cancels within 100 ms when summarize arrives
- [ ] Preempted enrichment re-enters queue (not dropped silently)
- [ ] Memory-pressure test: 10 consecutive scene captures + 3 recall calls → no eviction / OOM
- [ ] All three consumers cancellable (user leaves feature → in-flight gen discarded)
- [ ] Unit tests mock mlx backend and assert priority queue behavior + per-consumer timeout

## Technical Approach

Separate the model runner (mlx-swift inference loop) from the orchestrator (priority queue, cancellation, memory budget). Single-GPU Gemma instance; priority queue serialises access. High-priority slot size = 1; enrichment slot blocked while high-priority runs.

Prompt templates:
- Enrichment: short JSON schema input `{detections, distances, classifications}` → 1-sentence output
- Summarize: `{annotations: [{label, distance, direction}]}` → 1-sentence gestalt
- Room label: `{meshClassificationDistribution, annotations, anchorAge}` → 1-3 word noun phrase ("living room", "office space", "corridor")

No chain-of-thought anywhere.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Reasoning/GemmaRunner.swift` | mlx-swift inference wrapper + public enrich/summarize/inferRoomLabel API |
| `Sources/EchoSightCore/Reasoning/GemmaPriorityQueue.swift` | High/low priority scheduler with preemption |
| `Sources/EchoSightCore/Reasoning/EnrichmentOrchestrator.swift` | Enrichment queue + throttle + write-back |
| `Sources/EchoSightCore/Reasoning/EnrichmentPromptBuilder.swift` | Enrichment schema prompt |
| `Sources/EchoSightCore/Reasoning/SummarizePromptBuilder.swift` | Recall-gestalt prompt |
| `Sources/EchoSightCore/Reasoning/RoomLabelPromptBuilder.swift` | Ambient-label prompt |
| `Sources/EchoSightCore/Reasoning/GemmaModelManager.swift` | Load / unload / warmup |
| `Tests/EchoSightCoreTests/EnrichmentOrchestratorTests.swift` | Queue + cancel behavior (mocked runner) |
| `Tests/EchoSightCoreTests/GemmaPriorityQueueTests.swift` | Preemption + re-enqueue |
| `Tests/EchoSightCoreTests/EnrichmentPromptBuilderTests.swift` | Prompt shape |
| `Tests/EchoSightCoreTests/SummarizePromptBuilderTests.swift` | Prompt shape |
| `Tests/EchoSightCoreTests/RoomLabelPromptBuilderTests.swift` | Prompt shape |

## Tasks

1. Add mlx-swift SPM dep (upgrade from placeholder)
2. Implement `GemmaRunner` with warm-up + the three public async API methods
3. Implement `GemmaPriorityQueue` with preemption + re-enqueue semantics
4. Implement `EnrichmentPromptBuilder`, `SummarizePromptBuilder`, `RoomLabelPromptBuilder` + tests
5. Implement `EnrichmentOrchestrator` (unchanged role: queue + throttle for enrichment-only)
6. Wire write-back to `AnnotationStore`
7. Priority-preemption integration test
8. Memory-pressure stress test on device with all three consumers firing

## Dependencies

- **Needs from:** root, detector (detections/schema), annotation-store (write target, annotation queries)
- **Provides to:** onboarding-download (Gemma weight file), spatial-recall (`summarize` API), ambient-announce (`inferRoomLabel` API), future v1.0 voice router (reasoner backbone)

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** Added two synchronous read paths (`summarize`, `inferRoomLabel`) and a priority queue. Original plan had Gemma as a write-only async enricher; under expansion it becomes the reasoning backbone with three consumers. Priority preemption is new — recall/ambient calls must not wait behind a low-priority enrichment.
- **Premise validation:** Single Gemma instance holds — we can't afford a second model in memory. Priority queue is the only way to serve user-waiting calls without a second instance.

### Dream State Delta
At 12-month ideal, Gemma is the voice router for voice-input features (v1.0) and the continuous scene narrator (v1.0+). The priority queue design here is deliberately forward-compatible — add new consumers by adding priority slots, not by spawning model instances.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| Preemption | Enrichment cancel doesn't land in 100 ms | Recall/ambient speech delayed | Acceptance criterion #5 | Yes |
| Timeout | Gemma exceeds 1.5 s for summarize | Caller falls back to template (caller's responsibility) | Integration test | Yes |
| Memory | Model weight + activations overshoot 2.5 GB | OS evicts app | Memory stress test | Yes |
| Re-enqueue | Preempted enrichment dropped silently | Annotation never enriched | Preemption + re-enqueue test | Yes |
| Warm-up | First call before warm-up complete | Wait on cold start | Warm-up gating logic | Partial |

### Deferred Work
- [ ] Multi-model routing (different sizes for different tasks) — v1.0+
- [ ] Streaming token output for long enrichments — v1.0 latency polish
- [ ] Voice-router consumer — v1.0 when voice lands

## Eng Review

- **Depth:** BIG
- **Scope changes (concurrency correctness):**
  - **Preemption cadence pinned:** mlx-swift token generation is cooperative. `GemmaRunner` checks `Task.isCancelled` between each generated token. At ~20 ms/token on M2 Ultra (visionOS Neural Engine family comparable), worst-case preemption latency is ~20 ms — comfortably inside the 100 ms acceptance criterion.
  - **Re-enqueue position policy pinned:** preempted enrichment re-enters the queue at the **head**, not the tail. Rationale: the work was already in progress; other enrichments haven't started yet. Re-enqueuing at tail would penalize the interrupted task twice. This also makes enrichment progress ergonomic — a user doing back-to-back recall calls doesn't starve enrichment indefinitely because the same enrichment keeps resuming.
  - **Snapshot pinning for read paths:** `summarize(annotations:)` and `inferRoomLabel(...)` pin their input at call entry by copying into an immutable value. Rehydration / writes to annotation-store during the call don't affect the output. (Coordinated with annotation-store's Eng Review section.)
  - **Token budgets enforced as hard limits:** `enrich ≤40`, `summarize ≤30`, `inferRoomLabel ≤20`. mlx-swift's `maxTokens` parameter set per call. Prevents runaway generation when the model latches onto a verbose output.
  - **Fallback contract clarified:** callers (spatial-recall, ambient-announce) own their template fallback. `GemmaRunner` throws `.timeout` or `.modelUnavailable`; caller catches and speaks template phrase. This spec does not compose user-facing fallback strings.

### Data Flow

```
consumers (priority)           GemmaPriorityQueue          GemmaRunner (single GPU instance)
 │                              │                           │
 │ recall.summarize (.high) ───→│ if running .low: cancel   │
 │                              │ push caller to .high slot │
 │                              ├─ mlx inference run ──────→│
 │                              │   cancelled.low           │
 │                              │   re-enqueue .low at head │
 │                              │                           │
 │ ambient.inferRoomLabel(.high)│ wait if .high slot busy   │
 │ enrichment (.low) ──────────→│ append to tail            │
 │                              │                           │
                                │ on each token generated:
                                │   if Task.isCancelled: stop
                                │   else: accumulate
```

### State Diagram (priority queue)

```
 .idle ──enrich──→ .runningLow ──summarize/inferLabel arrives──→ .cancellingLow
                                                                    │
                                                                    ▼
                           .runningHigh ←──dispatched (re-enqueue prior .low at head)
                                │
                                ▼
                          .idle (or dispatch next .low from head)
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Enrich async | Integration | <2 s wall, write-back to store | Queue full (>8) → drop oldest enrichment | Back-to-back enrichments serialize |
| Summarize | Integration | <1.5 s p95 for 5 annotations | Timeout → throws `.timeout`; caller templates | Empty annotations → minimal prompt, short output |
| inferRoomLabel | Integration | <1.5 s p95 | Timeout → throws; ambient uses mesh-classification fallback | Sparse mesh → low-confidence label |
| Preemption cadence | Unit (mocked runner) | Low-priority cancels within 100 ms (20 ms/token check) | Mock run with slow tokens (50 ms) → still under 100 ms | Preempt-during-first-token edge case |
| Re-enqueue head | Unit | Preempted enrichment resumes next, before queue tail | Multiple preemptions in a row → enrichment still eventually completes | Re-enqueue when queue already has 8 items → drops tail, not head |
| Snapshot pinning | Integration | Annotations mutated mid-summarize → summarize output reflects entry snapshot | Concurrent writes during summarize don't cause races | Writes finish before summarize → summarize still uses entry snapshot |
| Token budget | Unit | Output ≤ budget tokens | Model wants to continue → truncated cleanly | Budget=0 → immediate stop |
| Warm-up | Integration | Model ready <5 s post-download | Pre-warm-up call → wait + log | Warm-up fails → `.modelUnavailable` |
| Memory pressure | Integration | 10 captures + 3 recalls → no eviction | Memory warning → unload on backgrounding, reload on foreground | Concurrent .high + .low → serialized, no OOM |

### Critical Paths

- `.high` preemption within 100 ms — the guarantee recall and ambient depend on
- Re-enqueue-at-head prevents enrichment starvation under recall-heavy usage
- Memory resident stays <2.5 GB — single most likely catastrophic failure under load
- All three consumers cancel cleanly when caller's Task is cancelled (propagation through mlx loop)

### Performance Notes

- mlx-swift Gemma 4 E2B Q4 on M2-class Neural Engine: ~15-25 tokens/sec (per published benchmarks for similar models); 20 ms/token check cadence
- Summarize (~30 tokens) → ~1.2-1.5 s — tight to the 1.5 s budget; monitor p95 on device
- inferRoomLabel (~20 tokens) → ~0.8-1.0 s — comfortable margin
- Enrichment (~40 tokens) → ~1.6-2.0 s — acceptable (async, not user-waiting)

### Observability

- **Log category:** `echosight.gemma`
- **Key events:**
  - `gemma.warmUp.started` / `gemma.warmUp.completed(durationMs)`
  - `gemma.call.enqueued(priority, queueDepth)`
  - `gemma.call.started(priority, callId)`
  - `gemma.call.preempted(callId, reason)`
  - `gemma.call.reEnqueued(callId, position=head)`
  - `gemma.call.completed(callId, tokensGenerated, durationMs)`
  - `gemma.call.timeout(callId, priority)`
  - `gemma.call.cancelled(callId, source)`
  - `gemma.memory.residentMb` (periodic sample)
