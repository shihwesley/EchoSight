> **Historical planning snapshot (2026-04-11).** Some decisions have since changed -- notably, PeekABoo was ditched in favor of an internal PhotosLibraryCaptureSource. See docs/plans/findings.md and docs/plans/progress.md for current state.

# EchoSight on Apple Vision Pro — Brainstorm Document

**Date:** 2026-04-11
**Status:** Design exploration, pre-implementation
**Origin:** Capstone project *EchoSight* (March–April 2024, Flutter iOS/Android), GPT-4 Vision-based scene description for BLV (blind/low-vision) users. 2024 thesis: capture → VLM → TTS under 1 second.
**Target:** Evolve EchoSight into an always-on spatial sensory companion for Apple Vision Pro, fully local (privacy-preserving), leveraging 2026 on-device VLMs.

---

## 1. Product Vision

### The 2024 → 2026 shift

EchoSight v1 (2024) proved the core thesis: visually impaired users benefit from a ~1-second round-trip "what's in front of me" loop (capture → VLM → TTS). The 2024 constraints were:

- Only GPT-4V was SOTA → pixels had to leave the device → privacy cost
- No on-device VLM was viable
- One-shot, stateless descriptions only
- Phone-based capture, with aiming problems for BLV users

The 2026 version is a different product because two things changed:

1. **On-device VLMs are now strong enough** — Gemma 4 E2B, Falcon-Perception 0.6B, and MLX/mlx-swift make local inference viable on Apple Silicon
2. **Spatial computing devices give you eye-level capture + persistent world coordinates** — solving the camera-aim accessibility problem *and* enabling stateful spatial memory

### The new product

Not just "describe the scene." An **always-on sensory companion** a BLV user opens in the morning and uses all day. Single trusted app, voice-first UX, fully local, persistent spatial memory across sessions.

### Why unify features into one app (not many apps)

- BLV users face real friction when switching apps blindly
- Shared spatial memory carries across use cases (navigation + describe + read + translate all reference the same mental map)
- Shared models load once, serve everything
- Matches how assistive tech has evolved (Seeing AI, Be My Eyes, Envision all became multi-feature)
- Differentiation from Seeing AI (Microsoft) = **spatial persistence on a head-worn device**, which no phone app can match

---

## 2. Platform Decision: Apple Vision Pro

### Why AVP, despite the obvious drawbacks

**Conceded drawbacks** (all true, accepted):
- AVP is heavy (~600g), expensive ($3500), opaque
- Gen-1 is a dev kit, not a consumer device
- Consumer BLV users won't adopt it at current form factor/price
- Apple ecosystem lock-in

**Reasons to commit anyway:**
- **Eye-level camera solves the aim problem.** Phone-based capture has a documented accessibility failure: BLV users can't frame a shot they can't see. EchoSight v1 hit this. Head-stabilized, eye-aligned capture on AVP is objectively better input for this population.
- **Betting on the form factor trajectory.** Gen-2 is lighter/cheaper. Gen-3 is where consumer adoption starts. Smart glasses (Ray-Ban Meta, Brilliant Labs, XREAL, future AR glasses) converge on the same input/output modalities. Code written today ports forward.
- **Spatial primitives are unique to this hardware.** ARKit scene mesh + persistent world anchors + sub-10ms head pose + spatial audio output = a UX paradigm phones literally cannot replicate.
- **Apple's Accessibility team wants flagship accessibility apps on visionOS.** Being early is worth something for exposure, App Store featuring, and eventual Apple partnership.
- **Strategic play:** ship the reference BLV app that defines accessibility on Apple's spatial platform for the next decade.

### Platform risk to manage

Betting on a *timeline* (AVP gen-2/3 adoption) is risky. Need to decide whether the parallel Flutter iOS/Android EchoSight v1 codebase stays alive (shipping for today's users) or goes into deep freeze. Both are legitimate; must choose, not drift.

---

## 3. The Camera Access Problem & PeekABoo Solution

### The problem

Consumer visionOS apps cannot read passthrough camera frames. The `CameraFrameProvider` API exists in ARKit but requires `com.apple.developer.arkit.main-camera-access.allow` — an **Enterprise API entitlement** granted case-by-case, typically to enterprise/research/accessibility applicants. Approval takes 2–6 weeks and restricts App Store distribution.

### The PeekABoo workaround (https://github.com/OmChachad/PeekABoo)

A Swift Package that dodges the entitlement wall entirely:

- Uses **Photos framework** (`NSPhotoLibraryUsageDescription`, standard consumer entitlement)
- Observes the user's screenshot album via `PHPhotoLibraryChangeObserver`
- When user presses **Digital Crown + Capture Button** simultaneously, the OS takes a screenshot **that includes the passthrough world view**
- PeekABoo sees the new asset land, loads it as `UIImage`, hands it to `.onCapture { image in ... }`
- No enterprise entitlement needed
- Ships on the regular App Store

### Why this is actually good UX for BLV users

- **Digital Crown + Capture Button is a tactile physical combo**, both buttons findable by feel
- User knows with certainty the capture happened (audible shutter, haptic)
- More accessible than eye-tracking + air pinch gestures
- One-shot discrete capture is the *right* interaction model for this use case (battery, photo library pollution, user agency)

### Limitations to design around

1. **Every capture pollutes the Photos library.** Apple does not allow silent deletion.
   - Mitigation: create dedicated "EchoSight Captures" album, move assets there via `PHAssetChangeRequest`. Offer a "clear captures" button for batch deletion (user confirms).
2. **Requires Full Photo Library Access** (not Limited). Privacy-sensitive onboarding required.
3. **Not real-time.** One image per button combo. For EchoSight this is correct — continuous capture would be wasteful and polluting.
4. **No depth in the screenshot.** RGB only. Depth comes from ARKit (separate path).
5. **Resolution is OS-decided.** Likely ~2K × 2K. Downscale to 448px or 512px before VLM inference.
6. **App Store review risk.** The trick is legal but clever. Design behind a protocol so backends are swappable (PeekABoo today, `CameraFrameProvider` via entitlement tomorrow, official API in visionOS 4+).

```swift
protocol PassthroughCaptureSource {
    func requestCapture() async throws -> CapturedFrame
    var isAvailable: Bool { get }
}
struct PeekABooSource: PassthroughCaptureSource { ... }
struct CameraFrameProviderSource: PassthroughCaptureSource { ... }  // enterprise fallback
```

---

## 4. Architecture Layers

The app runs three concurrent layers, each with a different trigger and latency budget.

### Layer 1 — Continuous spatial awareness (always on, no capture needed)

- `SceneReconstructionProvider` (ARKit) streams a real-time semantic mesh of the user's surroundings
- Mesh classifications (per-face): `.none, .wall, .floor, .ceiling, .table, .seat, .window, .door`
- `WorldTrackingProvider` streams head pose at ~100 Hz (ring buffer for later time-sync)
- Ray-cast forward from head pose → detect obstacles in walking path
- Output: **spatialized audio cues** via RealityKit `SpatialAudioComponent`, panned and pitched by direction/distance
- No ML inference, no pixels, pure geometry
- Power cost: negligible, sustainable all day
- **This is shippable on its own without any VLM.** Core accessibility value even at v0.1.

### Layer 2 — On-demand description (triggered by capture gesture)

- User presses Digital Crown + Capture Button
- PeekABoo delivers `UIImage` (~400 ms after shutter)
- Falcon-Perception 0.6B runs on the image with a default query set
- Ray-cast each detection into Layer 1 mesh → metric distance + mesh classification
- Fast-path speech template (~1.2 s end-to-end): "chair 2m ahead, doorway 4m right"
- Async Gemma 4 reasoning pass enriches the annotation asynchronously

### Layer 3 — Ambient spatial soundscape (the AVP-native UX)

- Every classified mesh region (walls, doors, chairs) gets a low-volume continuous spatialized tone
- Walls hum, doors chime, chairs have a warmer tone, obstacles rise in pitch as user approaches
- Runs in `ImmersiveSpace` with `.mixed` immersion, zero visual rendering
- **This is echolocation as a software service.** It is the UX paradigm that doesn't exist on phones.
- Novelty: this is the feature that gets Apple Accessibility team featuring, and the reason the app *belongs* on AVP instead of being a port.

### What Layer 1 uniquely unlocks (with no camera access)

Even before any VLM is loaded, Layer 1 alone can tell the user:
- "Wall 1.2 m ahead"
- "Door 3 m ahead left"
- "Table 0.8 m ahead" (trip hazard at hip height)
- "Step down — floor drops 40 cm" (mesh height analysis)
- "Ceiling clearance 1.9 m" (low-ceiling warning)

That's a shippable app by itself. It's also a strong fallback when Layers 2/3 are unavailable or throttled.

---

## 5. Model Stack

### Three models loaded at launch

| Model | Role | Q4 RAM | Notes |
|---|---|---|---|
| **Falcon-Perception 0.6B** | Open-vocabulary detection + segmentation + measurement | ~400 MB | TII model. Early-fusion VLM. Emits `{xy, hw, mask}` structured detections per text query. Needs Python → Swift port (no mlx-swift version yet). |
| **Gemma 4 E2B (Q4)** | Reasoning, language understanding, open-vocab Q&A, translation fallback | ~2 GB | MatFormer architecture — E4B contains E2B as a nested sub-model, runtime-selectable fast/slow path from one weight file. User prefers E2B Q4 over MXFP8 (smaller, faster). |
| **WhisperKit small-multilingual** | Speech-to-text for voice commands + translating a friend's speech | ~240 MB | argmax/WhisperKit Swift wrapper. Better than `SFSpeechRecognizer` for multilingual + long-form + offline. |

**Total model RAM at rest: ~2.6 GB**

Add ARKit mesh (~300 MB), RealityKit + SwiftUI + app (~300 MB) = **~3.2 GB total**.

On AVP's 16 GB unified memory with a 6–9 GB foreground budget, this leaves 3–6 GB headroom. Comfortable, not tight.

### Why these three and not others

- **Falcon-Perception** over generic VLMs: pixel-accurate segmentation + structured output + extremely small. Measurement, not reasoning. Apple's Vision framework can't do open-vocabulary detection from a text query.
- **Gemma 4 E2B** over Apple Foundation Models: Apple FM is ~3B, good at schema-constrained short generation, but weak on nuanced description, spatial reasoning, and open-ended Q&A. Real-world experience confirms FM is not flagship-quality for this use case. Gemma 4's reasoning capability is the right level.
- **Gemma 4 E2B** over E4B: E4B MXFP8 is 8.73 GB on disk, ~10 GB including activations/KV cache. Too risky for AVP memory budget. E2B fits comfortably. A self-quantized Q4 E4B (~2.5 GB) would be ideal but wasn't available at time of writing; worth revisiting for v1.0.
- **WhisperKit** over `SFSpeechRecognizer`: multilingual auto-detect, offline reliability, no dictation-context restrictions. Needed for the "translate what my friend is saying" feature.

### MatFormer fast/slow path (Gemma 4)

E4B contains E2B as a nested sub-model. At inference time, route through fewer layers to get E2B-speed output from E4B weights. If you ever load E4B, you get two performance tiers from a single weight file. Not needed for v0.1 but a useful optimization path later.

### Apple frameworks leveraged for free (0 MB in your app)

These handle commodity tasks much better than a general VLM would, and they're free in RAM:

| Capability | Apple framework | Why |
|---|---|---|
| OCR (menus, signs, labels) | `VNRecognizeTextRequest` | ~100 ms per page, 30+ languages, higher accuracy than VLM OCR |
| Translation (text + speech) | `Translation` framework (visionOS 2+) | ~50 ms per sentence, ~20 on-device language pairs, higher quality than Gemma for mainstream pairs |
| Text-to-speech | `AVSpeechSynthesizer` | Native, low-latency, respects user's VoiceOver voice |
| Barcode/QR scanning | `VNDetectBarcodesRequest` | ~50 ms, needed for medication bottles, groceries |
| Face detection | `VNDetectFaceRectanglesRequest` + on-device embedding matching | Future feature: "your friend Alice is 2 m ahead" |
| Depth (indoor) | `SceneReconstructionProvider` (ARKit) | Live semantic mesh of the room |
| Head pose | `WorldTrackingProvider` (ARKit) | 100 Hz, stable world coordinates |

**Rule:** use Apple's specialist frameworks for commodity tasks, save Gemma 4 for open-ended reasoning and Falcon for open-vocab detection. Don't route everything through the biggest model.

---

## 6. The Fusion Design — 2D Detection → 3D World

This is the engineering heart of the app and the reason it's uniquely an AVP product.

### The problem

Falcon-Perception gives you 2D pixel-space masks from a flat screenshot. ARKit gives you continuous 3D geometry. They don't talk to each other. The bridge is **ray-casting at capture time**, then persisting the result as a world-locked annotation.

### Pipeline

```
Continuous background:
  WorldTrackingProvider → head pose ring buffer (100 Hz, timestamped)
  SceneReconstructionProvider → live mesh (wrapped as CollisionComponents)

On capture:
  1. PeekABoo delivers UIImage + PHAsset.creationDate
  2. Look up head pose at creationDate from the ring buffer (interpolate between nearest two entries)
  3. Run Falcon-Perception on the image → N detections {xy, hw, mask}
  4. For each detection:
       a. Convert (xy) to a 3D ray in head-local space using assumed passthrough FOV (~100°)
       b. Transform ray to world space using captured head pose
       c. Scene.raycast(origin: headPos, direction: rayWorld, length: 10m)
       d. Hit → world position + face classification
       e. Create WorldAnnotation(position, falconLabel, meshClassification, timestamp)
  5. Reconcile Falcon label and mesh classification (agreement → high confidence; disagreement → compose)
  6. Persist annotation in spatial hash keyed by world anchor
```

### Two engineering details that matter

**(1) Time-sync the head pose to the capture.** PeekABoo delivers the image 200–600 ms after the shutter. The head pose at delivery time is NOT the head pose at capture time. Use the `PHAsset.creationDate` as the true capture timestamp and linearly interpolate the ring buffer. Getting this wrong puts ray-casts tens of centimeters off.

**(2) Projection from 2D pixel to 3D ray.** Apple doesn't publish the effective camera model for passthrough screenshots. Pragmatic approach: assume pinhole camera with ~100° horizontal FOV, calibrate empirically by running Falcon on a known object at a known distance and sweeping the FOV until hit distance matches reality. One afternoon of tuning gives you the real number. A few centimeters of error at 3 m is fine for BLV audio descriptions.

```swift
func pixelToRay(nx: Float, ny: Float, hFovDeg: Float = 100, aspect: Float) -> SIMD3<Float> {
    let hFov = hFovDeg * .pi / 180
    let vFov = 2 * atan(tan(hFov / 2) / aspect)
    let x = (nx - 0.5) * 2     // [-1, 1]
    let y = (0.5 - ny) * 2     // [-1, 1], image Y flipped
    return normalize(SIMD3<Float>(
        x * tan(hFov / 2),
        y * tan(vFov / 2),
        -1                      // -Z forward in head-local space
    ))
}
```

### Ray-cast itself (RealityKit does the heavy lifting)

```swift
let headPos = capturedHeadPose.position
let headRot = capturedHeadPose.rotation
let rayLocal = pixelToRay(nx: det.xy.x, ny: det.xy.y, aspect: imgW / imgH)
let rayWorld = simd_act(headRot, rayLocal)

let hits = scene.raycast(
    origin: headPos,
    direction: rayWorld,
    length: 10.0,
    query: .nearest,
    mask: .sceneUnderstanding
)
if let hit = hits.first {
    let distance = simd_distance(headPos, hit.position)
    let classification = hit.entity.components[SceneUnderstandingComponent.self]?.classification
    // Fuse: Falcon label + metric distance + mesh classification + world position
}
```

RealityKit's `Scene.raycast` handles the spatial hash and collision math for you. Enable scene reconstruction in the `RealityView` and it automatically exposes classification via `SceneUnderstandingComponent`.

### ARKit mesh fidelity (concrete numbers)

| Property | Value |
|---|---|
| Triangle edge length | ~3–8 cm indoors, ~10–15 cm at >4 m |
| Mesh coverage delay | ~2–3 s after surface enters view |
| Classification classes | 8 fixed (wall/floor/ceiling/table/seat/window/door/none) |
| Classification accuracy | ~85–90% planar, ~60% small/irregular |
| Pose stability drift | <1 cm over 10 min indoors |
| LoD knob | None — density is system-decided |
| Texture | None — geometry only |

### Fusion failure modes and mitigations

| Failure | Mitigation |
|---|---|
| Small objects (mug, phone, keys) fall through mesh — ray hits supporting surface instead | If Falcon label is small-object class and mesh hit is `.table/.floor`, override classification with Falcon's but keep the distance (close enough) |
| Dynamic objects (people walking) — mesh gets carved, stale | Skip mesh depth lookup for "person" class; use shoulder-height heuristic (~2 m for adult at frame mid-height) |
| Outdoor scenes — mesh sparse/delayed | Scope v1 as indoor-only; add monocular depth estimation later |
| Passthrough lens distortion at frame edges | Bias Falcon output to central 80% of frame, or fit polynomial distortion correction |

---

## 7. Persistent Spatial Memory — The Magic Feature

### The core idea

Every annotation created from a capture is **world-locked**. It has a 3D position in the session's world coordinate space. This unlocks UX that phone apps *cannot* replicate:

- **Walking-away recall.** User walks past a chair. 30 seconds later asks "where's the chair?" App computes vector from current head pose to saved annotation, speaks "chair is 4 m behind you and to the right." No second capture needed.
- **Multi-capture mental map.** User walks into a room, shoots three captures at 90° angles. 15 annotations = full semantic map of the room. From then on, "what's around me" queries hit the cached annotation set, zero VLM calls, zero battery, zero photo-library pollution.
- **Duplicate merging.** Second capture of the same object from a different angle → merge annotations within 30 cm threshold. Better pose estimate, possibly richer label.
- **Cross-session persistence.** visionOS 2.0+ supports persistent world anchors. Write annotation set to disk keyed by world anchor. Next time user walks into their kitchen, EchoSight recognizes the space and reloads: "Welcome back to the kitchen. Fridge on your left, table 2 m ahead."

### Why this is the product

EchoSight v1 was stateless: ask, forget, pay again. EchoSight v2 is **stateful**: build a growing memory of your surroundings that you can query freely.

- Pure Falcon without mesh = "what's in this picture" (forgotten immediately)
- Pure mesh without Falcon = "there's a seat-class polygon at 2 m" (no semantic richness)
- Fusion + persistence = a knowledge graph of your environment that grows as you explore and persists across sessions

No iPhone app can do this. Neither can Meta's smart glasses. Neither can Apple's own Door Detection. This is the moat.

### Annotation data structure (sketch)

```swift
struct WorldAnnotation {
    let id: UUID
    let worldPosition: SIMD3<Float>     // in world anchor frame
    let worldAnchor: UUID               // persistent visionOS anchor ID
    let falconLabel: String             // "blue office chair"
    let meshClassification: MeshClass   // .seat
    let confidence: Float               // from label/class agreement
    var description: String?            // async-enriched by Gemma 4
    let createdAt: Date
    var lastSeenAt: Date
    var captureCount: Int               // increments on merge
}
```

Spatial hash for O(1) "what's within N meters of current head pose" queries. Persist to disk as JSON or a lightweight SQLite store.

---

## 8. Multi-Model Orchestration — Fast Path / Slow Path / Verbal Path

### The critical insight

VLMs reason but don't measure. Falcon measures but doesn't reason. The naive loop (Gemma plans → Falcon measures → Gemma reasons) is **too slow on the critical path** — 5–8 seconds total on AVP. BLV users can't wait that long.

**Rearrangement:** synchronous measurement, asynchronous reasoning. Don't put reasoning on the critical path.

### Three paths

**Fast path (≤1.5 s, synchronous, user waits)**
```
PeekABoo capture (400 ms)
  → Falcon-Perception with default query set (500 ms)
  → Ray-cast into mesh (5 ms)
  → Template-based speech ("chair 2 m ahead, doorway 4 m right")
  → Speaks at ~1.2 s
```
No Gemma in this path. Template formatting from structured detection+distance output.

**Slow path (2–5 s, async, background)**
```
Same detections fed to Gemma 4 E2B (text-only pass)
  → Rich description written to annotation set
  → Spoken IF user is still listening and hasn't moved
  → Otherwise stored for next query
```
This is where reasoning lives. It enriches the mental map without blocking the user.

**Verbal query path (2–4 s, on demand)**
```
User says "is the red mug still on the kitchen table"
  → WhisperKit transcribes
  → Gemma 4 (text-only) intent-routes to: query annotation set OR trigger new capture
  → If new capture needed: Falcon with specific query → ray-cast → Gemma 4 summarize
```
Gemma is only on the critical path when the user asked a specific verbal question — the 10% case. Even then, it's a compact structured call, not a heavy reasoning loop.

### Latency budget table (Gemma 4 E2B Q4 on AVP M2)

| Operation | Estimated latency |
|---|---|
| PeekABoo capture delivery | 400 ms |
| Falcon-Perception inference (448 px, 1–3 queries) | 500–800 ms |
| Ray-cast + mesh fusion | <10 ms |
| Template speech formatting | <5 ms |
| **Fast path total** | **~1.2 s** |
| WhisperKit transcription (5 s of audio) | 300–500 ms |
| Gemma 4 E2B text-only prefill (200 tok JSON) | 200 ms |
| Gemma 4 E2B generation (30 tok) | 1.0 s |
| **Async reasoning total** | **~1.2 s (background)** |
| Gemma 4 E2B vision prefill (512 px) | 0.8–1.5 s |
| **Verbal query with vision total** | **~2–3 s** |

### Compression moves already applied

1. **Skip the VLM planner for default queries.** Hardcode the default query set for "describe" → no Gemma prefill needed for the 90% case.
2. **Replace Apple FM with Gemma 4 for reasoning.** Quality wins over marginal latency cost.
3. **Two-stage speech: fast template, then rich reasoning.** User gets navigation info immediately, richer description arrives when ready.
4. **Async reasoning into annotation set.** The persistent mental map is the reason this works — expensive reasoning happens once, result is queryable instantly afterwards.

---

## 9. Feature Catalog

Seven features compose from the same primitives. Each is a different routing of (capture source, detector, reasoner, speaker).

| # | Feature | Trigger | Pipeline | Latency |
|---|---|---|---|---|
| 1 | **Describe scene** | Capture gesture | PeekABoo → Falcon → mesh → template TTS (fast) + Gemma 4 async | ~1.2 s fast, ~3 s rich |
| 2 | **Read text** (menu, sign, label) | "Read" / gesture | PeekABoo → `VNRecognizeTextRequest` → TTS | ~600 ms |
| 3 | **Translate sign** | "Translate" + capture | PeekABoo → Vision OCR → `Translation` framework → TTS | ~800 ms |
| 4 | **Translate friend's speech** (live) | "Translate what they're saying" | Mic → WhisperKit streaming → `Translation` framework → TTS | ~2 s lag |
| 5 | **Spatial memory query** | "Where is [X]" | Mic → WhisperKit → Gemma 4 text-only → annotation lookup → TTS | <1.5 s |
| 6 | **Complex visual Q&A** | "What kind of dog is that" + capture | Mic → WhisperKit → PeekABoo → Falcon + Gemma 4 vision → TTS | ~3–5 s |
| 7 | **Barcode / medication** | Capture + "read label" | PeekABoo → `VNDetectBarcodesRequest` + `VNRecognizeTextRequest` → TTS | <1 s |

### The unifying principle

**Same primitives, different compositions, routed by voice intent.** Not seven pipelines — seven recipes over the same seven ingredients:

- Capture source (PeekABoo / microphone / ARKit)
- Detector (Falcon / Vision framework)
- Geometric grounding (ray-cast + mesh)
- Reasoner (Gemma 4 / direct template)
- Translator (Apple Translation framework)
- Speaker (AVSpeechSynthesizer)
- Memory (annotation set)

---

## 10. UX — Voice-First With Physical Fallback

### Principle

BLV user sees no UI. Interaction is entirely through sound and physical controls.

### Input modalities

- **Physical capture gesture:** Digital Crown + Capture Button → capture, then optionally open voice prompt
- **Voice wake word / hold-to-talk:** start listening for a verbal query without capture
- **Hardware:** both AVP buttons are tactile and findable by feel

### Verb router (on WhisperKit transcript)

| Spoken | Routes to |
|---|---|
| "Describe" / "What's in front of me" | Feature 1 |
| "Read" / "What does that say" | Feature 2 |
| "Translate" (with capture) | Feature 3 |
| "Translate what they're saying" | Feature 4 |
| "Where is [X]" / "Find [X]" | Feature 5 (spatial memory) |
| "Is there [X]" / "What's on [Y]" / open question | Feature 6 |
| "What's this medication" / "Read the label" | Feature 7 |
| "Stop" | Cancel current task |
| "Repeat" | Re-speak last output |

Keyword matcher handles 95% of cases. Gemma 4 only handles ambiguous/conversational intents.

### Why this UX over a mode carousel

Seeing AI has 9+ modes (short text, document, scene, person, product, light, color, handwriting, currency). Known usability problem — users get lost in the mode space. Voice-first verb routing sidesteps this entirely. User never has to remember "what mode am I in." Cost: harder speech pipeline. Benefit: vastly simpler mental model for the user.

---

## 11. Scope Discipline

### v0.1 (6–10 weeks)

Ship two features, polished:

1. **Feature 1 — Scene description** (Falcon + ray-cast + fast-path template + async Gemma)
2. **Feature 2 — Read text** (Vision OCR + TTS)

Plus:

- Layer 1 spatial awareness always-on
- Basic voice verb router (keyword matcher)
- PeekABoo capture + dedicated photo album
- Persistent annotation set across sessions

### v1.0 (3–6 months after v0.1)

Add features 3, 4, 5. Layer 3 spatial soundscape. BLV alpha tester feedback incorporated.

### v2.0 (6–12 months)

Features 6 and 7. Possibly self-quantized Gemma 4 E4B Q4 for richer reasoning. Face recognition of known friends. Outdoor support with monocular depth estimation.

### Non-goals

Name them explicitly to protect against scope drift:

- **Not** a GPS/outdoor navigation app (v2+ at earliest)
- **Not** a photo editor / photography app
- **Not** a social app (no sharing, no remote assistance — that's Be My Eyes' job)
- **Not** a general AI assistant (no calendar, reminders, email)
- **Not** a productivity app
- **Not** a game
- **Not** a replacement for a cane or guide dog — complementary spatial awareness only
- **Not** a medical device — does not diagnose, does not replace clinical judgment

---

## 12. Hard Questions / Open Risks

### Who tests this?

BLV alpha testers are non-negotiable. Sighted engineers cannot detect the subtle failures. Start relationships NOW with:

- Lighthouse for the Blind
- National Federation of the Blind (NFB)
- Local accessibility user groups
- University disability services offices
- Apple Accessibility Research partnerships (capstone lineage may help)

### Enterprise API entitlement decision

PeekABoo path means you can ship without it. But applying anyway is smart:

- Unlocks continuous-mode v2
- Provides fallback if Apple tightens screenshot observation
- EchoSight 2024 capstone is strong prior art for the application
- File it early — approval takes 2–6 weeks; not blocking critical path

### FOV calibration

Passthrough effective camera model is undocumented. Need empirical measurement early in dev (week 2). Method: place chair at known distance, capture, sweep assumed FOV until ray-cast distance matches tape measure. One-afternoon task.

### Photos library pollution

Every capture persists to Camera Roll. Unavoidable given PeekABoo mechanism. Must be disclosed clearly in onboarding. "Clear captures" feature is important. Monitor for user complaints.

### Model download size

~2.6 GB of models on first launch is rough for cellular users. Options:

- Ship with on-demand resource bundles
- `NSURLSession` background download with VoiceOver progress announcements
- Allow WiFi-only initial download
- Consider progressive capability unlock (start with Layer 1 only, download Falcon on demand, download Gemma 4 on demand)

### Differentiation from Seeing AI

Microsoft's Seeing AI is free, polished, well-known in BLV community. The differentiation must be the AVP-specific capabilities: **spatial persistence, head-aligned capture, Layer 3 ambient soundscape**. All three are impossible on a phone. This is the moat. Anything Seeing AI also does well is commodity — do not compete there.

### Platform timeline risk

AVP gen-1 is not the mass-market device. If the goal is "BLV users rely on this daily in 2026," this app alone won't ship to them. Decide whether the Flutter iOS/Android EchoSight v1 codebase stays alive in parallel (shipping for today) or goes into deep freeze (full commitment to spatial future).

### Falcon-Perception Swift port effort

No mlx-swift version exists today. Effort estimate: 1500 lines of Swift, ~1 week for a comfortable MLX dev. Files to port:
- `language.py` → decoder (largest chunk, mostly boilerplate from mlx-swift-examples MLXLLM)
- `falcon_perception.py` → backbone + detection head parser
- `anyup.py` → learned mask upsampler (~100 lines, pixel shuffle + conv)
- `processing_falcon_perception.py` → preprocessing

Weights from HF (`tiiuae/Falcon-Perception`) already MLX-native via `mlx_vlm.convert` — no re-quantization needed.

### Placeholder path before Falcon port

Can use Apple's `VNRecognizeObjectsRequest` or a Core ML YOLO as the detector placeholder to validate the full pipeline end-to-end before committing to the Falcon port. Swap in Falcon once the geometry math and UX are proven.

---

## 13. Concrete Next Steps (Ordered)

1. **Write one-page v0.1 product spec.** Feature set, non-goals, success metrics. Lives in this repo.
2. **Contact one BLV organization** about alpha tester availability in 2–3 months. Plant the seed early.
3. **File Enterprise API application.** Not blocking, but long pole. Use EchoSight capstone as prior art in the narrative.
4. **Stand up AVP project skeleton:**
   - New visionOS SwiftUI app
   - PeekABoo dependency integrated
   - `SceneReconstructionProvider` stream + `WorldTrackingProvider` head pose ring buffer
   - `AVSpeechSynthesizer` wired up
   - Stubbed voice verb router (keyword matcher)
   - Test in simulator first, then device
5. **Build Layer 1 on its own.** Semantic mesh classification + spatial audio cues. Shippable as v0.0.1 alpha.
6. **Calibrate the FOV.** Empirical ray-cast tuning with known distances.
7. **Wire dummy Layer 2.** Use `VNRecognizeObjectsRequest` as Falcon placeholder. Get PeekABoo → detect → ray-cast → TTS loop working end-to-end.
8. **Port Falcon-Perception to mlx-swift.** Swap out the Vision placeholder.
9. **Add Gemma 4 E2B** for async reasoning pass. Test memory pressure on device.
10. **Alpha release** to BLV testers. Iterate hard based on feedback.

---

## 14. Key Insights (Reference)

These are the structural ideas worth remembering, pulled together:

- **The capture problem is the gate, not the model problem.** Models are plentiful in 2026; camera access on visionOS is rare. PeekABoo unlocks everything downstream.
- **Synchronous measurement, asynchronous reasoning.** Never put a reasoning LLM on the critical path for a BLV navigation query. Measurements block the user; reasoning shouldn't.
- **The annotation set is the product, not the one-shot caption.** Stateful spatial memory is what makes this an AVP app and not a phone app port.
- **Don't route everything through the biggest model.** Apple's specialist frameworks (OCR, Translation, TTS, depth) are better than Gemma 4 at their narrow jobs and cost zero RAM in your app. Use them.
- **Mesh classification and VLM detection are complementary, not competing.** Mesh gives you spatial extent + navigation safety. VLM gives you semantic richness. Fusion beats either alone.
- **MatFormer fast/slow path is a runtime toggle from one weight file.** Worth leveraging once you go from E2B to E4B.
- **Digital Crown + Capture Button is a surprisingly accessible gesture for BLV users.** Tactile, two-handed, unambiguous. Don't underestimate physical inputs.
- **Layer 1 is shippable by itself with no ML inference at all.** Scene reconstruction + semantic classification + spatial audio is a complete accessibility feature.
- **The moat is AVP-native capabilities no phone can replicate:** persistent world anchors, eye-level capture, spatial audio output, sub-10ms head pose, semantic mesh.
- **Scope discipline for accessibility apps is different from consumer apps.** Half-working features are dangerous (trip hazards, wrong medication instructions). Narrow + polished beats wide + rough, always.
- **The user's verb router is the whole UX.** Voice-first with keyword-matched verbs sidesteps the mode-carousel usability trap that Seeing AI has.
- **Differentiate only where AVP uniquely wins.** Scene description alone isn't enough — Seeing AI does that well. Spatial persistence, head-aligned capture, and ambient soundscape are the moat.

---

## 15. Open Design Questions (Unresolved)

Things we didn't decide and should before implementation:

1. **Annotation decay policy.** Do annotations expire? After how long? Does the user ever see a "this is old, re-capture" warning?
2. **Room anchor semantics.** How does the app know it's "the kitchen" vs "the living room"? Manual labeling by user? Auto-cluster by semantic mesh signatures? Or just unnamed anchors?
3. **Privacy: captures on disk.** Encrypt the annotation set? What happens if the user lends their AVP to a sighted friend?
4. **Monetization.** Free? Paid? Sliding scale for accessibility? Apple Accessibility-featured apps typically free. But model download + ongoing support has real cost.
5. **Language support.** Which languages for the voice router at v0.1? English only is the easy answer but the translation features imply multilingual UI.
6. **Haptic vocabulary.** Layer 3 is audio-primary, but AVP has subtle haptics. Do we add a haptic language for common events (obstacle entering threshold, annotation merged, capture succeeded)?
7. **Fallback when models fail.** If Falcon returns zero detections, what does the app say? Silence? "Nothing detected"? "Try again"? This is a UX decision with accessibility implications.
8. **Session start UX.** When the user launches the app each morning, what does it say? "Good morning. You're in the living room. 8 annotations loaded."?

---

*End of brainstorm document. Next action: decide between (a) writing the v0.1 product spec as a separate doc, (b) starting the AVP project skeleton, or (c) beginning the Falcon-Perception Swift port.*
