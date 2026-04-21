# EchoSight (Apple Vision Pro)

Accessibility-first spatial companion for blind and low-vision (BLV) users. Runs fully on-device on Apple Vision Pro.

## Status

**v0.1 in planning → Sprint 1.1 starting.** See `docs/plans/manifest.md` for the spec map and `docs/plans/progress.md` for execution state.

## v0.1 Scope

Four modes, zero voice input, all local inference:

| Mode | Trigger | What it does |
|------|---------|--------------|
| **Scene** | Digital Crown → `scene` + button | Describes what's in front of you via on-device detector + TTS |
| **Recall** | Crown → `recall` + button | 1st press: Gemma-generated room gestalt. 2nd press within 5 s: top-N nearest annotations |
| **Read** | Crown → `read` + button | Captures passthrough, runs `VNRecognizeTextRequest`, speaks the text |
| **Silent** | Crown → `silent` | Mutes normal speech; ambient cold-anchor speech and chimes still fire |

Plus ambient announce: spatial chime on world-anchor novelty, full speech only on cold (>30 min unseen) anchor AND idle user (no gesture/head-motion in last 5 min).

## Module Structure

Two Swift products in `Package.swift`:

| Module | Role |
|--------|------|
| `EchoSightCore` | Engine: ARKit, perception, speech, storage. No SwiftUI. Fully unit-testable. |
| `EchoSightApp` | UI shell: SwiftUI views, WindowGroup, ImmersiveSpace, glue code. Depends on Core. |

The split keeps `EchoSightCore` importable in test targets without pulling in the app lifecycle.

## Architecture Principles

- **Zero external network at inference time.** All models ship or download once at first launch (~2.6 GB).
- **Layer 1 always-on.** Scene reconstruction + world tracking run continuously with negligible power cost.
- **Annotations anchored to world.** Persistent visionOS world anchors back cross-session recall.
- **Single `SpeechOut` actor** owns `AVSpeechSynthesizer` with priority slots (`.high` preempts `.normal`, ducks via `.duckOthers`).

## Build

```bash
xcodebuild -scheme EchoSight -destination 'generic/platform=visionOS' build | xcbeautify
xcodebuild test -scheme EchoSight -destination 'platform=visionOS Simulator,name=Apple Vision Pro' | xcbeautify
```

Requires Xcode 16+, visionOS 2.0 SDK, Apple Vision Pro (or simulator) for runtime verification.

## Privacy Posture

- Zero network inference. All models run on-device (local inference only).
- Photos: full access required (passthrough capture reads camera frames via visionOS 2 API).
- Microphone: reserved in Info.plist; not used in v0.1.
- World sensing: required for ARKit mesh reconstruction and anchor persistence.
- Log exports hash anchor UUIDs (SHA-256). No frames, OCR text, or prompts leave the device.

## Repo Layout

- `docs/plans/` — manifest, 16 spec files, findings, workflow, progress log
- `EchoSight-AVP-Brainstorm.md` — original brainstorm (planning input, 2026-04-11)
- `archive/legacy-web/` — previous web-app version of the project (Django backend + React frontend)
- `.claude/` — project-local Claude Code config and research cache

## History

This repository previously hosted a Django + React web-app prototype of EchoSight (2023). Earlier work is preserved under `archive/legacy-web/` with full git history via `git log --follow`. The visionOS rewrite begins 2026-04-21 as a greenfield native app.

## Authors

Wesley Shih, Pranathi Mokshagundam, Chaitra Vishweshwaraiah (original web app).
Wesley Shih (visionOS rewrite).
