# Implementation Plan — AIA-0333 (extension): tour through saving a first finding

> Extends the shipped first slice (address bar → models → demo models → enable model) with the
> deferred "record a finding" steps, on the same branch/PR (#334). Owner-confirmed decisions:
> scope = through **saving** a finding; capture = **manual pick** (deterministic); **fullscreen
> disabled while the tour is active** (chrome stays visible so PLAY/Find stay in the top toolbar).

## New steps (appended after step 4 "enable model")
| # | Target | Bubble (intent) | Advance |
|-|-|-|-|
| 5 | PLAY button (`globalToolbarPlayDetection`) | "Start detection" | overlay-driven tap → `guide.ontheflyDetectionTapped()` → `ontheflyDetectionEnabled` true |
| 6 | Find button (`globalToolbarFind`) | "Tap to mark a finding" | overlay-driven tap → `guide.findTapped()` → `findModeRequested` true |
| 7 | (none — passive, no dim) | "Tap the map to capture a finding" | a ready `Finding` is saved (count increases) |
| 8 | (none — closing) | "You saved your first finding! You're all set." | scripted Done → finish |

Step 4 no longer finishes the tour; its `bubblePrimaryTapped` enable now advances to step 5.
Before step 5 the tour auto-closes the drawer (`drawer.close()`).

## Architecture decisions (grounded in the traced flow; revised after grill round 1)
1. **Fullscreen suppressed during tour — render-time gate, no setting mutation.** The user's
   `settings.fullscreenDetection` is NOT touched. Instead ContentView's effective-fullscreen
   conditions (`fullscreenActive`, the `modeTab(barsHidden:)` arg, `floatingChromeButton`) gain
   `&& !appState.tour.isActive`, so chrome/toolbar stay visible while the tour runs. Nothing to
   revert on finish/skip.
2. **Overlay-driven taps that advance directly** (steps 5, 6): PLAY/Find toolbar buttons can't
   receive a pass-through tap, so — like `.modelsButton` — a transparent tap target over the cutout
   calls `performCutoutAction()`. For these conditions `performCutoutAction()` BOTH performs the
   action (`ontheflyDetectionTapped()` / `findTapped()`) AND calls `advance()` immediately. No
   `guide`→`evaluate()` observer is added (the grill's objection #1): `isSatisfied` returns false
   for them and they never rely on polling. `advance()` updates `currentIndex` synchronously, so
   step 7 is rendered (no-dim) before the user can tap the map; step 6's cutout is gone by then.
3. **Passive no-dim step** (step 7): the map tap must reach `FindPickOverlay`, so this step renders
   **only the bubble** (no dim, no cutout, no hit-blocking). New `TourStep.dimsBackground = false`
   (default true). Manual pick (`WebScreen.manualPick`) works with no real detection, so the step
   never depends on the model finding anything.
4. **Saved-finding signal — edge-triggered, not count-compared.** No published count exists. Add a
   `@FetchRequest<Finding>` (predicate `lifeCycleString == CoreDataManageableState.ready.rawValue`)
   in ContentView and `.onChange(of: findings.count) { old, new in if new > old { tour.findingDidSave() } }`.
   `onChange` fires only on a real change, so a pre-existing/demo finding never triggers (no demo
   findings are seeded). `tour.findingDidSave()` advances only if on the `.findingSaved` step. The
   `SaveFindingSheet` presents above the root overlay and covers it while open — no hide logic;
   Cancel just leaves the user on step 7 to retry.
5. **New `TourAnchorID`**: `.playButton`, `.findButton`. New `AdvanceCondition`: `.detectionStarted`,
   `.pickModeEntered`, `.findingSaved`. Switch sites to update (exhaustive): `AdvanceCondition.isOverlayDriven`
   (detection/pick → true; findingSaved → false), `TourState.isSatisfied` (all three → false; not
   polled), `TourState.performCutoutAction` (detection → tap+advance; pick → tap+advance;
   findingSaved → no-op). New `TourState.findingDidSave()`. Step 4's `bubblePrimaryTapped` already
   `advance()`s, so 4→5 works once step 5 exists in `slice`.
6. **Mid-tour abandonment:** the gate still flips only on terminal (finish/skip), so backgrounding
   at steps 5–7 re-onboards from step 1 next launch (the shipped re-arm behavior). The enabled model
   persists; re-running step 4 is a no-op if a model is already on.
7. **Localization**: add `tour.play.text`, `tour.find.text`, `tour.capture.text`, `tour.done.text`,
   and a `tour.done` button label to the catalog and to `allKeys`.

## Tests
- **Unit (`TourStateTests`)**: step 4 enable now advances to step 5 (not finish); `.detectionStarted`
  advances only when detection flag flips; `.pickModeEntered` on `findModeRequested`; `.findingSaved`
  advances only via the saved hook; step 8 finishes + seeds the gate.
- **UI (`TourUITests`)**: extend the happy path — after enabling, tap PLAY (overlay-driven), tap Find,
  tap the map (passive step), fill the title (`saveFindingTitle`) + Save (`saveFindingSave`), assert
  the tour finishes and a `ready` Finding exists. Screenshot each step.

## Risks
- **Map tap not reaching FindPickOverlay** → passive no-dim step (UI-test-gated by the capture sheet
  appearing).
- **Detection auto-start timer** (`handleOnAppear` 5s) is gated on `snapAfterAppStart` (default
  false), so it won't fire mid-tour; the tour starts detection itself in step 5.
- **Fullscreen creeping in** → suppressed for the whole `tour.isActive` window, not per-step.
- **Find/pick requires a model/detection?** Manual pick is independent of detections; step 5 (PLAY)
  precedes it anyway.

## Out of scope (still deferred)
Findings list + open finding; share; settings/label-shape step; demo-finding cleanup.
