# UI Testing Plan — AIA-0189

Add UI tests covering basic functionality + in-app introspection via **checkpoints**.

Converged via 3 rounds of adversarial review (`/grill-yourself`) + a Codex (gpt-5.5) design
review. Test-quality criteria, in priority order: **stability, longevity, maintainability,
granularity, cost of execution.**

## Goal

A modern, low-flake UI-test foundation for ML Browser, then the issue's listed scenarios on
top of it. Three pillars:

1. **Deterministic launch configuration** — kills state bleed (the #1 UI-test flake source).
2. **Checkpoints** — in-app state introspection over the accessibility bridge (the issue's
   explicit "add introspection via checkpoints" ask).
3. **Page Object Model** — one fix-site per UI change.

## Existing facts this plan builds on (verified)

- `AppEnvironment.isRunningUITests` is `true` when `launchEnvironment["UI_TESTING"] == "1"`.
  (The earlier `&& XCTestConfigurationFilePath != nil` condition was removed — that variable
  is absent in the app-under-test process, which is separate from the test runner, so it made
  the flag always false in the app. The `UI_TESTING` marker can't be injected into a sandboxed
  production app, so the gate stays inert in production.)
- `Testability` enum maps Swift cases → a11y identifiers like `_AIA:Button.GlobalToolbarPlayDetection`
  (`Testability.swift`). `.testability(...)` sets `accessibilityIdentifier` (+ label under UI tests).
- `Settings` is a singleton built exactly once via `DependencyContainer.shared.settings = { Settings() }`,
  lazily, **before** any view reads it. `Guide`/`BrowserState` take it lazily *after*.
- The welcome **wizard** (`SlideshowView`) is presented as a sheet **iff** `keepSlideShowActive`
  is true (`ContentView.swift:228`). Default true (`Settings.swift:138`).
- Wizard arrow buttons have **empty closures** (`Slide.swift:54-56,80-82`); the `TabView` has no
  `selection`/`.tag`. Navigation is by swipe only; slides currently carry **no per-slide identity**.
- Home/blank page decision in `WebScreen.onAppear` (`WebScreen.swift:142-160`):
  `if reopenLastPage && lastPage != nil → load lastPage` ; `else if defaultPage != nil → load
  defaultPage` ; `else → return` (blank). `.enabled` is `{ self }` on `Bool`.
- `Settings.validate()` is called **only** in `SettingsView.swift:41` (user editing), **never at
  launch**; and a nil `defaultPage` does not throw (`Settings.swift:184` guard requires `isNotNil`).
  → the "blank" scenario (cleared `defaultPage`) is safe at launch.
- `onAppear` starts a 5s `asyncAfter` that auto-triggers detection iff `snapAfterAppStart`
  (`ContentView.swift:220-224`) — must be pinned off or it races composition assertions.

## Chrome composition (grep-verified placement)

| Element | Source | Container / size-class gate |
|-|-|-|
| CPU | `GlobalToolbarLeading` | leading nav item (all widths) |
| ADDRESS | `WebAddressDisplay` | principal HStack (all widths) |
| BACK / FORWARD / RELOAD | `WebBack/Forward/ReloadStopButton` | principal HStack, **regular only** (`WebScreen.swift:89-98`) |
| FIND | `GlobalToolbarTrailing.findButton` | trailing, **regular only** |
| PLAY / PAUSE | `detectionButton` | trailing (all widths) |
| EDIT (adjustments) | `adjustmentButton` | trailing (all widths) |
| floating BACK/RELOAD/FORWARD/FIND | `FloatingNavBar` | overlay, **compact only** (`ContentView.swift:183`) |

**Divergence from the issue prose:** the issue's iPad case lists a floating bar with
`[BACK][RELOAD][FORWARD][RECORD_FINDING]` and implies FIND there, but the code makes the floating
capsule **compact-only** and FIND a **regular-width trailing** button. Tests assert *actual code
behavior*; this divergence is reported to the user, not asserted as spec. (Issue is explicitly a
draft: "This document is not complete… improved after the first version.")

## Pillar 1 — Deterministic launch configuration

- `Codable UITestLaunchConfiguration` with a `version: Int` field (schema-version guard).
- The test JSON-encodes it into the single launch-env var `UI_TEST_CONFIG`. A typed builder on the
  test side encodes it so tests never hand-write JSON.
- Decoded at the **end of `Settings.init()`** when `isRunningUITests`. On decode failure → **trap
  loudly** (visible launch failure; never a silent fallback / false pass).
- Applies a **FULL deterministic baseline** (every relevant key, every launch) **then scenario
  deltas** onto the live `Settings` properties. Because the full baseline is re-applied each launch,
  persisted-UserDefaults bleed between scenarios cannot survive a launch. Persistence to the standard
  domain via `didSet` is accepted as harmless for that reason.
- **Seam justification (accepted trade-off):** mutating the live `Settings` in `init()` (vs. a
  composition-root + injectable store refactor Codex suggested) is correct *here* because `Settings`
  is the leaf singleton built first and does no async/derived work between its UserDefaults reads and
  the end-of-init override — no consumer ever observes a contaminated value. The refactor would
  re-plumb every `UserDefaults.standard` reference for zero added test value.

### Baseline (always applied under UI tests)

| Key | Baseline value | Why |
|-|-|-|
| `keepSlideShowActive` | `false` | skip the wizard by default |
| `snapAfterAppStart` | `false` | kill the 5s auto-detection timer (races composition) |
| `isDetectionPaused` | `false` | deterministic detection state |
| `fullscreenDetection` | `false` | matches issue precondition (detection-off, fullscreen-off) |
| `reopenLastPage` | `false` | deterministic page decision |
| `lastPage` | `nil` | "" |
| `defaultPage` | `about:blank` (`baselineHome`) | deterministic home with zero network; tests assert the load *decision*, not the render |
| `historySize` | `30` | fixed |
| `tiledDetection` | `true` | determinism (no UI impact) |

### Scenario deltas

| Scenario | Delta over baseline |
|-|-|
| `presentWizard` | `keepSlideShowActive = true` |
| home page set | (baseline `defaultPage` set) |
| blank page | `defaultPage = nil`, `reopenLastPage = false` |
| reopen last | `reopenLastPage = true`, `lastPage = <seeded>` |
| fullscreen on | `fullscreenDetection = true` |

- Locale pinned via `launchArguments`: `-AppleLanguages (en)`, `-AppleLocale en_US` — stops
  RTL/localization from reordering the toolbar.

## Pillar 2 — Checkpoints (state introspection)

- `.checkpoint(_ name: Testability.Checkpoint, value: String)` view modifier. **Only when
  `isRunningUITests`** it renders a **hidden but non-zero** `Text` (≈1pt, ~0 opacity,
  `.allowsHitTesting(false)`, not `accessibilityHidden`) → reliably surfaces as a `staticText` with
  `accessibilityIdentifier = _AIA:Checkpoint.<Name>` and the value as its label/value.
  - Non-zero + concrete `Text` type chosen deliberately: 0-size overlays can be pruned/merged/retyped
    across framework releases (Codex). Data-valued, not symbol-name reflection → release-safe (rule #7).
- Tests read via `waitForCheckpoint(_ name, equals:)` — a predicate expectation on the **value**, not
  mere existence (the element can exist before the state settles).
- Emitters are **single-instance** sites to avoid ambiguous duplicate identifiers.

| Checkpoint | Emitted at | Values |
|-|-|-|
| `intendedPageKind` | `WebScreen.onAppear` decision site (exact branches) | `home` / `last` / `blank` |
| `fullscreenFeatureEnabled` | `ContentView` | `true` / `false` |
| `appMode` | `ContentView` | current `AppMode` |
| `horizontalSizeClass` | `ContentView` | `compact` / `regular` |

- Naming: `intendedPageKind` (not "loadedPageKind") — it asserts the load **decision**, not render success.
- Wizard *presence* is not a checkpoint: it's asserted directly via the per-slide identity
  (`Testability.View.slideshowSlide` index 0), which only exists when the slideshow is shown.

## Pillar 3 — Page Objects + tests

- `UITestCase` base: `launchApp(config:)`, `waitForCheckpoint`, orientation helper that **resets to
  `.portrait` in `setUp`/`tearDown`** (kills cross-test order dependence) and, after rotating, **waits
  on the `horizontalSizeClass` checkpoint to stabilize** before asserting.
- `Screen` structs: `WizardScreen`, `BrowserScreen`, `DrawerScreen` wrap XCUIElement queries.
- **Composition tests are size-class-adaptive** (resolves skip-vs-fail honestly): read the
  `horizontalSizeClass` checkpoint, assert the expected element **set + `frame.minX` order** for that
  class. Order asserted only after each element `exists` and `frame.width > 0` (layout settled).
  - Compact (iPhone): leading `CPU`, principal `ADDRESS` only, trailing `PLAY` `EDIT`; floating capsule
    `BACK RELOAD FORWARD FIND`.
  - Regular (iPad): principal `BACK ADDRESS FORWARD RELOAD`, trailing `FIND PLAY EDIT`; no floating capsule.
  - Same test runs meaningfully on both device classes; never silently skips, never false-passes.
    iPad coverage = a CI-matrix destination concern, not an in-bundle `XCTSkip`.

### Test list (first version)

1. **Wizard — dismiss**: `presentWizard`; assert slide 0 (`slideshowSlide` index 0) is present;
   drag-down dismiss (the existing `BrowserRevampUITests` pattern — the sheet has no nav bar);
   assert it's gone.
2. **Wizard — scroll all slides**: `presentWizard`; **add `.testability(Testability.View.slideshowSlide,
   index:)` to each slide container** (`Slide.swift:109`); `.swipeLeft()` through all slides asserting
   each indexed slide via `waitForExistence`; end on dismiss. (Dead arrow buttons ignored.)
3. **Home page set** (iPhone & iPad): default config; assert `intendedPageKind == home`.
4. **Blank page** (iPhone & iPad): blank scenario; assert `intendedPageKind == blank`.
5. **iPhone navigation composition** (compact): portrait + landscape; size-class-adaptive composition
   assertion above. Floating capsule present.
6. **iPad navigation composition** (regular, landscape): size-class-adaptive composition assertion.
   No floating capsule; run on an iPad destination.

### Testability additions

- New `Testability.Checkpoint` enum (cases per checkpoint above).
- New `Testability.View.slideshowSlide` (per-slide identity).
- Address field + floating nav buttons are **already wired** (verified) — no change.

## Cost of execution

- UI tests stay in `MLBrowserUITests.xctestplan`. Per the project's CI cost policy, **PR pushes run
  unit tests only**; the full set (incl. UI) runs on `develop` merges. Relaunch-per-scenario +
  rotations dominate UI-test wall-clock — accepted as the price of strongest isolation. Rotations
  minimized by grouping portrait vs landscape assertions.

## Assumptions

- UI tests run where `isRunningUITests` is true via the existing `UI_TESTING=1` env.
- iPad regular-width coverage requires running the suite on an iPad destination (CI matrix).
- "EDIT" = adjustments (pencil) button; "FIND/RECORD_FINDING" = the find affordance (floating on
  compact, trailing on regular).

## Resolved objections (3 grill rounds + Codex)

- UserDefaults precedence/`register(defaults:)` → apply to live `Settings`, full baseline every launch.
- `init()`/`crashReporter` ordering → mooted by the in-`Settings.init` seam.
- Exact 2-branch + guard-return `pageKind` (not a fictional 3-way).
- Dead wizard arrows / no slide identity → swipe + added per-slide testability.
- Order via `frame.minX` (+ width>0), not query index; locale pinned for RTL.
- `onAppear` checkpoint race → `waitForCheckpoint(equals:)`.
- Schema `version` + loud decode failure (no silent false pass).
- Checkpoint element: non-zero `Text`, not prunable 0-size overlay.
- `XCTSkip` false-pass risk → size-class-adaptive composition tests instead.
- Wizard gated by `keepSlideShowActive` (not `isFirstLaunch`) → `presentWizard` scenario delta.
- Baseline completeness: pin `snapAfterAppStart=false` (5s timer), `isDetectionPaused`, `tiledDetection`.
- `validate()` not called at launch + nil `defaultPage` safe → blank scenario verified safe.

## Accepted trade-offs (not fixed, chosen deliberately)

- Live-`Settings`-init seam over a composition-root/injectable-store refactor — surgical, no
  re-plumbing, safe given `Settings` is the first-built leaf.
- Test values persist to the standard UserDefaults domain (self-correcting via full re-apply each launch).
