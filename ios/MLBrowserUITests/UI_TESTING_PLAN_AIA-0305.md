# AIA-0305 — Add more UI tests (final plan, after 1 grill round)

**Goal:** Add stable, deterministic XCUITest coverage for the app's core functional flows
(drawer/config list, settings + submenus, browsing history, address/location sheet), backed
by a Core Data test-isolation reset so mutating tests are repeatable.

## Foundation

1. **Core Data UI-test isolation** — `DataController.init(inMemory:)`: when
   `AppEnvironment.isRunningUITests` and not `inMemory`, use a dedicated UI-test SQLite store
   in Caches and `persistentStoreCoordinator.destroyPersistentStore(at:ofType:options:)` it
   before `loadStores()`. WAL/SHM-safe (not `FileManager.removeItem`). Production store
   untouched. Every UI-test launch → clean store → `DemoDataManager` reseeds 2 demo models +
   6 history pages. Mirrors the AIA-0298 ephemeral-`UserDefaults` isolation.
   - Isolation invariant: each test method calls `launch(...)`; XCUITest spawns a fresh app
     process per launch, so `init` (and the wipe) runs per test.

2. **Wire missing identifiers** — `ConfigurationRow` (DrawerContent.swift) currently has no
   testability hooks. Add `sideMenuConfigurationCell` (row), `sideMenuCellEnabled` (toggle),
   `sideMenuDeleteConfiguration` (swipe delete).

3. **Extend `UITestSupport.swift`** — new `AID` identifiers + helpers (open drawer, open
   settings, wait-for-seeded-data with a 20s timeout).

## Test suites (all network-free, deterministic)

- **SettingsUITests** — open settings; assert every option present; toggle ShowLabels; visit
  About / Introduction / History submenus and assert key content; restore-defaults alert;
  dismiss.
- **DrawerConfigUITests** — drawer lists the 2 seeded demo models; toggle a model's enabled;
  delete a model → cell count drops.
- **BrowsingHistoryUITests** — list shows seeded pages; delete an entry → count drops; set
  default page → home indicator; clear-all → empty.
- **AddressBarUITests** — tap address bar → location sheet opens; seeded history items shown;
  toggle sort + full-URLs; dismiss.

Verify each on iPhone 16 + an iPad sim. SwiftLint. Commit.

## Outcome

Shipped **13 passing** UI tests across the four suites (Settings 7, AddressBar 3, DrawerConfig
2, BrowsingHistory 1). Three mutation tests are present but `XCTSkip`-ped with precise reasons
(test logic is written and re-enableable):

- `DrawerConfigUITests.testDrawer_deleteModel_removesCell` — the rows are real cells, but the
  custom drawer panel's drag gesture intercepts a row's leftward swipe, so swipe-to-delete
  can't be triggered from XCUITest. Model deletion is covered at the unit level.
- `BrowsingHistoryUITests.testHistory_deleteEntry_removesIt` / `testHistory_clearAll_emptiesList`
  — **discovered app limitation**: the history list does not refresh after a delete/clear (the
  delete button is found and tapped, but the row stays). This matches the existing
  `// TODO: history is not being reloaded after deletion` in `BrowsingHistoryView`. Recommend a
  separate fix issue (the per-row delete and clear-all bypass the `@FetchRequest`'s change
  tracking); re-enable these tests once it's fixed.

Also fixed a real testability bug in passing: `BrowsingHistoryView`'s `List` carried a
`.testability` identifier that SwiftUI propagates onto every row, clobbering the per-row and
button identifiers. Removed it; the screen is now anchored by its navigation title. The same
propagation pattern also affects `downloaderList` (out of scope here).

## Deferred (named tradeoff — require network or a new harness; no CI to shake out flakiness)

- **Detection-on-mockup UI e2e** (the issue's central ask). Needs: a `file://` WKWebView
  loader with sandbox read access (not wired today), an enabled demo model (seeded
  *disabled*), a live detection-count checkpoint, and handling of async WebKit
  render→snapshot→detection. **Detection *engine* coverage already ships deterministically in
  AIA-0306** (the user's dedicated detection card), so this is the UI-layer complement, not
  the core guarantee.
- Remote model download / import / cancel / pause (network).
- Remote page load + browser back/forward/reload + history-from-navigation (network).
- Web content brightness/contrast/saturation (only available after a detection snapshot from
  a loaded page).

**Resolved objections:** 4 (destroy mechanism, per-test launch invariant, identifier
verification, seeding timeout). **Accepted tradeoff:** 1 (detection-UI-e2e deferred; engine
coverage shipped in AIA-0306).
