# AIA-0217 — Split detection content into tiled sub-images (final: 6 regions)

*(The issue proposed 5 images; decision 2 added a full-frame pass — 4 quadrants + center + full frame.)*

Issue: [#217](https://github.com/aiarcheology-com/aiarcheology/issues/217) · Branch: `feature/AIA-0217/split-detection-content-into-5-sub-images` · Status: APPROVED FOR IMPLEMENTATION (Codex round 1 folded in; user decisions confirmed 2026-06-12)

## Problem

Detection misses artifacts near the snapshot edges (left/right/top/bottom), especially on iPad. Working hypothesis: the full content snapshot is handed to one `VNCoreMLRequest` with `imageCropAndScaleOption = .scaleFit` (`Detector.swift:69`), so a large iPad snapshot is letterboxed down to the model's input resolution (the bundled demo model is 1280×1280) — edge artifacts shrink below the model's reliable detection size. No retraining wanted.

**Named caveat (Codex):** this is a hypothesis, not a proven root cause. Tiling raises effective resolution, but an object at the outer snapshot edge is still at the model-input edge of its quadrant — if the misses come from training edge bias rather than downscaling, tiling won't fix them. The manual verification step (step 8) on the issue's lidar page is the validation gate before the toggle default is finalized.

## Approach

Run the detector over **6 regions** of the same snapshot — 4 quadrants + 1 center region of identical size + a full-frame pass (decision 2) — and merge the results back into full-image coordinates. Each half-size region reaches the model at roughly 2× the effective resolution of today's full-frame pass.

**Mechanism: `VNCoreMLRequest.regionOfInterest`, not physical crops.** One `VNImageRequestHandler` per frame; per region we set `regionOfInterest` and `perform` serially. Vision does the cropping internally — no 5× `CIImage` cropping cost, no extra image copies. Because every region scales both image dimensions by 0.5, each region keeps the original snapshot's aspect ratio, so `.scaleFit` letterboxing padding is unchanged while content resolution roughly doubles (Codex-confirmed). Observations returned under an ROI are normalized **to the ROI**, so each box is remapped to full-image normalized space:

```
full.origin.x = roi.minX + box.minX * roi.width
full.origin.y = roi.minY + box.minY * roi.height      // Vision coords, bottom-left origin; no Y flip here —
full.size     = box.size  scaled by roi.size          // the annotation views own the Vision→SwiftUI flip
```

Remapped boxes are clamped to `[0, 1]` and dropped if non-finite or empty (defense against degenerate model output).

### Frame atomicity + latest-wins (Codex High 1)

Today `process(image:)` and `detect()` are two separate actor calls (`DeepDriver.swift:170-172`): snapshot B can replace the detector's `handler` between A's `process` and A's `detect`, making A silently detect on B's frame. Five serial region passes widen that window 5×. Fix folded into this feature:

- The detect path becomes **one atomic actor call**: `Detector.detect(image:regions:) async -> [DetectedObject]` — image conversion, region loop, remap, and NMS all inside a single actor-isolated method. No cross-call mutable `handler`/`ciImage` state for the detect path.
- **Latest-wins at the call site:** `DetectableView` keeps a monotonically increasing snapshot sequence; a completion is applied only if its sequence is still the newest (the existing `detectionGeneration` only covers interaction/layout changes, not consecutive timer snapshots). Snapshots arriving while a pass is in flight are coalesced: remember the newest pending image, run it when the current pass finishes (no queue growth).

### Per-region failure policy (Codex Medium 6)

Results are consumed **only after a successful `perform`** (a `VNRequest` retains the previous run's results — the existing `Detector.swift:102` warning). A region whose `perform` throws is logged and skipped; the remaining regions still run. `regionOfInterest` is restored to full-frame in a `defer` so a thrown pass can't leak a stale ROI into the next frame.

### Region geometry — dynamic, not hardcoded

`TileLayout.regions(tiled:)` returns normalized ROIs (resolution- and aspect-independent; actual crop pixel sizes derive from whatever snapshot WKWebView produced):

- tiled OFF → `[(0, 0, 1, 1)]` (exactly today's behavior)
- tiled ON → **6 regions** (user decision): 4 quadrants `(0, 0, .5, .5)`, `(.5, 0, .5, .5)`, `(0, .5, .5, .5)`, `(.5, .5, .5, .5)` + center `(.25, .25, .5, .5)` + full frame `(0, 0, 1, 1)` — the full-frame pass removes the large-object regression (an artifact bigger than ~half the screen fits in no half-size region); the containment merge prefers its untruncated geometry over clipped region boxes

### The immutability problem → small pipeline type change

`VNRecognizedObjectObservation` is not publicly constructible and `boundingBox` is read-only, so remapped results cannot stay `VNObservation`. Introduce a value type that the detect path emits instead:

```swift
struct DetectedObject: Sendable {
    struct Label: Sendable, Hashable { let identifier: String; let confidence: Float }   // Hashable: ForEach(labels, id: \.self)
    let uuid: UUID
    let labels: [Label]            // model label confidences, as Vision reports them
    let confidence: Float          // VNObservation.confidence — distinct from label confidence
    let boundingBox: CGRect        // full-image normalized, Vision coords
    let regionIndex: Int           // provenance: which region produced this box (NMS + debugging)
}
typealias DetectionResult = (observations: [DetectedObject], params: DeepDriverParams)
```

**Exact API (Codex High 3):** `Detector` gains `func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject]` — the only entry point `DeepDrivers.detect` uses (it already downcasts `as? Detector`, so the `DeepDriver` protocol and `ResultsCollector` stay untouched for the classify path). The old `process`/`run`/`observations` members remain only as protocol conformance; the detect path no longer touches them. `DeepDrivers.detect` collects `[DetectionResult]` in a plain local array (the loop is serial inside one Task — the actor collector was never needed there).

Downstream consumers updated to `DetectedObject` (they only read `boundingBox`, `labels`, `uuid` today): `AnnotationOverlay`/`AnnotationViewBuilder`, `ObservationCircleView`, `ObservationRectangleView`, `ObservationPointView`. The classify path keeps `ObservationParams` unchanged (`classify(on:)` currently has **no call sites** — tiling does not apply to whole-image classification). The legacy `Annotator` view modifier (`Annotator.swift`) also has no call sites and still compiles unchanged — left alone, flagged for separate cleanup. Side benefit: detection results crossing actors become a real `Sendable` value type instead of `@unchecked Sendable` Vision classes.

### Deduplication (the center region overlaps every quadrant)

The same artifact will frequently be detected in the center region *and* a quadrant. Per detector, after merging all regions, dedup runs **only across boxes from different regions** (within one region the model's own NMS already ruled), matching on the **primary (top) label identifier**, in two order-independent stages:

1. **Containment merge, geometry-preferring (Codex High 2):** for every cross-region same-label pair, if the smaller box's area is ≥ 70 % inside the larger box, drop the **smaller** box — regardless of confidence. A quadrant-clipped partial box is by construction smaller than the center region's full box, so the full geometry always survives; confidence ordering can't strand a clipped box (the failure mode of greedy confidence-first NMS).
2. **IoU NMS for near-identical survivors:** greedy by `confidence`, suppress IoU ≥ 0.45 same-label cross-region pairs.

Pure function, unit-tested. Named limitation: class-jitter duplicates (the same artifact classified differently in two regions) are not merged — matching on all labels would be ambiguous; revisit only if observed.

### Serial vs parallel + measurement (Codex Medium 5)

Serial, as the issue accepts. A single `VNCoreMLRequest` is stateful (`results` are per-perform), so parallel region passes would need one request instance per region — not warranted now. The cost is **measured, not assumed**: debug logging covers per-region inference duration *and* total end-to-end snapshot latency with detector count (the demo model's 1280×1280 input × 5 passes × N detectors is non-trivial). The on-device p50/p95 numbers and thermal behavior from manual verification feed the toggle-default decision. Parallelization is a named follow-up only if measurements demand it.

### Settings toggle

`Settings.tiledDetection: Bool` following the existing pattern (`UserDefaultsKeys` + registered default + `reset()` + persisted `didSet`), surfaced as a `Toggle` in `SettingsView` next to the other detection settings, new L10n key (en, `Localizable.xcstrings`, `scripts/swiftgen.sh`). `WebScreenView` mirrors it into `DetectableView` the same way `showIdentifiers` already flows (`onReceive` of the published setting). The flag reaches the drivers as a parameter: `drivers.detect(on:tiledDetection:completion:)` — `DeepDrivers` stays settings-agnostic.

## Known limitations (named, accepted)

1. **Region-boundary blind spots at half-size resolution.** An artifact straddling a midline *outside* the 25–75 % center band appears only as two halves across quadrants — the full-frame pass still sees it, but only at today's resolution. Overlapping tiles (e.g. 55 % regions) are a tunable follow-up if this bites in practice.
2. **6× inference per snapshot** — battery/thermal cost on long sessions; mitigated by the toggle and the 3 s cadence; measured before the default flips ON.
3. Higher-resolution regions may surface more low-confidence detections; dedup merges cross-region duplicates but the model's own confidence filtering is unchanged.
4. **Class-jitter duplicates** (same artifact, different label in two regions) are not merged.

## Decisions (user, 2026-06-12)

1. **Toggle default:** verify first, then ON — registered default flips to ON in the same PR only after the lidar-page on-device check proves the edge-detection win at acceptable latency; ships OFF if it doesn't.
2. **Regions:** 6 — quadrants + center + full frame.
3. **Scope:** detection only; classificators untouched.

## Implementation steps

1. **`Drivers/DetectionTiling.swift` (new)** — `TileLayout.regions(tiled:)`, `DetectedObject`, ROI→full-image remap (+ clamp/validity filter), two-stage cross-region dedup. Pure, no Vision dependency beyond `CGRect`. Register in pbxproj (manual 4-entry add).
2. **`Drivers/Detector.swift`** — atomic `detect(image:regions:) async -> [DetectedObject]`: convert image, serial region loop (set `regionOfInterest`, `perform`, consume results only on success, skip failed regions, `defer` ROI restore), remap + dedup; per-region and total duration debug logs. Legacy `process`/`run` remain only for protocol conformance.
3. **`Drivers/DeepDriver.swift`** — `DetectionResult` typealias; `DeepDrivers.detect(on:tiledDetection:completion:)` builds regions via `TileLayout`, calls the atomic Detector API, collects into a local array. `DeepDriver` protocol and `ResultsCollector` untouched (classify path).
4. **`UI/Annotation/*`** — `DetectableView` gains `tiledDetection: Bool`, a snapshot sequence counter with latest-wins application and in-flight coalescing; `detectedObservations: [DetectionResult]`; `AnnotationOverlay`/`AnnotationViewBuilder`/the three `Observation*View`s read `DetectedObject` (drop the `VNRecognizedObjectObservation` cast).
5. **`State/Settings.swift` + `UI/SettingsView/SettingsView.swift` + L10n** — `tiledDetection` toggle end to end (key, registered default, `reset()`, Toggle, en string, swiftgen).
6. **`UI/Screens/WebScreen.swift`** — mirror the setting into `DetectableView` (showIdentifiers pattern).
7. **Tests** (`MLBrowserUnitTests`) — `TileLayout` geometry (tiled/untiled, region invariants); remap math (corner regions, center region, identity full frame, clamping of out-of-range boxes, malformed-box rejection); dedup (clipped-quadrant-box-with-HIGHER-confidence vs center full box → full box survives; distinct same-label neighbors kept; different labels never suppress; same-region pairs never suppressed); latest-wins ordering (older completion arriving after newer is discarded); toggle flip mid-flight (next pass uses new region set); settings persistence + reset; update `DeepDriversTests` detect-path signatures; one Vision integration test with the demo model on a non-square image (skipped-if-unavailable guard like existing model tests).
8. **Verification** — gates (`swiftlint.sh`, `harmonize.sh`, `unittest.sh`); manual on iPad simulator with the lidar page from the issue: artifact near left/right/top edges detected with tiling ON that full-frame misses (**root-cause validation gate** — if tiling doesn't improve edge detection, stop and report before shipping a default); toggle OFF restores today's behavior; boxes land on artifacts (remap correct); no duplicate boxes over the center region; p50/p95 total latency recorded and posted in the PR.

## Files touched

| File | Change |
|-|-|
| `Drivers/DetectionTiling.swift` | new — TileLayout, DetectedObject, remap, cross-region dedup |
| `Drivers/Detector.swift` | atomic detect(image:regions:) → [DetectedObject] |
| `Drivers/DeepDriver.swift` | DetectionResult, detect(on:tiledDetection:) |
| `UI/Annotation/DetectableView.swift` | flag, result type, latest-wins snapshot sequencing |
| `UI/Annotation/AnnotationViewBuilder.swift`, `Observation{Circle,Rectangle,Point}View.swift` | DetectedObject |
| `State/Settings.swift`, `UI/SettingsView/SettingsView.swift`, `Resources/Localizable.xcstrings`, `Generated/L10n.swift` | toggle |
| `UI/Screens/WebScreen.swift` | setting → DetectableView |
| `MLBrowserUnitTests/…` | tiling/remap/NMS tests, signature updates |
| `MLBrowser.xcodeproj/project.pbxproj` | register new files |
