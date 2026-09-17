# iOS / MLBrowser guidance

Read the [repository guidance](../AGENTS.md) as well. Commands run from the repository root.
Section numbers are retained for existing source/document references; detailed workflows live in
linked references rather than in this instruction file.

## 1. Working scope

Preserve the existing architecture and unrelated work. Resolve routine choices within the requested
scope. Prefer a focused behavior fix; do not add adjacent cleanup to satisfy a style preference.

## 2. Relevant documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): composition root, app entry/gating, detection, and persistence.
- [TESTING.md](../specification/TESTING.md): suite selection, commands, fixtures, and result interpretation.
- [MLBrowser/README.md](MLBrowser/README.md): setup, pinned tools, secrets, and cache troubleshooting.
- Read [MAP_LOCATION.md](../specification/MAP_LOCATION.md), [USER_DATA_PERSISTENCE.md](../specification/USER_DATA_PERSISTENCE.md),
  [AUTH-SUBSCRIPTION.md](../specification/AUTH-SUBSCRIPTION.md), [FEATUREFLAGS.md](../specification/FEATUREFLAGS.md),
  [USERMESSAGING.md](../specification/USERMESSAGING.md), or [LOGGING_GUIDE.md](../specification/LOGGING_GUIDE.md) when touching
  that domain. A domain-specific `ARCHITECTURE.md` is additional context for its code.

## 3. Architecture and state

- Views render state and send intents; state objects own app/view behavior. Services own work at
  explicit boundaries. Use protocols for major boundaries or expensive/uncontrollable dependencies
  when they add testing value; avoid abstractions that merely rename one implementation.
- `DependencyContainer` is the single composition root. Add shared services there and inject them
  through `makeAppState()`. `AppState` receives dependencies; it never accesses
  `DependencyContainer.shared`. Views use injected state/environment values. Only bootstrap sites
  such as app entry and the background-session app delegate may access the composition singleton.
- Use `Environment`/`EnvironmentObject` for UI-scoped dependencies. Re-inject required custom
  environment values on sheets on Mac (Designed for iPad); do not assume they cross that boundary.
- `CoreDataManageable` is the default entity CRUD/fetch/count API. `CoreDataManagableWithState`
  adds the lifecycle state machine; use it only for genuine draft/import workflows. Preserve the
  distinction; do not migrate adjacent entities as cleanup.
- Assess whether a feature needs an independent rollout, recovery, or user-control decision before
  adding a flag. Reuse a flag only when its semantics and lifecycle match. Keep flags few and retire
  obsolete ones after rollout; feature size alone does not require a flag.
- Flag keys/defaults are declared in `FeatureFlagKey`; use literal `rawValue` keys and published
  snapshots. Provision a remote key before shipping its reader. Choose and test each fallback;
  do not assume all flags fail open. Never block launch on remote config.
- Decide live versus launch-captured behavior explicitly. Root gating such as `isPaymentsEnabled`
  uses `LaunchCapturedFlags` through the composition root, not an early live snapshot. See
  [FEATUREFLAGS.md](../specification/FEATUREFLAGS.md) for observation behavior and verification.
- New views should have lightweight previews for representative states without real network/stores.

## 4. Concurrency and threading

- Prefer `async/await`; make actor isolation explicit. UI state updates belong on `@MainActor`.
- Do not add a `Task { @MainActor in ... }` hop to an already-isolated synchronous mutation: it
  changes ordering. Define task cancellation and ownership.
- Keep Vision, image decoding, file IO, and heavy parsing off the main thread. Check context/run
  identity across awaits when results can outlive navigation, account changes, or detection sessions.

## 5. Logging and errors

- Follow [LOGGING_GUIDE.md](../specification/LOGGING_GUIDE.md) and use existing logging helpers/categories.
- Handle recoverable errors explicitly. Use the project's assertion/critical-failure policy for
  invariants; do not swallow errors or turn expected external failures into crashes.
- Keep account identifiers, full URLs, precise locations, images, and other private data out of
  telemetry/diagnostic messages as required by the logging/privacy policy.

## 6. Testing and persistence

- Prefer real objects with isolated dependencies. Use fakes for expensive/uncontrollable resources;
  avoid subclassing deprecated system classes when a minimal protocol seam works.
- Group tests by component/domain and name behavior/scenario/result clearly. Keep platform
  integration tests for Keychain, Core Data, WebKit, Vision, and other Apple-specific behavior.
- The testable app module is `ML_Browser`. New Swift files in plain Xcode groups need explicit
  target membership. Check discovery/execution, not just a successful `-only-testing` exit.
- Actor-isolated tests use async `setUp()`/`tearDown()`; do not capture mutable variables across
  concurrent closures. Prefer controlled continuations, clocks, and expectations over sleeps.
- Use in-memory Core Data for ordinary isolated tests, and SQLite for batch operations/migration.
  Prefer entity factories such as `.create(in:)` when multiple test stacks coexist.
- **Released Core Data models are immutable.** Add a new version when evolving a shipped schema.
  An unreleased destination with no mappings may be edited in place; once mappings exist, treat its
  schema and mapping artifacts as one unit. An intentional edit requires regenerating every affected
  mapping and verifying every supported shipped-source-to-current upgrade with inference disabled.
- Generate mappings with Xcode; never hand-write archived model hashes. Core Data does not
  automatically chain these mappings. Supported versions/paths live in the
  [README release baseline](../README.md#release-baseline). Debug/TestFlight recovery does not prove
  a shipping migration works and must not justify resetting user data.
- Select a destination supported by the active Xcode, deployment target, and test requirements.
  Keep simulator signing for Keychain entitlements. Physical-device tests need physical-device
  evidence; a simulator skip is not a pass. See [TESTING.md](../specification/TESTING.md).

## 7. Harmonize

Run `./scripts/harmonize.sh` for architecture changes or changes to inputs its rules inspect. The
dedicated macOS target reads source/resources from disk; it is not a simulator suite. Inspect
[ArchitectureTests.swift](MLBrowserArchitectureTests/ArchitectureTests.swift) and
[LocalizationCatalogTests.swift](MLBrowserArchitectureTests/LocalizationCatalogTests.swift) for
actual rules, including singleton, privacy, environment, and legacy-boundary baselines.

Scans must fail on unreadable inputs or unexpectedly empty scope. New rules need actionable failures
and regression coverage. Justified exceptions must be explicit in the rule/allowlist and documented
at the declaration; do not weaken a whole guard. Legacy boundary allowlists only shrink.

## 8. Localization and accessibility

- App copy belongs in `ios/MLBrowser/iOS/Resources/Localizable.xcstrings`; system permission/file-type
  copy belongs in `ios/MLBrowser/iOS/Resources/InfoPlist.xcstrings`, kept consistent with
  `ios/MLBrowser-Info.plist`.
- Use generated `L10n` keys matching `^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9_]+)+$`. Do not introduce
  hardcoded SwiftUI literals that bypass this project's translation workflow.
- Use `scripts/xcstrings_tool.py` via `./scripts/localization.sh`; do not reserialize whole catalogs
  by hand. When meaning changes, create a new key and remove the old one so translations cannot
  silently preserve the old meaning. Ordinary typo/copy tightening may retain the key.
- Preserve format-specifier count, kind, and positional indices. Author CLDR plural categories
  required by each locale, not just English. Use the tool's restricted-copy workflow for legal/billing
  strings; preserve product meaning and established store terminology.
- `./scripts/localization.sh` is the local and GitHub CI semantic gate. Harmonize adds Swift catalog
  assertions. `./scripts/check_localization_build.sh` separately checks that an Xcode build leaves
  both catalogs unchanged; the pre-push hook currently invokes it for branch pushes.
- Use `.testability` identifiers for automation and real labels/hints/traits for accessibility.
  Verify RTL, Dynamic Type, contrast, truncation, and platform sheet behavior; accessibility-tree
  assertions alone cannot establish what pixels a person sees.

## 9. Performance and lifetime

Measure with Instruments and Xcode's memory tools before optimizing. Bound image/model lifetimes
and cancel obsolete work when a view/session ends. Use weak capture to break retention cycles or
represent optional ownership; retain deliberately when work must keep its owner alive to finish.
Document lifetime/cancellation intent rather than applying `[weak self]` mechanically. Store
Combine subscriptions with the object that owns their lifetime.

## 10. Privacy and secrets

Follow the [repository privacy boundary](../AGENTS.md#data-and-privacy): on-device inference,
no transient-frame uploads, and authorized saved-finding sharing/backup only. Respect ownership and
backup preferences across awaits. Generated `Secrets.xcconfig` and `.sentryclirc` stay untracked;
credentials come from [project setup tooling](MLBrowser/README.md).

## 11. Dependencies and tooling

Prefer native frameworks and existing dependencies. Assess license, maintenance, footprint, and
testing value before adding one; prefer SwiftPM for app dependencies. Repository tooling policy
lives in [root AGENTS.md](../AGENTS.md#scope-and-decisions).

## 12. Assets

Prefer asset catalogs for images/colors. Avoid duplicate or unnecessarily large bundled models,
images, and fonts. Resource changes are test inputs, including model fixtures and JavaScript harnesses.

## 13. Workflow and verification references

Use [root AGENTS.md](../AGENTS.md) for issues/project status, Git, review, TestFlight notes, and release
rules. Use [TESTING.md](../specification/TESTING.md) for unit/UI/converter commands, fixture gates, build reuse, and
result interpretation. Preserve required gates until #850's selector is implemented and validated.
Caches are preserved or selectively invalidated, not deleted after every ticket.

## 14. Code review

Follow the requested scope and root review policy. Check state ownership, actor/lifetime correctness,
storage/format compatibility, privacy, consumers, and test evidence. Distinguish observed failures
from inferred risks and checks that still need a person or device.

## 15. Common pitfalls

- Replace timing assumptions with explicit readiness/cancellation signals and deterministic tests.
- Justify `try?`, `try!`, and forced casts; preserve recoverable error paths.
- Share logic when meaning and lifecycle match; avoid coupling unrelated behaviors to remove duplication.
- Do not normalize a base and a not-yet-created child independently and assume their path strings
  remain comparable. Normalize once and derive children; compare path components, not bare prefixes.
  Neither lexical comparison nor standardization proves symlink containment. Check actual trust
  boundaries and real-device path differences (`/private`, case, container layout).
- Update references when behavior/symbols change, including relevant architecture and tester/review
  metadata. No local code scan verifies live App Store metadata.
