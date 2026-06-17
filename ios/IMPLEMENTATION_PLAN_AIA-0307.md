# Implementation Plan — AIA-0307: Browsing History list not refreshing after deletion

> Status: IMPLEMENTED. The verify-first investigation below was carried out; the outcome diverged
> from the ticket's premise — see **Outcome** next.

## Outcome (what the investigation actually found)

The reported "list does not refresh after delete/clear-all" bug is **not reproducible on current
`develop`**. Evidence gathered while implementing:

- **Clear-all refreshes correctly in the UI** — `testHistory_clearAll_emptiesList` (XCUITest) passes:
  the list empties in place. (The batch delete merges into the viewContext via
  `executeAndMergeChanges`, which the `@FetchRequest` observes.)
- **Per-row delete persists and refreshes the FRC** — proven deterministically at the unit level by
  `BrowsingHistoryRefreshTests`: `delete(id, in: viewContext)` drops the row from the store
  (`storeCount` 6→5) and the backing `NSFetchedResultsController` reflects it once it gets a normal
  run-loop turn (as SwiftUI's `@FetchRequest` always does). A non-vacuity guard (batch delete
  **without** the merge leaves the FRC unchanged) proves the assertions aren't satisfied by a store
  re-fetch.
- **The only real artifacts were the stale `@State refreshFrom` + its `// TODO` and the dead
  `refreshFrom.toggle()`** — removed.
- **The per-row delete UI e2e is NOT automatable** (harness limitation, not an app bug): the trailing
  swipe actions reveal, but XCUITest cannot fire the *middle* destructive trash button (a full swipe
  only auto-triggers the trailing-edge action = copy). Proven by reopening the screen and seeing the
  store unchanged (count 6→6→6). That test is `XCTSkip`-ped with this reason and cross-referenced to
  the swipe-to-delete testability work in AIA-0308; its data path is fully covered by the unit tests.

Net delivery: removed the stale TODO/`refreshFrom`; added `BrowsingHistoryRefreshTests` (4 unit
tests: per-row, clear-all, store-fetched per-row, non-vacuity guard); added the passing
`testHistory_clearAll_emptiesList` UI test; kept `testHistory_deleteEntry_removesIt` as a documented
skip. No data-layer fix was needed (Step 3 was a confirmed no-op).

---

> Original plan (post-grill, 3 rounds → SHIP), reconciled against `develop` with #310 + #311 merged.

## ⚠️ Reconciliation note (this plan was first drafted against stale `develop`)

The original draft (and its grill) ran against `develop` *before* PR #311 (AIA-0305)
merged, so it assumed the history UI tests, the UI-test store isolation, and history
seeding all had to be built from scratch. **They now already exist on `develop`:**

- `ios/MLBrowserUITests/BrowsingHistoryUITests.swift` already has the two target tests,
  currently `XCTSkip`-ped *"Blocked by AIA-0307"* — plus `testHistory_showsSeededEntries`,
  an `openHistory()` helper, and a `historyRows()` query (the `browsingHistoryItem` leaf id).
- **UI-test Core Data isolation already exists** in `DataController` (a disposable SQLite
  store in Caches, destroyed per launch) — so **Step 2a is DONE** (not to be re-added).
- **History seeding already exists**: `DemoDataManager` reseeds 6 history pages into the
  wiped UI-test store every launch — so **Step 2b is DONE**; tests use that seeded set.

**Net effect:** Step 2 drops entirely; Step 1 becomes "un-skip the existing tests + keep the
negative control"; assumptions A2/A3 are inverted (see below). Steps 0, 3, 4, 5 stand. The
verify-first spine and the FRC-propagation caveat are unchanged.

## Goal
After deleting a single Browsing History entry (swipe → trash) or tapping
"Clear all", the visible list (driven by `@FetchRequest`) must update
immediately, without reopening the screen. Lock the behavior in with tests and
remove the stale TODO / unused `refreshFrom` state.

## Root cause (read the code — leading hypothesis, validated by Step 0/1)

The original AIA-0307 ticket assumes the deletes bypass the `@FetchRequest`.
Reading the current code shows the data layer was hardened after the TODO was
written (data-layer merge fix commit `8976337` "[AIA-0270] Fix Core Data
deletion/migration safety"; TODO commit `e39b3dd`, AIA-0107). The leading
hypothesis is therefore that the TODO and `refreshFrom` are **stale leftovers**
and the data layer already refreshes the list — but this is confirmed only by
Step 0/1, not asserted as fact:

- View: `ios/MLBrowser/iOS/UI/SettingsView/BrowsingHistoryView.swift`
  - `:11` `@Environment(\.managedObjectContext) var moc` — this is the
    **viewContext** (injected at the app root,
    `ios/MLBrowser/iOS/UI/MLBrowser.swift:53`, inherited through the
    `NavigationLink` in `SettingsView.swift:131`).
  - `:18` `@State private var refreshFrom: Bool = false // TODO: history is not being reloaded after deletion`
  - `:79` per-row delete → `WebHistoryEntry.delete(entityId, in: moc)`
  - `:108` clear-all → `try WebHistoryEntry.deleteAll(in: moc)` then
    `refreshFrom.toggle()` (`:109`) — `refreshFrom` is never read anywhere, so
    the toggle is a no-op.

- Per-row delete: `CoreDataManagable.swift:374` `delete(_ entityId:in:)` does
  `context.delete(objectToDelete)` + `context.save()` **on the viewContext**.
  A `@FetchRequest` observes saves on its own context, so the row disappears.

- Clear-all: `CoreDataManagable.swift:352` `deleteAll(in:mergingInto:)` runs an
  `NSBatchDeleteRequest` via
  `NSManagedObjectContext+Extensions.swift:24 executeAndMergeChanges`, which sets
  `resultType = .resultTypeObjectIDs` and calls
  `mergeChanges(fromRemoteContextSave:into: [self] + additionalContexts)`. The
  view calls `deleteAll(in: moc)` with the defaulted `additionalContexts = []`,
  so it merges into `[moc]` = the viewContext. The merge posts an
  objects-did-change notification that `@FetchRequest` observes, so the list
  empties.

**Conclusion (a HYPOTHESIS, not a closed verdict):** Both paths *appear* to feed
the viewContext that backs the `@FetchRequest`, so the bug may already be fixed
in the data layer with only the stale TODO/`refreshFrom` remaining. But this
rests on a load-bearing, unverified claim:

> **The FRC-propagation caveat.** `@FetchRequest` is driven by an
> `NSFetchedResultsController` bound to the viewContext. For a *batch delete*
> merged via `mergeChanges(fromRemoteContextSave:into:[viewContext])` to remove a
> row from the FRC, the deleted object must be **registered/realized in the
> viewContext** at merge time. If the FRC holds only faulted/unrealized rows, the
> merge can be a no-op for the FRC and the row stays on screen. This is the exact
> mechanism the original bug could exploit, and it is why the clear-all path is
> riskier than the per-row path (per-row deletes the very object via the
> viewContext and saves, which the FRC always observes).

The plan is therefore **verify-first with a negative control**: the new tests
must be shown to FAIL against a deliberately-broken delete before a PASS on HEAD
is allowed to mean anything. We also reproduce the reported failure manually
first. Only then do we treat "already fixed" as established. Do not close the
ticket on an unverified green test.

## Plan (each step has a concrete verify)

### Step 0 — Reproduce the reported bug manually (gate before any test work)
Before writing tests, reproduce by hand on `develop` HEAD: open Settings →
History (with real entries), delete one entry and "Clear all", observe whether
the list updates live.
- Verify: written note of actual observed behavior per path (per-row,
  clear-all). If neither reproduces, the data layer is provisionally correct and
  the deliverable narrows to tests + cleanup; if one reproduces, that path is the
  live bug and Step 3 must fix it. This replaces inference with observation.

### Step 1 — Un-skip the existing UI tests AND prove they catch the bug (negative control)
The two tests **already exist** in `ios/MLBrowserUITests/BrowsingHistoryUITests.swift`,
currently `XCTSkip`-ped *"Blocked by AIA-0307"*:

- `testHistory_deleteEntry_removesIt` — swipes a `historyRows()` row, taps the
  `browsingHistoryDeleteEntry` action, asserts the realized row count drops.
- `testHistory_clearAll_emptiesList` — taps clear → confirms the alert → asserts the
  row count goes to 0.

Both navigate via the existing `openHistory()` helper against the already-seeded history.
Work here = **remove the two `throw XCTSkip(...)` lines** and confirm the assertion logic
still matches the screen. (They already act and assert without reopening the screen.)

- Verify (negative control, mandatory): temporarily break **only the
  propagation** (not the store deletion) on a throwaway local revision, so the
  control isolates the FRC-refresh behavior the test claims to lock — a control
  that breaks deletion itself would fail even on reopen and prove nothing.
  Concretely: keep the row deleted in the store, but suppress the change
  notification the FRC observes. For clear-all, run the existing batch delete on
  the viewContext but **skip the `mergeChanges` call** (e.g. a local variant of
  `executeAndMergeChanges` that executes the request and does not merge) — the
  rows are gone from the store, but the viewContext/FRC is never notified, so the
  on-screen list should NOT update until reopened. For per-row, wrap the
  `context.delete` so it deletes-and-saves on a separate child/background context
  sharing the same coordinator **without** the viewContext merging — same effect.
  Confirm **each test FAILS specifically on the on-screen-row assertion** (not on
  a fetch error). Revert the breakage; it is never committed.
- Verify (positive): with the breakage reverted, run both against `develop`
  HEAD. If they PASS, the data layer is confirmed correct → Step 3 is a no-op.
  If either FAILS, that is the live bug → Step 3 fixes that path.

### Step 2 — UI-test store isolation + history seeding — ✅ ALREADY DONE (PR #311)
No work here. PR #311 (AIA-0305) already shipped both prerequisites the original draft
proposed, and they're on `develop`:

- **Isolated store:** `DataController.init(inMemory:)` uses a dedicated disposable SQLite
  store in Caches under `AppEnvironment.isRunningUITests`, destroyed (WAL/SHM-safe) on each
  launch, with a fail-fast if the reset fails. The production store is never touched — the
  data-loss risk the original Step 2a addressed is already resolved.
- **Seeding:** `DemoDataManager` reseeds 6 deterministic history pages (satisfying the
  `@FetchRequest` predicate: `lifeCycleString == "ready"`, non-nil `page`/`creationDate_`)
  into the wiped store every UI-test launch. The existing `testHistory_showsSeededEntries`
  already relies on this.

So the tests in Step 1 launch with seeded history and an isolated store for free. Do **not**
add a new seeding flag or a second store-selection branch.

### Step 3 — (Conditional) Minimal data-layer fix, only if Step 0/1 shows a failure
Only if a path actually fails to refresh. Each branch carries one named,
falsifiable hypothesis (no "investigate"):

- Per-row path — expected NO-OP. The existing `delete(_ entityId:in:)`
  (`CoreDataManagable.swift:374`) deletes by objectID and saves **on the
  viewContext**; an FRC tracks objectID identity on its own context, so a save
  there always refreshes it (instance identity is irrelevant). There is no
  credible mechanism by which this path fails to refresh, so Step 0/1 should show
  per-row already works and this branch is a no-op. Only if the per-row UI test
  unexpectedly fails do we re-investigate from the observed failure — and the
  first suspect is then the predicate (`BrowsingHistoryView.swift:14`) or the
  test's own seeding, NOT the delete call.
  - Verify: the per-row UI test passes unchanged; if it fails, a written failure
    note names the actual mechanism before any edit.

- Clear-all path — Hypothesis: the FRC holds faulted rows not registered in the
  viewContext, so `mergeChanges(...into:[moc])` does not propagate the deletion
  to the FRC (the FRC-propagation caveat above). Fix if confirmed: make the merge
  target explicit and match the proven `DemoDataManager.deleteBrowsingHistory`
  usage (`DemoDataManager.swift:74` `deleteAll(in: context, mergingInto:
  [viewContext])`) — run the batch delete on a background context and merge into
  the viewContext. Keep `deleteAll(in: moc)` only if Step 1's positive run proves
  it already refreshes. Choose the smaller diff that makes the failing test pass.
  - Verify: the clear-all UI test passes; the other still passes.

### Step 4 — Remove the stale TODO and dead `refreshFrom`
Independent of Step 3 (the TODO/`refreshFrom` are dead either way):
- Delete `@State private var refreshFrom` (`:18`) and the `refreshFrom.toggle()`
  call (`:109`).

- Verify: project builds; SwiftLint clean; both UI tests still pass;
  grep shows no remaining `refreshFrom` references.

### Step 5 — Add a focused unit test for the data layer (regression lock)
Add an integration-style unit test using a **SQLite** store (temporary
`DataController(storeURL:)`, because `NSBatchDeleteRequest` does NOT work with
`NSInMemoryStoreType` per AGENTS.md §6). The assertions must operate on
a live **`NSFetchedResultsController`** bound to the viewContext, NOT a fresh
post-delete fetch — a fresh fetch always hits the store and returns 0 regardless
of whether the in-memory merge updated the viewContext, which would false-pass
(objection #4). The FRC is the exact mechanism `@FetchRequest` uses, so this
tests the real propagation:
- Clear-all: insert N `WebHistoryEntry` (predicate-satisfying); create and
  `performFetch` an `NSFetchedResultsController` over the same predicate on the
  viewContext, asserting `fetchedObjects.count == N`; call `deleteAll(in:
  viewContext)`; assert the FRC's `fetchedObjects.count == 0` (the FRC's delegate
  fires / its snapshot updates from the merge). This proves the merge reached the
  FRC, not merely the store.
- Per-row: same FRC setup, then `delete(id, in: viewContext)` one row; assert the
  FRC's `fetchedObjects.count == N-1`.

For the post-batch-merge object state, do not assert an ambiguous OR: a
`mergeChanges(fromRemoteContextSave:)` with `NSDeletedObjectsKey` **invalidates**
the registered objects (turns them into faults / removes them from the FRC's
snapshot); it does **not** set `isDeleted == true` (that flag is for
context-level `delete()`). The single assertion we rely on is the FRC count drop
above.

- Verify: both unit tests pass against a SQLite temp store; and as a vacuity
  sanity check, a variant that executes the batch delete WITHOUT the
  `mergeChanges` call leaves the FRC count unchanged (proving the count-drop
  assertion is real, not satisfied by the underlying store fetch).

## Success criteria
- `BrowsingHistoryUITests.testHistory_deleteEntry_removesIt` and
  `testHistory_clearAll_emptiesList` exist and PASS (no `XCTSkip`), and were each
  demonstrated to FAIL under the Step 1 negative control before passing.
- New data-layer unit tests (SQLite store, held-object assertions) pass and were
  shown to fail when the merge is removed (non-vacuous).
- UI tests run against an isolated temp store; production browsing history is
  untouched after a UI-test run.
- `refreshFrom` and the stale TODO are gone; no dangling references.
- Full local gate (swiftlint.sh, harmonize.sh, unit + UI tests) green before any
  push.

## Assumptions
- A1: `moc` in `BrowserHistoryView` is the app viewContext (confirmed:
  `MLBrowser.swift:53`).
- A2 (CORRECTED after #311 merge): The two named UI tests **already exist** in
  `BrowsingHistoryUITests.swift`, `XCTSkip`-ped "Blocked by AIA-0307". The ticket's
  "currently XCTSkip-ped" premise is now accurate. We **un-skip** them, not author them.
  (The original draft's "no BrowsingHistoryUITests" finding was true only on stale
  pre-#311 `develop`.)
- A3 (CORRECTED after #311 merge): UI-test Core Data store isolation **already exists**
  in `DataController` (disposable Caches store, wiped per launch). Step 2 is DONE; nothing
  to add.
- A4 (UNVERIFIED — load-bearing, treated as a hypothesis, not a fact):
  `mergeChanges(fromRemoteContextSave:into:[viewContext])` propagates a batch
  delete to the `@FetchRequest`/FRC ONLY for objects registered/realized in the
  viewContext at merge time. Step 0/1's negative control exists precisely to
  validate or refute this before relying on it.

## Risks / trade-offs
- R1 (MOOT after #311): no new app-startup branching — store isolation already exists
  on `develop` (single `isRunningUITests` gate in `DataController`, dead-code in shipping).
- R2 (RESOLVED on `develop`): UI tests already run against a dedicated temp/Caches store,
  so seeding/reset never touches the user's production history.
- R3 (accepted trade-off): if Step 0/1 show both paths already refresh, Step 3
  is a no-op and the deliverable narrows to tests + cleanup. Acceptable because
  the regression-locking tests + stale-code removal are the real value, and the
  negative control prevents this from being a silent false-pass.
- R4 (accepted trade-off): the negative-control breakage in Step 1 is done on a
  throwaway local revision and reverted; it is never committed. Adds effort but
  is the only way to prove the tests can actually fail.

## Grilling summary
- Rounds: 3 (grill-yourself:grill-master). Round 1 REVISE → addressed; round 2
  REVISE → addressed; round 3 **SHIP**.

Round 1 objections (all addressed):
- 1/2 (root cause was an unverified assumption; "skip Step 3 on PASS" risks a
  false-pass): added Step 0 (manual repro) and reframed Step 1 with a **negative
  control**; root cause demoted to a hypothesis with the FRC-propagation caveat.
- 3 (reset-then-insert would wipe the real user's SQLite history): added Step 2a
  — isolate the UI-test store to a temp URL via `DataController(storeURL:)`
  before any seeding. R2 reclassified as resolved.
- 4 (post-delete fresh fetch false-passes): unit tests assert on realized state.
- 5 ("investigate predicate/animation" hand-wave): replaced with named,
  falsifiable hypotheses per path.

Round 2 objections (all addressed):
- 1 (per-row hypothesis was wrong — objectID re-fetch + save on the viewContext
  is already FRC-correct): rewrote the per-row branch of Step 3 as an expected
  **no-op**; the existing delete already refreshes the FRC.
- 2 (ambiguous `isDeleted`/`isFault`/`nil` OR assertion): pinned Step 5 to a
  single guaranteed mechanism — assert an `NSFetchedResultsController`'s
  `fetchedObjects.count` drops; documented that batch-merge invalidation does not
  set `isDeleted`.
- 3/4 (negative controls broke deletion, not propagation, and fail for the wrong
  reason): redesigned both controls to keep the store deletion intact and break
  ONLY the `mergeChanges` propagation, asserting failure on the on-screen-row
  assertion specifically.
- 5 (document self-certified FINAL/SHIP before the verdict): status corrected;
  marked SHIP only after round 2 returned it.

Round 3 accepted trade-offs (verdict SHIP — these are inherent to a verify-first
plan, not fixable defects):
- The per-row negative control changes which context performs the delete, so it
  is informational rather than gating — acceptable because per-row is a
  documented expected-pass no-op. The clear-all control (skip merge, same
  context) remains the clean gating control.
- Step 3 is conditional on Step 0/1 actually failing; if clear-all passes on
  HEAD it is a no-op and we ship tests + cleanup only (R3).
- A4 stays formally unverified but is resolved empirically by Step 0 + the Step 1
  positive run before any conclusion is drawn.

Earlier accepted trade-offs: R3 (Step 3 may be a no-op) and R4 (throwaway
negative control, never committed).
