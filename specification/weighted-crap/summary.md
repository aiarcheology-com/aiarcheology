# Weighted-CRAP baseline

Analyzer: slopguard-swift 0.1.0 at `70245e434a271d6ce95a62976d67f7a14f9f298c`.
Source revision: `37f3972d55df2b66673634d9bee8331aa524cff7`.
Regenerate with `./scripts/slopguard-baseline.sh report`.

## Collection

- app: 2463 passed, 0 failed, 8 skipped. MLBrowserUnitTests on an iPhone 18 Pro iOS 27.0 simulator with code coverage enabled. The skips are opt-in physical-device parity and live-map tests.
- converter: 556 passed, 0 failed, 0 skipped. Root swift test with ONNX fixtures, Apple MobileNet reference models, and code coverage. ADAFCheckpointDirectoryTests were excluded with --skip, so they are not in the skip count.
- tools: 23 passed, 0 failed, 0 skipped. swift test --package-path Tools with code coverage. The tested product is ProjectToolCore.

## How a method is scored

Weighted CRAP uses `W = sqrt(cyclomatic × cognitive)` and `W² × (1 − coverage)³ + W`. Coverage is a percentage from a function whose first line lies inside the method span. The closest such function wins. File-level fallback, a missing file, and an ambiguous path or closure match do not receive a score. Zero cognitive complexity scores 0.

Suites combine by the highest function coverage percent, not a line-level union. The app figure counts the application product only. Converter and tool figures omit test sources. SwiftUI getters measured here are unit-suite coverage, not a UI journey.

The converter suite is the root package test with ONNX fixtures and the Apple reference models. `ADAFCheckpointDirectoryTests` is not part of that command. The tool suite is `swift test --package-path Tools`, which builds `ProjectToolCoreTests`. Sources that exist only in the `ProjectTool` executable, including tool installation, are absent from that product and stay unmeasured.

## Production coverage

- app: 33.44% (25295 / 75648 executable lines, production files only)
- converter: 83.92% (10198 / 12152 executable lines, production files only)
- tools: 89.31% (284 / 318 executable lines, production files only)

## Scored population

- Analyzed methods: 3268
- Function-matched methods: 3058
- Provenance counts: {"file-fallback": 105, "function-match": 2210, "measured-zero": 848, "missing": 105}
- Median / p90 / p95 / max: 0 / 7.34538 / 13.162278 / 567.323808
- Methods above 7: 329
- Methods above 30: 68
- Scored methods with zero cognitive complexity: 1725 (their weighted CRAP is 0, which pulls the median down)

Missing, ambiguous, and file-fallback methods stay in the provenance counts. They are not folded into the median or the threshold counts.

## Frozen cohort

Worst 15% of analyzed methods (490), taken only from function-matched scores. Cutoff: 4.732051. Ties break by file, line, and qualified name. Identities are in `cohort.csv`.

Triage of that cohort: {"acceptable": 422, "actionable": 68}.
Actionable clusters: {"background-download-reconnect": 2, "converter-emission": 3, "converter-other": 2, "crash-reporting": 2, "debug-launch-helpers": 3, "detection": 2, "finding-restore": 2, "map-location-probe": 1, "persistence-store-recovery": 1, "storekit-purchase": 1, "swiftui-findings": 11, "swiftui-import-and-catalog": 15, "swiftui-other": 15, "swiftui-settings": 4, "swiftui-subscription": 4}.

## Reconciliation with the 2026-09-13 list

The September 13 list scored absent coverage as 0% and reused one app-test bundle. Identity match is file plus qualified name. Status counts: {"entered": 115, "left-cohort": 81, "removed": 5, "stayed": 374, "unmeasured": 32}.

`stayed` is still in the frozen cohort. `left-cohort` is function-matched and now outside it. `unmeasured` has no function match, so it is not given a fake zero. `entered` is new to the cohort. `removed` is no longer in the complexity report.

