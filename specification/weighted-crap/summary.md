# Weighted-CRAP baseline

Analyzer: slopguard-swift 0.1.0 at `70245e434a271d6ce95a62976d67f7a14f9f298c`.
Source revision: `392312f7b2a6c73dd20a15cc7915e1f63bc08742`.
Collect on a clean revision, then run `./scripts/slopguard-baseline.sh report`; output goes to `build/slopguard/report/` and keeps this cohort's identities.

PR #950 review correction: these are the original pre-refactor exports, reprocessed with corrected region, target, path, and ambiguity handling. Cohort membership and original rank order are unchanged. The legacy exports predate collection attestations; the source revision and test-run descriptions below are the original collector’s attribution, not a new source attestation or validation of the refactored code. New collections require revision/hash sidecars.

## Collection

- app: 2463 passed, 0 failed, 8 skipped. MLBrowserUnitTests on an iPhone 18 Pro iOS 27.0 simulator with code coverage enabled. The skips are opt-in physical-device parity and live-map tests.
- converter: 556 passed, 0 failed, 0 skipped. Root swift test with ONNX fixtures, Apple MobileNet reference models, and code coverage. ADAFCheckpointDirectoryTests were excluded with --skip, so they are not in the skip count.
- tools: 23 passed, 0 failed, 0 skipped. swift test --package-path Tools with code coverage. The tested product is ProjectToolCore.

## How a method is scored

Weighted CRAP uses `W = sqrt(cyclomatic × cognitive)` and `W² × (1 − coverage)³ + W`. Coverage is a percentage from a function whose first line lies inside the method span. The closest such function wins. File-level fallback, a missing file, and an ambiguous path or closure match do not receive a score. Zero cognitive complexity scores 0.

Suites combine by the highest function coverage percent, not a line-level union. The app figure counts the application product only. Converter and tool figures omit test sources. SwiftUI getters measured here are unit-suite coverage, not a UI journey.

The converter suite is the root package test with ONNX fixtures and the Apple reference models. `ADAFCheckpointDirectoryTests` is not part of that command. The tool suite is `swift test --package-path Tools`, which builds `ProjectToolCoreTests`.

Programs that are not linked into those tested products — CLI mains under `Sources/*CLI*` / parity runners, the `ProjectTool` executable (not `ProjectToolCore`), and `scripts/` — are classified `excluded` with an explicit reason. They are not scored as coverage 0%, do not enter the cohort as measured-zero hotspots, and appear in reconciliation as `excluded` rather than `unmeasured` or a silent drop.

## Production coverage

- app: 45.72% (23283 / 50920 executable lines, production files only)
- converter: 83.97% (10150 / 12088 executable lines, production files only)
- tools: 92.41% (268 / 290 executable lines, production files only)

## Scored population

- Analyzed methods: 3268
- Function-matched methods: 3033
- Provenance counts: {"ambiguous": 25, "excluded": 83, "file-fallback": 105, "function-match": 2184, "measured-zero": 849, "missing": 22}
- Median / p90 / p95 / max: 0 / 7.402653 / 13.482297 / 567.323808
- Methods above 7: 332
- Methods above 30: 69
- Scored methods with zero cognitive complexity: 1712 (their weighted CRAP is 0, which pulls the median down)

Missing, ambiguous, and file-fallback methods stay in the provenance counts. They are not folded into the median or the threshold counts.

## Frozen cohort

Frozen identities and original rank order (490) are retained from the published worst-15% cohort. Scores reflect the current joiner; unmeasured members have blank scores. No replacement members are selected.

Triage of that cohort: {"acceptable": 420, "actionable": 69, "measurement": 1}.
Actionable clusters: {"background-download-reconnect": 2, "converter-emission": 3, "converter-other": 3, "crash-reporting": 2, "debug-launch-helpers": 3, "detection": 2, "finding-restore": 2, "map-location-probe": 1, "persistence-store-recovery": 1, "storekit-purchase": 1, "swiftui-findings": 11, "swiftui-import-and-catalog": 15, "swiftui-other": 15, "swiftui-settings": 4, "swiftui-subscription": 4}.

## Reconciliation with the 2026-09-13 list

The September 13 list scored absent coverage as 0% and reused one app-test bundle. Identity match is file plus qualified name. Status counts: {"entered": 115, "excluded": 31, "left-cohort": 80, "removed": 5, "stayed": 374, "unmeasured": 2}.

`stayed` is still in the frozen cohort. `left-cohort` is function-matched and now outside it. `excluded` is an explicit non-product coverage gap with a reason. `unmeasured` has no function match and is not excluded, so it is not given a fake zero. `entered` is new to the cohort. `removed` is no longer in the complexity report.

