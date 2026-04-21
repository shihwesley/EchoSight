---
name: ocr
description: Read mode — capture → VNRecognizeTextRequest → reading-order TTS
phase: 2
sprint: 2
parent: root-spec
depends_on: [root, modal-input, capture, speech-out, observability]
status: eng-reviewed
created: 2026-04-21
---

# OCR Spec (Read Mode)

## Goal

When user is in read mode and presses the Capture Button, capture a frame, run `VNRecognizeTextRequest` on it, and speak the detected text in reading order. Zero model download (Vision framework is OS-provided). Covers the #1 BLV accessibility need (reading signs, mail, labels, screens) that v0.1 originally deferred to v1.0.

## Requirements

- Subscribe to `ModeFiredEvent(.read)` from `modal-input`
- Consume `CapturedFrame` from `PassthroughCaptureSource`
- Run `VNRecognizeTextRequest` with `recognitionLevel = .accurate`, `usesLanguageCorrection = true`
- Reading-order heuristic: sort observations top-to-bottom, left-to-right within similar y-bands (y-band threshold ~5% of image height)
- Confidence gate: drop observations below confidence 0.4 before speaking
- Speak via `SpeechOut` (shared with `scene-description` spec)
- Graceful degradation: no text detected → "I don't see any readable text"
- Time budget: ≤1.5 s p95 from button-up to first syllable
- Cancellable (user switches mode or fires another press → previous speech cut short)
- Long-text handling: if >30 seconds of speech, offer an interrupt mechanism (brief pause every 10 s, next press in read mode cuts current and re-captures)

## Acceptance Criteria

- [ ] Fixture image with clear text returns correct transcription in reading order
- [ ] Physical-device round-trip ≤1.5 s p95 for signs / labels / book pages
- [ ] Empty-text case speaks graceful fallback
- [ ] Low-confidence observations (e.g., motion-blurred text) are filtered, not spoken as garbage
- [ ] VoiceOver voice respected (same as scene mode)
- [ ] Multi-column layouts tested with sample page image (magazine, newspaper)
- [ ] Unit tests for reading-order heuristic with synthetic `VNRecognizedTextObservation` fixtures

## Technical Approach

Thin pipeline: `CapturedFrame` → `VNRecognizeTextRequest` → reading-order sort → confidence filter → joined string → `SpeechOut`. No ML model beyond what Vision ships. Reuse `PassthroughCaptureSource` and `SpeechOut` from other specs — this spec adds ~1 class and a unit-tested sort heuristic.

Reading-order heuristic: partition observations into y-bands (rows), sort by minX within each band, concatenate. Naive but handles signs / labels / bullet-pointed lists cleanly; multi-column layouts degrade gracefully (reads left column fully, then right column).

Language detection is off in v0.1 — English only. Multi-language detection is v1.0 work that belongs in a separate spec.

## Files

| File | Purpose |
|------|---------|
| `Sources/EchoSightCore/Features/OcrPipeline.swift` | Orchestrator: capture → recognize → speak |
| `Sources/EchoSightCore/Features/ReadingOrderSorter.swift` | Y-band partition + in-band left-to-right sort |
| `Sources/EchoSightCore/Features/TextConfidenceFilter.swift` | Drop low-confidence observations |
| `Tests/EchoSightCoreTests/ReadingOrderSorterTests.swift` | Sort correctness on synthetic observations |
| `Tests/EchoSightCoreTests/OcrPipelineTests.swift` | Integration with mocked capture + mocked Vision request |

## Tasks

1. Implement `ReadingOrderSorter` with unit tests (y-band + in-band sort)
2. Implement `TextConfidenceFilter` (tunable threshold, default 0.4)
3. Implement `OcrPipeline` orchestrator subscribing to `.read` mode events
4. Reuse `SpeechOut` for output; ensure cancellability on mode change
5. Fixture-image integration test with known-text sample
6. Multi-column layout test (magazine page sample)
7. Perf measurement on device; record p95 in progress.md

## Dependencies

- **Needs from:** root, modal-input (`ModeFiredEvent(.read)`), capture (`CapturedFrame`)
- **Provides to:** none (terminal user-facing feature)

## CEO Review

- **Mode:** EXPANSION
- **Scope decision:** New spec. OCR was explicitly deferred to v1.0 in the original plan. Under expansion, it comes back because (a) `VNRecognizeTextRequest` is OS-provided with zero model download cost, (b) reading is the #1 unmet BLV accessibility need per field research, (c) the Flutter predecessor shipped with text reading — shipping v0.1 without it is a regression against user expectations, (d) the Crown-as-mode pattern absorbs a 4th mode cleanly.
- **Premise validation:** Deferring OCR to v1.0 made sense when v0.1 was "Feature 1 only" and gesture-only with a single press. With modal input already carrying 3 modes, the 4th mode is ~2-3 days of incremental work for a feature that transforms the product from "scene description app" to "BLV reading + scene + memory companion."

### Dream State Delta
At 12-month ideal, OCR is continuous (read-any-text-that-looks-intentional passively) and multi-language. v0.1's gesture-triggered English-only is scaffolding. Keep `ReadingOrderSorter` and `TextConfidenceFilter` as pure functions so they can be fed by a later continuous-text-watcher without modification.

### Failure Modes
| Codepath | Failure Mode | User Sees | Tested? | Logged? |
|----------|-------------|-----------|---------|---------|
| VNRecognizeTextRequest | Motion-blurred capture → low-confidence results | Filter drops everything, graceful fallback | Acceptance criterion #4 | Yes |
| Reading order | Multi-column layout mis-ordered | Reads columns in wrong order | Acceptance criterion #6 | Yes |
| Long text | Novel page / full-document → 30+ s of speech | User can't interrupt naturally | Interrupt mechanism partial-tested | Partial |
| Non-English text | Latin-script non-English (French menu) | Reads with English pronunciation | Flag for v1.0, not tested | No |
| Long pause | Vision request times out | No speech | Surface as error event | Partial |

### Deferred Work
- [ ] Multi-language OCR — v1.0; requires language detection + voice selection
- [ ] Continuous passive text reading (auto-read when text enters FOV) — v1.0 ambient feature
- [ ] Layout preservation for complex docs (tables, forms) — v1.0+
- [ ] Handwriting recognition — v1.0+, separate Vision request type

## Eng Review

- **Depth:** BIG
- **Scope changes:**
  - Gate 2: speech routed through `SpeechOut.speak(priority: .normal)`. `.high` (ambient cold-anchor) will preempt long read sessions — this is correct; a user entering a new room deserves the "welcome back" over continued reading.
  - Gate 3 adjacent: subscribes to `ModeChangeEvent` for mid-read abort. Also subscribes for "new `.read` press during read" — cancels current speech and re-captures.
  - Long-text interrupt mechanism refined: rather than trying to speak 30s+ straight, break at natural paragraph boundaries (double newline or >50 char gap in y-coord). At each break, briefly yield via `SpeechOut.speak` completion + check for cancellation. Next `.read` press triggers re-capture; escape-to-abort = Crown to any other mode.

### Data Flow

```
modal-input                     OcrPipeline                    downstream
 │ ModeFiredEvent(.read) ──────→│                               │
 │                               │ capture.request() ──────────→│ capture
 │                               │ ← CapturedFrame ──────────────│
 │                               │                               │
 │                               │ VNRecognizeTextRequest(       │
 │                               │   .accurate, langCorrect)     │
 │                               │ → [VNRecognizedTextObservation]
 │                               │                               │
 │                               │ TextConfidenceFilter (≥0.4)   │
 │                               │ ReadingOrderSorter (y-band)   │
 │                               │ paragraph-break chunker       │
 │                               │                               │
 │                               │ for each chunk:               │
 │                               │   SpeechOut.speak(            │ speech-out
 │                               │     chunk, .normal) ─────────→│
 │                               │   await completion            │
 │                               │   check cancellation          │
 │                               │                               │
 │ ModeChangeEvent ─────────────→│ cancel pipeline Task          │
 │ ModeFiredEvent(.read) again ─→│ cancel + restart              │
```

### Test Plan

| Flow | Test Type | Happy Path | Failure Path | Edge Cases |
|------|-----------|------------|--------------|------------|
| Fixture text | Unit | Correct transcription in reading order | Blurry fixture → filtered, fallback speech | Empty image → graceful fallback |
| Multi-column | Integration | Left column read fully, then right | Complex magazine layout → degrades gracefully, still reads something | Newspaper with mixed column widths |
| Confidence filter | Unit | <0.4 dropped | All dropped → speak "don't see readable text" | Mixed confidence → only >=0.4 spoken |
| Paragraph chunking | Unit | Natural breaks at double-newline | Single long paragraph → single utterance | No breaks found → full text as one utterance |
| Interrupt mid-read | Integration | Mode change cancels all remaining chunks | New `.read` press during read cancels + re-captures | Chunk boundary cancellation < 200 ms |
| `.high` preemption | Integration | Ambient `.high` preempts current read chunk | OCR pipeline pauses remaining chunks? No — cancels entirely; user re-fires | — |

### Critical Paths

- End-to-end ≤1.5 s p95 from fire to first syllable
- Cancellation propagation (mode change or new press) must cut current speech within ~100 ms
- `.high` preemption by ambient should NOT resume OCR after — cancelled-and-done by design

### Observability

- **Log category:** `echosight.read`
- **Key events:**
  - `read.fire.received`
  - `read.capture.complete(durationMs)`
  - `read.vnRequest.complete(observationCount, durationMs)`
  - `read.filter.kept(count)` / `read.filter.dropped(count)`
  - `read.chunks.created(count, totalChars)`
  - `read.speak.started(chunkIndex)` / `read.speak.chunk.finished(chunkIndex, durationMs)`
  - `read.cancelled(reason, chunkIndex)`
  - `read.pipeline.total(durationMs, outcome)`
