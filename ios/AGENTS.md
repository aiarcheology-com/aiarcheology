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
- When adding strings:
  - Prefer string keys managed by the project's localization tooling (see generated `L10n.swift` usage patterns).
  - Handle pluralization using `.stringsdict`-style plural rules via xcstrings where applicable.
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
- Build and run unit tests (prefer the scheme's test plans).
  - Xcode: run via the `MLBrowser` scheme and select the test plan.
  - CLI example (choose an available simulator destination on your machine):

```bash
xcodebuild -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser -testPlan MLBrowserUnitTests test
```

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

## 16. Version History & Evolving These Guidelines

### Changelog

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
