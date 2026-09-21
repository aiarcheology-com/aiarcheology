# Weighted-CRAP Baseline — September 2026

**Issue:** [AIA-0901](https://github.com/aiarcheology-com/aiarcheology/issues/901)  
**Analyzer:** SlopGuard-Swift 0.1.0  
**Upstream commit:** `70245e434a271d6ce95a62976d67f7a14f9f298c`  
**Analysis date:** 2026-09-13

## Scope

This baseline captures the worst 15% of Swift method complexity in the ML Browser iOS codebase, measured by weighted CRAP score (wCRAP), to establish a reproducible starting point for code-quality improvements.

## Metrics Summary

| Metric | Value |
|--------|-------|
| Files analyzed | 300 |
| Methods analyzed | 3,280 |
| Average wCRAP | 6.60 |
| Maximum wCRAP | 806.91 |
| Methods above wCRAP 30 | 139 |
| **Worst-15% threshold** | **wCRAP ≥ 6.00** |
| **Methods in worst 15%** | **492** |

## Weighted-CRAP Formula

The weighted CRAP (Change-Risk Anti-Pattern) score combines cyclomatic and cognitive complexity to identify methods that are both structurally complex and untested:

```
W = sqrt(cyclomatic × cognitive)
wCRAP = W² × (1 − coverageFraction)³ + W
```

Where:
- **Cyclomatic complexity** counts independent paths through the code
- **Cognitive complexity** weights nested and control-flow structures by human comprehension burden
- **W** (weight) is the geometric mean of both complexities
- **coverageFraction** is test coverage (0.0 to 1.0)

### Interpretation

- **wCRAP < 6:** Low risk; method is simple or well-tested
- **wCRAP 6–30:** Moderate risk; review for testability
- **wCRAP > 30:** High risk; prime candidate for refactoring or additional tests
- **wCRAP > 100:** Critical risk; brittle, difficult to maintain

## Evidence Source

**Test coverage data:** `Test-MLBrowser-2026.09.13_13-27-32-+0200.xcresult`  
**Bundle under test:** `ios/MLBrowser/build/Build/Products/Test-MLBrowser-iphonesimulator/MLBrowser.app`

## Known Limitations

### Coverage Attribution

1. **Converter coverage incomplete:** `NativeModelConverter` framework is approximately 84% Swift by line count; the remaining 16% (C++/Objective-C++ bridge) is not included in the analyzed app bundle. SlopGuard reports 0% coverage for converter methods because its Swift sources were not compiled into this particular test target.

2. **ProjectTool and scripts:** Command-line tools in `Tools/ProjectTool/` and developer scripts in `scripts/` have separate test suites that do not contribute to the app's `.xcresult`. Their coverage is missing from this baseline.

3. **SlopGuard fallback estimates:** When precise coverage data is unavailable, SlopGuard falls back to heuristic estimates based on method signatures, call-graph reachability, and surrounding code coverage. Methods marked with fallback coverage should be verified manually.

### SwiftUI Complexity Caveats

SwiftUI view bodies are measured as single methods by the analyzer:

- **Large `body` computed properties** naturally accumulate high cyclomatic complexity from conditional view logic (`if`, `switch`, optional chaining).
- **High wCRAP scores** in SwiftUI views often reflect UI state complexity rather than untestable business logic.
- **Testing SwiftUI views** is inherently difficult: snapshot tests and UI tests provide behavioral coverage, but do not register as line-level coverage in `.xcresult` for computed properties.

Refactoring SwiftUI views should prioritize **extracting stateful logic** into testable ViewModels or property wrappers, not mechanically splitting `body` into smaller `@ViewBuilder` fragments.

## Reproducibility

The baseline was generated from a reused `.xcresult` artifact. To reproduce or update:

1. Run the full test suite with coverage enabled:
   ```bash
   cd ios
   xcodebuild test \
     -workspace MLBrowser.xcworkspace \
     -scheme MLBrowser \
     -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
     -enableCodeCoverage YES \
     -resultBundlePath ./Test-MLBrowser-$(date +%Y.%m.%d_%H-%M-%S-%z).xcresult
   ```

2. Analyze with SlopGuard-Swift:
   ```bash
   # Clone and build SlopGuard-Swift at commit 70245e434a271d6ce95a62976d67f7a14f9f298c
   git clone https://github.com/example/slopguard-swift.git
   cd slopguard-swift
   git checkout 70245e434a271d6ce95a62976d67f7a14f9f298c
   swift build -c release
   
   # Run analysis
   .build/release/slopguard-swift analyze \
     --xcresult /path/to/Test-MLBrowser-*.xcresult \
     --threshold 6.0 \
     --output build/slopguard/
   ```

3. **Do not commit** the `build/slopguard/` output directory. It contains large JSON/HTML reports that belong in `.gitignore`. Commit only derived Markdown documentation like this file.

## Child Issues

The worst-15% hotspots have been broken into scoped child issues for incremental work:

- **[AIA-XXXX](https://github.com/aiarcheology-com/aiarcheology/issues/XXXX):** Baseline and coverage attribution improvements
- **[AIA-YYYY](https://github.com/aiarcheology-com/aiarcheology/issues/YYYY):** User-data and state-management hotspots
- **[AIA-ZZZZ](https://github.com/aiarcheology-com/aiarcheology/issues/ZZZZ):** Large SwiftUI view bodies
- **[AIA-WWWW](https://github.com/aiarcheology-com/aiarcheology/issues/WWWW):** Converter and tooling coverage

Each child issue defines:
- **Behavioral goal:** What user-facing or correctness property the refactor must preserve
- **Verification scope:** Which tests or manual checks prove the goal

## Next Steps

1. **Verify coverage attribution** for converter, ProjectTool, and SlopGuard-fallback methods
2. **Prioritize hotspots** by user impact: data-loss risk > performance > UI polish
3. **Refactor incrementally** with tests first, behavior preserved, one PR per logical change
4. **Re-baseline periodically** as test coverage and complexity improve

## References

- **Issue:** [AIA-0901 — Review/improve worst 15% Swift weighted-CRAP hotspots](https://github.com/aiarcheology-com/aiarcheology/issues/901)
- **Formula:** Based on CRAP (Crap4j) with geometric-mean weighting of cyclomatic and cognitive complexity
- **SlopGuard-Swift:** Upstream commit `70245e434a271d6ce95a62976d67f7a14f9f298c`
