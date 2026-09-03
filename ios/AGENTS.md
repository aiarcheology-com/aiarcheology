# AI Agent Guidelines (iOS / MLBrowser): The "Senior Pair Programmer" Standard

You are acting as a Senior iOS Engineer pair-programming with the user. Your goal is to deliver high-quality, maintainable, and performant code while respecting the existing codebase's evolution.

## Quick Reference (cheat sheet)

| Task | Command / Location |
|------|--------------------|
| Repo setup (installs tools) | `swift run --package-path Tools ProjectTool setup` |
| Open workspace | `open ios/MLBrowser.xcworkspace` |
| Run SwiftLint | `./scripts/swiftlint.sh` |
| SwiftLint autocorrect | `./scripts/swiftlint.sh fix` |
| Run Harmonize (architecture) | `./scripts/harmonize.sh` |
| Validate secrets | `swift run --package-path Tools ProjectTool secrets validate` |
| Generate secrets (first time) | `swift run --package-path Tools ProjectTool secrets generate` |
| Force refresh secrets | `swift run --package-path Tools ProjectTool secrets refresh` |
| Localization file | `ios/MLBrowser/iOS/Resources/Localizable.xcstrings` |
| Primary scheme | `MLBrowser` (see `ios/MLBrowser.xcodeproj/xcshareddata/xcschemes/MLBrowser.xcscheme`) |
| Test plans | `ios/MLBrowserTestPlan/MLBrowserUnitTests.xctestplan`, `ios/MLBrowserTestPlan/MLBrowserUITests.xctestplan` |
| Run unit tests (CLI) | `./scripts/unittest.sh` or `./scripts/unittest.sh --verbose` |
| Build & test (CLI) | `xcodebuild -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser -destination 'platform=iOS Simulator,id=<UDID from xcrun simctl list devices available>' -testPlan MLBrowserUnitTests test` (or just use `./scripts/unittest.sh`, which picks a simulator automatically) |
| Run a single test (CLI) | Add `-only-testing:MLBrowserUnitTests/<TestClass>/<testMethod>` to the `xcodebuild … test` command above (`./scripts/unittest.sh` runs the whole plan) |
| Codebase map / wiring | `./ARCHITECTURE.md` |

## 1. The Mindset

- **Context is King**: Before writing code, understand *where* you are.
  - **Legacy**: Refactor cautiously. Apply the "Boy Scout Rule" (leave it slightly better), but don't rewrite architecture unless asked.
  - **New code**: Use modern best practices (Swift Concurrency, clear boundaries, testable design).
- **Think Like a User**: If a "clean code" solution results in janky UI, broken accessibility, or crashes, it is a **bad solution**.
- **Pragmatic SwiftUI**: Work *with* SwiftUI, not against it.
  - Prefer explicit injection for core dependencies/state at the boundaries.
  - Use `Environment` / `EnvironmentObject` for UI-scoped concerns or when the project's architecture already routes state that way.

## 2. Related Documentation (read before big changes)

- `./ARCHITECTURE.md`: the app's concrete wiring — layering, composition root (`DependencyContainer`), app entry/gating, and the detection pipeline. Read this to orient in the codebase.
- `../LOGGING_GUIDE.md`: OSLog usage, log levels, privacy annotations, and crash policy.
- `./MLBrowser/README.md`: project setup, pinned tools, and secrets management via 1Password.
- `../MAP_LOCATION.md`: how a finding records where it was made (AIA-0817) — the no-hostnames rule, the four location witnesses, why we never write coordinate maths, how to extend coverage, and the manual test reference.
- `../USERMESSAGING.md`: remote app→user messaging (AIA-0115) — payload schema, surfaces, targeting, replies, notifications, and the operator publish/retract runbook.

## 3. Architecture & State

> For the concrete wiring and file map (composition root, app entry/gating, detection pipeline), see **`./ARCHITECTURE.md`**. This section covers the *rules* that structure must follow.

- **Pattern**: pragmatic MVVM-like structure.
  - **Views**: dumb; they render state and send intents/actions.
  - **State objects**: hold state + business logic (`AppState`, `DeepState`, etc.).
  - **Services**: stateless workers (networking, Vision processing, persistence helpers).
- **Dependencies**:
  - Use protocols to define boundaries between *major* components or external resources (networking, file system, camera, etc.).
  - Avoid "fake" abstractions: don't introduce a protocol if it adds no testing value and will never have a second implementation.
  - Cross-reference: see **6. Testing** for when to use real implementations vs protocol fakes.

### Composition root (which layer builds what)

- **`DependencyContainer` is the app's single composition root** (AIA-0385). It owns every shared
  service (Core Data, settings, snap/deep state, downloader, demo data, auth/subscription providers)
  and builds the fully-wired `AppState` via `makeAppState()`.
- **`AppState` is NOT a second root.** It receives its shared services by constructor injection and
  holds only app/view-derived state (guide, renderers, browser/visit state, tour, auth/subscription).
  It must **never** reference `DependencyContainer.shared`.
- **Views never reference `DependencyContainer.shared`.** Read what you need from `AppState`
  (`@EnvironmentObject`) or a dedicated environment value. The **only** allowed `.shared` sites are
  bootstrap: the `@main` app entry (`MLBrowser.swift`) and the background-session
  `UIApplicationDelegate`, which run before/outside the SwiftUI graph.
- New **shared service** → add it to `DependencyContainer` and inject it through `makeAppState()`.
  New **app/view state** → add it to `AppState`. Don't reach across into `.shared`.
- **Environment values that gate UI on composition-root config** (e.g. `\.usesRealAuth`) are
  injected once at the app root. Like `\.managedObjectContext`, custom environment values do **not**
  reliably cross `.sheet` boundaries on Mac (Designed for iPad) — **re-inject them on any sheet**
  whose content reads them.

### Core Data protocols (which one to adopt)

- **`CoreDataManageable`** (note the spelling — trailing `-eable`) is the standard entity API: consistent `performAndWait`, error surfacing, CRUD/fetch/count, and batch-delete merge semantics. **Default to it for every Core Data entity.**
- **`CoreDataManagableWithState`** (no trailing `e`) refines it with a full lifecycle state machine (`undefined → empty → draft → ready → deprecated`). Reach for it **only** when an entity has a genuine draft/import flow — e.g. `DeepConfiguration`, `Finding`. Simple lookup/log rows (`WebHistoryEntry`, `WebVisit`-style records) don't need the extra states; the lifecycle adds ceremony with no payoff there.
- The two names differ by one letter *and* by scope, which is easy to misread. Some existing simple-row entities predate this guidance and still adopt `...WithState`; migrate opportunistically and don't add new ones.

### Feature flags

- **Gate every significant feature behind a feature flag** so it can be turned on/off without ripping code out — e.g. **login/auth gate**, **payments/subscriptions**, and any other large or risky surface. Shipping a feature dark (flag off) and flipping it on later is the default, not the exception.
- **Flags are remote (ConfigCat) since AIA-0350** — see **`../FEATUREFLAGS.md`** for the full picture. Add a `case` to `FeatureFlagKey` (`State/FeatureFlags.swift`); its `rawValue` **is** the ConfigCat key and its `defaultValue` is the compiled fallback. Read values from the published `FeatureFlagSnapshot`, never from a global.
- **Create the flag in the ConfigCat dashboard *before* shipping code that reads it.** The dashboard auto-generates the key from the name — overwrite it to match `rawValue` exactly, or the lookup silently falls back to the compiled default forever.
- **Defaults fail open.** Offline, a bad SDK key, a missing flag, or a ConfigCat outage leaves the feature at its `defaultValue` (currently `true` for both). This preserves shipped behaviour but means a flag is not a guaranteed remote kill switch. A flag that must fail closed needs `defaultValue = false`.
- **Decide live vs launch-only per flag.** A flag that only shows/hides an entry point may apply live. A flag gating a view *above* `ContentView` (e.g. `isPaymentsEnabled` → `SubscriptionGateView`, the app root) must be captured once at launch — applying a mid-session flip would replace a working app with a paywall, or release an unpaid user from it.
- **Never block launch on a flag.** The snapshot seeds synchronously; refresh runs detached after `isReady`.
- Keep flags **few and meaningful** (one per shippable feature), name them for the feature (`isPaymentsEnabled`, `isAuthGateEnabled`), and remove a flag once its feature is permanently on and stable — don't let dead flags accumulate.
- **Payments note (research, 2026-06):** in-app digital subscriptions on iOS must use **StoreKit 2 IAP** (Apple Guideline 3.1.1; Apple is merchant-of-record and handles per-country VAT/tax + local pricing — the reason to prefer it). Clerk Billing/Stripe is **web-checkout only** (no native StoreKit path, USD-only, you become merchant-of-record), so it is **not** the in-app purchase path. Plan: StoreKit 2 → App Store Server Notifications → backend writes the entitlement to the Clerk user → app gates on it. Optional US-only "subscribe on web" external Stripe link is upside (0% Apple fee post-*Epic*), not the foundation. Ship all of it behind a payments feature flag.

### SwiftUI Previews (developer velocity)

- Provide `#Preview` blocks for new views with representative states (empty/loading/error/success).
- Use lightweight preview data; do not require real Core Data or network calls.

## 4. Concurrency & Threading

- Default to `async/await`.
- **Be explicit about `@MainActor`**. UI updates must happen on the main actor. If you are unsure, verify isolation.
- In tests, prefer actor-safe patterns (see **6. Testing → Concurrency in Tests**).

### Common `@MainActor` pitfall

```swift
// ❌ BAD - creates a race by scheduling an extra hop
@MainActor
final class MyClass {
    private var items: [Int] = []

    func register(_ value: Int) {
        Task { @MainActor in
            if !items.contains(value) { items.append(value) } // race window
        }
    }
}

// ✅ GOOD - atomic on the main actor
@MainActor
final class MyClass {
    private var items: [Int] = []

    func register(_ value: Int) {
        if !items.contains(value) { items.append(value) }
    }
}
```

## 5. Logging, Error Handling & Observability

- Follow `../LOGGING_GUIDE.md`. Use project logging helpers (e.g., `logInfo`, `logDebug`, etc.) when available.
- Use category-specific loggers where appropriate (drivers/rendering/persistence/etc.).
- Error handling:
  - Don't silently drop failures.
  - Use project policies for "this should never happen" vs "recoverable" paths (assertion vs critical failure) where applicable.

## 6. Testing Guidelines

### Test strategy

- **Prefer real objects** with isolated dependencies (e.g., in-memory Core Data) over heavy mocking—this tests real logic.
- Use protocols when swapping out expensive/uncontrollable resources (networking, camera, system tasks).
- **Protocol-based mocking for deprecated APIs**: avoid subclassing deprecated system classes; extract a minimal protocol and conform the system class to it.

### File management (Xcode)

- When creating new `.swift` files, ensure they are added to the Xcode project and the correct target(s).
  - Preferred workflow: add via Xcode so build phases/targets are correct.
  - If editing `.pbxproj` manually, do it carefully and keep diffs minimal.

### Core Data model versioning

- **Add a new model version only when the previous version has already been released** (shipped to real users). While a model version is unreleased, fold schema changes into it in place — dev installations are simply reset, and the destroy-and-recreate recovery in `DataController` covers stale local stores.
- A new (post-release) model version requires the full migration step: a new `MLBrowser_x.y.z.xcdatamodel`, an explicit `.xcmappingmodel` under `Persistence/Migration/<from>-<to>/` generated **in Xcode** (its model-version hashes are tool-computed; never hand-write it), and any custom `NSEntityMigrationPolicy` wiring — see `Migration/0.0.0-0.0.1/` as the template. Release builds run with mapping inference disabled, so a missing mapping fails migration for real users.
- Editing a model version in place invalidates the version hashes any existing mapping models reference for it; regenerate affected mappings if their source/target changed.

### Core Data testing

- `NSBatchDeleteRequest` and other batch operations do **not** work with `NSInMemoryStoreType`. Test batch behavior via integration tests with SQLite stores.
- Multiple in-memory stacks across test classes can cause entity resolution conflicts. Prefer factory methods (e.g., `.create(in:)`) over `EntityName(context:)` direct initialization.

### Concurrency in tests

- For `@MainActor` test classes, use `override func setUp() async throws` / `tearDown() async throws` to inherit isolation correctly.
- Don't capture mutable `var` across concurrent closures; use an `actor` for thread-safe state.

### UI testing & accessibility

- **UI tests**: for controls targeted by UI tests, use the `.testability` modifier to set a stable `accessibilityIdentifier`.
- **Real accessibility**: also add `.accessibilityLabel`, `.accessibilityHint`, traits, etc. See examples in `DrawerContainer.swift` and `AppDescriptionView.swift`.
- Review: watch for low contrast, small touch targets, truncated text, overlapping views, and Dynamic Type breakage.

### Test organization & naming

- Group tests by component (`FooTests.swift` tests `Foo.swift`), not by "unit vs integration".
- Use descriptive naming: `test[Method]_[Scenario]_[ExpectedResult]` (e.g., `testRegister_SameDriverTwice_OnlyRegistersOnce`).

### Cross-platform considerations

- Don't depend on architecture- or machine-specific behavior (CPU architecture, available simulators, locale, timing): tests must pass both locally and on Xcode Cloud CI runners.

## 7. Harmonize (Architectural Linting)

Harmonize enforces architectural rules as unit tests. Unlike SwiftLint (regex-based style rules), Harmonize provides semantic analysis of code structure.

### Running Harmonize

```bash
./scripts/harmonize.sh          # Run architectural tests
./scripts/harmonize.sh --verbose # Detailed output
```

### Current Rules (in `ios/MLBrowserArchitectureTests/ArchitectureTests.swift`)

| Rule | What It Enforces |
|-|-|
| State objects are `@MainActor` | Thread-safe UI updates for `*State` classes |
| Services are not `@MainActor` | Heavy work stays off the main actor (actors/classes/structs all allowed) |
| Views are structs | SwiftUI value-type design (no `*View` classes) |
| ObservableObjects have descriptive suffixes | Clear naming (`*State`, `*Manager`, etc.) |
| CoreData entity classes exist | Core Data entities compile and are discoverable |
| Singleton guardrail | `static let/var shared` only in per-declaration allowlisted files |
| Screenshot privacy invariant (AIA-0392) | Only `FindingRepository` calls `FindingScreenshotStore.save` |
| Account-identifier privacy invariant (AIA-0437) | The raw Clerk account id is never passed to `LoggingPolicy` (its messages become Sentry breadcrumbs, and since AIA-0602 also on-disk support-log entries) |
| Boundary baselines (aspirational) | Views importing CoreData / `*State` importing SwiftUI+UIKit: frozen legacy list, new offenders fail, list only shrinks |
| Planned: extensions are organized | Future rule for extension file structure |

All rules fail closed: an unreadable file or an empty scan fails the rule instead of passing vacuously.

### Philosophy: Guidelines, Not Dogma

Harmonize rules are **architectural guidelines**, not unbreakable constraints. When a rule conflicts with pragmatic design:

1. **Evaluate the trade-off**: Is the violation intentional and justified?
2. **Document exceptions**: Add a comment explaining why the exception exists.
3. **Consider renaming**: Sometimes a name change resolves the conflict (e.g., a background-only "State" class should be renamed).

Example of a justified exception (hypothetical — `SnapState`, the former example, is now `@MainActor`, so there are no such exceptions in the codebase today):
```swift
// A genuinely background-only "State" type that never drives UI directly.
// Prefer renaming it (point 3); if the name is kept, document why and add it
// to the exclusion list in testStateObjectsAreMainActor.
final class ExampleBackgroundState: ObservableObject { ... } // not @MainActor by design
```

### Adding New Rules

Add rules to `ios/MLBrowserArchitectureTests/ArchitectureTests.swift`. Each rule should:
- Have a clear, actionable error message
- Reference the relevant AGENTS.md section
- Suggest how to fix or when exceptions are acceptable

## 8. Localization & Internationalization

- Any user-visible string must be localized in `ios/MLBrowser/iOS/Resources/Localizable.xcstrings`.
  System-owned copy such as permission alerts and exported/imported file-type descriptions belongs
  in the separate `ios/MLBrowser/iOS/Resources/InfoPlist.xcstrings` catalog; it is checked by the
  same localization gate and must be kept in sync with `MLBrowser-Info.plist`.
- When adding strings:
  - Prefer string keys managed by the project's localization tooling (see generated `L10n.swift` usage patterns).
  - Keys must be dot-namespaced (`history.title`); `LocalizationCatalogTests` enforces
    `^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9_]+)+$`. A bare literal in SwiftUI (`Text("Add Model")`) is
    auto-extracted by `SWIFT_EMIT_LOC_STRINGS`, never reaches `L10n.swift`, and can never be
    translated — route it through `L10n` instead.
  - Handle pluralization using `.stringsdict`-style plural rules via xcstrings where applicable.
    Author the CLDR categories the *target* locale requires, not English's: Czech/Polish/Russian/
    Ukrainian need `few` and `many`, Arabic needs `two`/`few`/`many`. A missing category silently
    falls back to `other` and renders the wrong grammatical case.
- Never edit the catalog with a whole-file JSON re-serialization; use `scripts/xcstrings_tool.py`
  (see `.claude/skills/ship-ticket/references/localization.md` for why a round-trip cannot be
  byte-faithful).
- **When a string's *meaning* changes, change the key** — add a new one and prune the old, rather
  than editing the English in place (AIA-0455). Editing leaves the other 16 locales holding a
  fluent, grammatical translation of the *old* meaning, and **no gate can see it**: the coverage
  ratchet counts presence, and `verify` checks shape and format specifiers. An incomplete
  translation pass on a new key falls back to English carrying the new meaning; on an edited key it
  renders a local sentence that quietly says something else. Fixing a typo or tightening wording is
  still an ordinary edit — this is about meaning.
- Translated values must carry exactly the format specifiers of their English sibling — same count,
  same kind, same positional indices, and `%lld` is not `%d`. A mismatch makes `String(format:)`
  read the wrong argument.
  - **In CI:** the Harmonize workflow runs `LocalizationCatalogTests`, whose Swift tests enforce
    format-specifier agreement and a per-locale coverage ratchet. That is the subset that gates a PR.
  - **Before pushing:** run `python3 scripts/xcstrings_tool.py verify`, which additionally checks
    entry shape, CLDR plural categories per locale, and protected terms. It is not run by CI.
  - The repository pre-push hook runs `./scripts/check_localization_build.sh`. It snapshots both
    catalogs, performs the Xcode build, and fails if Xcode rewrites either one; rerun it manually
    after an Xcode or localization-tooling change. GitHub CI keeps the fast Python gate on Ubuntu.
- Internationalization checks:
  - Right-to-left layouts (mirroring, alignment, icons with directionality).
  - Dynamic Type (large fonts) and text truncation.

## 9. Performance Guidelines

- Don't block the main thread with heavy work (Vision, image decoding, file IO, JSON parsing).
- Be mindful of memory:
  - Avoid retaining large images/models longer than needed.
  - Release heavy resources on `onDisappear` or when state transitions out of a heavy mode.
- Prefer measurement over guessing:
  - Use Instruments (Time Profiler, Allocations, Leaks) and Xcode's Memory Graph Debugger.

### Memory management

- Use `[weak self]` in escaping closures; add `guard let self else { return }` at the top.
- Store Combine subscriptions in `Set<AnyCancellable>` owned by the subscribing object.
- Use Xcode's Memory Graph Debugger to detect leaks and retain cycles.

### MLBrowser domain notes (Vision + WebViews)

- Vision and WebViews are CPU/memory intensive—batch work, avoid repeated conversions, and keep UI responsive.

## 10. Security, Privacy & Secrets

- **On-device ML privacy invariant (the product promise)**: page snapshots and detection imagery never leave the device. The app must not transmit them — no uploads, no Sentry attachments or breadcrumbs carrying image data, no image contents in logs. The only path off-device is an explicit user-initiated export/share.
- **Never commit secrets**.
  - Templates (committed): `ios/Secrets.template.xcconfig`, `ios/.sentryclirc.template`
  - Generated (gitignored): `ios/Secrets.xcconfig`, `ios/.sentryclirc`
- Local secrets are managed via 1Password + ProjectTool (see `./MLBrowser/README.md`).
- Never hardcode API keys/tokens in code. Use xcconfig-injected values.
- Logging privacy:
  - Annotate private user data in logs per `../LOGGING_GUIDE.md`.
  - Avoid logging full URLs that may contain sensitive query parameters.

## 11. Third-Party Dependencies

- Prefer native frameworks and existing project utilities first.
- When adding a dependency:
  - Prefer Swift Package Manager.
  - Review license, maintenance, and footprint (binary size / startup / privacy).
  - Keep the surface area small (wrap in a thin adapter if it's a major dependency).

### Repository tooling (scripts & ProjectTool)

- **Prefer the Swift codebase for repo tooling over Ruby** (or other interpreters). New tool logic
  belongs in `ProjectTool` (`Tools/`) — the repo's tooling home — unless the effort to build it in
  Swift is disproportionately large. A `scripts/*.sh` wrapper may shell out to a small `ProjectTool`
  subcommand for the non-trivial parts (e.g. `scripts/deliver.sh` mints its App Store Connect ES256
  JWT via `ProjectTool asc token`, CryptoKit — no OpenSSL/Ruby).
- A **ready-made Ruby tool or library** (Fastlane, CocoaPods, an existing gem) is acceptable when it
  clearly beats writing and maintaining a Swift equivalent — judge by effort and fit, not dogma.

## 12. Asset Management (images, models, fonts)

- Prefer `Assets.xcassets` for images and colors; keep naming consistent and descriptive.
- Optimize heavy assets (large JPG/PNG, models) and avoid duplication.
- Be mindful of app size and memory: large bundled assets have real cost.

## 13. Workflow, Quality Gates & Git

- **Don't guess**: if requirements are ambiguous, ask.
- **Incremental changes**: don't mix "renaming" with "threading model changes" in one step.

### Quality gates (per chunk of work)

- Run lint: `./scripts/swiftlint.sh` (use `./scripts/swiftlint.sh fix` only when safe).
- Run architectural lint: `./scripts/harmonize.sh` (for significant structural changes).
- Add/update tests when behavior changes.
- **Touched `Sources/NativeModelConverter/` or `Tests/NativeModelConverterTests/`? The app's test
  plans do not cover them** — and that is enforced by the plan, not by this paragraph.
  `MLBrowserUnitTests.xctestplan` lists exactly one target, and the converter's own workflow
  (`.github/workflows/native-model-converter.yml`) is gated on `paths:` covering
  `Sources/NativeModelConverter/**`, `Tests/NativeModelConverterTests/**` and `Package.swift`, so
  the suite runs when converter code changes and not otherwise. (It was listed as a second target in
  the app plan until AIA-0680, which meant it ran on every app unit run while its seven
  fixture-gated parity tests silently skipped there — the redundancy cost time and proved less than
  the dedicated job, which runs with zero skips among the suites it selects — it deliberately skips
  `ADAFCheckpointDirectoryTests`, which belongs to `scripts/test_adaf_checkpoints.sh`.) The converter is a separate SPM package at the
  repo root with its own suite — run `swift test` for it, and see the check table in `../NATIVE_MODEL_CONVERSION.md` for the
  Apple-artifact and Python parity runs. Three of its suites are gated on fixtures the repo
  deliberately does not carry, and **each skips silently while the run still reports success**:
  - `NATIVE_MODEL_ONNX_DIRECTORY` — the `.onnx` conversion fixtures behind
    `ONNXConversionIntegrationTests` and the YOLO trunk tests. Populate it with
    `./scripts/fetch_native_test_models.sh [TARGET_DIR]`, which downloads the manifest's models and
    verifies each SHA-256, then pass the same directory in the variable.
  - `NATIVE_MODEL_REFERENCE_DIRECTORY` — Apple's MobileNetV2 FP16 / INT8-LUT artifacts behind
    `MobileNetV2ReferenceModelTests`. Do not export it by hand:
    `./scripts/test_native_model_converter.sh` downloads them to a temp directory, pins their SHA-256
    and sets the variable itself.

  - `ADAF_CHECKPOINT_DIRECTORY` — the published ADAF PyTorch checkpoints behind
    `ADAFCheckpointDirectoryTests` (AIA-0666). Populate it with
    `./scripts/fetch_adaf_checkpoints.sh [--full] [TARGET_DIR]`, which reconstructs each file
    sparsely from HTTP range requests (~10 MB of disk for 2.9 GB of logical files; `--full` fetches
    whole files and verifies each md5). **Run the suite via
    `./scripts/test_adaf_checkpoints.sh [TARGET_DIR]`, not `swift test` directly** — the wrapper
    fails when the fixtures are absent or when any test skipped, which is precisely what a bare run
    will not tell you.

  No variable is set by another's script, so a run with only one of them still skips the rest.
  A converter change verified against the app's test plans alone has exercised none of this.

  The checkpoint reader is the one part of the converter with an always-on real-bytes suite: the
  head and tail ranges of two published ADAF checkpoints are committed under
  `Tests/NativeModelConverterTests/Fixtures/ADAF/` (CC-BY-SA-4.0, see its `NOTICE.md`), and because
  the reader's whole read set lies inside them, a plain `swift test` really does exercise it against
  real bytes. The gated suite above is the redundant check over files fetched fresh, not the only
  one.
- Build and run unit tests (prefer the scheme's test plans).
  - Xcode: run via the `MLBrowser` scheme and select the test plan.
  - CLI example (choose an available simulator destination on your machine):

```bash
xcodebuild -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser -testPlan MLBrowserUnitTests test
```

#### Reading an `xcodebuild` result: three ways to misread a green run

Learned the hard way on AIA-0650; each of these looked like a passing suite.

- **The module name for `@testable import` is `ML_Browser`, with an underscore** — not `MLBrowser`.
  `PRODUCT_NAME` is "ML Browser", and Swift replaces the space. Getting it wrong fails with
  `unable to resolve module dependency: 'MLBrowser'`, which reads like a broken project rather than
  a typo in one import.
- **`xcodebuild` prints the per-test-case lines *after* `** TEST SUCCEEDED **`.** Waiting for that
  marker and counting immediately reports `0 passed`, which is indistinguishable from the
  genuine zero-test run below. Wait for the process to exit, not for the marker.
- **The two suites log in different formats.** Unit tests print `Test case '...' passed`
  (lowercase c); UI tests print `Test Case '-[Suite testMethod]' passed` (capital C, legacy form).
  A counter written for one silently reports zero for the other — an 89-test UI run looked like a
  silent no-op because of this.

Whatever counts tests, verify the count **moved** by the number of tests you added. A new file that
is not in its target compiles into nothing, `-only-testing:` then matches nothing, and the run is
green and empty. `MLBrowserUnitTests` and the UI groups are plain `PBXGroup`s — only
`MLBrowserArchitectureTests` and `Testability` are synchronized — so a new test file needs explicit
`.pbxproj` membership in all four places (`PBXBuildFile`, `PBXFileReference`, the group's children,
and the target's Sources phase).

#### `test-without-building` can report a green run for code that does not compile

Splitting a run into `build-for-testing` then `test-without-building` is worth doing — it keeps a
long suite off the critical path and lets several `-only-testing:` passes share one build. It also
has a trap that looks exactly like success:

**`test-without-building` does not check that the build succeeded.** It runs whatever `.xctest`
bundles are already in the products directory. If `build-for-testing` failed — even on a single
typo in a test file you were still writing — the previous build's products are still sitting there,
and the test step will run them and print a full, plausible pass count.

Observed while shipping AIA-0567: `build-for-testing` exited 65 on a missing argument in a new
test, and the very next step reported `1832 passed, 0 failed`. Every one of those was the *old*
binary. Nothing in the output says so.

Two habits close it:

- **Check every step's exit code, not just the last one.** `&&` between the steps, or an explicit
  `echo "exit=$?"` after each. A pass count is not evidence that the thing you just wrote compiled.
- **Expect the count to move when you add tests.** If you added three and the total is unchanged,
  you are looking at stale products — that is the cheapest tell there is.

A second mechanism produces the identical false green: **an `-only-testing:` filter that matches
nothing runs zero tests, exits 0, and prints `** TEST SUCCEEDED **`.** Observed three times in a row
while diagnosing AIA-0603 — first because a new file under `MLBrowserUnitTests/` was never compiled
(that target is a plain group; only `MLBrowserArchitectureTests` and `Testability` are
`PBXFileSystemSynchronizedRootGroup`s, so a new file there must be added to the target explicitly),
then because the test method sat in a `private extension`, where XCTest cannot discover it. Same
tell, same fix: confirm the test actually ran before believing the result.

The same applies to the *app* binary you hand a human to test: verify what is installed rather than
trusting that the build you ran produced it. See §13 on `WhatToTest` — a tester reporting "the new
screen is missing" is usually a stale install, not a bug.

### Clear the local DerivedData caches when a ticket is done

The repo holds gitignored per-lane DerivedData caches. Two are defined by tooling —
`.deriveddata` (`scripts/unittest.sh`) and `.deriveddata-localization`
(`scripts/check_localization_build.sh`) — and both honour a `DERIVED_DATA_PATH` override, so ad-hoc
lanes (`.deriveddata-prepush`, `.deriveddata-replay-tests`) accumulate too. Nothing prunes any of
them, and each keeps a full copy of the build products — three lanes totalling 16 GB is normal.

**They are not only at the repo root: `ios/.deriveddata` happens too**, depending on the directory a
lane was invoked from. A `rm -rf .deriveddata*` run from the root will not catch it, so delete both
(see the command below).

**Delete them when a ticket is closed or its branch is merged.** Reclaiming disk is the small
reason. There are two large ones.

**It breaks `./scripts/swiftlint.sh`, and the failure does not look like yours.** `.swiftlint.yml`
excludes `**/DerivedData` but not the lowercase `.deriveddata`, so a leftover cache puts the
vendored SPM checkouts under `SourcePackages/checkouts` in scope. Measured on AIA-0623: **5680 files
linted instead of 324, 32 733 violations, 3061 serious, exit 2** — every one of them in `sentry-cocoa`
and none in this repo's own source. If a lint run that passed an hour ago suddenly fails with
thousands of violations in files you have never opened, check for a cache before reading a single
one of them. (The pre-commit hook lints only the changed files, so it stays green throughout and
does not warn you; CI checks out fresh and is unaffected.)

The second is that a stale cache fails in a way that does not look like staleness either:

- After AIA-0591 changed the Clerk package version, builds from the surviving caches died with
  `Unable to resolve module dependency: 'CAsyncHTTPClient'` — also `CNIOLLHTTP`, `CNIOPosix`,
  `_NumericsShims`, `CSystem` — in target EventSource. That is a package-graph error naming modules
  nobody touched, on a branch whose only Swift change was one view. A fresh DerivedData path built
  and tested cleanly.
- It is not the old build-location bug: this reproduces with `IDEBuildLocationStyle = Unique`. Any
  dependency version change can invalidate a cache this way.

```bash
rm -rf .deriveddata* ios/.deriveddata*
```

If you hit either symptom, clear the caches *before* debugging anything else. CI checks out fresh
and is unaffected; the caches rebuild on the next run.

### Shipping a release

When a version goes live, update the **Release baseline** in `../README.md` in the same pass:
the app version now in production, and the Core Data model version that ships with it.

It is two values, and the only place that answers "what is actually live?". Everything
downstream leans on it — whether a Core Data migration is required at all, whether a persisted
format is still free to change, and which build a crash report belongs to. Left to rot it does not
merely go stale, it actively misleads: a contributor reading "production is `0.0.0`" while `0.0.1`
has in fact shipped will treat a released schema as editable.

#### `deliver.sh` will not archive from an arbitrary branch

The local TestFlight lane mirrors what Xcode Cloud's Release workflow would ship, so it refuses to
archive unless you are on a `release/*` branch — or you pass `--ref <tag|sha>`, which is an
**assertion that HEAD already equals that ref**, not a checkout. `--ref $(git rev-parse HEAD)` is
therefore how you deliver a feature branch deliberately, and it cannot silently ship the wrong
commit.

Two things that follow: a `release/*` branch **pushed** to the remote fires the paid Xcode Cloud
Release workflow, so create one locally or not at all; and `deliver.sh notes --build-number N`
fails until App Store Connect finishes processing, which takes minutes — re-run it rather than
treating the first failure as real.

`ITSAppUsesNonExemptEncryption` is set to `false` in `MLBrowser-Info.plist`. Nothing prompts for it
and a missing key stalls a TestFlight build silently, so leave it in place.

### Issues

- **Every issue belongs to the [AI Archeology project](https://github.com/orgs/aiarcheology-com/projects/1)** (org project #1). Add it at creation time — an issue that is not on the board is invisible to planning, and "I'll add it later" is how it stays invisible.
- **New issues start at `Todo`.** The board's Status field runs `Todo → Waiting → In Progress → In Review → Done`. An empty Status is not a valid starting state; set it when you file the issue.
- Title issues `AIA-XXXX: <summary>` so the key lines up with the branch segment (`<type>/AIA-XXXX/desc`) and the commit prefix (`[AIA-XXXX]`).
- **Read an issue's comments, not just its body — the scope is the whole thread.** Scope is routinely *added* after filing, as `## Also in scope:` comments, and `gh issue view --json body` does not return them. Fetch `.../issues/<n>/comments` (or `--json body,comments`) before planning: AIA-0659 looked like a one-line fix from its body and was in fact four items, three of them added by comment hours later.
- **`Closes #NNN` does not auto-close for PRs targeting `develop`.** GitHub only honours closing keywords on merges to the default branch (`main`). Since PRs here target `develop`, closing the issue *and* moving its board status to `Done` is a manual step after every merge — budget for it rather than assuming the link fired.

### Branches & commits

- Never push without explicit user consent.
- Never commit or push directly to `develop` or `main`.
- Branch naming: `<type>/AIA-XXXX/short-description` — include the issue key as its own path segment (e.g. `feature/AIA-0011/browser-fullscreen-revamp`).
  - `feature/AIA-XXXX/short-description` for new features
  - `fix/AIA-XXXX/issue-description` for fixing issues
  - `doc/AIA-XXXX/area-affected` for documentation
  - `test/AIA-XXXX/area-affected` for the branches dedicated only to tests or their infrastructure
- Commit messages:
  - Include an issue ID prefix in the form `[AIA-XXXX]` or `[AIA-XXXX, AIA-YYYY]` for multiple related issues.
  - Use an imperative summary ("Fix crash when…").
  - Add a short body describing *why* and any tradeoffs, especially for threading, persistence, or logging changes.

### Pull requests

- Pull requests target `develop`.
- **Every time a PR is opened (or materially updated), update `ios/TestFlight/WhatToTest.en-US.txt`** with a short "what to test" section for that change. This is mandatory — no PR without it. Xcode Cloud ships this file's contents to TestFlight testers as the build's "What to Test" description. Keep it:
  - **Tester-facing, not dev jargon** — describe the user-visible behavior and concrete steps to exercise it, not the implementation.
  - **Scoped to this change** — what's new/changed in this PR and how to verify it; call out anything risky or easy to miss.
  - **Concise** — a short intro line plus a few bullet steps.
  - **Notes for ONE build, not a changelog.** Adding a section is only half the job: **remove the
    sections for features that already shipped.** Their notes went out with their builds, and a
    tester opening TestFlight should see what to test *now*, not instructions for a build from
    weeks ago.
  - **Under 4000 characters** — App Store Connect's hard cap on `whatsNew`. Exceeding it does not
    truncate, it fails the upload of the notes, so the build ships with **no** tester notes at all.
    Only ever adding sections is how the file reached 12 480 characters and silently stopped
    publishing (AIA-0574). Enforced by the TestFlight notes workflow and by `deliver.sh` preflight.

## 14. Code Review Guidelines (what "good" looks like)

- Correctness: edge cases handled, errors not swallowed, thread/actor correctness.
- Maintainability: clear names, minimal public surface area, avoids needless abstraction.
- SwiftUI: avoids update loops, state is owned appropriately, previews cover key states.
- Performance: avoids main-thread heavy work, avoids repeated conversions/allocations.
- Security/privacy: secrets not hardcoded; logs use privacy annotations.
- Tests: behavior changes are covered; test naming/organization follows conventions.

## 15. Common Anti-Patterns (and what to do instead)

- **Hard-coded delays** (`sleep`, `asyncAfter` "wait for UI/network"):
  - Instead: `XCTestExpectation`, deterministic clocks, explicit callbacks/awaits.
- **Ignoring errors** (`try?`, `try!` without justification):
  - Instead: handle explicitly; log; surface to user if needed; assert only when appropriate.
- **Forced downcasting** (`as!`) without proof:
  - Instead: fix the abstraction, use `as?` with a controlled fallback, or assert in debug with a clear message.
- **Over-engineering** (generic factories, layers of indirection for one implementation):
  - Instead: start simple; introduce abstraction when a second implementation or test seam is actually needed.
- **Duplicated logic** (copy-pasting code, multiple sources of truth):
  - Instead: extract shared logic into a single implementation; prefer a single source of truth for data and behavior. 
- **Normalising two paths separately and then comparing them** (`a.standardizedFileURL` on one side
  of a check and `b.standardizedFileURL` on the other):
  - Why it bites *here*: `standardizedFileURL` and `resolvingSymlinksInPath()` are
    **existence-conditional** — a leading `/private` is stripped only when the stripped path exists —
    so they are not pure functions of the path they are given. Applying the *same* function to two
    URLs therefore does not produce comparable results, which is why "both sides are standardised"
    reads as safe and is not. On device the app container is `/private/var/mobile/…`: in AIA-0603 a
    staging directory that already existed standardised to `/var/mobile/…` while the file about to be
    written into it did not exist and kept its `/private` prefix, so a containment guard rejected
    every catalog package download. Simulator and iOS-on-Mac containers live under `/Users/…`, where
    the transform is a no-op — no local test, on any locale or device family, could observe it.
  - Instead: normalise **once** and derive every other URL from that value, so the two cannot
    disagree. Compare with a `pathComponents` prefix rather than `path.hasPrefix`, which also matches
    a sibling (`…/Documents` satisfies a `…/Documents` prefix test against `…/DocumentsBackup`).
  - The same reasoning applies to any device-vs-simulator path assumption: `/private`, case
    sensitivity, and container layout all differ, and the simulator is the more permissive of the two.
- **Prose that outlives what it describes** (a comment, doc, or store listing still explaining a
  thing that has moved, been renamed, or been deleted):
  - Why it bites *here*: the comments in this codebase assert invariants and justify decisions
    rather than restating the code. A stale one therefore does not read as untidy — it reads as
    authoritative and is believed until something independently checks it. Several of AIA-0567's
    review findings were exactly this: a comment promising a guarantee the code no longer made.
  - Instead: when you delete, rename or move something, grep for what refers to it **before**
    calling the change done, and treat every hit as part of the same change. A doc comment left
    pointing at a deleted symbol is a defect, not a tidy-up for later.
  - The surface is wider than code, and the compiler covers none of it: doc comments, `ARCHITECTURE.md`,
    `ANALYTICS.md`, `AUTH-SUBSCRIPTION.md`, `ios/TestFlight/WhatToTest.en-US.txt`, and the App Store
    Connect review notes and screenshots. The last two live outside the repo, so nothing local will
    ever tell you they are wrong — and they are read by App Review.

## 16. Version History & Evolving These Guidelines

### Changelog

- **2026-08-14**: §13 Quality gates gained the **native converter package** (AIA-0637). The app's
  test plans do not cover `Sources/NativeModelConverter/`, so a converter change could pass every
  documented gate with none of its own suites run — and its two fixture-gated suites *skip silently
  while the run still reports success*. The bullet names both variables, the script that supplies
  each (`./scripts/fetch_native_test_models.sh`, `./scripts/test_native_model_converter.sh`), and the fact that neither
  script sets the other's variable. `fetch_native_test_models.sh` had until now been documented
  nowhere but its own header comment.
- **2026-08-12**: §15 gained the **separately-normalised paths** anti-pattern and §13's false-green block gained the `-only-testing:`-matches-nothing mechanism (both from AIA-0603: `standardizedFileURL` is existence-conditional, so a device-only `/private` prefix broke every catalog package download while remaining invisible to the simulator).
- **2026-08-11**: §13 gained an **Issues** subsection (every issue joins the AI Archeology org project #1 and starts at `Todo`; `Closes #NNN` never fires on a `develop` merge, so closing and moving the board is manual) and a **DerivedData cleanup** rule (clear `.deriveddata*` when a ticket closes; a stale cache surfaces a dependency change as a bogus `CAsyncHTTPClient` module-resolution error, observed on AIA-0591).
- **2026-07-15**: §3 Feature flags rewritten for AIA-0350 — flags are now remote (ConfigCat) via `FeatureFlagKey`/`FeatureFlagSnapshot`, not compile-time constants. Documents the fail-open default, the create-the-flag-first rule (the dashboard auto-generates keys), the per-flag live vs launch-only decision, and the never-block-launch rule. Full detail moved to `../FEATUREFLAGS.md`; product analytics (not yet implemented) is specified in `../ANALYTICS.md`.
- **2026-07-14**: §7 synced with the actual rules (AIA-0429): correct test-target path (`MLBrowserArchitectureTests/`), services rule stated as "not `@MainActor`", added singleton/privacy/baseline rules and the fail-closed policy.
- **2026-07-02**: §10 now states the on-device privacy invariant explicitly (snapshots/detection imagery never leave the device); §13 Pull requests states the `develop` target.
- **2026-07-02**: Added `ARCHITECTURE.md` (codebase wiring/map) and referenced it from §2, §3, and the cheat sheet; added a single-test CLI cheat-sheet entry.
- **2026-06-23**: Added Feature Flags guidance (section 3) — gate significant features (login, payments) behind in-source flags now, with a proper flag system deferred to a later PR; plus the iOS payments research summary (StoreKit 2 IAP, not Clerk Billing/Stripe). Made the WhatToTest update mandatory for every PR (section 13).
- **2026-06-11**: Added Core Data model versioning rules (new model version only after the previous one shipped; unreleased versions are edited in place; explicit Xcode-generated mapping models required per released migration step).
- **2026-06-11**: Branch naming now documents the issue-key segment (`<type>/AIA-XXXX/desc`) matching actual practice; removed the stale Intel/x86_64 Xcode Cloud claim; cheat-sheet `xcodebuild` example no longer hardcodes a simulator model.
- **2026-01-03**: Added Harmonize architectural linting (section 7), updated section numbering.
- **2026-01-03**: Reorganized document, added Quick Reference, expanded sections (Security/Secrets, Performance, Code Review, Dependencies, Assets), merged anti-patterns, and added cross-references to existing docs.

### Rules for changing this file

- If you find an instruction that is no longer relevant, propose an update. Do not change these guidelines without user approval.
- If you solve a complex problem, suggest adding a brief guideline here to help future contributors and agents.

---
Use these guidelines to make decisions. If a user request conflicts with these guidelines, politely point it out and suggest the better path.
