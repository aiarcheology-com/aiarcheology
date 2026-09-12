# Build-Time Backend Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decide which backend a build talks to — Clerk instance *and* findings Worker, as one inseparable pair — once at build time, so the two can never disagree.

**Architecture:** One build setting, `AIA_BACKEND_ENVIRONMENT` (`development` | `production`), reaches the app twice from the same source: as a Swift compilation condition (so an invalid value is a *compile* error and the resolved value is non-optional) and as an `Info.plist` string (so build artifacts can be asserted about from shell). One type, `BackendEnvironment`, is the only reader. Both `ClerkAuthProvider.publishableKey` and `FindingsCloudEndpoint.baseURL` go through it. The runtime distribution-channel inference that used to pick the Clerk instance is removed from that path entirely.

**Tech Stack:** Swift 6 / SwiftUI, Xcode build settings + `SWIFT_ACTIVE_COMPILATION_CONDITIONS` + Info.plist `$(VAR)` substitution, `xcodebuild`, zsh/bash delivery and Xcode Cloud scripts, XCTest, UIKit (one overlay window).

**Spec:** This document is self-contained; the "Spec" section below is normative. Ticket: AIA-0791.

**Provenance:** Drafted, then hardened over three rounds against a grill-master subagent. Objections that changed the design are recorded in "Concession log" at the end; risks both sides agreed to accept are in "Accepted-risk register". Do not quietly re-litigate those — they were argued and settled.

---

## Spec

### The defect this replaces

`ClerkAuthProvider.publishableKey` picks the Clerk instance from `AppEnvironment.isAppStoreDistribution`. `FindingsSyncCoordinator` picks the Worker from `ClerkAuthProvider.selectedEnvironment`, a `UserDefaults` value that defaults to `.development` and that `switchEnvironment` **refuses to write when `isAppStoreDistribution` is true**. So on any build classified as App Store, Clerk is production and the Worker is staging. Staging pins the issuer `advanced-tetra-5.clerk.accounts.dev`; the token says `clerk.aiarcheology.com`; `jwtVerify` rejects it and every request is a 401 `unauthorized`.

Confirmed on the reporter's machine (1.0.8 build 1005, iOS-app-on-Mac):

- `/Applications/ML Browser.app` contains **no receipt file and no `embedded.mobileprovision`**, so `AppEnvironment.distributionChannel` reaches its fail-closed `return .appStore` (`AppEnvironment.swift:185`).
- The app's `UserDefaults` plist contains **no `clerk.selectedEnvironment` key**, so the Worker resolved to staging.
- 34 × `Findings sync stopped: unauthorized` in the decrypted support log, one per cycle, from first launch onward.

The same split hits a genuine App Store install (receipt named `receipt` → `.appStore` → same desync), so cloud sync would be dead for every paying user. That is the release-blocking part.

### Product decision this encodes

**TestFlight builds now run against the production backend by default.** This is the human owner's explicit call, not a side effect: *"by default each testflight will be like a production build… only production, not flaky logic."* The reasoning is that a TestFlight build is a release candidate, and the configuration it ships with is the one that has to be exercised before it ships — under the old policy the archive promoted to the App Store had never had its production path run by anyone.

Consequences, all accepted:

- Every existing tester is signed into the **development** Clerk instance. The new build does not configure that instance, so their first launch lands them **signed out**. Task 7 verifies that path reaches a clean signed-out state rather than a wedged cached client.
- Tester findings now go to the **production** R2 bucket and D1 database, under real production accounts.
- Tester traffic now spends the production R2 allowance, which is account-wide, shared with real users, and billed on daily peak. `--execution-environment development` exists for heavy test cycles.

### Requirements

1. The Clerk instance and the findings Worker are chosen from **one** value. It must be impossible to express a mismatched pair.
2. That value is fixed **at build time**. No runtime inference from receipts, provisioning profiles, or `UserDefaults` decides it — in a shipping build or anywhere else.
3. An unset or unrecognized value **fails the build**. No runtime fallback in either direction: production→development is this defect; development→production writes test data into the production R2 bucket under real accounts.
4. Xcode Cloud archives are **always** `production`, with no configuration outside the repository, and an assertion on the produced artifact rather than on intent.
5. `scripts/deliver.sh` defaults to `production`, accepts `--execution-environment development|production`, and **refuses to upload** a non-production build without a second explicit flag.
6. A local Xcode build (simulator, device, or Mac) can be pointed at production **deliberately** — and says so, visibly, for the entire runtime, on every screen including presented sheets.
7. Distribution-channel inference is removed from every decision about which backend holds user data, and is **not introduced anywhere new** — including the production banner. Its remaining consumers are out of scope for this ticket and are **not** all cosmetic: besides Settings' debug section, Sentry sampling and StoreKit sandbox detection, `DataController.swift:67` uses it to decide Core Data mapping-model inference and `DataController.swift:238` to gate destructive store-destruction recovery. Those are pre-existing and load-bearing; this plan neither fixes nor worsens them, and the earlier claim that the inference "only decides cosmetic things" was wrong. Raise them separately if they matter.

### Resolution order (highest wins)

| Source | Applies to |
|-|-|
| `#if DEBUG` runtime override | Debug builds only; compiled out of Release |
| `xcodebuild … AIA_BACKEND_ENVIRONMENT=…` | `deliver.sh`, manual command-line builds |
| Target build settings: `Debug = development`, `Release = production` | Xcode, Xcode Cloud, everything else |

Xcode Cloud only ever archives under Release and cannot pass a command-line override, so requirement 4 holds with zero Xcode Cloud configuration.

### Explicitly considered and rejected

- **A `Debug-Production` build configuration.** Adds a third configuration to every target in `project.pbxproj` and to every script naming a configuration. The `#if DEBUG` override plus a command-line override covers the same need with a far smaller diff.
- **An Xcode Cloud environment variable.** Lives outside git, invisible in review, can be edited or forgotten. Per-configuration build settings need no such thing.
- **Putting the setting in `Secrets.xcconfig`.** That file is generated wholesale in two places (`ProjectTool secrets refresh`, `ci_scripts/ci_pre_xcodebuild.sh`) and is the single `baseConfigurationReference` for both configurations. Anything added there must be added to both generators or it silently vanishes on one path. It is also not a secret.
- ~~**A Run Script phase validating the setting.**~~ **Rejected, then reinstated — the rejection rested on a false premise.** `#error` does *not* catch every invalid value, because Xcode treats `SWIFT_ACTIVE_COMPILATION_CONDITIONS` as a **whitespace-separated list**. Verified by running `xcodebuild -showBuildSettings` with `AIA_BACKEND_ENVIRONMENT='development production'`:

  ```
  AIA_BACKEND_ENVIRONMENT = development production
  SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG AIA_BACKEND_ENV_development production
  ```

  `AIA_BACKEND_ENV_development` is defined, so the `#elseif` branch compiles and the build **silently succeeds as development**. Any value whose first word is `development` or `production` defeats the compile guard. The Run Script phase is therefore a genuine second guard on a different failure mode — exact-value validation, which the compilation condition structurally cannot do — and Task 1 reinstates it.
- **A unit test parsing `project.pbxproj` to assert the Release value.** Asserts about a configuration the test process is not running under, string-matches a file Xcode may reformat, and adds no coverage the two artifact assertions lack.
- **An `AIA_DISTRIBUTION_BUILD` marker to drive the banner without `#if DEBUG`.** Would buy the local-Release case at the cost of a third build setting, a generator edit, another `deliver.sh` passthrough and another assertion. Local Release builds in this project go through `deliver.sh`, which archives. Registered as an accepted risk instead.

### Global Constraints

- Build setting name: `AIA_BACKEND_ENVIRONMENT`. Values: exactly `development` or `production`, lowercase.
- Info.plist key: `BackendEnvironment`, in `ios/MLBrowser-Info.plist`.
- Worker base URLs unchanged: development → `https://aia-findings-staging.vladimir-slavik.workers.dev`, production → `https://aia-findings-production.vladimir-slavik.workers.dev`.
- Clerk keys unchanged: development → `ClerkPublishableKey` (`pk_test_…`), production → `ClerkPublishableKeyLive` (`pk_live_…`).
- The client says `development` where the Worker's `wrangler.jsonc` says `staging`. Keep the client vocabulary; the mapping is written down once, in `FindingsCloudEndpoint`.
- **`SWIFT_ACTIVE_COMPILATION_CONDITIONS` must always be written with `$(inherited)`.** The project-level Debug definition is `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;` with no `$(inherited)` (`project.pbxproj:2524`), and the app target currently defines none. A target-level definition written without `$(inherited)` **silently removes `DEBUG` from the app module** — taking `MockAuthProvider` (and therefore every `UI_TESTING` run), `DataController.swift:76`, `AppEnvironment.swift:204,226` and the Sentry tag with it, while compiling clean.
- New test files **must** be added to the `MLBrowserUnitTests` target in `ios/MLBrowser.xcodeproj/project.pbxproj`. A file that is not in the target produces `TEST SUCCEEDED` with zero tests run.
- Clerk keys are **absent** in non-archive CI builds by design (`ci_pre_xcodebuild.sh:65-84`, "keeps the test workflows hermetic"). No unconditional test may assume `testKey`/`liveKey` are non-empty.
- Run the suite with `./scripts/unittest.sh`. Do not pre-filter its output.
- `scripts/deliver.sh` requires a subcommand (`main()` at `:843-849`); `--dry-run` additionally requires `--build-number` (`:882-884`). `deliver.sh selftest` runs a `--dry-run` child and **requires exit 0** (`:801-806`).
- The archive is at `build/delivery/MLBrowser.xcarchive`; the export product is an **`.ipa`**, not an unpacked `.app` (`:57`, `:563-568`).
- Do not create a `release/*` branch at any point — that fires the paid Xcode Cloud Release workflow.

---

## File Structure

| File | Responsibility |
|-|-|
| `ios/MLBrowser/iOS/Tools/BackendEnvironment.swift` | **New.** The enum and the compile-time resolution. The only place the build-time value is interpreted. |
| `ios/MLBrowser/iOS/Tools/ProductionBannerWindow.swift` | **New.** The `#if DEBUG` passthrough overlay window and its scene wiring. One responsibility, so the UIKit escape hatch is contained. |
| `ios/MLBrowser-Info.plist` | **Modify.** Adds `BackendEnvironment` → `$(AIA_BACKEND_ENVIRONMENT)`. |
| `ios/MLBrowser.xcodeproj/project.pbxproj` | **Modify.** `AIA_BACKEND_ENVIRONMENT` and `SWIFT_ACTIVE_COMPILATION_CONDITIONS` per configuration on the app target; new files added to their targets. |
| `ios/MLBrowser/iOS/State/ClerkAuthProvider.swift` | **Modify.** `publishableKey` reads `BackendEnvironment`. `ClerkEnvironment`, `selectedEnvironment`, `switchEnvironment`, `environmentDefaultsKey` deleted. |
| `ios/MLBrowser/iOS/Services/FindingsCloudTransport.swift` | **Modify.** `FindingsCloudEndpoint.baseURL(for:)` takes a `BackendEnvironment` and is non-optional-friendly. |
| `ios/MLBrowser/iOS/State/FindingsSyncCoordinator.swift` | **Modify.** Three call sites read `BackendEnvironment.current`. |
| `ios/MLBrowser/iOS/UI/Auth/SignInSheet.swift` | **Modify.** The picker becomes `#if DEBUG`, keeps both existing guards, drives `BackendEnvironment.override`. |
| `ios/MLBrowser/iOS/UI/MLBrowser.swift` | **Modify.** Logs the environment at launch; installs the banner window. |
| `ios/MLBrowserUnitTests/BackendEnvironmentTests.swift` | **New.** The pairing invariant, the mapping, and the `DEBUG`-still-defined tripwire. |
| `scripts/deliver.sh` | **Modify.** `--execution-environment`, `--allow-staging-upload`, passthrough, archive assertion, `WhatToTest` prefix, summary. |
| `ios/ci_scripts/ci_post_xcodebuild.sh` | **Modify.** Archive builds must be `production`. |
| `ios/ci_scripts/ci_pre_xcodebuild.sh` | **Modify.** Comments at `:12` and `:68-72` currently assert what this change makes false. |
| `AUTH-SUBSCRIPTION.md`, `USER_DATA_PERSISTENCE.md` | **Modify.** Document the build-time rule; `:288` describes `baseURL(for:)` in the old vocabulary. |

---

## Task 1: `BackendEnvironment`, resolved at compile time

**Files:**
- Create: `ios/MLBrowser/iOS/Tools/BackendEnvironment.swift`
- Create: `ios/MLBrowserUnitTests/BackendEnvironmentTests.swift`
- Modify: `ios/MLBrowser-Info.plist`
- Modify: `ios/MLBrowser.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum BackendEnvironment: String, CaseIterable, Sendable { case development, production }`
  - `static let BackendEnvironment.configured: BackendEnvironment` — **non-optional**, compile-time.
  - `@MainActor static var BackendEnvironment.current: BackendEnvironment` — **non-optional**.
  - `#if DEBUG @MainActor static var BackendEnvironment.override: BackendEnvironment?`
  - `static let BackendEnvironment.infoDictionaryKey = "BackendEnvironment"` — for artifact assertions and diagnostics only; never the source of truth.

- [ ] **Step 1: Write the failing test**

Create `ios/MLBrowserUnitTests/BackendEnvironmentTests.swift`:

```swift
//
//  BackendEnvironmentTests.swift
//  MLBrowserUnitTests
//

import XCTest
@testable import ML_Browser

final class BackendEnvironmentTests: XCTestCase {

    /// The unit suite compiles against the app module in Debug. If this fails, a target-level
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` was written without `$(inherited)` and `DEBUG` has
    /// been dropped from the app module — which also removes `MockAuthProvider` and silently
    /// flips `DataController` and StoreKit sandbox detection, while compiling clean.
    func test_debugFlagSurvivesTheCompilationConditionChange() {
        XCTAssertTrue(AppEnvironment.isDebugConfiguration)
    }

    /// Environment-**neutral** on purpose. Asserting `configured == .development` would only ever
    /// exercise the Debug branch, because tests run in Debug — so a `#if AIA_BACKEND_ENV_production`
    /// branch that mistakenly said `.development` would pass here *and* pass both archive
    /// assertions, which read the independently expanded plist string rather than the compiled
    /// value. This compares the two expansions of the one setting against each other, so it is
    /// meaningful under either. Step 9 runs it a second time with the production value.
    func test_compiledValueMatchesTheInfoPlistValue() throws {
        let raw = Bundle(for: ClerkAuthProvider.self)
            .object(forInfoDictionaryKey: BackendEnvironment.infoDictionaryKey) as? String
        try XCTSkipIf(raw == nil, "App bundle carries no BackendEnvironment key.")
        XCTAssertEqual(
            raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            BackendEnvironment.configured.rawValue,
            "The compilation condition and the Info.plist disagree — they expand from one setting, so one consumer was edited by hand."
        )
    }
}
```

- [ ] **Step 2: Add the test file to the `MLBrowserUnitTests` target**

In Xcode, select `BackendEnvironmentTests.swift` → File Inspector → tick **MLBrowserUnitTests**. Verify:

```bash
grep -c "BackendEnvironmentTests.swift" ios/MLBrowser.xcodeproj/project.pbxproj
```

Expected: `4` or more. If `0`, the membership did not save and every test below silently will not run.

- [ ] **Step 3: Run the test to verify it fails**

```bash
./scripts/unittest.sh 2>&1 | tail -40
```

Expected: compilation failure — `cannot find 'BackendEnvironment' in scope`.

- [ ] **Step 4: Write the implementation**

Create `ios/MLBrowser/iOS/Tools/BackendEnvironment.swift`:

```swift
//
//  BackendEnvironment.swift
//  AI Archeology
//
//  Which backend a build talks to, decided once at build time (AIA-0791).
//

import Foundation

/// The backend a build talks to: a **pair** of a Clerk instance and a findings Worker.
///
/// The pair is the whole point. Each Worker pins exactly one Clerk issuer, so a build that signs
/// in against one instance and uploads to the other Worker is refused on every request. That is
/// what shipped in 1.0.8 build 1005: the Clerk key was chosen from the distribution channel and
/// the Worker from a `UserDefaults` value that App-Store-classified builds could never write, so
/// they disagreed permanently and cloud sync was dead.
///
/// Fixed at **build time** from `AIA_BACKEND_ENVIRONMENT`, never inferred at runtime.
/// `AppEnvironment.distributionChannel` is not reliable enough to carry a decision about where a
/// user's data lives: an iOS-app-on-Mac install has no receipt at that path at all, and an iPhone
/// restored from backup has none until `SKReceiptRefreshRequest` completes. It stays in use for
/// decisions whose failure mode is cosmetic.
enum BackendEnvironment: String, CaseIterable, Sendable {
    case development
    case production
}

extension BackendEnvironment {

    /// The `Info.plist` key carrying `$(AIA_BACKEND_ENVIRONMENT)`.
    ///
    /// Diagnostics and artifact assertions only — `deliver.sh` and `ci_post_xcodebuild.sh` read it
    /// from a built `.app` where no Swift runs. It is never the source of truth in the app; that
    /// is `configured` below. Both are expansions of the same build setting, so they cannot drift.
    static let infoDictionaryKey = "BackendEnvironment"

    /// What the binary was built for.
    ///
    /// Non-optional by construction: an unset, misspelled or non-identifier value defines neither
    /// compilation condition and the `#else` below fails the build. There is deliberately no
    /// runtime fallback — falling back to `development` is the defect this replaces, and falling
    /// back to `production` would put test findings in real users' bucket.
    #if AIA_BACKEND_ENV_production
    static let configured: BackendEnvironment = .production
    #elseif AIA_BACKEND_ENV_development
    static let configured: BackendEnvironment = .development
    #else
    #error("AIA_BACKEND_ENVIRONMENT must be set to exactly 'development' or 'production'. See AUTH-SUBSCRIPTION.md, 'Which backend a build talks to'.")
    #endif

    #if DEBUG
    /// Points a Debug build at the other backend without rebuilding, for validating production
    /// from a simulator. `#if DEBUG`, so it cannot exist in TestFlight or App Store builds — the
    /// switcher this replaces was live in Release, which is how the pair came apart.
    ///
    /// `private(set)`: an open setter would let a caller move the Worker while Clerk stayed
    /// configured for the other instance — the exact mismatched pair this ticket removes. The
    /// only way to change it is `switch(to:)`, which reconfigures Clerk first.
    @MainActor private(set) static var override: BackendEnvironment?

    /// Moves both halves of the pair, or neither.
    ///
    /// Returns `false` (and changes nothing) when the target instance's key is missing or the
    /// reconfigure fails. `Clerk.configure` traps on a malformed key in DEBUG
    /// (`ClerkAuthProvider.swift:92-94`), and a local build may legitimately lack the live key.
    @MainActor
    static func `switch`(to environment: BackendEnvironment) async -> Bool {
        let key = ClerkAuthProvider.publishableKey(for: environment)
        guard key.hasPrefix("pk_") else {
            LoggingPolicy.warning(
                "No \(environment.rawValue) Clerk key available — cannot switch backend.",
                logger: .configuration
            )
            return false
        }
        do {
            // Clears the current session, which is required: a session from the other instance is
            // exactly what the other Worker rejects.
            try await Clerk.reconfigure(publishableKey: key)
            override = environment
            // The launch line would otherwise go stale and the support log would contradict the
            // running app — and that log is the only textual record of the environment.
            LoggingPolicy.info("Backend environment: \(environment.rawValue) (switched)", logger: .configuration)
            ProductionBannerWindow.update()
            return true
        } catch {
            LoggingPolicy.error("Clerk reconfigure failed: \(error.localizedDescription)", logger: .configuration)
            return false
        }
    }
    #endif

    /// The environment in force.
    @MainActor static var current: BackendEnvironment {
        #if DEBUG
        if let override { return override }
        #endif
        return configured
    }
}
```

- [ ] **Step 5: Add both build settings to both configurations**

In Xcode, MLBrowser target → Build Settings:

1. `+` → Add User-Defined Setting → `AIA_BACKEND_ENVIRONMENT`. Debug → `development`, Release → `production`.
2. Find **Active Compilation Conditions** (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`) and set it on the **MLBrowser target**, for **both** configurations, to exactly:

```
$(inherited) AIA_BACKEND_ENV_$(AIA_BACKEND_ENVIRONMENT)
```

**`$(inherited)` is not optional.** The project-level Debug value is `DEBUG` with no `$(inherited)` of its own (`project.pbxproj:2524`); omitting it here drops `DEBUG` from the app module and compiles clean. Step 8's first assertion is the tripwire for exactly this.

Verify both landed:

```bash
grep -n "AIA_BACKEND_ENVIRONMENT\|SWIFT_ACTIVE_COMPILATION_CONDITIONS" ios/MLBrowser.xcodeproj/project.pbxproj
```

Expected: the two pre-existing lines (`:2524`, `:2768`) plus four new ones — `AIA_BACKEND_ENVIRONMENT` and `SWIFT_ACTIVE_COMPILATION_CONDITIONS` under each of the app target's Debug and Release blocks. Every new `SWIFT_ACTIVE_COMPILATION_CONDITIONS` line must contain `$(inherited)`.

- [ ] **Step 6: Add the Info.plist key**

In `ios/MLBrowser-Info.plist`, beside the existing `ClerkPublishableKey` entry:

```xml
	<key>BackendEnvironment</key>
	<string>$(AIA_BACKEND_ENVIRONMENT)</string>
```

- [ ] **Step 7: Add the exact-value Run Script phase**

`#error` is **not** sufficient on its own. Xcode treats `SWIFT_ACTIVE_COMPILATION_CONDITIONS` as a whitespace-separated list, so `AIA_BACKEND_ENVIRONMENT="development production"` expands to `DEBUG AIA_BACKEND_ENV_development production` — the `#elseif` branch compiles and the build succeeds silently as development. Only a literal string comparison catches that.

In Xcode, MLBrowser target → Build Phases → `+` → New Run Script Phase, named **Validate backend environment**, dragged above **Compile Sources**. Uncheck **Based on dependency analysis** so it runs every build.

```sh
# Guards the failure mode `#error` structurally cannot: SWIFT_ACTIVE_COMPILATION_CONDITIONS is a
# whitespace-separated LIST, so any value whose first word is 'development' or 'production' still
# defines a valid condition and compiles clean. Only an exact comparison catches that (AIA-0791).
case "${AIA_BACKEND_ENVIRONMENT}" in
    development|production) ;;
    *)
        echo "error: AIA_BACKEND_ENVIRONMENT must be exactly 'development' or 'production', with no extra words (got '${AIA_BACKEND_ENVIRONMENT}')"
        exit 1
        ;;
esac
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
./scripts/unittest.sh > /tmp/aia-unit.log 2>&1; echo "STATUS=$?"
tail -40 /tmp/aia-unit.log
grep -c "BackendEnvironmentTests" /tmp/aia-unit.log
```

Expected: `STATUS=0`, and the grep is greater than `0`. Capture-then-inspect rather than piping: `./scripts/unittest.sh | tail` reports `tail`'s exit status, not the test run's, so a failing suite reads as a pass.

- [ ] **Step 9: Verify BOTH guards fire, on BOTH failure modes**

```bash
cd ios
# (a) A value that is not an identifier at all — caught by #error.
xcodebuild build -workspace MLBrowser.xcworkspace -scheme MLBrowser \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/aia-badenv \
  AIA_BACKEND_ENVIRONMENT=nonsense > /tmp/aia-badenv.log 2>&1; echo "STATUS_A=$?"
grep -c "AIA_BACKEND_ENVIRONMENT must be" /tmp/aia-badenv.log

# (b) A value whose FIRST WORD is valid — #error does NOT fire; only the Run Script catches it.
xcodebuild build -workspace MLBrowser.xcworkspace -scheme MLBrowser \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/aia-badenv2 \
  AIA_BACKEND_ENVIRONMENT='development production' > /tmp/aia-split.log 2>&1; echo "STATUS_B=$?"
grep -c "with no extra words" /tmp/aia-split.log
```

Expected: **both** `STATUS_A` and `STATUS_B` non-zero, and both greps greater than `0`. If `STATUS_B` is `0`, the Run Script phase from Step 7 is not running — that is the case `#error` cannot see, and shipping without it reintroduces a silent wrong-backend build. Then `rm -rf /tmp/aia-badenv /tmp/aia-badenv2`.

- [ ] **Step 10: Verify the production branch actually compiles to production**

Every other check runs in Debug, so a `#if AIA_BACKEND_ENV_production` branch that mistakenly returned `.development` would pass all of them — and both archive assertions read the *plist* string, which is expanded independently and would still say `production`. Run the suite once against the production value:

```bash
cd ios && xcodebuild test -workspace MLBrowser.xcworkspace -scheme MLBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MLBrowserUnitTests/BackendEnvironmentTests \
  AIA_BACKEND_ENVIRONMENT=production > /tmp/aia-prodbranch.log 2>&1; echo "STATUS=$?"
grep -c "compiledValueMatchesTheInfoPlistValue" /tmp/aia-prodbranch.log
```

Expected: `STATUS=0` and the test ran. `test_compiledValueMatchesTheInfoPlistValue` is environment-neutral, so it now compares the *production* compiled branch against the *production* plist value — the only check in the plan that exercises that branch at all.

- [ ] **Step 11: Verify `DEBUG` survived, out of band**

The unit test asserts this, but it runs in the same process that would be broken. Confirm independently that `MockAuthProvider` still compiles into the Debug app module:

```bash
cd ios && xcodebuild build -workspace MLBrowser.xcworkspace -scheme MLBrowser \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/aia-debugflag \
  -showBuildSettings 2>/dev/null | grep "SWIFT_ACTIVE_COMPILATION_CONDITIONS"
```

Expected: the resolved value contains **both** `DEBUG` and `AIA_BACKEND_ENV_development`. If `DEBUG` is missing, `$(inherited)` was dropped — fix Step 5 before continuing.

- [ ] **Step 10: Commit**

```bash
git add ios/MLBrowser/iOS/Tools/BackendEnvironment.swift \
        ios/MLBrowserUnitTests/BackendEnvironmentTests.swift \
        ios/MLBrowser-Info.plist ios/MLBrowser.xcodeproj/project.pbxproj
git commit -m "AIA-0791: resolve the backend environment at compile time"
```

---

## Task 2: Make the Clerk instance and the Worker read one value

**Files:**
- Modify: `ios/MLBrowser/iOS/State/ClerkAuthProvider.swift:12-89`
- Modify: `ios/MLBrowser/iOS/Services/FindingsCloudTransport.swift:123-141`
- Modify: `ios/MLBrowser/iOS/State/FindingsSyncCoordinator.swift:114,600,1161`
- Modify: `ios/MLBrowser/iOS/UI/Auth/SignInSheet.swift:25,33-36,86-102`
- Test: `ios/MLBrowserUnitTests/BackendEnvironmentTests.swift`

**Interfaces:**
- Consumes: `BackendEnvironment.current`, `BackendEnvironment.configured` from Task 1.
- Produces:
  - `nonisolated static func ClerkAuthProvider.publishableKey(for:testKey:liveKey:) -> String` — pure, the hermetic seam.
  - `static var ClerkAuthProvider.publishableKey: String` — `@MainActor`, resolves via `BackendEnvironment.current`.
  - `nonisolated static var ClerkAuthProvider.testKey: String`, `.liveKey: String` — made internal so tests can skip when they are empty.
  - `static func FindingsCloudEndpoint.baseURL(for: BackendEnvironment) -> URL?`
  - `enum ClerkEnvironment`, `selectedEnvironment`, `switchEnvironment(to:)`, `environmentDefaultsKey` **no longer exist**.

- [ ] **Step 1: Write the failing pairing tests**

Append to `ios/MLBrowserUnitTests/BackendEnvironmentTests.swift`:

```swift
// MARK: - The pairing invariant

/// Each findings Worker pins exactly one Clerk issuer, so the Clerk key and the Worker URL must
/// move together. These fail if anyone reintroduces a second source of truth.
extension BackendEnvironmentTests {

    // The mapping, tested hermetically. Non-archive CI builds deliberately ship no Clerk keys
    // (ci_pre_xcodebuild.sh:65-84, "keeps the test workflows hermetic"), so the assertion that
    // matters must not depend on them.
    private static let testFixture = "pk_test_FIXTURE"
    private static let liveFixture = "pk_live_FIXTURE"

    func test_development_mapsToTheTestInstance() {
        XCTAssertEqual(
            ClerkAuthProvider.publishableKey(for: .development, testKey: Self.testFixture, liveKey: Self.liveFixture),
            Self.testFixture
        )
    }

    func test_production_mapsToTheLiveInstance() {
        XCTAssertEqual(
            ClerkAuthProvider.publishableKey(for: .production, testKey: Self.testFixture, liveKey: Self.liveFixture),
            Self.liveFixture
        )
    }

    func test_everyEnvironmentMapsToADistinctInstance() {
        // Catches the "both cases return the same thing" mutation, which the two above survive.
        let keys = BackendEnvironment.allCases.map {
            ClerkAuthProvider.publishableKey(for: $0, testKey: Self.testFixture, liveKey: Self.liveFixture)
        }
        XCTAssertEqual(Set(keys).count, BackendEnvironment.allCases.count)
    }

    func test_development_usesTheStagingWorker() {
        XCTAssertEqual(
            FindingsCloudEndpoint.baseURL(for: .development)?.host(),
            "aia-findings-staging.vladimir-slavik.workers.dev"
        )
    }

    func test_production_usesTheProductionWorker() {
        XCTAssertEqual(
            FindingsCloudEndpoint.baseURL(for: .production)?.host(),
            "aia-findings-production.vladimir-slavik.workers.dev"
        )
    }

    func test_everyEnvironmentUsesADistinctWorker() {
        let hosts = BackendEnvironment.allCases.compactMap { FindingsCloudEndpoint.baseURL(for: $0)?.host() }
        XCTAssertEqual(Set(hosts).count, BackendEnvironment.allCases.count)
    }

    /// The real keys, when this build has them. Skipped rather than failed on hermetic CI builds.
    ///
    /// The prefix alone is not enough: a `pk_live_` key for the *wrong* Clerk instance has the
    /// right prefix and still produces a 401 against the Worker, which pins an exact issuer.
    /// A Clerk publishable key is `pk_(test|live)_` + base64 of the frontend API host with a
    /// trailing `$` — verified against the checked-in keys, which decode to
    /// `advanced-tetra-5.clerk.accounts.dev$` and `clerk.aiarcheology.com$`. So the key can be
    /// checked against the issuer the Worker actually pins, which is the property that matters.
    func test_realKeysBelongToTheInstanceTheWorkerPins() throws {
        try XCTSkipIf(
            ClerkAuthProvider.testKey.isEmpty || ClerkAuthProvider.liveKey.isEmpty,
            "This build ships no Clerk keys (non-archive CI action)."
        )
        XCTAssertEqual(Self.clerkHost(of: ClerkAuthProvider.testKey), "advanced-tetra-5.clerk.accounts.dev")
        XCTAssertEqual(Self.clerkHost(of: ClerkAuthProvider.liveKey), "clerk.aiarcheology.com")
    }

    /// Decodes the frontend API host a publishable key points at. Never log the key itself.
    private static func clerkHost(of key: String) -> String? {
        let body = key
            .replacingOccurrences(of: "pk_test_", with: "")
            .replacingOccurrences(of: "pk_live_", with: "")
        // Clerk omits base64 padding; Foundation requires it.
        let padded = body.padding(
            toLength: body.count + (4 - body.count % 4) % 4,
            withPad: "=",
            startingAt: 0
        )
        guard let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded.hasSuffix("$") ? String(decoded.dropLast()) : decoded
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./scripts/unittest.sh 2>&1 | tail -40
```

Expected: compilation failure — `publishableKey(for:testKey:liveKey:)` does not exist and `baseURL(for:)` still takes a `ClerkEnvironment`.

- [ ] **Step 3: Rewrite the environment surface of `ClerkAuthProvider`**

In `ios/MLBrowser/iOS/State/ClerkAuthProvider.swift`, **delete** the `ClerkEnvironment` enum (lines 12-18), the `environmentDefaultsKey` constant, the `selectedEnvironment` property and the whole `switchEnvironment(to:)` method. Change `testKey` and `liveKey` from `private static let` to `nonisolated static let` so the pure seam and the skip-guard can read them. Replace the `publishableKey` block with:

```swift
    /// The Clerk publishable key for an environment. Pure and injectable, so the pairing with the
    /// findings Worker is testable without a bundle — non-archive CI builds ship no Clerk keys.
    nonisolated static func publishableKey(
        for environment: BackendEnvironment,
        testKey: String = ClerkAuthProvider.testKey,
        liveKey: String = ClerkAuthProvider.liveKey
    ) -> String {
        switch environment {
        case .development: return testKey
        case .production: return liveKey
        }
    }

    /// The key for the environment in force. Non-optional: `BackendEnvironment` cannot be
    /// unresolved, because an invalid `AIA_BACKEND_ENVIRONMENT` fails the build (AIA-0791).
    static var publishableKey: String {
        publishableKey(for: BackendEnvironment.current)
    }
```

`configure()` keeps its existing `hasPrefix("pk_")` guard unchanged — it now catches a missing key rather than a missing environment, which is still the right refusal.

- [ ] **Step 4: Repoint `FindingsCloudEndpoint`**

In `ios/MLBrowser/iOS/Services/FindingsCloudTransport.swift`:

```swift
/// The findings Worker, per environment.
///
/// The base URL is paired with the Clerk instance deliberately: each Worker trusts exactly one
/// Clerk issuer, so a build signing in against the other instance is rejected rather than served.
/// Both halves of that pair now come from `BackendEnvironment`, which is fixed at build time —
/// they used to come from two different places and disagreed on every App Store build (AIA-0791).
///
/// The Worker's own configuration calls the development environment "staging"; this is the one
/// place the two vocabularies meet.
enum FindingsCloudEndpoint {
    static func baseURL(for environment: BackendEnvironment) -> URL? {
        switch environment {
        case .development:
            return URL(string: "https://aia-findings-staging.vladimir-slavik.workers.dev")
        case .production:
            return URL(string: "https://aia-findings-production.vladimir-slavik.workers.dev")
        }
    }
}
```

- [ ] **Step 5: Repoint the three coordinator call sites**

In `ios/MLBrowser/iOS/State/FindingsSyncCoordinator.swift`. Line 114:

```swift
        FindingsCloudEndpoint.baseURL(for: BackendEnvironment.current) != nil
```

Lines 600 and 1161:

```swift
        guard let baseURL = FindingsCloudEndpoint.baseURL(for: BackendEnvironment.current) else {
```

Leave the existing `else` bodies and their comments untouched — a `nil` URL still means "sync is off rather than pointed somewhere wrong".

- [ ] **Step 6: Take the live switcher out of `SignInSheet`**

In `ios/MLBrowser/iOS/UI/Auth/SignInSheet.swift`, delete the `clerkEnv` state, the `showEnvironmentSwitch` computed property and the `Picker` block. It returns in Task 3 under `#if DEBUG`. Update the type doc comment (lines 18-20):

```swift
/// The dev/prod instance picker the old root screen had is gone from shipping builds: the backend
/// is fixed at build time (AIA-0791). A Debug build still offers it — see the `#if DEBUG` block.
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
./scripts/unittest.sh 2>&1 | tail -40
```

Expected: PASS, including all six pairing tests. `test_realKeysCarryTheExpectedInstancePrefixes` passes locally (Secrets.xcconfig has both keys) and skips on hermetic CI.

- [ ] **Step 8: Mutation-check the pairing tests**

Temporarily change `FindingsCloudEndpoint.baseURL(for:)` so `.production` returns the staging URL — the exact shape of the shipped defect:

```bash
./scripts/unittest.sh 2>&1 | grep -E "test_production_usesTheProductionWorker|test_everyEnvironmentUsesADistinctWorker"
```

Expected: both **fail**. Then make `publishableKey(for:)` return `testKey` in both cases and confirm `test_production_mapsToTheLiveInstance` and `test_everyEnvironmentMapsToADistinctInstance` fail. Revert both and re-run. A pairing test that survives these mutations is not testing the pairing.

- [ ] **Step 9: Verify nothing still references the deleted symbols**

```bash
cd /Users/vladimircortesslavik/Development/aiarcheology && \
  grep -rn "selectedEnvironment\|switchEnvironment\|ClerkEnvironment" ios --include='*.swift'
```

Expected: no output.

- [ ] **Step 10: Commit**

```bash
git add ios/MLBrowser/iOS/State/ClerkAuthProvider.swift \
        ios/MLBrowser/iOS/Services/FindingsCloudTransport.swift \
        ios/MLBrowser/iOS/State/FindingsSyncCoordinator.swift \
        ios/MLBrowser/iOS/UI/Auth/SignInSheet.swift \
        ios/MLBrowserUnitTests/BackendEnvironmentTests.swift
git commit -m "AIA-0791: pair the Clerk instance and the findings Worker on one value"
```

---

## Task 3: The production banner, for the whole runtime

**Files:**
- Create: `ios/MLBrowser/iOS/Tools/ProductionBannerWindow.swift`
- Modify: `ios/MLBrowser/iOS/UI/MLBrowser.swift:242` and the root view body
- Modify: `ios/MLBrowser.xcodeproj/project.pbxproj` (new file → MLBrowser target)

**Interfaces:**
- Consumes: `BackendEnvironment.current` from Task 1.
- Produces: `#if DEBUG @MainActor enum ProductionBannerWindow { static func install() }`

A `safeAreaInset` or an `.overlay` on the root view is **not** sufficient and must not be used: it does not render over `.sheet` or `.fullScreenCover`, and Settings, the paywall, account deletion and "Remove all findings" are all presented that way — the banner would vanish exactly where the destructive actions live. A separate window is the only way to satisfy requirement 6.

- [ ] **Step 1: Write the banner window**

Create `ios/MLBrowser/iOS/Tools/ProductionBannerWindow.swift`:

```swift
//
//  ProductionBannerWindow.swift
//  AI Archeology
//
//  "You are pointed at production" — for the whole runtime, on every screen (AIA-0791).
//

#if DEBUG
import UIKit
import SwiftUI
import ClerkKit

/// A passthrough overlay window carrying a red strip whenever a Debug build is pointed at the
/// production backend.
///
/// A window rather than a view modifier because the warning has to survive `.sheet` and
/// `.fullScreenCover` — every destructive action in the app (account deletion, Remove All
/// Findings, sign-out) is presented that way, so a root-view banner would disappear at exactly
/// the moment it matters.
///
/// `#if DEBUG` is the gate rather than any distribution-channel inference: requirement 2 of
/// AIA-0791 forbids introducing new receipt or provisioning-profile inference, and neither can be
/// verified for an iOS-app-on-Mac Xcode run. Xcode's Run action is Debug on simulator, device and
/// Mac alike, which is the case this is for. A local *Release* build shows no banner; see the
/// accepted-risk register.
@MainActor
enum ProductionBannerWindow {

    private static var windows: [ObjectIdentifier: UIWindow] = [:]

    /// Call once, at app launch. Idempotent per scene.
    static func install() {
        NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let scene = notification.object as? UIWindowScene else { return }
                attach(to: scene)
            }
        }
        update()
    }

    /// Re-evaluates every scene. Called at launch and after `BackendEnvironment.switch(to:)`.
    ///
    /// Without this the banner would only ever reflect the environment at *scene connect* — a
    /// picker flip to production would show nothing, and a flip back would leave a stale red
    /// strip claiming production while the app talked to staging.
    static func update() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            attach(to: scene)
        }
    }

    /// One window per scene: iPad multiwindow, Mac and external displays each get their own, and a
    /// single window would warn on only one of them.
    private static func attach(to scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard BackendEnvironment.current == .production else {
            // Tear down rather than merely skipping, so a switch back to development clears it.
            windows[key]?.isHidden = true
            windows.removeValue(forKey: key)
            return
        }
        guard windows[key] == nil else { return }

        let window = UIWindow(windowScene: scene)
        // Above alerts and confirmation dialogs, which present in their own alert-level window.
        window.windowLevel = .alert + 1
        // Passthrough: without this the strip eats taps, including status-bar tap-to-scroll.
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        window.rootViewController = UIHostingController(rootView: ProductionBanner())
        window.rootViewController?.view.backgroundColor = .clear
        // Never makeKeyAndVisible: that would steal key-window and keyboard focus from the app.
        window.isHidden = false
        windows[key] = window
    }
}

private struct ProductionBanner: View {
    var body: some View {
        VStack {
            Text(verbatim: "PRODUCTION — \(Self.accountLabel)")
                .font(.caption2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(.red)
                .foregroundStyle(.white)
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The Clerk **user id**, truncated — never the email address. A full-runtime overlay is in
    /// every screen recording, demo and bug-report screenshot, which makes it more exposed than
    /// the share card `ClerkAuthProvider.nameUnlessItIsAnAddress` exists to protect.
    ///
    /// `Clerk.shared` is touched **only** on the real-auth path: the mock-auth path deliberately
    /// never calls `ClerkAuthProvider.configure()` (`MLBrowser.swift:229`), and reading
    /// `Clerk.shared` when Clerk was never configured **traps with SIGILL**
    /// (`DependencyContainer.swift:105`). A crash from the safety banner would be a poor joke.
    private static var accountLabel: String {
        guard DependencyContainer.shared.usesMockAuth == false else { return "mock auth" }
        guard let id = Clerk.shared.user?.id else { return "signed out" }
        return String(id.prefix(8)) + "…"
    }
}
#endif
```

`Text(verbatim:)` throughout: this is a developer warning, not user-facing copy, and must not enter the localisation catalogue.

- [ ] **Step 2: Install it and log the environment at launch**

In `ios/MLBrowser/iOS/UI/MLBrowser.swift`, immediately after the existing `MLBrowser app launching` line:

```swift
		// Answers "which Worker did this build talk to?" from a support log alone. Diagnosing
		// AIA-0791 needed a decrypted log plus three source files to answer it.
		LoggingPolicy.info(
			"Backend environment: \(BackendEnvironment.current.rawValue)",
			logger: .configuration
		)
		#if DEBUG
		ProductionBannerWindow.install()
		#endif
```

- [ ] **Step 3: Add the file to the MLBrowser target and build**

In Xcode, tick **MLBrowser** for `ProductionBannerWindow.swift`. Then:

```bash
./scripts/unittest.sh 2>&1 | tail -20
```

Expected: PASS (no behaviour under test changed).

- [ ] **Step 4: Verify the banner survives a sheet — the whole point**

Run on a simulator from Xcode. It starts on `development`, so no banner. Then flip to production **using the Task 4 picker** — implement Task 4 first if working strictly in order. Do **not** assign `BackendEnvironment.override` by hand to shortcut this: the setter is `private(set)` precisely because a direct assignment moves the Worker while leaving Clerk configured for the other instance, which is the mismatched pair this ticket removes. Confirm **all** of:

- The red strip is visible on the browser screen.
- It is **still visible** with Settings open (a sheet).
- It is **still visible** with the paywall open (a full-screen cover).
- It is **still visible** with the "Delete All Findings" confirmation dialog on screen.
- Tapping through the strip's area reaches the view beneath it (drag the top of a scroll view).
- The keyboard still works and text fields still take focus.

Any "no" here means the window level, `isUserInteractionEnabled`, or `isHidden` handling is wrong — fix before continuing.

- [ ] **Step 5: Verify multiwindow**

On an iPad simulator, open a second window of the app (drag from the dock). Expected: the strip appears in **both** windows. If only one, `attach(to:)` is not being reached from `willConnectNotification`.

- [ ] **Step 6: Commit**

```bash
git add ios/MLBrowser/iOS/Tools/ProductionBannerWindow.swift \
        ios/MLBrowser/iOS/UI/MLBrowser.swift \
        ios/MLBrowser.xcodeproj/project.pbxproj
git commit -m "AIA-0791: full-runtime banner when a Debug build is on production"
```

---

## Task 4: The Debug-only picker, with both guards intact

**Files:**
- Modify: `ios/MLBrowser/iOS/UI/Auth/SignInSheet.swift`

**Interfaces:**
- Consumes: `BackendEnvironment.override`, `ClerkAuthProvider.publishableKey(for:)` from Tasks 1-2.
- Produces: no new API.

- [ ] **Step 1: Restore the picker**

In `ios/MLBrowser/iOS/UI/Auth/SignInSheet.swift`, add the state beside the other `@State` properties:

```swift
	#if DEBUG
	@State private var debugEnvironment: BackendEnvironment = BackendEnvironment.current
	#endif
```

and inside the button `VStack`:

```swift
					#if DEBUG
					// Debug builds only, so it cannot ship. Drives the single value both the Clerk
					// key and the findings Worker read, so the pair cannot come apart (AIA-0791).
					//
					// `usesRealAuth` is kept from the code this replaces: on the mock path Clerk is
					// never configured, and reconfiguring it there is meaningless.
					if usesRealAuth {
						Picker(L10n.Auth.Environment.title, selection: $debugEnvironment) {
							Text(L10n.Auth.Environment.development).tag(BackendEnvironment.development)
							Text(L10n.Auth.Environment.production).tag(BackendEnvironment.production)
						}
						.pickerStyle(.segmented)
						.onChange(of: debugEnvironment) { _, newEnvironment in
							Task { await switchBackend(to: newEnvironment) }
						}
						.accessibilityLabel(Text(L10n.Auth.Environment.title))
					}
					#endif
```

and the handler:

```swift
	#if DEBUG
	/// Delegates to the one operation that moves both halves of the pair. The view never assigns
	/// `BackendEnvironment.override` itself — it cannot, the setter is `private(set)` — because an
	/// assignment would move the Worker while Clerk stayed on the other instance, which is exactly
	/// the mismatched pair this ticket exists to make unrepresentable.
	@MainActor
	private func switchBackend(to newEnvironment: BackendEnvironment) async {
		let moved = await BackendEnvironment.switch(to: newEnvironment)
		// Re-sync the control from the truth, so a refused or failed switch does not leave the
		// segmented picker showing an instance the app is not pointed at.
		if moved == false { debugEnvironment = BackendEnvironment.current }
	}
	#endif
```

- [ ] **Step 2: Verify the guards**

```bash
./scripts/unittest.sh 2>&1 | tail -20
```

Expected: PASS.

Then run the app under UI testing to confirm the mock path is unaffected:

```bash
cd ios && xcodebuild test -workspace MLBrowser.xcworkspace -scheme MLBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MLBrowserUITests 2>&1 | tail -30
```

Expected: PASS. This is the consumer that breaks loudest if `usesRealAuth` or `DEBUG` handling is wrong, and the unit suite would not notice.

- [ ] **Step 3: Verify the switch end to end**

Run on a simulator. Open the sign-in sheet, flip the picker to **production**, and confirm: the red banner from Task 3 appears immediately, the support log gains `Backend environment: production (switched)`, and signing in reaches the production Clerk instance. Flip back and confirm the banner disappears.

- [ ] **Step 4: Commit**

```bash
git add ios/MLBrowser/iOS/UI/Auth/SignInSheet.swift
git commit -m "AIA-0791: Debug-only backend picker, keeping the pk_ and mock-auth guards"
```

---

## Task 5: `deliver.sh --execution-environment`

**Files:**
- Modify: `scripts/deliver.sh` — help text, defaults, option parsing (~`:854`), archive invocation (`:629-637`), upload refusal, `WhatToTest`, summary.

**Interfaces:**
- Consumes: the `AIA_BACKEND_ENVIRONMENT` build setting and the `BackendEnvironment` Info.plist key from Task 1.
- Produces: `--execution-environment <development|production>` (default `production`) and `--allow-staging-upload`.

- [ ] **Step 1: Add the variables**

Beside the other defaults near the top:

```bash
# The backend this build talks to: Clerk instance + findings Worker, as one pair (AIA-0791).
# Production by default: a TestFlight build is a release candidate, and the configuration it ships
# with is the one that has to be exercised before it ships.
EXECUTION_ENVIRONMENT="production"
ALLOW_STAGING_UPLOAD=0
```

- [ ] **Step 2: Parse and validate**

In the option-parsing loop, beside `--build-number`:

```bash
            --execution-environment)
                [[ $# -ge 2 ]] || die "--execution-environment requires a value."
                case "$2" in
                    development|production) EXECUTION_ENVIRONMENT="$2" ;;
                    *) die "--execution-environment must be 'development' or 'production' (got '$2')." ;;
                esac
                shift 2 ;;
            --allow-staging-upload) ALLOW_STAGING_UPLOAD=1; shift ;;
```

- [ ] **Step 3: Refuse to upload a staging build by default**

In `main()`, beside the existing `--dry-run requires --build-number` check:

```bash
    # A staging build on TestFlight is indistinguishable from a production one in the TestFlight
    # UI, so a tester cannot tell why sync fails. Exporting one locally is fine; uploading is not.
    if [[ "$SUBCOMMAND" == "deliver" && "$EXPORT_ONLY" != 1 && "$DRY_RUN" != 1 \
          && "$EXECUTION_ENVIRONMENT" != "production" && "$ALLOW_STAGING_UPLOAD" != 1 ]]; then
        die "Refusing to upload a '${EXECUTION_ENVIRONMENT}' build to TestFlight. Pass --allow-staging-upload if that is genuinely what you want."
    fi
```

- [ ] **Step 4: Document both in `show_help`**

```
  --execution-environment <env>
                      Backend the build talks to: development (staging Worker +
                      pk_test_ Clerk) or production. Default: production.
                      Xcode Cloud archives are always production and cannot be
                      overridden — that is deliberate.
  --allow-staging-upload
                      Permit uploading a non-production build to TestFlight.
                      Refused without it: testers cannot tell the two apart.
```

- [ ] **Step 5: Pass it to the archive and assert on the archive**

In the `xcodebuild archive` invocation (`:629-637`), beside `CURRENT_PROJECT_VERSION="$num"`:

```bash
        AIA_BACKEND_ENVIRONMENT="$EXECUTION_ENVIRONMENT"
```

and change the line above it:

```bash
    info "Archiving (${CONFIGURATION}, ${EXECUTION_ENVIRONMENT} backend, CURRENT_PROJECT_VERSION=${num})…"
```

Then, **immediately after** the archive step and outside every `--skip-validate` / `--export-only` branch, so the plain upload path is covered too:

```bash
    # The one thing that can silently no-op: a build setting that never reached the binary. Assert
    # on the artifact, not the intention. The export product is an .ipa, so this reads the ARCHIVE.
    if [[ "$DRY_RUN" == 1 ]]; then
        info "Would verify BackendEnvironment=${EXECUTION_ENVIRONMENT} in the archive."
    else
        local app_plist built_env
        app_plist="$(find "${ARCHIVE_PATH}/Products/Applications" -maxdepth 2 -name Info.plist 2>/dev/null | head -1)"
        [[ -n "$app_plist" ]] || die "Could not find the archived app's Info.plist under ${ARCHIVE_PATH}."
        built_env="$(plutil -extract BackendEnvironment raw -o - "$app_plist" 2>/dev/null || true)"
        [[ "$built_env" == "$EXECUTION_ENVIRONMENT" ]] || \
            die "Archive carries BackendEnvironment='${built_env}', expected '${EXECUTION_ENVIRONMENT}'."
        info "Verified BackendEnvironment=${built_env} in the archive."
    fi
```

The `DRY_RUN` branch is required: `cmd_selftest` (`:801-806`) runs `deliver --dry-run …` and fails the whole script unless it exits 0.

- [ ] **Step 6: Mark a staging build in `WhatToTest`**

In `cmd_notes` / wherever `WHATSNEW_FILE` is read, prepend for non-production builds:

```bash
Inside `build_whatsnew_json` (`:718-730`), after `text` is assigned by the `awk` step — `text` is the real payload variable; there is no `notes` variable:

```bash
    if [[ "$EXECUTION_ENVIRONMENT" != "production" ]]; then
        text="STAGING BACKEND — do not report sync or sign-in issues.

${text}"
    fi
```

**And carry the environment into the follow-up command.** Publishing notes is a *separate* invocation: the upload path prints `./scripts/deliver.sh notes --build-number ${num}` (`:709`), which would default `EXECUTION_ENVIRONMENT` back to `production` and publish unmarked notes for a staging build. Change that emitted line to include the flag when it is not the default:

```bash
        local env_flag=""
        [[ "$EXECUTION_ENVIRONMENT" == "production" ]] || env_flag=" --execution-environment ${EXECUTION_ENVIRONMENT}"
        log "    ./scripts/deliver.sh notes --build-number ${num}${env_flag}"
```

Separately, and for the **production** build that carries this change, add one line to
`ios/TestFlight/WhatToTest.en-US.txt` for the migration in Task 7:

```
You will be signed out once, and need to sign in again. Findings backed up by earlier
TestFlight builds do not carry over — the ones on your device are untouched.
```

- [ ] **Step 7: Put it in the summary**

```bash
    info "  backend:      ${EXECUTION_ENVIRONMENT}"
```

- [ ] **Step 8: Verify the rejection paths**

```bash
./scripts/deliver.sh deliver --execution-environment staging 2>&1 | tail -2
./scripts/deliver.sh deliver --execution-environment development --skip-tests --allow-dirty 2>&1 | tail -2
```

Expected: the first dies with `--execution-environment must be 'development' or 'production' (got 'staging')`; the second dies with `Refusing to upload a 'development' build to TestFlight`.

- [ ] **Step 9: Verify `selftest` still passes**

```bash
./scripts/deliver.sh selftest 2>&1 | tail -5
```

Expected: exit 0. This is the regression guard for Step 5's `DRY_RUN` branch.

- [ ] **Step 10: Verify the passthrough cheaply**

A full archive is expensive; prove the setting reaches the binary with a plain build:

```bash
cd ios && xcodebuild build -workspace MLBrowser.xcworkspace -scheme MLBrowser \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/aia-passthrough \
  AIA_BACKEND_ENVIRONMENT=development 2>&1 | tail -3
plutil -extract BackendEnvironment raw -o - \
  "$(find /tmp/aia-passthrough -name 'ML Browser.app' -maxdepth 6 | head -1)/Info.plist"
```

Expected: `development` — proving the command-line override beats the Release build setting. Then `rm -rf /tmp/aia-passthrough`.

- [ ] **Step 11: One real end-to-end pass**

`deliver.sh` refuses a feature branch: `--allow-dirty` waives the dirty-tree check but **not** the separate branch/ref gate at `:418-423`. Pass the checked-out SHA explicitly rather than creating a `release/*` branch, which would fire the paid Xcode Cloud Release workflow:

```bash
./scripts/deliver.sh deliver --export-only --skip-tests --allow-dirty \
  --build-number 9001 --ref "$(git rev-parse HEAD)" > /tmp/aia-deliver.log 2>&1; echo "STATUS=$?"
grep "BackendEnvironment" /tmp/aia-deliver.log
```

Expected: `STATUS=0` and `Verified BackendEnvironment=production in the archive.`

- [ ] **Step 12: Commit**

```bash
git add scripts/deliver.sh
git commit -m "AIA-0791: deliver.sh --execution-environment, production by default"
```

---

## Task 6: Xcode Cloud archives are production, asserted

**Files:**
- Modify: `ios/ci_scripts/ci_post_xcodebuild.sh`

**Interfaces:**
- Consumes: `$CI_ARCHIVE_PATH`, `$CI_XCODEBUILD_ACTION`; the `BackendEnvironment` Info.plist key from Task 1.
- Produces: nothing.

- [ ] **Step 1: Add the assertion**

**First, make a missing archive fatal for an archive action.** The existing guard at `:25-29` `exit 0`s when `CI_ARCHIVE_PATH` is unset or absent — sensible for skipping a dSYM upload, fatal-by-omission for a backend assertion, because the check would "pass" by never running. Since the script has already established `CI_XCODEBUILD_ACTION == archive` by that point, an unavailable archive is a broken build, not a skip:

```zsh
if [[ -z "${CI_ARCHIVE_PATH:-}" ]] || [[ ! -d "${CI_ARCHIVE_PATH:-}" ]]; then
    echo "❌ Archive action produced no archive at CI_ARCHIVE_PATH — cannot verify the backend."
    exit 1
fi
```

Then, **before** the Sentry token checks, so a wrong backend fails even when Sentry is unconfigured:

```zsh
# --- Assert the backend this archive talks to (AIA-0791) ---
# Xcode Cloud only ever archives under Release, which sets AIA_BACKEND_ENVIRONMENT=production, and
# it cannot pass a command-line override. So this cannot fail unless someone changed a build
# setting — which is exactly the change that must not reach TestFlight unnoticed.
APP_PLIST=$(find "${CI_ARCHIVE_PATH}/Products/Applications" -maxdepth 2 -name Info.plist | head -1)
if [[ -z "$APP_PLIST" ]]; then
    echo "❌ Could not find the archived app's Info.plist under ${CI_ARCHIVE_PATH}"
    exit 1
fi
BUILT_ENV=$(plutil -extract BackendEnvironment raw -o - "$APP_PLIST" 2>/dev/null || true)
if [[ "$BUILT_ENV" != "production" ]]; then
    echo "❌ Xcode Cloud archives must target the production backend, got '${BUILT_ENV}'."
    echo "   Check AIA_BACKEND_ENVIRONMENT in the Release configuration of the MLBrowser target."
    exit 1
fi
echo "   ✅ BackendEnvironment=production"
```

- [ ] **Step 2: Verify the logic against the real archive from Task 5**

```bash
ARCHIVE="build/delivery/MLBrowser.xcarchive"
PLIST=$(find "$ARCHIVE/Products/Applications" -maxdepth 2 -name Info.plist | head -1)
echo "plist: $PLIST"
plutil -extract BackendEnvironment raw -o - "$PLIST"
```

Expected: a path, then `production`.

- [ ] **Step 3: Verify the failure path is reachable**

```bash
plutil -extract BackendEnvironment raw -o - /dev/null 2>/dev/null || echo "absent -> empty, guard fires"
```

Expected: `absent -> empty, guard fires` — confirming a missing key yields an empty string the `!=` catches, rather than an error `|| true` would swallow into a pass.

- [ ] **Step 4: Commit**

```bash
git add ios/ci_scripts/ci_post_xcodebuild.sh
git commit -m "AIA-0791: fail an Xcode Cloud archive that is not production"
```

---

## Task 7: Verify the tester migration

**Files:** none — this is a manual verification task whose output is a note on the PR.

The old TestFlight build signs testers into the **development** Clerk instance. The new one does not configure that instance at all. This task establishes what actually happens to them, before anyone else finds out.

- [ ] **Step 1: Establish the "before" state**

On a device or simulator, install the current TestFlight build (1.0.8 build 1005) and sign in. Confirm you are signed in and create one finding.

- [ ] **Step 2: Install a PRODUCTION-configured build over it**

**Not an Xcode Run.** The shared Run action is Debug (`MLBrowser.xcscheme:79`) and Debug now defaults to `development` — such a run would keep the old development session alive and "verify" a migration that never happened. Use a device, and install the same kind of artifact a tester would get:

```bash
./scripts/deliver.sh deliver --export-only --skip-tests --allow-dirty \
  --build-number 9002 --ref "$(git rev-parse HEAD)"
plutil -extract BackendEnvironment raw -o - \
  "$(find build/delivery/MLBrowser.xcarchive/Products/Applications -maxdepth 2 -name Info.plist | head -1)"
```

Confirm that prints `production` **before** first launch, then install the exported `.ipa` over the existing app without deleting it — so `UserDefaults`, the Core Data store, the findings ledger and the Clerk keychain entries all survive, exactly as a TestFlight update would.

- [ ] **Step 3: Record what happens**

Confirm and write down:

- The app launches and does not crash.
- The auth gate reaches **signedOut** cleanly — not a wedged "validating" state, not a spinner.
- The local finding from Step 1 is **still present** (findings are local first; nothing about this change may delete them).
- The support log shows `Backend environment: production`.
- Signing in with a production account works, and sync completes: `Findings sync finished in …: uploaded 1` rather than `stopped: unauthorized`.

- [ ] **Step 4: Record the result on the PR**

Paste the observations from Step 3. If the gate does **not** reach a clean signed-out state, stop and raise it — that is a migration bug this plan has to fix, not a note.

---

## Task 8: Write the rule down, and fix what now lies

**Files:**
- Modify: `AUTH-SUBSCRIPTION.md`
- Modify: `USER_DATA_PERSISTENCE.md:288`
- Modify: `ios/ci_scripts/ci_pre_xcodebuild.sh:12,68-72`

- [ ] **Step 1: Fix the CI script's comments**

`ci_pre_xcodebuild.sh:68-72` currently says the binary needs both keys because "the app selects at runtime via `AppEnvironment.isAppStoreDistribution` (App Store → pk_live_, else pk_test_), with a non-App-Store override from the sign-in environment switch". After this change that is false in every clause. Replace with:

```sh
    # An archive ships to both TestFlight and the App Store from the same binary, and a Debug
    # build can be pointed at either instance, so the binary carries BOTH public keys. Which one
    # is used is fixed at build time by AIA_BACKEND_ENVIRONMENT — not inferred from the receipt
    # (AIA-0791). See AUTH-SUBSCRIPTION.md, "Which backend a build talks to".
```

and correct the same claim at `:12`.

- [ ] **Step 2: Fix the other three stale claims**

All three still assert the old TestFlight→development Clerk rule and become false with this change:

- `USER_DATA_PERSISTENCE.md:288` — describes `baseURL(for:)` in the old vocabulary. Change the parameter type to `BackendEnvironment` and note that the Worker's `staging` is the client's `development`.
- `ios/MLBrowser/iOS/Tools/FeatureFlags/ConfigCatFeatureFlagProvider.swift:102` — comment repeating the receipt-selects-the-instance rule.
- `FEATUREFLAGS.md:121` — same claim in prose.
- `ios/MLBrowserArchitectureTests/ArchitectureTests.swift:836` — read this one before editing: if it *asserts* the old rule it is a failing test, not a stale comment, and it must be updated to the new rule rather than deleted.

- [ ] **Step 3: Add the section to `AUTH-SUBSCRIPTION.md`**

After the `ClerkSessionWatcher` section (around line 79):

```markdown
## Which backend a build talks to

The Clerk instance and the findings Worker are **one choice**, not two. Each Worker pins exactly
one Clerk issuer (`cloudflare/findings-worker/wrangler.jsonc`), so a build that signs in against
one instance and uploads to the other is refused with a 401 on every request.

That choice is `AIA_BACKEND_ENVIRONMENT`, a build setting. It reaches the app twice from the same
source: as a Swift compilation condition (`BackendEnvironment.configured`, non-optional, an
invalid value is a compile error) and as an `Info.plist` string that build artifacts can be
asserted about from shell. `ClerkAuthProvider.publishableKey` and `FindingsCloudEndpoint.baseURL`
read it and nothing else.

| Build path | Value |
|-|-|
| Xcode, Debug | `development` — staging Worker, `pk_test_` Clerk |
| Xcode / Xcode Cloud, Release | `production`, asserted in `ci_post_xcodebuild.sh` |
| `scripts/deliver.sh` | `production` unless `--execution-environment development`; uploading a non-production build additionally needs `--allow-staging-upload` |
| Debug build, at runtime | either, via the `#if DEBUG` picker in `SignInSheet` — and the app wears a red `PRODUCTION` banner for the whole session while it is |

There is no runtime fallback, deliberately: falling back to `development` is how cloud sync was
dead for every App-Store-classified build in 1.0.8 build 1005, and falling back to `production`
would put test findings in real users' bucket.

Distribution-channel inference (`AppEnvironment.distributionChannel`) does **not** decide this and
must not be reintroduced into it. It cannot be trusted for the purpose: an iOS-app-on-Mac install
has no receipt at that path, and an iPhone restored from backup has none until
`SKReceiptRefreshRequest` completes. It still decides things whose failure mode is cosmetic —
Settings' debug section, Sentry sampling, StoreKit sandbox detection.
```

- [ ] **Step 4: Confirm no localisation regression**

```bash
./scripts/localization.sh 2>&1 | grep -i "Auth.Environment" || echo "no findings"
```

Expected: `no findings`, or an explicit "unused" report for `L10n.Auth.Environment.*` — those keys are now referenced only from `#if DEBUG` code. If the tool reports them unused, keep them and add a comment saying why; do not delete strings the Debug picker still renders.

- [ ] **Step 5: Commit**

```bash
git add AUTH-SUBSCRIPTION.md USER_DATA_PERSISTENCE.md ios/ci_scripts/ci_pre_xcodebuild.sh
git commit -m "AIA-0791: document the build-time backend rule, correct what it invalidates"
```

---

## Verification before the PR

Every command below captures to a log and checks the status explicitly. Do **not** pipe these to `tail`/`grep` without `pipefail` — the pipeline reports the *filter's* status, so a failing suite reads as a pass.

- [ ] `./scripts/unittest.sh` exits 0, and `BackendEnvironmentTests` appears in the log.
- [ ] `xcodebuild … -showBuildSettings` shows **both** `DEBUG` and `AIA_BACKEND_ENV_development` for Debug (the `$(inherited)` tripwire).
- [ ] `-only-testing:MLBrowserUITests` passes (the loudest consumer of `#if DEBUG`).
- [ ] `AIA_BACKEND_ENVIRONMENT=nonsense` fails the build — `#error` fires.
- [ ] `AIA_BACKEND_ENVIRONMENT='development production'` **also** fails the build — the Run Script phase fires where `#error` structurally cannot.
- [ ] `BackendEnvironmentTests` run once with `AIA_BACKEND_ENVIRONMENT=production` and pass — the only check that executes the production compilation branch.
- [ ] `test_realKeysBelongToTheInstanceTheWorkerPins` passes locally (decodes to `advanced-tetra-5.clerk.accounts.dev` / `clerk.aiarcheology.com`) and skips on hermetic CI.
- [ ] `grep -rn "selectedEnvironment\|switchEnvironment\|ClerkEnvironment" ios --include='*.swift'` is empty.
- [ ] `grep -rn "BackendEnvironment.override *=" ios --include='*.swift'` matches only inside `BackendEnvironment.switch(to:)`.
- [ ] `./scripts/deliver.sh selftest` exits 0.
- [ ] `./scripts/deliver.sh deliver --execution-environment development --skip-tests --allow-dirty --ref "$(git rev-parse HEAD)"` refuses to upload.
- [ ] `deliver --export-only … --ref <sha>` reports `Verified BackendEnvironment=production in the archive.`
- [ ] The banner appears when the picker flips to production, **disappears** when it flips back, is visible over a sheet, a full-screen cover and a confirmation dialog, shows in both windows on iPad, and does not eat taps.
- [ ] A mock-auth Debug build (`UI_TESTING`) pointed at production does not crash — the banner reads `mock auth`, not `Clerk.shared`.
- [ ] Task 7's migration observations are recorded on the PR, from a **device** running a production-configured artifact.
- [ ] `./scripts/harmonize.sh` and `./scripts/swiftlint.sh` pass.
- [ ] No `release/*` branch was created.

---

## Concession log

| # | Objection | Change forced |
|-|-|-|
| 1 | The `deliver.sh` assertion looked for `*.app/Info.plist`, but the export product is an `.ipa` (`:563-568`) | Assertion moved to the archive |
| 2 | Assertion sat inside the `--skip-validate`-able branch and would have broken `deliver.sh selftest`, which requires exit 0 from a dry-run child (`:801-806`) | Unconditional, with a `DRY_RUN` branch |
| 3 | Pairing tests would fail on Xcode Cloud — Clerk keys are deliberately absent for non-archive actions (`ci_pre_xcodebuild.sh:65-84`) | Pure fixture seam + a skipped real-key test |
| 4 | The Debug picker dropped the `usesRealAuth` and `pk_` guards; `Clerk.configure` **traps** on a malformed key in DEBUG | Both guards restored; override set only after success |
| 5 | The TestFlight→production switch was not stated in the plan | Spec section, plus Task 7 |
| 6 | Half the verification commands could not run (`main()` needs a subcommand; `--dry-run` needs `--build-number`) | Commands corrected; one real archive instead of two |
| 7 | Optionality paid for a state the plan made unreachable | Compilation conditions + `#error`; `current` non-optional; Run Script phase deleted |
| 8 | *(my over-correction, withdrawn by the human)* a `project.pbxproj`-parsing test | Dropped; two artifact assertions are the whole mechanism |
| 9 | Wrong archive path | `build/delivery/MLBrowser.xcarchive` |
| 10 | The new Settings row was gated on the very inference that misfires on Mac | Row dropped; launch log + banner instead |
| 11 | Doc drift in `ci_pre_xcodebuild.sh` and `USER_DATA_PERSISTENCE.md` | Task 8 |
| 12 | The banner condition rested on `hasEmbeddedProvisioningProfile`, unverifiable for an Xcode Mac run | `#if DEBUG` |
| 13 | The amendment reintroduced provisioning-profile inference into a shipping binary, against requirement 2 | `#if DEBUG`; local-Release case registered as a risk |
| 14 | An email in a permanent overlay contradicts `nameUnlessItIsAnAddress` | Truncated Clerk user id |
| 15 | Window mechanics: per-scene, passthrough, `isHidden` not `makeKeyAndVisible`, level | All four specified |
| 16 | `SWIFT_ACTIVE_COMPILATION_CONDITIONS` without `$(inherited)` **silently drops `DEBUG`** from the app module (`project.pbxproj:2524`) | Exact string mandated; tripwire test; `-showBuildSettings` check; UI-test run |
| 17 | The `deliver.sh` assertion checked intent-match, so a staging build could be uploaded to TestFlight | `--allow-staging-upload` + `WhatToTest` prefix |
| 18 | The launch log went stale after a picker flip | Logged again on the switch |
| 19 | Orphaned staging findings for existing testers | Residual 6 + a `WhatToTest` line |
| 20 | Residuals described gaps in a mitigation, not the hazard | Residual 7 |
| 21 | Two verification strings referred to deleted text | Already corrected in the same revision |

### Second pass — codex (gpt-5.6-sol, xhigh)

| # | Finding | Change forced |
|-|-|-|
| C1 | `override` had an open setter, so a caller could move the Worker while Clerk stayed put — the plan's own banner-test shortcut did exactly that | `private(set)` + a single `switch(to:)` that reconfigures Clerk first |
| C2 | No check ever executed the **production** compilation branch; a wrong `#if` branch would pass every Debug test and both plist-based archive assertions | Environment-neutral compiled-vs-plist test, run once with `AIA_BACKEND_ENVIRONMENT=production` |
| C3 | **The `#error` guard was settled on a false premise.** `SWIFT_ACTIVE_COMPILATION_CONDITIONS` is a whitespace-separated list, so `AIA_BACKEND_ENVIRONMENT='development production'` defines `AIA_BACKEND_ENV_development` and compiles clean. Reproduced with `xcodebuild -showBuildSettings` | Run Script phase **reinstated**; whitespace mutation test added |
| C4 | The banner could never appear or disappear after a picker flip — `attach` ran only on scene connect and had no teardown | `update()` on switch; teardown when leaving production |
| C5 | A correctly-prefixed key from the *wrong* Clerk instance still mismatches; nothing validated the instance | Decode the key's base64 host and assert it equals the issuer the Worker pins |
| C6 | Task 7 would have tested the Debug/development path and falsely verified the migration | Device + production-configured artifact, asserted before first launch |
| C7 | The banner read `Clerk.shared` unconditionally, which **traps with SIGILL** on the mock-auth path | Guarded on `usesMockAuth` |
| C8 | The `WhatToTest` snippet mutated a variable that does not exist, and notes are published by a *separate* invocation that would default back to production | Prefix inside `build_whatsnew_json`; carry the flag into the emitted command |
| C9 | The Xcode Cloud assertion `exit 0`s when the archive is missing — passing by never running | Missing archive is fatal for an archive action |
| C10 | Verification commands piped to `tail`/`grep` report the *pipe's* status, so a failing suite reads as a pass | Capture to a log, check the status explicitly |
| C11 | The one real archive command would fail `deliver.sh`'s branch/ref gate, which `--allow-dirty` does not waive | `--ref "$(git rev-parse HEAD)"` |
| C12 | Requirement 7's "only cosmetic" claim was false — `DataController.swift:67,238` uses the inference for mapping-model inference and destructive store recovery | Requirement narrowed; three more stale references added to Task 8 |

## Accepted-risk register

1. **A local *Release* build run against production shows no banner** (`#if DEBUG` gate). Accepted: local Release builds in this project go through `deliver.sh`, which archives rather than runs, and the alternative reintroduces the inference this ticket removes.
2. **Out-of-process system UI may draw above the banner window** — the StoreKit purchase sheet and Sign in with Apple are remote view services. Accepted: every destructive action in scope (account deletion, Remove All Findings, sign-out) is in-app.
3. **A failing `ci_post_xcodebuild.sh` may not block Xcode Cloud distribution.** Unverified in both directions; confirming it costs a paid Xcode Cloud run. To be settled on the next archive that runs for its own reasons.
4. **Xcode Organizer's Distribute → TestFlight bypasses `deliver.sh`** and therefore every assertion in it. Inherent to that route; `ci_post_xcodebuild.sh` does not cover it either, since Organizer archives locally.
5. **Tester traffic now spends the production R2 allowance**, which is account-wide, shared with real users, and billed on daily peak. `--execution-environment development` is the release valve for heavy test cycles.
6. **Existing testers' backed-up findings are orphaned.** Anything uploaded by a build ≤1005 stays in the staging bucket under a development-instance account, which the new build cannot sign into — those testers land on an empty cloud account with no in-app route back, and the orphaned objects keep consuming the same account-wide allowance. Their **local** findings are untouched. Covered by the `WhatToTest` line in Task 5 Step 6 and verified in Task 7.
7. **A Debug build with the override can write to and delete from production** — real findings into the real bucket, and account deletion is reachable. The banner (risks 1-2) reduces the chance a developer forgets; it prevents nothing. The control that actually binds is that reaching production requires production Clerk credentials, so the blast radius is limited to accounts the developer can already sign into.

## Escalation

**None.** The one escalation this plan carried — whether #747 ("Production verified with more than one account") had to be settled first — was raised on a false premise: the grill-master read the unticked `- [ ]` at `RELEASE_CHECK.md:45` as an open gate, but **#747 is closed** (2026-08-28). Nothing here needs a decision before implementation.

Incidental, not part of this ticket: `RELEASE_CHECK.md:45` is stale and should be ticked to match. Ticking a release gate asserts the verification happened, so leave it to whoever ran it.
