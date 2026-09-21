# Creating Child Issues for AIA-0901

The `gh` CLI in this environment has read-only access and cannot create issues via `gh issue create`. Child issues AIA-0902–0905 should be created manually using the specifications in [AIA-0901-CHILD-ISSUES.md](AIA-0901-CHILD-ISSUES.md).

## Quick-Create Commands (for environments with write access)

Once write access is available, use these commands to create the child issues:

### AIA-0902: Improve Coverage Attribution

```bash
gh issue create \
  --title "AIA-0902: Improve coverage attribution for wCRAP baseline" \
  --body-file <(cat <<'EOF'
**Parent issue:** #901

## Behavioral Goal

Ensure the weighted-CRAP baseline accurately reflects test coverage across all Swift code in the repository, including:
- NativeModelConverter framework (currently ~84% attributed, missing C++/ObjC++ bridge)
- ProjectTool CLI (separate test suite not in app's xcresult)
- Developer scripts with Swift components

## Current State

The September 2026 baseline (docs/code-quality/WCRAP-BASELINE-2026-09.md) reports 0% coverage for many converter methods because their Swift sources were not compiled into the test bundle analyzed. SlopGuard falls back to heuristic estimates for these methods.

## Success Criteria

1. **Converter coverage:** Include NativeModelConverterTests xcresult in analysis, or document which methods are legitimately untested vs. mis-attributed
2. **ProjectTool coverage:** Run ProjectTool tests separately and merge coverage data, or explicitly scope baseline to app-only code
3. **Fallback audit:** List all methods using fallback coverage; verify manually or add tests

## Verification Scope

- Re-run SlopGuard with merged xcresult bundles (if tooling supports it)
- Compare before/after wCRAP scores for converter methods with corrected coverage
- Document which components are intentionally out-of-scope
- Update WCRAP-BASELINE-2026-09.md with refined attribution notes

## Out of Scope

- Increasing test coverage (addressed in other child issues)
- Modifying SlopGuard's fallback algorithm

## References

- Baseline: [docs/code-quality/WCRAP-BASELINE-2026-09.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/WCRAP-BASELINE-2026-09.md)
- Child specs: [docs/code-quality/AIA-0901-CHILD-ISSUES.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/AIA-0901-CHILD-ISSUES.md)
EOF
)
```

### AIA-0903: Refactor User-Data and State-Management Hotspots

```bash
gh issue create \
  --title "AIA-0903: Refactor user-data and state-management hotspots" \
  --body-file <(cat <<'EOF'
**Parent issue:** #901

## Behavioral Goal

Reduce complexity in critical user-data paths while preserving data ownership, backup consent, and crash recovery.

## Target Hotspots

From the September 2026 baseline, the highest-risk methods in user-data and state management:

1. **`DataController.handleStoreLoadError`** (high wCRAP)
   - Handles Core Data store load failures, migration errors, and corruption
   - Must preserve: data-loss prevention, ownership checks, backup consent
   
2. **`FindingRepository.restore(from:replacing:)`** (high wCRAP)
   - Restores findings from backup, including ownership transfer
   - Must preserve: account ownership validation, per-finding consent, image file handling
   
3. **`Downloader.reconnectBackgroundSession()`** (high wCRAP)
   - Reconnects to background URLSession after app relaunch
   - Must preserve: download resumption, duplicate prevention, completion-handler registration

## Success Criteria

- **Behavioral:** All data-ownership checks from USER_DATA_PERSISTENCE.md pass
- **No data loss:** Existing unit tests for Core Data migration, backup restore, and session reconnection remain green
- **Reduced complexity:** Target methods drop below wCRAP threshold of 30 (or document why not)

## Verification Scope

1. **Unit tests:**
   - DataControllerTests (store load failure scenarios)
   - FindingRepositoryTests (backup restore, ownership validation)
   - DownloaderTests (session reconnection, duplicate downloads)

2. **Manual verification:**
   - Force Core Data migration with dev builds
   - Restore backup with different account signed in (must reject)
   - Background download interrupted by app termination (must resume)

3. **Architecture tests:**
   - Run scripts/test-architecture.sh to verify ownership checks are not bypassed

## Out of Scope

- Changing backup file format (separate issue)
- Rewriting entire DataController (too large; extract smaller pieces)

## References

- Baseline: [docs/code-quality/WCRAP-BASELINE-2026-09.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/WCRAP-BASELINE-2026-09.md)
- Child specs: [docs/code-quality/AIA-0901-CHILD-ISSUES.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/AIA-0901-CHILD-ISSUES.md)
- User data rules: [specification/USER_DATA_PERSISTENCE.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/specification/USER_DATA_PERSISTENCE.md)
EOF
)
```

### AIA-0904: Simplify Large SwiftUI View Bodies

```bash
gh issue create \
  --title "AIA-0904: Simplify large SwiftUI view bodies" \
  --body-file <(cat <<'EOF'
**Parent issue:** #901

## Behavioral Goal

Extract stateful logic from large SwiftUI `body` computed properties into testable components, preserving UI behavior and accessibility.

## Context

SwiftUI view bodies naturally accumulate high cyclomatic complexity from conditional view logic (`if`, `switch`, optional chaining). High wCRAP scores often reflect UI state complexity rather than untestable business logic.

## Target Views

From the September 2026 baseline, SwiftUI views with body wCRAP > 50:

- `PaywallView.body` (mentioned in issue #901)
- Additional large views identified in SlopGuard output (TBD after full analysis)

## Success Criteria

- **Extract logic, not views:** Move stateful business logic into `@StateObject` ViewModels or property wrappers
- **Preserve behavior:** UI tests pass; no visual regressions
- **Testable state:** ViewModel logic covered by unit tests (not just UI tests)
- **Accessibility preserved:** VoiceOver labels, button actions, and focus order unchanged

## Verification Scope

1. **UI tests:**
   - Run scripts/test-ui.sh for affected screens
   - VoiceOver audit (manual or snapshot tests)

2. **ViewModel unit tests:**
   - Add tests for extracted state logic (subscriptions, validation, async workflows)

3. **Visual regression:**
   - Manual review of affected screens in light/dark mode, Dynamic Type sizes

## Out of Scope

- Mechanically splitting `body` into smaller `@ViewBuilder` fragments (does not improve testability)
- Rewriting entire view hierarchies (incremental extraction only)

## References

- Baseline: [docs/code-quality/WCRAP-BASELINE-2026-09.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/WCRAP-BASELINE-2026-09.md)
- Child specs: [docs/code-quality/AIA-0901-CHILD-ISSUES.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/AIA-0901-CHILD-ISSUES.md)
EOF
)
```

### AIA-0905: Improve Converter and Tooling Test Coverage

```bash
gh issue create \
  --title "AIA-0905: Improve converter and tooling test coverage" \
  --body-file <(cat <<'EOF'
**Parent issue:** #901

## Behavioral Goal

Increase test coverage for `NativeModelConverter` and `ProjectTool` to reduce wCRAP scores without changing conversion behavior.

## Current State

- **Converter coverage:** 0% reported due to mis-attribution (see AIA-0902), but actual coverage unknown
- **ProjectTool coverage:** Separate test suite exists but not merged into baseline

## Target Components

1. **NativeModelConverter:**
   - ONNX graph parsing and validation
   - Core ML pipeline synthesis (YOLOv8 box decode, NMS)
   - Metadata propagation (attribution, license, author)

2. **ProjectTool:**
   - Secrets management (create, rotate, validate)
   - Pinned-tool installation (SwiftLint, SwiftGen, Sentry CLI)
   - Git hook setup

## Success Criteria

- **Converter:** Add tests for uncovered ONNX operators, error diagnostics, and edge cases
- **ProjectTool:** Increase coverage of secrets and tool-installation paths
- **wCRAP reduction:** Target methods drop below 30, or document which complexity is inherent

## Verification Scope

1. **Converter tests:**
   - Run `swift test --package-path . --filter NativeModelConverterTests` with coverage
   - Verify converted models match expected Core ML structure (existing fixtures)

2. **ProjectTool tests:**
   - Run `swift test --package-path Tools/ProjectTool` with coverage
   - Test secrets creation/rotation in isolated test environment

3. **Behavioral preservation:**
   - All existing converter fixtures must produce identical Core ML output
   - ProjectTool must install pinned tools at correct versions

## Out of Scope

- Rewriting converter algorithm (too risky; preserve numerical behavior)
- Adding coverage for intentionally untested error paths (e.g., malloc failure)

## References

- Baseline: [docs/code-quality/WCRAP-BASELINE-2026-09.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/WCRAP-BASELINE-2026-09.md)
- Child specs: [docs/code-quality/AIA-0901-CHILD-ISSUES.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/docs/code-quality/AIA-0901-CHILD-ISSUES.md)
- Converter docs: [NATIVE_MODEL_CONVERSION.md](https://github.com/aiarcheology-com/aiarcheology/blob/develop/specification/NATIVE_MODEL_CONVERSION.md)
EOF
)
```

## Manual Creation via GitHub Web UI

Alternatively, create issues manually at https://github.com/aiarcheology-com/aiarcheology/issues/new using the issue bodies from [AIA-0901-CHILD-ISSUES.md](AIA-0901-CHILD-ISSUES.md).

## After Creation

Once child issues are created, add a comment to [#901](https://github.com/aiarcheology-com/aiarcheology/issues/901) listing the child issue numbers and links.
