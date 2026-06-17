# Implementation Plan — AIA-0316: UI-test harness — local-HTML WebView `file://` loader

> Status: FINAL — SHIP (grill-master: r1 REJECT → r2 REVISE → r3 SHIP; codex reviewed, points folded
> in). Prerequisite harness A for AIA-0309. Independent of AIA-0317/0318.

## Goal
A launch-config option that makes the app load a bundled static HTML page via
`WKWebView.loadFileURL(_:allowingReadAccessTo:)`, read access scoped to the fixture file itself, so
navigation/detection e2e tests run offline. A smoke UI test launches with the option and verifies the
load.

## Why round 0 was rejected (do not regress)
- A `file://…` string is classified `.searchTerm` by `browserInputType` (no host, non-http scheme) and
  **Google-searched** — it never reaches a `load()` file branch. `WebView.swift:158/164`,
  `String+Extensions.swift:~84`.
- `defaultPage` is the wrong carrier: `WebScreen.swift:155` stringifies it and `withHTTPS` mangles a
  file URL into `https://file:///…`; `createOrRefreshWebHistoryEntry` (`WebScreen.swift:163`) pollutes
  history; `Settings.validate` (`Settings.swift:~217`) traps on a host-less `defaultPage`; it persists
  to `UserDefaults` and shows raw in the address bar.

## Design (file dispatch at the URL-carrying layer; transient, non-persisted carrier)

### Step 1 — `LoadRequest` carries an optional file URL
- `BrowserState.swift:16` — add `public let fileURL: URL?` to `LoadRequest` (URL is `Sendable`+
  `Equatable`), default `nil` in `init`/`next(_:)`; add `func nextFile(_ url: URL) -> LoadRequest`
  (bumps generation, sets `fileURL`, `input = url.absoluteString` for display only).
- Verify: builds; existing `next(_:)` callers unaffected (`fileURL` defaults nil).

### Step 2 — `MLWebView` dispatches a file URL before classification
- `WebView.swift:~144` (in `updateUIView`, after the generation-dedup guard, BEFORE the
  `switch request.input.browserInputType`): `if let fileURL = request.fileURL { let nav =
  uiView.loadFileURL(fileURL, allowingReadAccessTo: fileURL); browserState.navigationIssued(nav);
  context.coordinator.lastLoadedGeneration = request.generation; return }`.
  - `navigationIssued` is a no-op when no user load is pending (initial load) — safe.
- Verify: a `LoadRequest.nextFile(url)` loads the file; the non-file path is byte-for-byte unchanged.

### Step 3 — Transient, UI-test-only carrier + launch-config wiring
- `Settings` — add a **non-persisted** `var launchFixtureURL: URL?` (plain stored property, no
  `UserDefaults` didSet; documented UI-test-only). Never read in shipping (only `WebScreen` reads it,
  and only after `applyIfNeeded` sets it under `isRunningUITests`).
- Add `case localFixture` to `PageScenario` and `var fixtureName: String?` to **BOTH**
  `UITestLaunchConfiguration` AND the test-side `LaunchConfig` mirror (`UITestSupport.swift`), incl.
  the mirror's `PageScenario` enum (else the test cannot encode the scenario). **Bump
  `currentVersion`→2 and the mirror `version`→2 together** — the in-file contract says keep keys and
  version in sync; honor it rather than relying on additive-decode.
- `applyIfNeeded`: in the `pageScenario` switch add `case .localFixture`: resolve
  `Bundle.main.url(forResource: fixtureName, withExtension: "html")`, **trap if `fixtureName` is nil
  or unresolvable** (a misconfigured fixture must not fall back to a network page); set
  `settings.launchFixtureURL = url`. Leave `defaultPage` at baseline. Enum mutual-exclusivity means
  `.localFixture` cannot collide with `.last`/`.blank`/`.home`/`defaultPageOverride`.
- Verify: JSON round-trip test (`LaunchConfig(pageScenario: .localFixture, fixtureName:)` ⇄
  `UITestLaunchConfiguration` at version 2), and a v1 (mismatched) config still traps.

### Step 4 — `WebScreen` loads the fixture first, bypassing history
- `WebScreen.swift:145` — make the fixture the **leading `if`** of the existing
  `hasPerformedInitialAction` one-shot chain (it already wraps the `.last`/`.home`/`.blank`
  branches), so it is mutually exclusive with them and never falls through:
  `if let fixtureURL = appState.settings.launchFixtureURL { intendedPageKind = "localFixture"; if
  loadRequest.fileURL != fixtureURL { loadRequest = loadRequest.nextFile(fixtureURL) } } else if
  <existing .last> … `. **Do not** call `createOrRefreshWebHistoryEntry` in the fixture branch.
- Re-entry: the fixture branch sits inside the same `hasPerformedInitialAction` one-shot as the
  home/last branches, so a WebScreen re-mount reloads the fixture exactly as it would reload the home
  page — identical semantics, no new risk. (Nilling `launchFixtureURL` after consumption would make
  re-mount *worse* than the home branch, so it is deliberately left set.)
- Verify: launching with the fixture loads it; history stays empty for the file URL; address bar/
  `persistLastPage` ignore it (`isRestorable` is already false for non-http).

### Step 5 — Bundle the fixture in the APP target
- `ios/MLBrowser/iOS/Resources/UITestFixtures/uitest_page.html` — minimal, self-contained (no external
  assets), with a stable marker (`<h1>AIA UITEST PAGE</h1>` + an element carrying an explicit `id`/
  ARIA role to maximize the chance it surfaces to the accessibility tree). Add to the app target
  (pbxproj, minimal diff). App-bundle placement is correct: the test runner's bundle is unreadable by
  the app process.
- Verify: `Bundle.main.url(forResource:"uitest_page",withExtension:"html")` non-nil; `plutil -lint`
  passes; app builds.

### Step 5b — Add a deterministic "live page" checkpoint (render proof)
- Add `case currentPageFile` to `Testability.Checkpoint` (`Testability.swift:294`) and the `AID`
  mirror (`UITestSupport.swift`). In `WebScreen`, render
  `.checkpoint(.currentPageFile, value: appState.browserState.currentURL?.lastPathComponent ?? "")`.
- This rides the `\.url` KVO path (`BrowserState.urlChanged`), which fires for **any** URL including
  host-less `file://` — so it deliberately avoids the `didFinish` host-guard (`WebView.swift:251`
  returns early for host-less URLs). It proves the file URL became the **live** page, not merely the
  decision.

### Step 6 — Smoke UI test (committed deterministic signals — no coin-flip)
- `LocalPageUITests.swift`: `launch(LaunchConfig(pageScenario: .localFixture, fixtureName:
  "uitest_page"))`. Two guaranteed, in-app checkpoint assertions:
  1. `waitForCheckpoint(AID.cpIntendedPageKind, equals: "localFixture")` — the app decided to load the
     fixture.
  2. `waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html")` — the file URL is the live
     page. (Render proof via Step 5b.)
- The `app.webViews.staticTexts[...]` query is **not** used as a load-bearing assertion (WKWebView
  content is not reliably exposed to XCUITest); both signals above are in-app `CheckpointMarker`
  `Text` elements, which surface reliably.
- Verify: passes locally; passes with the simulator/device offline (airplane mode) — truly no network.

## Assumptions
- A1: `LoadRequest.fileURL` dispatched before `browserInputType` is the correct seam (round-0's
  string/`defaultPage` seam was proven wrong).
- A2: `loadFileURL(_:allowingReadAccessTo: fileURL)` renders a self-contained page (Apple: scopes read
  access to that file only).
- A3: a tiny gated HTML in the app bundle is acceptable shipping weight.

## Risks / trade-offs
- R1: `app.webViews.staticTexts` may not expose the `<h1>` — Step 6 verifies empirically and falls
  back to a `didFinish` checkpoint. Not left to chance.
- R2: `LaunchConfig`/`UITestLaunchConfiguration` drift — Step 3 round-trip test guards it.
- R3: pbxproj resource wiring — `plutil -lint` + build.
- R4: a transient `Settings.launchFixtureURL` adds one UI-test-only property to a shipping type —
  acceptable (gated, never read in shipping), mirrors the existing `UITestLaunchConfiguration`
  dead-in-shipping pattern.
