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
| ProjectTool | `swift test --package-path Tools` |
| Credential-delivery shell logic | `./scripts/test_deliver_credentials.sh` uses its hermetic test harness. |
| Architecture and source/resource invariants | `./scripts/harmonize.sh` uses the macOS `MLBrowserArchitectureTests` scheme and `MLBrowserUnitTestsHarmonize` plan. It reads repository files from disk. |
| Localization parity and catalog validation | `./scripts/localization.sh` runs Python strict parity and checks both catalogs. This also runs in GitHub CI; it is not merely an optional editor helper. |
| Xcode catalog stability | `./scripts/check_localization_build.sh` builds and checks that both catalogs remain unchanged. This is separate from semantic validation and does not execute app tests. |
| Swift style | `./scripts/swiftlint.sh` lints `ios/`. For a file, pass an absolute path after `lint`, since the wrapper changes directory. Preserve required hook/CI scope. |
| Catalog/ONNX manifest consistency | `./scripts/verify_catalog_onnx_sync.sh`; relevant to catalog entries and converter fixture manifests. |
| Findings Worker | In `cloudflare/findings-worker`, `npm run typecheck` and `npm test` cover types and the local Worker test environment. Staging E2E is a separate command and provisioning step. |

Consult test plans and target membership for the current execution scope; do not infer scope from a
folder name. Shared formats, persistence, app composition, dependency changes, and build settings
often affect several rows. If the consumer set is unclear, broaden coverage.

## App unit and UI execution

Use `xcrun simctl list devices available` to choose a simulator compatible with the active Xcode
and deployment target. Set `TEST_SIMULATOR_ID` to its UUID before these examples:

```bash
xcodebuild test -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser \
  -testPlan MLBrowserUnitTests \
  -destination "platform=iOS Simulator,id=${TEST_SIMULATOR_ID}" \
  -derivedDataPath "$PWD/.deriveddata"

xcodebuild test -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser \
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
establish UI or converter parity coverage. Existing GitHub workflows have separate path filters
and gates; a skipped workflow is not proof that all consumers were checked. Xcode Cloud workflow
configuration is partly external to the repository and must be inspected before changing claims
about its coverage or costs.

Until #850 introduces and validates a selector, preserve these gates and use the suite map to make
local verification relevant. Documentation-only changes need checks of links, commands, and
consistency, without launching app tests solely for prose.
