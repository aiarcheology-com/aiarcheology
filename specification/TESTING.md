# Testing and verification

Run commands from the repository root unless a different directory is shown. The selection policy
lives in [AGENTS.md](../AGENTS.md#verification): verify each changed revision and its affected consumers.
Include resources, fixtures, build configuration, and dependency changes when assessing impact.
Issue [#850](https://github.com/aiarcheology-com/aiarcheology/issues/850) proposes an impact selector;
it is not implemented. Selection today is manual and does not replace existing required gates.

## Current suites

| Area and relevant inputs | Current entry point and limits |
|-|-|
| App behavior, persistence, URL/location parsing, services, state | `./scripts/unittest.sh` runs Tools tests, the credential-delivery shell regression, then the complete `MLBrowserUnitTests` plan on an available simulator. It accepts `--verbose`, not a test filter. |
| App UI and user journeys | Xcode's `MLBrowserUITests` plan, using the command below. Select journeys affected by behavior, navigation, strings, accessibility, or resources. |
| Map parsing and browser integration | App unit target: URL/type/resolver tests plus probe, installation, arming, and WebKit integration tests. Parser-only coverage does not establish browser installation behavior. See [MAP_LOCATION.md](MAP_LOCATION.md). |
| Native model conversion and package behavior | Root `swift test` on macOS. External ONNX, Apple reference, and checkpoint coverage needs the fixture setup below; a bare green run can include skips. |
| Shared support-log format | `swift test --filter SupportLogFormatTests`; shared format changes also need affected app/backend consumer checks. SwiftPM filtering selects execution, not necessarily compilation of other targets. |
| Headless screen/action package (HeadlessKit) | Lives in [aiarcheology-com/HeadlessKit](https://github.com/aiarcheology-com/HeadlessKit) since AIA-1005: `./scripts/test.sh` there (`swift test`, at least 260 tests by its own floor, 374 at 1.0.0, none skipped) and its footprint checks (`scripts/check-example-footprint.sh`, `scripts/check-host-build.sh`), in that repository's CI. Since kit 1.0.0 (AIA-1008) that includes the host side: the command line, the simulator launcher and the route lint. `swift test --package-path Tools` keeps ML Browser's own headless tests in ProjectToolCoreTests (`HeadlessTests.swift`): image staging, launch options, the handshake refusals, `HeadlessScenarioPolicyTests`, the build, and the committed scenarios against the committed map. Here, `swift test --package-path Tools --filter HeadlessKitPackageTests` checks that the app and ProjectTool pin the same version, that ProjectTool enables the `HeadlessHost` trait, and that the kit's code stays out of this repository. The app's own Release footprint is a release-time check ([RELEASE_CHECK.md](RELEASE_CHECK.md#every-release-headlesskit-footprint)). See [HEADLESS.md](HEADLESS.md#where-ml-browser-pins-it). |
| Headless mode of the app | Headless mode is a launch mode (`-interface headless`) of the Debug app that `./scripts/unittest.sh` builds, so the unit sweep compiles `Headless/Entry/` and the rest of the mode (AIA-0991). `scripts/headless.sh build` makes that same build (`build-for-testing -testPlan MLBrowserUnitTests` with `AIA_INCLUDE_TEST_FIXTURES=YES`, in `.deriveddata`) and recompiles nothing after it; see [HEADLESS.md](HEADLESS.md#ml-browsers-headless-mode). Every build into that DerivedData passes the fixtures flag, and it never runs while another build or test uses the DerivedData. |
| Headless scenarios (end to end, on simulators) | `scripts/headless.sh test` builds the Debug app (`--no-build` reuses `unittest.sh`'s product) and runs `ios/HeadlessScenarios/*.json` on `aia-headless-*` simulators against the development backend. Run it for changes to the headless adapters, the gate deciders they share, or the flows the scenarios cover. `sign-in-sign-out.json` signs in to Clerk's development instance, so it needs the Clerk keys from `Secrets.xcconfig` and network access to Clerk. Without keys the build falls back to mock auth, and that scenario fails at its first step (`usesRealAuth`) by design. The AIA-0975 scenarios (`find-store-backup`, `saved-before-sign-in`, `backup-off`, `foreign-findings-stay-local`) need the same keys, plus network access to the development findings Worker. They stage `ios/MLBrowserUnitTests/Fixtures/terrain_iphone.png`, so they also run for changes to the save path (`FindingRepository`, `FindingCapture`), sync (`FindingsSyncCoordinator`) or that fixture. For changes to the crash-reporter choice (`DependencyContainer`) or the headless entry, also run `SIMCTL_CHILD_SENTRY_TEST_ERROR=1 scripts/headless.sh test ios/HeadlessScenarios/payments-off-no-gate.json` (it builds first, so it tests the change): it passes only while headless mode keeps the no-op reporter with a `SENTRY_TEST_*` variable set, because the launcher refuses a handshake whose `crashReporting` is not `false` (AIA-1016; limits in [HEADLESS.md](HEADLESS.md)). |
| Headless routes and navigation map (no simulator) | `scripts/headless.sh test --lint [files…]` checks every route the scenarios name, and every action and literal argument against the map's catalog, against the checked-in `ios/HeadlessScenarios/Map/navigation-map.json`, with no build and no simulator; `scripts/headless.sh test` runs the same check before it builds. Run it for changes to scenarios or to the map. The map's own tests, `HeadlessNavigationMapTests` (the checked-in copy equals the declaration; sheet exits; the app's own moves) and `HeadlessWalkTests` (an in-process walk of the adapters against the map), are in the `MLBrowserUnitTests` plan: run them for changes to the headless adapters, the gate deciders or `HeadlessNavigationMap`. See [HEADLESS.md](HEADLESS.md#ml-browsers-headless-mode). |
| Headless/UI parity (local only, AIA-0984) | Two legs, run one after the other, never at once: `scripts/headless.sh test ios/HeadlessScenarios/parity-*.json`, then the `HeadlessParity` plan (`xcodebuild test … -testPlan HeadlessParity` on an erased simulator, same flags as the UI command below). Both check the four `parity-*` flows against the same declared screen sequence; see [HEADLESS.md](HEADLESS.md#parity-with-the-app). The UI leg signs in to Clerk's development instance and waits for free access to run out (about 2 minutes), so it needs the Clerk keys and network access. Not in any CI job; `MLBrowserUITests` skips `HeadlessParityUITests`. Run it for changes to the headless route decision, the shared presentation models, the gate or analytics views, or the drawer, web screen, save sheet and sign-in sheet. |
| ProjectTool | `swift test --package-path Tools` |
| Credential-delivery shell logic | `./scripts/test_deliver_credentials.sh` uses its hermetic test harness. |
| Architecture and source/resource invariants | `./scripts/harmonize.sh` uses the macOS `MLBrowserArchitectureTests` scheme and `MLBrowserUnitTestsHarmonize` plan. It reads repository files from disk. |
| Localization parity and catalog validation | `./scripts/localization.sh` runs Python strict parity and checks both catalogs. This also runs in GitHub CI; it is not merely an optional editor helper. |
| Issue automation trust boundary | `node --test .github/tests/issue-automation.test.cjs` executes the inline workflow with offline GitHub API doubles; requires Node and Ruby/Psych. Runs in Harmonize CI. Covers permissions, exact commands, issue/PR events, and comment updates; hosted event/token behavior remains a separate check. |
| Apple test-fixture setup | `python3 scripts/test_apple_test_models.py` checks cache repair, offline reuse, fail-closed opt-in, notice embedding, and ordinary-build cleanup without network or Xcode. Runs in the unit wrapper and Harmonize CI. |
| Xcode catalog stability | `./scripts/check_localization_build.sh` builds and checks that both catalogs remain unchanged. This is separate from semantic validation and does not execute app tests. |
| Swift style | `./scripts/swiftlint.sh` lints `ios/`. For a file, pass an absolute path after `lint`, since the wrapper changes directory. Preserve required hook/CI scope. |
| Catalog/ONNX manifest consistency | `./scripts/verify_catalog_onnx_sync.sh`; relevant to catalog entries and converter fixture manifests. |
| Findings Worker | In `cloudflare/findings-worker`, `npm run typecheck` and `npm test` cover types and the local Worker test environment. Staging E2E is a separate command and provisioning step. |

Consult test plans and target membership for the current execution scope; do not infer scope from a
folder name. Shared formats, persistence, app composition, dependency changes, and build settings
often affect several rows. If the consumer set is unclear, broaden coverage.

## Observe Xcode Cloud

`scripts/aia-xcode-cloud-poll.sh` is a thin wrapper around `ProjectTool asc cloud`. It makes
read-only App Store Connect API requests; it does not start, retry, cancel, or change builds.
Materialize the existing API credentials once with
`swift run --package-path Tools ProjectTool asc credentials generate`. The observer requires the
secure files in `ios/asc.auth`; it does not print tokens or fall back to an interactive sign-in.

```sh
# One snapshot of any build, including PR builds. Full App Store Connect build/action URLs work too.
./scripts/aia-xcode-cloud-poll.sh <build-uuid-or-url>

# Select the latest non-PR build of this exact branch, across the product's workflows.
./scripts/aia-xcode-cloud-poll.sh --branch develop
./scripts/aia-xcode-cloud-poll.sh --branch release/1.0.9 --watch --interval 60

# Select a different Xcode Cloud product; the default is ML Browser.
./scripts/aia-xcode-cloud-poll.sh --branch main --product <product-uuid>
```

Branch lookup follows all pages and compares creation times; API ordering is not assumed. The
branch must already have a build. Use an explicit build URL when selecting a particular workflow,
PR, or older run. Watch mode stays on the selected build even if a newer build starts, and stops
when that run completes. Ctrl-C stops observation. HTTP/authentication failures stop with an error;
rerun the command after resolving them.

The output discovers every action and reports issues, deduplicating repeated issue details. Test
totals are fetched after each test action completes, with pagination; zero published results are
not test-pass evidence. Completed unsuccessful/canceled/skipped builds exit 1. A running one-shot
snapshot exits 0 to indicate a successful query, not a successful build. Watch mode defaults to
60-second polling; `--interval` accepts 5–86,400 seconds. Tokens are renewed for every request.

Run `swift test --package-path Tools` for the observer's offline API-fixture regression tests.
API references: [build runs](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-ciproducts-_id_-buildruns),
[actions](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-cibuildruns-_id_-actions),
and [test results](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-cibuildactions-_id_-testresults).

## App unit and UI execution

Use `xcrun simctl list devices available` to choose a simulator compatible with the active Xcode
and deployment target. Set `TEST_SIMULATOR_ID` to its UUID before these examples.

FastViT is an on-demand Apple test fixture, not a demo model. Run
`./scripts/fetch_apple_test_models.sh` before direct unit/UI test builds (or before testing in Xcode
with the custom build setting below). It verifies the archive and package hashes and reuses the
ignored `.apple-test-fixtures/` cache. `./scripts/unittest.sh` handles fetching and opt-in automatically;
Xcode Cloud fetches for `build-for-testing` and includes the fixture in its prebuilt test app.
Ordinary builds do not fetch or embed it. Missing/corrupt fixtures fail opted-in builds instead of
silently skipping real-model tests. Release builds reject opt-in.

Direct test commands:

```bash
xcodebuild test -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser \
  AIA_INCLUDE_TEST_FIXTURES=YES \
  -testPlan MLBrowserUnitTests \
  -destination "platform=iOS Simulator,id=${TEST_SIMULATOR_ID}" \
  -derivedDataPath "$PWD/.deriveddata"

xcodebuild test -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser \
  AIA_INCLUDE_TEST_FIXTURES=YES \
  -testPlan MLBrowserUITests \
  -destination "platform=iOS Simulator,id=${TEST_SIMULATOR_ID}" \
  -derivedDataPath "$PWD/.deriveddata"
```

For focused iteration, append one or more `-only-testing:TARGET/CLASS` arguments. For example,
`-only-testing:MLBrowserUnitTests/MapURLLocationInferenceTests` selects URL inference;
`MapLocationProbeTests` and `MapProbeInstallationTests` cover different browser boundaries.
These examples are not a complete impact map. Include affected resolver, arming, state, and UI
consumers as appropriate, and check the named tests actually executed.

Keep simulator code signing enabled: Keychain tests need the embedded entitlements. The unsigned
Harmonize and catalog-stability builds are not templates for running app tests. Do not assume a
simulator pass covers physical-device-only assertions.

Map integration uses bundled [MapHarness fixtures](../ios/MLBrowserUnitTests/Fixtures/MapHarness) resources, including real
Leaflet/OpenLayers harnesses. Resource-only changes can require these tests. A missing-fixture skip
is not evidence of working integration. Live-site tests are opt-in (`MAP_LIVE_TESTS`); follow
[MAP_LOCATION.md](MAP_LOCATION.md) for environment forwarding and network expectations.

For migration changes, run `FindingMigrationTests` with the current explicit mappings and inference
disabled. The [release baseline](../README.md#release-baseline) defines every supported shipped source;
1.0.8 shipped `0.0.2`, so both 0.0.0 → 0.0.2 and 0.0.1 → 0.0.2 must keep working; once a
schema change creates `0.0.3`, all three live sources need a mapping to it. Do not replace SQLite
migration evidence with an in-memory store or a successful Debug/TestFlight launch.

The committed ADAF checkpoint header/tail fixtures and their attribution notice are copied into
`MLBrowserUnitTests.xctest/ADAF`. `ImportedCheckpointAnalyserTests` reads that bundle, so prebuilt
simulator/device tests do not require the build machine's source checkout at runtime.

## Converter fixtures and parity

The root package includes always-on structural tests and fixture-gated integration tests. A bare
`swift test` can succeed while the latter skip. For the ONNX and Apple reference lane:

```bash
./scripts/fetch_native_test_models.sh
NATIVE_MODEL_ONNX_DIRECTORY="$PWD/.native-model-fixtures" ./scripts/test_native_model_converter.sh
```

The fetch caches and verifies ONNX fixtures. The test wrapper supplies Apple reference artifacts
through `NATIVE_MODEL_REFERENCE_DIRECTORY` and explicitly excludes `ADAFCheckpointDirectoryTests`,
which have a separate lane. Inspect the execution log for unexpected skips; the native-converter
CI lane enforces its no-skip expectation. The wrapper alone does not populate ONNX fixtures.

For changes affecting the published ADAF checkpoint path:

```bash
./scripts/fetch_adaf_checkpoints.sh
./scripts/test_adaf_checkpoints.sh
```

That wrapper requires the expected fixtures and named tests and fails on skips. The default sparse
download proves structural extraction, graph emission, compilation, and opening; it does not prove
numerical prediction parity. Always-on tests also use committed real checkpoint header/tail bytes.
Dense checkpoints (`fetch_adaf_checkpoints.sh --full`) and the configured Python environment are
needed for `bash scripts/test_adaf_fasterrcnn_parity.sh`. See
[NATIVE_MODEL_CONVERSION.md](NATIVE_MODEL_CONVERSION.md) for the applicable source-to-native,
Float16, intermediate-tensor, and device parity gates. Do not equate one model's result with all
architectures or all platforms.

Serialize builds that share SwiftPM artifact or DerivedData directories. A missing XCFramework
after concurrent builds is a build failure, not a test result.

## Backend, device, and external checks

The Worker local suite runs against its test environment for D1/R2 and authentication boundaries.
`npm run test:e2e` is separate: it needs the documented staging deployment, test credentials, and
fixtures and performs remote operations. Read the
[Worker README](../cloudflare/findings-worker/README.md) before using it; do not substitute production.

Physical-device converter/performance gates require the documented assets, environment, and
hardware. Their opt-ins include `NATIVE_MODEL_CONVERSION_DEVICE_BENCHMARK`,
`ADAF_CONVERSION_DEVICE_BENCHMARK`, and `ADAF_DETECTOR_DEVICE_BENCHMARK`; follow the test classes
and [converter reference](NATIVE_MODEL_CONVERSION.md) for build-time asset staging as well as
runtime settings. Record the actual device and executed tests. Human visual checks remain necessary for
layout, accessibility presentation, subscription screens, and other acceptance items that test
identifiers cannot prove. App Store metadata and release-service state need their own evidence.

## Trustworthy results and build reuse

- A successful process exit alone is insufficient. Verify the intended test identifiers executed,
  inspect failures/skips, and retain the relevant log or `.xcresult`. An empty `-only-testing`
  selection can look green. Ensure new files have target membership and XCTest can discover them;
  do not hide test methods in a `private extension`. In plain Xcode groups, membership includes
  `PBXBuildFile`, `PBXFileReference`, the group's children, and the target's Sources phase.
- `build-for-testing` followed by `test-without-building` is useful for repeated execution only
  after the build succeeded and the products match the current source, resources, dependencies,
  configuration, and destination. Rebuild when those inputs change; stale products prove nothing
  about the updated revision. Verify the installed app's build identity before handing it to a
  person for acceptance testing as well.
- Wait for the build/test process to exit and check its exit code. An empty Swift Testing summary
  does not mean XCTest ran zero tests, and an XCTest success banner does not override a later
  process failure. Inspect the framework-specific results and selected identifiers.
- Localization has separate evidence: Python catalog/parity checks, Swift catalog assertions in
  Harmonize, and Xcode's build-stability check. None alone proves translated meaning or visual fit.
- Keep compatible incremental products; follow [build cache troubleshooting](../ios/MLBrowser/README.md#build-caches)
  instead of deleting all caches after a ticket.

## Automation boundaries

The pre-commit hook lints staged Swift files. The pre-push hook invokes the catalog-stability build
for branch pushes. `deliver.sh` runs lint, localization, Harmonize, and the unit wrapper; it does not
establish UI or converter parity coverage. SwiftLint, Harmonize, and Native Model Converter run
on every PR into `develop` or `main`, without path filters; Localization also runs without path
filters. Other GitHub workflows retain their own triggers and gates; a skipped workflow is not
proof that all consumers were checked. Xcode Cloud workflow
configuration is partly external to the repository and must be inspected before changing claims
about its coverage or costs.

Until #850 introduces and validates a selector, preserve these gates and use the suite map to make
local verification relevant. Documentation-only changes need checks of links, commands, and
consistency, without launching app tests solely for prose.

### Merging without CI

The "Required Actions checks" ruleset (develop and main) requires Code Analysis, Architecture
Tests, Every string translated in every locale, and Native Model Converter Tests. It has no bypass
actors, so `gh pr merge --admin` is refused while those checks cannot run (for example, when Actions
billing is exhausted). With the user's approval for that merge:

1. Run each required check's local equivalent (SwiftLint, Harmonize, localization, and the converter
   suite when the diff reaches the root package) and record the results in the PR.
2. Resolve every review thread.
3. Disable the ruleset's enforcement, merge with `--admin`, and immediately re-enable it in the same
   command sequence, re-enabling even if the merge fails.
4. Confirm the ruleset reports `active` before continuing.

## Weighted-CRAP baseline

`./scripts/slopguard-baseline.sh` collects the AIA-0901 measurements. Commit tracked changes
before collection. `complexity` runs the pinned SlopGuard checkout with coverage disabled;
`collect-app`, `collect-converter`, and `collect-tools` gather coverage. Each successful command
records the source revision and artifact SHA-256 in a sidecar. `report` rejects absent, altered,
or mixed-revision exports, and uses the collection revision rather than the current HEAD.
Recollect old exports that lack sidecars; do not attest them retroactively. Set `SLOPGUARD_OUT`
to keep a new collection separate from historical artifacts.

`report` writes `build/slopguard/report/` by default, preserving the identities and original order
in [the frozen cohort](weighted-crap/cohort.csv). A missing or ambiguous function has a blank
score, including when it was previously ranked. Set `SLOPGUARD_REPORT_OUT` only when deliberately
publishing reviewed evidence. The September reconciliation input is committed as
[initial.csv](weighted-crap/initial.csv), so it does not depend on an ignored local file.

App totals include only `ML Browser.app`. LLVM totals omit generated runners, dependencies, and
test sources; nested unexecuted regions override their enclosing function's count. Same-line
functions with different names in one suite are ambiguous, not credited with whichever has the
highest coverage. The command needs the pinned SlopGuard checkout named in the summary, plus the
converter fixtures from `./scripts/fetch_native_test_models.sh`. Run
`python3 scripts/test_slopguard_baseline.py` for the attribution/provenance regressions; the unit
wrapper and Harmonize CI include these checks.

## Opt-in coverage pitfalls

The live-map harness hosts its web views in the test app window so map SDKs can finish rendering.
A finished navigation in an offscreen web view is not evidence that its map initialized. OpenLayers'
module-scoped example must return a labelled Web Mercator position; the harness does not require or
invent a latitude/longitude conversion. Its offline animation-frame test runs in the ordinary unit plan.

The `Stage Device Parity Assets` phase copies SDK-generated Core ML directory trees. Xcode cannot
represent unknown recursive script outputs, so `MLBrowserUnitTests` disables user-script sandboxing
for its sole script phase. App and other test targets retain their existing settings. The phase exits
on validation or copy errors, including benchmark fixture copies, so an explicitly supplied fixture directory cannot silently produce a skipped
test. Supply `AIA_DEVICE_PARITY_ASSETS` or `AIA_ADAF_CONVERSION_BENCHMARK_ASSETS` only for the corresponding
opt-in run; no models are downloaded or staged by this phase when both are unset.
