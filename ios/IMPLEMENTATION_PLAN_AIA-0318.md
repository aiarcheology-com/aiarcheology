# Implementation Plan — AIA-0318: UI-test harness — model-download mock/stub

> Status: FINAL — SHIP (grill-master: r1 REVISE → r2 SHIP; codex review requested but the CLI ran
> long/inconclusive, so the two grill rounds are the review of record). Prerequisite harness C
> for AIA-0309. Independent of AIA-0316/0317. (r2 note folded in: the unit test asserts the delivered
> file is non-empty before byte-equality, so an empty temp file can't false-pass.)

## Goal
A deterministic, network-free model-download source so model-lifecycle tests don't hit the real
network: a custom `URLProtocol` that serves a tiny fake payload, activated by a launch-config flag,
wired so `Downloader` uses it only under UI tests with the flag set. Production path untouched.

## Key facts (file:line)
- `Downloader` (`State/Downloader.swift`) selects the session in `startDownload` (~`:471`):
  `sessionFactory` (unit-test hook) → else `shouldUseBackgroundSession` → `backgroundSession` → else
  `foregroundSession`. **Under any test run `shouldUseBackgroundSession` is `false`**
  (`:187` = `!AppEnvironment.isRunningUnderAnyTests`), so UI-test downloads already use
  `foregroundSession` (`:201`, `URLSessionConfiguration.default`).
- **`URLProtocol` works with `.default` sessions but NOT background sessions** — so the stub must
  ride `foregroundSession`, which UI tests already use. No change to session selection needed.
- Launch config (`UITestLaunchConfiguration` + `LaunchConfig` mirror) is version-checked; reads
  `UI_TEST_CONFIG` from the environment via `fromEnvironment`.
- `AppEnvironment.isRunningUITests` (`:66`) is the `UI_TESTING=1` marker (not set in shipping).

## Plan
### Step 1 — `StubDownloadURLProtocol`
- New `StubDownloadURLProtocol: URLProtocol` (app target, UI-test-only). `canInit(with:)` claims
  any http(s) request; it is a pure predicate and does not know about gating — inertness in
  shipping comes entirely from the protocol never being inserted into a session's `protocolClasses`
  unless gated in (Step 2). `startLoading` synthesizes an `HTTPURLResponse` (200,
  `Content-Length` = payload size), calls `client?.urlProtocol(_:didReceive:cacheStoragePolicy:)`,
  `client?.urlProtocol(_:didLoad:)` with a tiny fixed payload, then
  `client?.urlProtocolDidFinishLoading(_:)`. `stopLoading` is a no-op. For a **`downloadTask`** the
  URL loading system writes those bytes to a temp file and delivers a file URL — so the production
  task type (`downloadTask`, `Downloader.swift:489`) is what the stub feeds. Deterministic, no
  network. Carries the canned payload as a static constant.

### Step 2 — Gate it onto `foregroundSession` via a testable decision
- Extract the decision into a pure static helper so the novel logic is unit-testable without faking
  the environment:
  `static func foregroundProtocolClasses(base: [AnyClass], isUITest: Bool, stubDownloads: Bool) ->
  [AnyClass]` → returns `[StubDownloadURLProtocol.self] + base` when `isUITest && stubDownloads`,
  else `base`.
- In `Downloader.foregroundSession`'s lazy init:
  `configuration.protocolClasses = Self.foregroundProtocolClasses(base: configuration.protocolClasses
  ?? [], isUITest: AppEnvironment.isRunningUITests, stubDownloads:
  UITestLaunchConfiguration.fromEnvironment?.stubDownloads == true)`. The exact reassignment
  **prepends** the stub and **preserves** the existing classes (no `insert` on the property, no
  dropped intercepts). Shipping/normal-test paths are byte-for-byte unchanged (guard false → returns
  `base`).
- The flag is read at first `foregroundSession` access (first download) via `ProcessInfo`, which is
  populated from process start, so the read is always valid — intentional, no stale-capture path.

### Step 3 — Launch-config flag (both sides)
- Add `var stubDownloads: Bool?` to `UITestLaunchConfiguration` and the `LaunchConfig` mirror; bump
  `currentVersion`/`version` to 2 on both. Verified: no existing UI-test file pins a `version`
  literal (they all use the `LaunchConfig` struct default at `UITestSupport.swift:24`), so bumping
  the default updates them uniformly.

### Step 4 — Deterministic unit proofs (cover BOTH the stub and the gating logic)
- `StubDownloadURLProtocolTests` (unit target):
  1. **Stub serves a completing download:** build a `URLSession` with
     `configuration.protocolClasses = [StubDownloadURLProtocol.self]`, run a **`downloadTask`** (same
     API as production) via a `URLSessionDownloadDelegate`, and assert `didFinishDownloadingTo`
     fires and the **delivered file's bytes equal the canned payload** (a download task yields a temp
     file, not in-memory `Data`). No network.
  2. **Gating logic:** assert `foregroundProtocolClasses` prepends the stub only when
     `isUITest && stubDownloads` are both true, and returns `base` unchanged otherwise (covers the
     shipping/normal-test guard — the one piece of novel wiring).
  3. **`canInit` scope:** `canInit` only claims http(s) requests (it is a pure predicate; it is
     never *asked* in shipping because the protocol isn't inserted into any session's
     `protocolClasses` unless gated in — that membership, not `canInit`, is what makes it inert).

### Step 5 — Named scope boundary (not a buried gap)
- This PR ships the **deterministic download source + the gating logic, both unit-tested**. Driving
  the stub through `Downloader`'s live `foregroundSession` end-to-end requires the **add-model-by-URL
  UI flow, which is AIA-0319's scope** — that flow does not exist yet and building it here would be
  out of scope for a harness building block. The gating *logic* is unit-tested via
  `foregroundProtocolClasses` (so it is NOT an untested novel path); only the live e2e wiring is
  exercised by 0319. Explicitly stated, not hidden.

## Assumptions
- A1: UI-test downloads use `foregroundSession` (confirmed via `shouldUseBackgroundSession == false`
  under tests), so a `URLProtocol` on its config intercepts them.
- A2: `URLProtocol` cannot intercept background sessions — hence the foreground-only wiring; this is
  acceptable because tests never use the background session.

## Risks / trade-offs
- R1: a stubbed payload is not a valid `.mlmodel`, so model *import/compile* would fail — but the
  harness contract is "download completes deterministically", not "produces a loadable model".
  Model-import behavior is out of scope (and 0319 can bundle a real tiny fixture if it needs import).
- R2: `LaunchConfig`/`UITestLaunchConfiguration` sync (version bump) — same pattern as #316.
- R3: registering a `URLProtocol` globally vs per-session — use the per-session
  `configuration.protocolClasses` (scoped to `foregroundSession`), never `URLProtocol.registerClass`
  (process-global), so nothing leaks.
