# AIA-0215 — Store the detected findings

*Adversarially reviewed: 5 grill-master rounds (25 objections resolved or rebutted with code evidence) + Codex review (3 confirmed migration blockers folded in). Product decisions confirmed with the user.*

Issue: [#215](https://github.com/aiarcheology-com/aiarcheology/issues/215) — branch `feature/AIA-0215/store-the-detected-findings`, PR → develop.

## Goal

The user taps a detected annotation over the web content → detection pauses with the displayed boxes held frozen → a save dialog offers storing the finding (page URL + the displayed frame's clean snapshot + bounding box + free-text label + note + manual GPS) → findings live in a filterable inventory list reachable from the drawer.

## User-confirmed decisions

- Findings list = **drawer section** (no new tab; fits the fullscreen-browser direction).
- Labels = **free text, field starts empty**, with suggestion chips; no label allowed.
- GPS = **manual entry field** in v1 (automatic extraction deferred; URL often encodes position anyway).
- Storage = **clean full snapshot + box data**; highlight always drawn live, never baked into the PNG.

## Implementation

### 1. Core Data — `Finding` entity (migration is NOT trivially lightweight)

New model version `MLBrowser_0.0.2`, additive entity `Finding` following `CoreDataManagableWithState`:

- `entityId: UUID`, `lifeCycleString: String`, `creationDate_: Date`
- `page: URI` — the remote web URL (`WebHistoryEntry.page` precedent; **never** a file URI)
- `screenshotFilename: String` — filename only (`<entityId>.png`); the Documents container path is not stable across restore, so the full path is resolved at read time
- `label_: String?`, `note_: String?`, `gps_: String?`
- `detectionClass: String?` = tapped detection's `primaryLabelIdentifier`; `detectionConfidence: Double` = that primary label's confidence
- `modelId: UUID?` — `DeepDriverParams.entityId` of the producing configuration (provenance; multiple detectors run concurrently)
- `boxX/boxY/boxWidth/boxHeight: Double` — **full-image Vision-normalized** (`DetectedObject.boundingBox` is already remapped by `TileLayout.remap`, Detector.swift:115; `regionIndex` is provenance only)

**Migration (Codex-confirmed blockers):** `DataController.shouldInferMappingModelAutomatically` is `false` for App Store **and Debug** builds (DataController.swift:75-77) — inference alone will not migrate production stores. Required:

- Explicit mapping model `MLBrowser_0.0.1_to_0.0.2.xcmappingmodel` (Xcode-generated; all existing entities pass-through, `Finding` added).
- Direct `MLBrowser_0.0.0_to_0.0.2.xcmappingmodel` reusing `FillEntityIdIfNilPolicy` — Core Data does not chain mappings and the existing policy targets exactly 0.0.1, so 0.0.0 stores would otherwise dead-end (App Store builds crash; dev builds destroy the store).
- `.xccurrentversion` → 0.0.2.

**Test gate:** the migration test must NOT use `DataController(storeURL:)` — it forces inference on (line 127) and non-App-Store builds destroy-and-recreate on failure (false pass). Build a bare `NSPersistentContainer` with production-equivalent options (`shouldInferMappingModelAutomatically = false`), seed a 0.0.1 store (and a 0.0.0 store) with rows, open with the 0.0.2 model, assert every row survives. 

Validation (`validationReport()`): `page` is http(s), box coordinates finite within the unit rect, confidence in 0...1, `screenshotFilename == "\(entityId).png"`, `creationDate_` non-nil.

### 2. Screenshot storage — `FindingScreenshotStore`

- PNG at `Documents/Findings/<entityId>.png`, written atomically (`.atomic` write options).
- **Save ordering:** write PNG first → insert + validate + save entity; on any failure the entity is deleted from the context (the `WebScreen.createOrRefreshWebHistoryEntry` failure pattern — no pending object may survive for a later unrelated save to commit) **and** the PNG is deleted in the same code path.
- **Delete ordering:** capture the filename first → delete entity via a throwing path (direct `moc.delete` + `try save`, the `LocationSheetView.deleteSiteHistory` precedent — `CoreDataManageable.delete` swallows save failures) → best-effort file delete. A failed file delete leaves a file-without-row, which the sweep self-heals.
- **Orphan sweep** when the findings list opens: files-without-rows are deleted; rows-without-files render a placeholder (never auto-delete user data). All `Finding` mutations and the sweep run on the viewContext/MainActor and the save sheet is dismissed before the list can open — sequential by construction, never concurrent.

### 3. Frame-coherent capture — `DetectableView`

Replace `detectedObservations: [DetectionResult]` with **one source of truth**: `appliedFrame: AppliedDetectionFrame?` (struct: `image: UIImage`, `results: [DetectionResult]`, `date: Date`). It is written **only** at the existing apply site (the completion closure of `drivers.detect(on:tiledDetection:completion:)` inside the `detectionQueue.enqueue` pass, DetectableView.swift:101-113), after BOTH existing guards (generation, `!isInteracting`) plus a new `guard !isCapturingFinding`. `AnnotationOverlay` renders from `appliedFrame` — the cached image and the on-screen boxes can never diverge by construction.

### 4. Tappable annotations

- Each observation view gets an explicit **sized clear hit element** (`.frame` of the box size, `.position(center)`, `.contentShape(Rectangle())`, `.onTapGesture`) — there is no implicit hittable container, and the visible border fades to opacity 0 (un-hit-testable) over `phaseOutTime`.
- The hit element is disabled when the fade completes (`withAnimation(_:completion:)` flips `allowsHitTesting` off) — no invisible dead zones blocking links/pans after the box disappears; tappable exactly while visible ("tap the breathing location", per the issue). Boxes are re-applied every detection pass, restarting visibility.
- Callback `onDetectionTapped(DetectedObject, DeepDriverParams)` up through `AnnotationOverlay` → `DetectableView` → screen.
- The center/size transform (`(midX·W, (1−midY)·H)` center, `(w·W, h·H)` size) is extracted into one shared helper used by the live views, the hit element, and the static highlight — no drift.
- **Named trade-off:** a pan starting inside a visible detection box does not scroll the page (boxes are small; capture is the primary intent). Fallback if simulator testing shows annoyance: non-hit-testable overlay + `SpatialTapGesture` in `simultaneousGesture` with manual box hit-testing (double-delivers the tap to the page).

### 5. Tap → pause → `SaveFindingSheet`

Capture ownership is split: `DetectableView` owns the freeze; `Guide` only owns the timer.

Tap handler (one synchronous MainActor block, in this order):
1. Read `appliedFrame` (the displayed, historical frame — not a future completion).
2. `isCapturingFinding = true` — gates the apply site, the `geometry.size` clearer (line 88), the `interactionState` clearer (line 120), and new enqueues in `onSnapshot`.
3. `Guide.findingCaptureStarted()` — stops the snap timer (`cancelPending()` + generation bump happen locally in DetectableView; `stopTimer()` alone doesn't stop an in-flight pass, and `done()` chains a coalesced pending pass even after the timer stops).
4. Present the sheet with the captured `(frame, detection, params)`.

Sheet contents: URL read-only (`BrowserState.displayedURL` at tap time), label free text starting **empty** with suggestion chips = distinct stored user labels ∪ the tapped detection's `primaryLabelIdentifier` (single top-confidence class only — the full label list would pollute suggestions), note, manual GPS field, snapshot preview with the highlight **drawn fresh at full opacity** from the captured `boundingBox` via the shared transform mapped into the aspect-fitted rendered image rect (not the container).

Dismiss (every path, including interactive swipe) → `isCapturingFinding = false`, clear the captured state, `findingCaptureEnded()` resumes the timer **only if detection was enabled before**.

**Named cosmetic trade-off:** rotating while the sheet is up leaves the frozen boxes misaligned behind the sheet; the saved data is already captured in sheet state.

### 6. Findings inventory — `FindingsListView`

- New drawer section "Findings" (the AIA-0249 settings-in-drawer precedent) → list screen.
- Rows: cropped thumbnail + label + date + host. **Crop math:** pixel rect computed against `cgImage.width/height` directly (top-left space, Y-flip: `(minX·W, (1−maxY)·H, w·W, h·H)`) — no separate `image.scale` multiplication (double-scaling).
- Label filter chips from distinct stored labels; swipe-delete (ordering per step 2).
- Detail: full snapshot with live-drawn full-opacity highlight (shared transform, fitted-rect mapping), all fields, "open page" button → dismiss findings UI → load the stored URL in the web screen via a `Guide` published request consumed by `WebScreen` (`onReceive` → `openRequested`; note: `Guide.pageToOpen` currently has no production reader — this adds the consumer or a parallel dedicated one).
- `resetApplication()` does **not** delete findings in v1 (most precious user data; lowest blast radius) — noted in the PR as an open product decision.

### 7. Plumbing & tests

- L10n keys (en, surgical `Localizable.xcstrings` insertion + `scripts/swiftgen.sh`), `Testability` ids, manual pbxproj registration (+ `plutil -lint`).
- Unit tests: `Finding` lifecycle/validation; **migration gate from step 1 (0.0.1→0.0.2 and 0.0.0→0.0.2, production-equivalent options, rows survive)**; failed-insert cleanup (no pending object, no PNG); suggestion union; crop transform with an off-center box (Y-flip) against `cgImage` dims; aspect-fit highlight mapping; pause invalidation (apply discarded when `isCapturingFinding`); apply-site cache coherence.
- Local gates before any push: `scripts/swiftlint.sh`, `scripts/harmonize.sh`, unit tests with the explicit simulator destination. No push without explicit user OK.

## Known limitations (named, accepted)

- Pan starting inside a visible box doesn't scroll the page (fallback variant documented in §4).
- Rotation during the save sheet cosmetically misaligns the frozen boxes behind it.
- GPS is manual in v1; URL-derived prefill deferred.
- Suggestions before the first save = only the tapped detection's class.
