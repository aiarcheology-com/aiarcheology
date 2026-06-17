# Implementation Plan — AIA-0317: UI-test harness — live detection-count checkpoint

> Status: FINAL — SHIP (grill-master: r1 REVISE → r2 SHIP; codex review requested but the CLI ran
> long/inconclusive, so the two grill rounds are the review of record). Prerequisite harness B
> for AIA-0309. Independent of AIA-0316/0318. Small: reuses the existing checkpoint infrastructure.

## Goal
Expose the live count of rendered detection annotations as a checkpoint so UI tests can assert
`>= 1` after a detection run (and `0` when none). Reuses `Testability.Checkpoint` + `.checkpoint`
modifier + `waitForCheckpoint`/`checkpointValue` — only a new case + one publish site.

## Key facts (file:line)
- Detections render in `AnnotationOverlay` (`DetectableView.swift:239`) over
  `observations: [DetectionResult]`; each `DetectionResult.observations` is the per-group detected
  objects. The overlay is created in `DetectableView`'s body ZStack (`:85/:92`) from
  `appliedFrame?.results ?? []`. The live rendered count is
  `results.reduce(0) { $0 + $1.observations.count }`.
- Checkpoint infra exists: `func checkpoint(_:value:)` = `.background(CheckpointMarker)`
  (`Checkpoint.swift:23`); test side has `waitForCheckpoint`/`checkpointValue`.

## Plan
### Step 1 — Add the checkpoint case (both sides)
- `Testability.Checkpoint`: add `case detectionCount`. `AID` mirror (`UITestSupport.swift`): add
  `cpDetectionCount = "_AIA:Checkpoint.DetectionCount"`.

### Step 2 — Publish the live count from a STABLE view, outside the snapshot subtree
- In `DetectableView`'s body, attach `.checkpoint(.detectionCount, value: String(count))` to the
  **outer `GeometryReader`** (the body root), NOT the inner ZStack. The ZStack contains
  `SnapableGroup` (whose subtree is snapshotted and fed to detection); attaching at the body root
  keeps the 1pt `CheckpointMarker` as a background of the whole view, outside `SnapableGroup`'s
  snapshot subtree, so it can never enter the captured image. (`CheckpointMarker` is already a 1pt,
  clear, non-hit-testing, UI-test-only `Text` — `Checkpoint.swift:32` — so it is layout/render inert
  regardless.)
- `count = (appliedFrame?.results ?? []).reduce(0) { $0 + $1.observations.count }`, reading
  **`DetectableView`'s own `@State appliedFrame`** (`DetectableView.swift:51`) — the exact array
  passed to `AnnotationOverlay` (`:93`), so the published count equals the rendered annotation total.
  NOT `WebScreen`'s parallel `appliedFrame` mirror. `appliedFrame` is `@State`, so the body re-runs
  and the value recomputes when a detection frame is applied/cleared.

### Step 3 — Smoke test (scoped honestly to "exists + readable")
- `DetectionCountCheckpointUITests.swift`: launch (default config) and assert
  `checkpointValue(AID.cpDetectionCount) == "0"`. This PR's claim is scoped to **"the checkpoint
  element exists and is readable, reflecting the current count (0 with no detections)"** — it does
  NOT claim to observe live recompute, which an all-zeros launch cannot falsify. The element
  resolving by identifier is also the guard that the hand-typed `AID` string matches the app-side
  enum case.
- The `>= 1`-after-detection / recompute proof is deferred to **AIA-0322**, which composes this
  harness with the #316 local-page loader and a model-enable path. Explicitly deferred, not dropped.
- Verify: passes locally; the checkpoint exists immediately at launch (`DetectableView` backs the
  web screen and renders before any page/detection).

## Assumptions
- A1: `DetectableView` is on screen at launch (it backs the web screen), so the checkpoint is present
  from the start.
- A2: `DetectableView.appliedFrame?.results` is exactly what `AnnotationOverlay` renders, so the count
  matches the visible annotation total (including 0).

## Risks / trade-offs
- R1: marker entering the detection snapshot — avoided by attaching at the body root (outside
  `SnapableGroup`) and by the marker being a 1pt clear inert `Text`.
- R2: this PR ships only the `0` (exists + readable) assertion; the `>= 1`/recompute proof is deferred
  to AIA-0322 (noted, not silently dropped).
- R3: the `AID` mirror is a hand-typed string with no compile link to the enum; the smoke test
  resolving the element by that string is the drift guard.
