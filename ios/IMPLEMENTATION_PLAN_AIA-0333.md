# Implementation Plan — AIA-0333: Interactive onboarding wizard (spotlight tour)

> Status: FINAL — SHIP after 3 grill rounds + Codex technical review.
> Scope of THIS PR: reusable tour **engine** + the **first vertical slice** of steps. Remaining
> steps (settings/label-shape → play → find → finding form → save → findings list → share) are
> explicit follow-ups (AIA-0333 sub-issues to be filed).

## Goal
Replace the 10-slide onboarding slideshow with an interactive, state-machine-driven **spotlight
tour**: a full-screen dimming overlay with a cutout around one target element plus a pointing
"coach-mark" bubble, advancing through a scripted sequence that drives the **real** app UI. The
tour auto-starts on first launch and is re-runnable from Settings. All dimming/bubble/state code is
encapsulated in a dedicated `Tour/` module so it does not spray across the affected views (one
`.tourTarget(...)` marker per target element + one root `.tourOverlay(...)`).

## Product decisions (owner-confirmed)
1. **PR scope:** engine + first slice only: `address bar → CPU/models button → drawer opens →
   highlight the 2 demo models → enable-model toggle`. Tour ends gracefully after the slice.
2. **Advance model:** hybrid — the user performs the highlighted real action where natural; pure
   transitions are scripted; every bubble has **Skip**, and a per-step timeout surfaces **Next**.
3. **Old slideshow:** replaced now (deleted), tour becomes the first-launch experience.
4. **Side effects:** the model the user enables **persists** (it is the slice's payoff); only
   tour-*staging* state (a drawer the tour itself opened) is reverted on finish/skip.

## Architecture (`ios/MLBrowser/iOS/UI/Tour/`)
- `TourStep` — enum/value type per step: `target` (a `TourAnchorID`), `bubbleText` (L10n key),
  `placement`, `advance: .scripted | .userAction(AdvanceCondition)`, `fallbackAfter: TimeInterval`.
- `AdvanceCondition` — explicit per-step completion predicate (see Slice steps).
- `TourState` — `@Observable @MainActor`, owned by the (`@MainActor`) `AppState`. Holds the ordered
  `[TourStep]`, `currentIndex`, `isActive`; `start()/advance()/skip()/finish()`; the gate flag;
  the staging snapshot + cleanup; and the cancellable per-step timeout task.
- `TourOverlay` — root overlay (attached once at `ContentView`): reads the active target's bounds
  and renders dim + cutout + bubble.
- `TourSpotlight` — the dim+cutout shape.
- `TourBubble` — speech bubble (text + Skip + conditional Next), positioned relative to the cutout.

### 1. Anchoring
`.tourTarget(_ id: TourAnchorID)` marks each target via `anchorPreference(key:value:{ .bounds })`.
The single root `.tourOverlay(tour)` reads the active id's anchor through
`overlayPreferenceValue` + `GeometryReader` `proxy[anchor]`. Layout-driven, so it follows chrome
show/hide and orientation. **Mid-animation caveat (Codex):** `anchorPreference` reports in-flight
frames. The drawer-open step therefore gates its bubble until the drawer-open animation **completes**
(`withAnimation(_:completionCriteria: .removed, _:completion:)` / `Transaction.addAnimationCompletion`)
**and** the target anchor is non-nil.

### 2. Hit-test pass-through (the highest-risk piece — a Step, not an assumption)
The dim layer sets `.contentShape(.interaction, cutoutPath, eoFill: true)` so its interaction shape
is the dimmed area *with the cutout excluded*: taps inside the cutout fall through to the real
control beneath in the ZStack; taps in the dim are swallowed. Codex confirmed `eoFill` is the right
mechanism and that the shape must be on the **actual hit-test layer** — no full-screen ancestor /
gesture may hit-test as a rectangle over the hole. **Gated by a UI test** asserting a tap inside the
cutout opens the drawer. **Fallback** if device behavior is unreliable: the overlay intercepts the
cutout tap and invokes the action itself (noted risk: bypasses the control's disabled/accessibility
state — fallback only).

### 3. Advance + no-deadlock
Each `.userAction` step observes its explicit `AdvanceCondition`. A per-step timeout
(`fallbackAfter`) surfaces **Next** so no step can hang; **Skip** is always present. The timeout is a
cancellable `Task<Void, Never>?` cancelled on advance/finish/skip, and — per Codex — guarded by a
**step-generation id** re-checked after `Task.sleep` so a stale timeout cannot mutate a later step.
All mutation stays main-actor-isolated (TourState + AppState are `@MainActor`).

### 4. Gating, migration, launch flag
- New owned key **`hasSeenOnboardingTour`**. Presence detected via `object(forKey:) != nil`
  (Codex: `bool(forKey:)` cannot distinguish absent from `false`). Auto-start iff not seen.
- Flag flips **on finish/skip (terminal)**, never on start, so an interrupted/backgrounded tour
  re-arms.
- One-shot migration: if the legacy `keepSlideShowActive` key is **present and `false`** (the user
  opted out of the old slideshow), seed `hasSeenOnboardingTour = true` — do not re-onboard opt-outs.
  Everyone else sees the tour once on upgrade.
- Launch flag: rename `presentWizard` → **`startOnboardingTour: Bool?`**, bump
  `UITestLaunchConfiguration.currentVersion` 2→3 (no in-flight collision; #316/#318 merged), mirror
  in `UITestSupport`. The old wizard path is fully deleted, so the flag has a single consumer.
- Add a **"Replay onboarding"** row in Settings calling `tour.start()`.

### 5. Cleanup
The enabled model persists. `TourState.tourOwnsDrawer` is set true only when the tour calls
`drawer.open()`; it is **cleared on any user-originated drawer toggle** (drawer button, scrim tap,
close button hooks). On finish/skip the tour closes the drawer **iff** the flag is still set. Scroll/
highlight is transient view state — no revert.

## Slice steps (this PR)
| # | Target | Bubble (intent) | Advance |
|-|-|-|-|
| 1 | address bar | "Type a page address — a Bavaria LiDAR page is in your history" | address field `isEditing` false→true |
| 2 | CPU/models button | "Download or configure your detection models" | `drawer.isOpen` false→true |
| 3 | first 2 demo models (drawer) | "These are your detection models" | scripted / Next |
| 4 | enable-model toggle | "Enable a model to use it" | highlighted demo model `enabled` false→true (matched by `objectID`) |

Tour then finishes cleanly (slice end). Remaining sequence = follow-up issues.

## Removals / replacements
- Delete `SlideshowView` / `Slide.swift`, the slideshow sheet presentation in `ContentView`, and the
  `keepSlideShowActive` key + read site + its Settings toggle.
- Replace `WizardUITests` with `TourUITests` in the same PR (coverage retargeted, not dropped — the
  PR's green gate requires `TourUITests` passing).

## Tests
- **Unit (`TourState`):** ordered sequence; each `AdvanceCondition` fires only on the right
  transition; skip; timeout→Next via the generation guard (no stale mutation); cleanup incl.
  open→user-close→finish leaves the drawer as the user left it; gate + migration logic via
  `object(forKey:)`.
- **UI (`TourUITests`, via `startOnboardingTour` + a `cpTourStep` checkpoint):** bubble appears on
  the address bar; cutout tap passes through (drawer opens); bubble re-anchors correctly **after**
  the drawer-open animation; Skip dismisses; gate not re-shown after finish.

## Local gate (before push)
`./scripts/swiftlint.sh`, `./scripts/harmonize.sh`, `./scripts/unittest.sh`, and the UI test plan
(at least `TourUITests`). All green. No push without explicit OK; do not merge (owner tests first).

## Assumptions
- Slice-only is the intended first-launch onboarding until follow-ups (owner-confirmed).
- Legacy opt-outs are not re-onboarded; everyone else sees it once.
- iOS 17.6 retained — all required APIs are iOS-17-available (owner allowed raising the target if
  needed; not needed).

## Risks (mitigated)
- `eoFill` device hit-testing → UI-test-gated + overlay-drives-action fallback.
- Mid-animation anchoring (esp. the drawer-open transition in this very slice) → step gated on
  animation completion + non-nil anchor; UI test asserts post-transition anchoring.
- Stale per-step timeout → step-generation guard after `Task.sleep`.

## Grill + Codex summary
- **Round 0 → REVISE:** cleanup-vs-payoff conflict (revert would undo the enable); wrong gating key;
  hit-test "guarantee" unearned; no deadlock fallback; coverage gap on deleting WizardUITests.
- **Round 1 → REVISE:** `isFirstLaunch` is a dead gate; no migration for removing
  `keepSlideShowActive`; launch-config version trap; advance predicates unnamed; staging-revert
  interleaving.
- **Round 2 → REVISE:** flip gate on terminal not start; bake in (not defer) the opt-out migration;
  don't overload `presentWizard`; clear drawer-ownership on user event, not end-state; mitigate
  in-slice anchoring jitter.
- **Round 3 → SHIP.**
- **Codex:** confirmed `eoFill` (use `.interaction`, right hit-test layer); iOS-17
  `completionCriteria: .removed` for animation-settled anchoring; `@MainActor` Task + generation
  guard for the timeout; `object(forKey:) != nil` for the gate/migration.

## Out of scope (follow-ups to file under AIA-0333)
Settings/label-shape step; play (start detection); find; finding form (title + save); findings list
+ open finding; share. Plus per-artifact cleanup of the demo finding the full tour records.
