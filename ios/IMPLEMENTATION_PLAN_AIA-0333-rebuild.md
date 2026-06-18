# Implementation Plan — AIA-0333 (rebuild): real-action interaction model

On-device testing reshaped the tour's interaction model. This plan captures the agreed rebuild.

## The model (owner-confirmed)
- **Every step's bubble has a Next button.** Teaching steps show Next immediately. **Action steps
  hide Next until the user performs the real action**, then Next appears; the user taps Next to
  advance. **Skip** is always present (the only way to dismiss; tapping the dim never does).
- The user performs the **real action on the real control** (tap the CPU button, flip the real
  toggle, tap PLAY/Find, tap the map, tap Save) — not the overlay doing it for them.
- **No timeout/Next fallback** on action steps: the real control is reliably tappable (see dim),
  so Skip is the escape if needed.

## Foundation: four-rectangle dim + how actions actually fire (DONE)
`TourSpotlight` draws four dim rects around the cutout (a thin stroke outlines the focus; lighter
in dark mode). **Reality check:** even with a true hole, a tap does NOT reach a UIKit toolbar
button or the drawer toggle through the SwiftUI overlay (verified — and XCUITest can't tap through
either). So action steps are **overlay-driven**: a transparent tap target over the cutout runs the
real action (`performCutoutAction`), whose *effect* (drawer opens / detection on / pick mode /
model enabled) then **reveals Next**; the user taps Next to advance. Visually it's "tap the
highlighted control → Next appears." The in-sheet Save step uses a **non-blocking (visual-only)
dim** so the real Save (and the Title field) stay tappable.

## Per-step plan
| # | Step | Kind | Bubble / Next | Focus | Interactive control |
|-|-|-|-|-|-|
| 1 | addressBar | teaching | Next immediate | address bar | **none** (hole blocked — fixes the crash) |
| 2 | modelsButton | action(drawerOpened) | Next after drawer opens | CPU button | real CPU button |
| 3 | demoModels | teaching | Next immediate | drawer models | none |
| 4 | enableModelToggle | action(modelEnabled) | Next after a model is enabled | drawer models | real toggle (user sees it flip) |
| 5 | playButton | action(detectionStarted) | Next after detection starts | PLAY button | real PLAY (drawer auto-closed on entry) |
| 6 | findButton | action(pickModeEntered) | Next after capture mode | Find button | real Find |
| 7 | captureArea | action(captureStarted) | no Next — **auto-advances** when the sheet opens | none (no dim) | real map |
| 8 | saveButton | action(findingSaved) | no Next — **auto-advances** on save | Save button **in the sheet** | real Save |
| 9 | finished | teaching | Done immediate → finish | none | — |

Steps 7–8 auto-advance because the Save sheet covers the bubble; the real map/Save taps are the
"action", and tapping Save dismisses the sheet, so a Next there is impossible. The bubble for
step 7 disappears the instant the sheet opens (advance to 8), fixing the stuck-bubble issue.

## Work items
1. **`TourState`** — gating, not auto-advance (except 7/8):
   - `showsNextButton` = teaching ? true : (action satisfied). Hidden until the action.
   - `bubblePrimaryTapped()` → `advance()` only (no action performed by the overlay).
   - Remove the overlay-driven `performCutoutAction` path (real taps work now).
   - `evaluate()` (poked by observers) → if the current action's condition holds, **show Next**
     (steps 2/5/6) — or **advance** for auto-advance steps. `userEnabledModel()` → show Next
     (step 4). `captureDidStart()` → advance (step 7). `findingDidSave()` → advance (step 8).
   - Drawer auto-closes when entering step 5 (PLAY is in the chrome).
   - New `AdvanceCondition.captureStarted`; `TourAnchorID.saveButton`; per-step flags
     `interactiveHole` (teaching=false) and `autoAdvancesOnAction` (7/8) and `rendersInSheet` (8).
2. **`TourOverlay`** — 4-rect dim; for teaching steps add a transparent hole-blocker (so the
   spotlighted element isn't tappable — fixes the address-bar crash); no dim for step 7; **skip
   rendering** for `rendersInSheet` steps (the sheet hosts its own overlay). Bubble always shows
   Next when `showsNextButton`.
3. **`ContentView`** — observers poke `tour.evaluate()` on `guide.ontheflyDetectionEnabled` and
   `guide.findModeRequested` (and existing drawer.isOpen + finding-count). Whole-drawer focus
   anchor for in-drawer steps (cell anchors don't propagate; precise row anchor isn't reachable —
   documented trade-off), and disable the non-model drawer rows (Findings/Settings) + the address
   bar during the tour so only the intended control is interactive.
4. **`SaveFindingSheet`** — host a small tour overlay; `.tourTarget(.saveButton)` on Save; signal
   `tour.captureDidStart()` when it appears.
5. **Localization** — `tour.save.text` (+ allKeys); reuse `L10n.Common.done` for the close button.
6. **Tests** — rewrite `TourUITests` happy path for the real-action model (tap real controls,
   Next appears, advance), through the in-sheet Save; unit tests for the new gating.

## Already shipped (separate commits)
Dark-mode bubble/dim, reset-on-start (stop detection / close drawer), Replay label color.

## Trade-offs
- Whole-drawer focus for in-drawer steps (precise model-row cutout isn't reachable via List-cell
  anchors); mitigated by disabling the non-model rows so only the toggles are interactive.
- No no-deadlock timeout on action steps (owner chose real-action gating); Skip is the escape.
