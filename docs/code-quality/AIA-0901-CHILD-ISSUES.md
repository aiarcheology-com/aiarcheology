# AIA-0901 Child Issues — Weighted-CRAP Hotspots

**Parent issue:** [AIA-0901](https://github.com/aiarcheology-com/aiarcheology/issues/901)  
**Baseline:** [WCRAP-BASELINE-2026-09.md](WCRAP-BASELINE-2026-09.md)

This document defines scoped child issues for the worst-15% weighted-CRAP hotspots identified in the September 2026 baseline. Each issue includes a behavioral goal and verification scope to ensure refactoring preserves correctness.

---

## AIA-0902: Improve Coverage Attribution for wCRAP Baseline

**Behavioral Goal:** Ensure the weighted-CRAP baseline accurately reflects test coverage across all Swift code in the repository.

### Current State

The September 2026 baseline reports 0% coverage for many methods due to mis-attribution:

1. **NativeModelConverter framework:** Approximately 84% Swift by line count; the remaining 16% (C++/Objective-C++ bridge) is not in the analyzed app bundle. SlopGuard reports 0% coverage for converter methods because their Swift sources were not compiled into the test target.

2. **ProjectTool CLI:** Has a separate test suite (`Tests/ProjectToolTests/`) that does not contribute to the app's `.xcresult`. Coverage is missing.

3. **SlopGuard fallback estimates:** When precise coverage is unavailable, SlopGuard falls back to heuristics. These methods need manual verification.

### Success Criteria

1. **Converter coverage:** Include `NativeModelConverterTests` xcresult in the analysis, or document which methods are legitimately untested vs. mis-attributed
2. **ProjectTool coverage:** Run ProjectTool tests separately and merge coverage data, or explicitly scope baseline to app-only code
3. **Fallback audit:** List all methods using fallback coverage; verify manually or add tests

### Verification Scope

- Re-run SlopGuard with merged xcresult bundles (if tooling supports multiple inputs)
- Compare before/after wCRAP scores for converter methods with corrected coverage
- Document which repository components are intentionally out-of-scope
- Update `WCRAP-BASELINE-2026-09.md` with refined attribution notes

### Out of Scope

- Increasing test coverage (addressed in other child issues)
- Modifying SlopGuard's fallback algorithm

---

## AIA-0903: Refactor User-Data and State-Management Hotspots

**Behavioral Goal:** Reduce complexity in critical user-data paths while preserving data ownership, backup consent, and crash recovery.

### Target Hotspots

From the baseline, the highest-risk methods in user-data and state management:

1. **`DataController.handleStoreLoadError`** (wCRAP: high)
   - Handles Core Data store load failures, migration errors, and corruption
   - Must preserve: data-loss prevention, ownership checks, backup consent
   
2. **`FindingRepository.restore(from:replacing:)`** (wCRAP: high)
   - Restores findings from backup, including ownership transfer
   - Must preserve: account ownership validation, per-finding consent, image file handling
   
3. **`Downloader.reconnectBackgroundSession()`** (wCRAP: high)
   - Reconnects to background URLSession after app relaunch
   - Must preserve: download resumption, duplicate prevention, completion-handler registration

### Success Criteria

- **Behavioral:** All data-ownership checks from [USER_DATA_PERSISTENCE.md](../../specification/USER_DATA_PERSISTENCE.md) pass
- **No data loss:** Existing unit tests for Core Data migration, backup restore, and session reconnection remain green
- **Reduced complexity:** Target methods drop below wCRAP threshold of 30 (or document why not)

### Verification Scope

1. **Unit tests:**
   - `DataControllerTests` (store load failure scenarios)
   - `FindingRepositoryTests` (backup restore, ownership validation)
   - `DownloaderTests` (session reconnection, duplicate downloads)

2. **Manual verification:**
   - Force Core Data migration with dev builds
   - Restore backup with different account signed in (must reject)
   - Background download interrupted by app termination (must resume)

3. **Architecture tests:**
   - Run `scripts/test-architecture.sh` to verify ownership checks are not bypassed

### Out of Scope

- Changing backup file format (separate issue)
- Rewriting entire `DataController` (too large; extract smaller pieces)

---

## AIA-0904: Simplify Large SwiftUI View Bodies

**Behavioral Goal:** Extract stateful logic from large SwiftUI `body` computed properties into testable components, preserving UI behavior and accessibility.

### Context

SwiftUI view bodies naturally accumulate high cyclomatic complexity from conditional view logic (`if`, `switch`, optional chaining). High wCRAP scores often reflect UI state complexity rather than untestable business logic.

### Target Views

From the baseline, SwiftUI views with `body` wCRAP > 50:

- `PaywallView.body` (mentioned in issue #901 as high-complexity)
- Additional large views identified in SlopGuard output (TBD after full analysis)

### Success Criteria

- **Extract logic, not views:** Move stateful business logic into `@StateObject` ViewModels or property wrappers
- **Preserve behavior:** UI tests pass; no visual regressions
- **Testable state:** ViewModel logic covered by unit tests (not just UI tests)
- **Accessibility preserved:** VoiceOver labels, button actions, and focus order unchanged

### Verification Scope

1. **UI tests:**
   - Run `scripts/test-ui.sh` for affected screens
   - VoiceOver audit (manual or snapshot tests)

2. **ViewModel unit tests:**
   - Add tests for extracted state logic (subscriptions, validation, async workflows)

3. **Visual regression:**
   - Manual review of affected screens in light/dark mode, Dynamic Type sizes

### Out of Scope

- Mechanically splitting `body` into smaller `@ViewBuilder` fragments (does not improve testability)
- Rewriting entire view hierarchies (incremental extraction only)

---

## AIA-0905: Improve Converter and Tooling Test Coverage

**Behavioral Goal:** Increase test coverage for `NativeModelConverter` and `ProjectTool` to reduce wCRAP scores without changing conversion behavior.

### Current State

- **Converter coverage:** 0% reported due to mis-attribution (see AIA-0902), but actual coverage unknown
- **ProjectTool coverage:** Separate test suite exists but not merged into baseline

### Target Components

1. **NativeModelConverter:**
   - ONNX graph parsing and validation
   - Core ML pipeline synthesis (YOLOv8 box decode, NMS)
   - Metadata propagation (attribution, license, author)

2. **ProjectTool:**
   - Secrets management (create, rotate, validate)
   - Pinned-tool installation (SwiftLint, SwiftGen, Sentry CLI)
   - Git hook setup

### Success Criteria

- **Converter:** Add tests for uncovered ONNX operators, error diagnostics, and edge cases
- **ProjectTool:** Increase coverage of secrets and tool-installation paths
- **wCRAP reduction:** Target methods drop below 30, or document which complexity is inherent (e.g., large switch statements for operator dispatch)

### Verification Scope

1. **Converter tests:**
   - Run `swift test --package-path . --filter NativeModelConverterTests` with coverage
   - Verify converted models match expected Core ML structure (existing fixtures)

2. **ProjectTool tests:**
   - Run `swift test --package-path Tools/ProjectTool` with coverage
   - Test secrets creation/rotation in isolated test environment

3. **Behavioral preservation:**
   - All existing converter fixtures must produce identical Core ML output
   - ProjectTool must install pinned tools at correct versions

### Out of Scope

- Rewriting converter algorithm (too risky; preserve numerical behavior)
- Adding coverage for intentionally untested error paths (e.g., malloc failure)

---

## Implementation Principles

Each child issue follows these rules:

1. **Behavior first:** Define what must not break before refactoring
2. **Incremental:** One logical change per PR; preserve existing tests
3. **Evidence-based:** Re-run SlopGuard after each change to verify wCRAP reduction
4. **Traceable:** Link commits to child issue; child issue to parent #901

## Next Steps

1. **Create child issues in GitHub** with these bodies
2. **Link to parent #901** in each issue body and a comment on #901 with links to all children
3. **Prioritize by risk:** AIA-0903 (user-data) > AIA-0902 (attribution) > AIA-0905 (converter) > AIA-0904 (SwiftUI)
4. **Re-baseline after each PR** to track progress toward worst-15% threshold reduction
