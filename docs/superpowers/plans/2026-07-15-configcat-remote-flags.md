# ConfigCat Remote Feature Flags — Implementation Plan (AIA-0350, Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the two compile-time `FeatureFlags` booleans to ConfigCat so they can be flipped without an App Store release, with zero user-visible change.

**Architecture:** A non-`@MainActor` adapter wraps the ConfigCat SDK and reads values **synchronously** from `client.snapshot()`, falling back to compiled-in defaults. A `@MainActor` `FeatureFlagsState` holds an immutable `FeatureFlagSnapshot` value type and republishes when config lands. `DependencyContainer` owns both and injects the state into `AppState` and — explicitly, because it lives above `ContentView` — into `SubscriptionGateView`.

**Tech Stack:** Swift 5/SwiftUI, XCTest, ConfigCat Swift SDK 11.3.1 (SPM), Harmonize architecture lint, SwiftLint, 1Password + `ProjectTool secrets`.

**Spec:** `docs/superpowers/specs/2026-07-15-remote-flags-and-analytics-design.md`

## Global Constraints

- **Phase 2 is out of scope.** No TelemetryDeck, no analytics, no privacy-policy edits in this plan.
- **No user-visible change.** Both flags ship `true` in both ConfigCat environments; this is a pure refactor.
- **Never block launch.** Flag reads are synchronous against a snapshot; refresh is best-effort. No `await` on ConfigCat before UI.
- **Fail open, safely.** Any failure (offline, bad key, missing flag, outage) must resolve to the compiled `defaultValue`. Never throw to the UI.
- **Never commit secrets.** Real values live only in `ios/Secrets.xcconfig` (gitignored, `ios/.gitignore:3`). Templates carry `op://` refs only.
- **Architecture lint (must pass `scripts/harmonize.sh`):**
  - Services/adapters must **not** be `@MainActor` (`ArchitectureTests.swift:224`).
  - Types named `*State` **must** be `@MainActor` (`:198`) and must not import SwiftUI/UIKit (`:574` — do not add to the ratchet baseline).
  - `ObservableObject`s need an approved suffix (`:266`) → `FeatureFlagsState`, never `FeatureFlagSnapshot` as a class.
  - No new app-defined `static shared` singletons (`:397`).
- **Tabs, not spaces**, in `ios/MLBrowser/iOS/State/*.swift` (match each file's existing indentation exactly).
- **Every PR updates** `ios/TestFlight/WhatToTest.en-US.txt` (AGENTS.md §13).
- **1Password refs (verified resolving 2026-07-15):**
  - `op://Personal/ConfigCat Keys/CONFIGCAT_SDK_KEY_TEST`
  - `op://Personal/ConfigCat Keys/CONFIGCAT_SDK_KEY_PROD`
- **ConfigCat IDs:** org `08dee1f8-a06e-4795-818e-cd1612376cac`, product `08dee1f8-a07b-4d24-8078-7804525fca65`, config `08dee1f8-a08f-45c8-8235-850708d71230`, env Test `08dee1f8-a07f-4ed1-855d-aa0111147d1e`, env Production `08dee1f8-a087-4227-8358-d56ffddecbde`.

## File Structure

| File | Responsibility |
|-|-|
| `ios/MLBrowser/iOS/State/FeatureFlags.swift` | **Modify.** Becomes `FeatureFlagKey` (keys + defaults) and `FeatureFlagSnapshot` (immutable value). |
| `ios/MLBrowser/iOS/Tools/FeatureFlags/FeatureFlagProviding.swift` | **Create.** Narrow internal seam + `StaticFeatureFlagProvider` fake. |
| `ios/MLBrowser/iOS/Tools/FeatureFlags/ConfigCatFeatureFlagProvider.swift` | **Create.** Non-`@MainActor` ConfigCat adapter. Only file importing `ConfigCat`. |
| `ios/MLBrowser/iOS/State/FeatureFlagsState.swift` | **Create.** `@MainActor` observable holding the snapshot. |
| `ios/MLBrowser/iOS/State/DependencyContainer.swift` | **Modify.** Own provider + state; inject via `makeAppState()`. |
| `ios/MLBrowser/iOS/State/Appstate.swift` | **Modify.** Hold `featureFlags`; line 133 reads snapshot. |
| `ios/MLBrowser/iOS/State/SubscriptionState.swift` | **Modify.** Inject flags; `isPremiumUnlocked` uses them. |
| `ios/MLBrowser/iOS/UI/MLBrowser.swift` | **Modify.** Inject state into `SubscriptionGateView`. |
| `ios/MLBrowser/iOS/UI/Subscription/SubscriptionGateView.swift` | **Modify.** Take flags explicitly (sits above `ContentView`). |
| `ios/MLBrowser/iOS/UI/SettingsView/SettingsView.swift` | **Modify.** Read from `AppState`. |
| `ios/MLBrowser/iOS/UI/FileImporter/ModelImportView.swift` | **Modify.** Read from `AppState` (sheet — needs re-injection). |
| `ios/MLBrowser/iOS/Tools/Testability/UITestLaunchConfiguration.swift` | **Modify.** v5→v6 + flag overrides. |
| `ios/MLBrowser-Info.plist` | **Modify.** `$(CONFIGCAT_SDK_KEY)` / `$(CONFIGCAT_SDK_KEY_LIVE)`. |
| `ios/Secrets.template.xcconfig`, `ios/Config/Secrets.template.xcconfig` | **Modify.** Add both `op://` refs (**both** templates exist — keep in sync). |
| `ios/MLBrowserUnitTests/FeatureFlagsTests.swift` | **Create.** Defaults/fallback/mapping tests. |
| `ios/MLBrowserUnitTests/SubscriptionStateTests.swift` | **Modify.** Line 95 seam. |

---

### Task 1: Add the ConfigCat SPM package

**Files:**
- Modify: `ios/MLBrowser.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing.
- Produces: `import ConfigCat` compiles in the `ML Browser` target.

> **Why by hand:** `ProjectTool` has no Xcode-project command (only `setup`, `cleanup`, `secrets`, `asc`). Mirror the existing `sentry-cocoa` entries exactly. If hand-editing goes wrong, fall back to Xcode → File → Add Package Dependencies → `https://github.com/configcat/swift-sdk` → Up to Next Major `11.3.1` → add `ConfigCat` to the `ML Browser` target, then commit the resulting diff.

- [ ] **Step 1: Inspect the existing package reference block to copy its shape**

```bash
sed -n '2283,2300p' ios/MLBrowser.xcodeproj/project.pbxproj
sed -n '2328,2364p' ios/MLBrowser.xcodeproj/project.pbxproj
```

Expected: an `XCRemoteSwiftPackageReference` for `sentry-cocoa` with `repositoryURL` + `requirement`, and an `XCSwiftPackageProductDependency` with `productName = Sentry;`.

- [ ] **Step 2: Add the package via Xcode (preferred) or hand-edit**

In Xcode: File → Add Package Dependencies → `https://github.com/configcat/swift-sdk` → Dependency Rule: Up to Next Major Version, `11.3.1` → Add to target **ML Browser**, product **ConfigCat**.

- [ ] **Step 3: Verify it resolves and the project still builds**

```bash
cd ios && xcodebuild -project MLBrowser.xcodeproj -scheme "ML Browser" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -resolvePackageDependencies 2>&1 | tail -5
```

Expected: resolves `swift-sdk` at 11.3.1, no error.

- [ ] **Step 4: Confirm the package is registered**

```bash
grep -c 'configcat' ios/MLBrowser.xcodeproj/project.pbxproj
```

Expected: `>= 1`.

- [ ] **Step 5: Commit**

```bash
git add ios/MLBrowser.xcodeproj/project.pbxproj ios/MLBrowser.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "[AIA-0350] Add ConfigCat SDK package"
```

---

### Task 2: Typed flag keys, defaults, and snapshot

**Files:**
- Modify: `ios/MLBrowser/iOS/State/FeatureFlags.swift`
- Test: `ios/MLBrowserUnitTests/FeatureFlagsTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum FeatureFlagKey: String, CaseIterable { case isModelCatalogEnabled, isPaymentsEnabled; var defaultValue: Bool { get } }`
  - `struct FeatureFlagSnapshot: Equatable { init(values: [FeatureFlagKey: Bool]); subscript(_ key: FeatureFlagKey) -> Bool; var isModelCatalogEnabled: Bool; var isPaymentsEnabled: Bool; static let defaults: FeatureFlagSnapshot }`

- [ ] **Step 1: Write the failing tests**

Create `ios/MLBrowserUnitTests/FeatureFlagsTests.swift`:

```swift
//
//  FeatureFlagsTests.swift
//  AI ArcheologyTests
//
//  Remote feature flags (AIA-0350).
//

import XCTest
@testable import ML_Browser

final class FeatureFlagsTests: XCTestCase {

	/// The compiled defaults must preserve today's shipped behaviour exactly:
	/// both features are on. This is the offline / first-launch / outage path.
	func test_defaults_matchShippedBehaviour() {
		XCTAssertTrue(FeatureFlagKey.isModelCatalogEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagKey.isPaymentsEnabled.defaultValue)
	}

	/// The ConfigCat key is the rawValue — a declared literal, never a reflected
	/// symbol name, so release-build symbol stripping cannot break lookup.
	func test_rawValues_areTheConfigCatKeys() {
		XCTAssertEqual(FeatureFlagKey.isModelCatalogEnabled.rawValue, "isModelCatalogEnabled")
		XCTAssertEqual(FeatureFlagKey.isPaymentsEnabled.rawValue, "isPaymentsEnabled")
	}

	func test_defaultsSnapshot_usesEveryKeysDefault() {
		let sut = FeatureFlagSnapshot.defaults
		for key in FeatureFlagKey.allCases {
			XCTAssertEqual(sut[key], key.defaultValue, "\(key.rawValue) should use its default")
		}
	}

	/// A snapshot built from partial remote data falls back per-key.
	func test_snapshot_missingKeyFallsBackToDefault() {
		let sut = FeatureFlagSnapshot(values: [.isPaymentsEnabled: false])
		XCTAssertFalse(sut.isPaymentsEnabled)
		XCTAssertEqual(sut.isModelCatalogEnabled, FeatureFlagKey.isModelCatalogEnabled.defaultValue)
	}

	func test_snapshot_remoteValuesWin() {
		let sut = FeatureFlagSnapshot(values: [.isModelCatalogEnabled: false, .isPaymentsEnabled: false])
		XCTAssertFalse(sut.isModelCatalogEnabled)
		XCTAssertFalse(sut.isPaymentsEnabled)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios && xcodebuild test -project MLBrowser.xcodeproj -scheme "ML Browser" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MLBrowserUnitTests/FeatureFlagsTests 2>&1 | tail -20`

Expected: FAIL — `cannot find 'FeatureFlagKey' in scope`.

- [ ] **Step 3: Replace `FeatureFlags.swift` with the typed version**

Replace the whole file (tabs for indentation, matching the original):

```swift
//
//  FeatureFlags.swift
//  AI Archeology
//
//  Feature flag keys + compiled defaults (AIA-0343, AIA-0413; remote via AIA-0350).
//

import Foundation

/// A remotely-switchable feature flag.
///
/// The `rawValue` **is** the ConfigCat setting key — a declared literal, deliberately not
/// derived from the symbol name, so release-build symbol stripping cannot break lookup.
///
/// `defaultValue` is the compiled fallback used whenever remote config is unavailable:
/// first launch, offline, a bad SDK key, a missing flag, or a ConfigCat outage. These
/// defaults **fail open** — see the spec's "Honest limits of the kill switch".
enum FeatureFlagKey: String, CaseIterable {
	/// Gates the public model-catalog acquisition surface (AIA-0413).
	case isModelCatalogEnabled

	/// Gates the in-app subscription/paywall surface (AIA-0343): the Settings
	/// "Upgrade" entry point and any feature gated on entitlement.
	case isPaymentsEnabled

	/// The value used when remote config cannot be consulted.
	var defaultValue: Bool {
		switch self {
		case .isModelCatalogEnabled: return true
		case .isPaymentsEnabled: return true
		}
	}
}

/// An immutable set of resolved flag values.
///
/// A value type on purpose: an `ObservableObject` here would need an approved suffix
/// (Harmonize `testObservableObjectsHaveDescriptiveSuffixes`), and the observable owner
/// is ``FeatureFlagsState``. Any key absent from `values` resolves to its `defaultValue`.
struct FeatureFlagSnapshot: Equatable {
	private let values: [FeatureFlagKey: Bool]

	init(values: [FeatureFlagKey: Bool] = [:]) {
		self.values = values
	}

	subscript(key: FeatureFlagKey) -> Bool {
		values[key] ?? key.defaultValue
	}

	var isModelCatalogEnabled: Bool { self[.isModelCatalogEnabled] }
	var isPaymentsEnabled: Bool { self[.isPaymentsEnabled] }

	/// Every key at its compiled default — the launch/offline value.
	static let defaults = FeatureFlagSnapshot()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios && xcodebuild test -project MLBrowser.xcodeproj -scheme "ML Browser" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MLBrowserUnitTests/FeatureFlagsTests 2>&1 | tail -20`

Expected: PASS — 5 tests. The app target will **not** compile yet (call sites still reference `FeatureFlags.isPaymentsEnabled`); that is Task 5. If the test target cannot build because of those call sites, do Task 5 first and re-run.

- [ ] **Step 5: Commit**

```bash
git add ios/MLBrowser/iOS/State/FeatureFlags.swift ios/MLBrowserUnitTests/FeatureFlagsTests.swift
git commit -m "[AIA-0350] Add typed feature flag keys, defaults, and snapshot"
```

---

### Task 3: Provider seam + static fake

**Files:**
- Create: `ios/MLBrowser/iOS/Tools/FeatureFlags/FeatureFlagProviding.swift`
- Test: `ios/MLBrowserUnitTests/FeatureFlagsTests.swift` (append)

**Interfaces:**
- Consumes: `FeatureFlagKey`, `FeatureFlagSnapshot` (Task 2).
- Produces:
  - `protocol FeatureFlagProviding: Sendable { func currentSnapshot() -> FeatureFlagSnapshot; func refresh() async }`
  - `final class StaticFeatureFlagProvider: FeatureFlagProviding { init(overrides: [FeatureFlagKey: Bool] = [:]) }`

> The protocol is a **narrow internal seam** for tests, previews and UI tests. It is deliberately **not** exposed to views — consumers read one typed snapshot from `AppState`, not a provider.

- [ ] **Step 1: Write the failing tests (append to `FeatureFlagsTests.swift`)**

```swift
final class StaticFeatureFlagProviderTests: XCTestCase {

	func test_withoutOverrides_returnsDefaults() {
		let sut = StaticFeatureFlagProvider()
		XCTAssertEqual(sut.currentSnapshot(), FeatureFlagSnapshot.defaults)
	}

	func test_overrides_win() {
		let sut = StaticFeatureFlagProvider(overrides: [.isPaymentsEnabled: false])
		XCTAssertFalse(sut.currentSnapshot().isPaymentsEnabled)
		XCTAssertTrue(sut.currentSnapshot().isModelCatalogEnabled)
	}

	/// refresh() must be a no-op that never touches the network in tests.
	func test_refresh_doesNotChangeValues() async {
		let sut = StaticFeatureFlagProvider(overrides: [.isPaymentsEnabled: false])
		await sut.refresh()
		XCTAssertFalse(sut.currentSnapshot().isPaymentsEnabled)
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd ios && xcodebuild test -project MLBrowser.xcodeproj -scheme "ML Browser" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MLBrowserUnitTests/StaticFeatureFlagProviderTests 2>&1 | tail -20`

Expected: FAIL — `cannot find 'StaticFeatureFlagProvider' in scope`.

- [ ] **Step 3: Create the seam**

Create `ios/MLBrowser/iOS/Tools/FeatureFlags/FeatureFlagProviding.swift`:

```swift
//
//  FeatureFlagProviding.swift
//  AI Archeology
//
//  Remote feature flags (AIA-0350).
//

import Foundation

/// Source of resolved feature-flag values.
///
/// Deliberately narrow and internal: this is a test/preview seam, **not** a view-facing
/// API. Views read the published ``FeatureFlagSnapshot`` from `AppState`; a provider
/// abstraction at the app boundary would be a fake abstraction.
///
/// Implementations must be non-`@MainActor` (Harmonize `testServicesAreNotMainActor`)
/// and must resolve synchronously without blocking launch.
protocol FeatureFlagProviding: Sendable {
	/// The values known right now. Never blocks; never throws; falls back to defaults.
	func currentSnapshot() -> FeatureFlagSnapshot

	/// Best-effort refresh from the remote source. Failures are swallowed.
	func refresh() async
}

/// A fixed provider for tests, SwiftUI previews, and UI tests. Never touches the network.
final class StaticFeatureFlagProvider: FeatureFlagProviding {
	private let snapshot: FeatureFlagSnapshot

	init(overrides: [FeatureFlagKey: Bool] = [:]) {
		self.snapshot = FeatureFlagSnapshot(values: overrides)
	}

	func currentSnapshot() -> FeatureFlagSnapshot { snapshot }

	func refresh() async {}
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd ios && xcodebuild test -project MLBrowser.xcodeproj -scheme "ML Browser" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MLBrowserUnitTests/StaticFeatureFlagProviderTests 2>&1 | tail -20`

Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/MLBrowser/iOS/Tools/FeatureFlags/FeatureFlagProviding.swift ios/MLBrowserUnitTests/FeatureFlagsTests.swift
git commit -m "[AIA-0350] Add feature flag provider seam and static fake"
```

---

### Task 4: ConfigCat adapter + secrets wiring

**Files:**
- Create: `ios/MLBrowser/iOS/Tools/FeatureFlags/ConfigCatFeatureFlagProvider.swift`
- Modify: `ios/MLBrowser-Info.plist`
- Modify: `ios/Secrets.template.xcconfig`
- Modify: `ios/Config/Secrets.template.xcconfig`

**Interfaces:**
- Consumes: `FeatureFlagProviding`, `FeatureFlagKey`, `FeatureFlagSnapshot`.
- Produces: `final class ConfigCatFeatureFlagProvider: FeatureFlagProviding { init?(sdkKey: String?) ; static func sdkKeyFromInfoPlist() -> String? }`

> **The only file that imports `ConfigCat`.** Non-`@MainActor`. Reads via `client.snapshot().getValue(for:defaultValue:)` — synchronous. **No custom cache**: the SDK already persists config to `UserDefaults` under `com.configcat-`.
>
> ⚠️ **Unverified API shapes.** `ConfigCatClient.get(sdkKey:configurator:)`, `PollingModes.autoPoll(autoPollIntervalInSeconds:)`, `client.forceRefresh()`, and `snapshot.getValue(for:defaultValue:)` were read off the SDK's public declarations but **never compiled** against 11.3.1. Expect argument-label drift. The compiler is the oracle — if a signature differs, fix the call to match the SDK; do not change the design to suit a guess. Confirm against `Sources/ConfigCat/ConfigCatClient.swift` and `PollingModes.swift` in the resolved package.

- [ ] **Step 1: Add the keys to both secret templates**

`ios/Secrets.template.xcconfig` **and** `ios/Config/Secrets.template.xcconfig` — append (both files exist; keep them identical):

```
CONFIGCAT_SDK_KEY = op://Personal/ConfigCat Keys/CONFIGCAT_SDK_KEY_TEST
CONFIGCAT_SDK_KEY_LIVE = op://Personal/ConfigCat Keys/CONFIGCAT_SDK_KEY_PROD
```

- [ ] **Step 2: Expose them to the bundle**

`ios/MLBrowser-Info.plist` — after the `ClerkPublishableKeyLive` entry (line ~20), mirroring the existing `$(VAR)` pattern:

```xml
	<key>ConfigCatSDKKey</key>
	<string>$(CONFIGCAT_SDK_KEY)</string>
	<key>ConfigCatSDKKeyLive</key>
	<string>$(CONFIGCAT_SDK_KEY_LIVE)</string>
```

- [ ] **Step 3: Regenerate local secrets and verify (never print values)**

```bash
swift run --package-path Tools ProjectTool secrets generate
grep -c 'CONFIGCAT_SDK_KEY' ios/Secrets.xcconfig
git check-ignore -v ios/Secrets.xcconfig
```

Expected: `2`, and `ios/.gitignore:3` confirms the real file is ignored.

- [ ] **Step 4: Write the adapter**

Create `ios/MLBrowser/iOS/Tools/FeatureFlags/ConfigCatFeatureFlagProvider.swift`:

```swift
//
//  ConfigCatFeatureFlagProvider.swift
//  AI Archeology
//
//  Remote feature flags via ConfigCat (AIA-0350).
//

import Foundation
import ConfigCat

/// Resolves feature flags from ConfigCat.
///
/// The **only** file that imports `ConfigCat`. Not `@MainActor` (Harmonize
/// `testServicesAreNotMainActor`).
///
/// Reads are synchronous against `client.snapshot()`, so nothing blocks launch. The SDK
/// owns freshness and persistence: it auto-polls and already caches config JSON in
/// `UserDefaults` under `com.configcat-`, so this type deliberately keeps **no cache of
/// its own** — a second cache would be a competing source of truth.
///
/// A snapshot taken before the SDK's cache sync completes returns the supplied default;
/// that is safe, and ``FeatureFlagsState`` republishes once config lands.
final class ConfigCatFeatureFlagProvider: FeatureFlagProviding {
	private let client: ConfigCatClient

	/// Poll interval. The SDK's 60s default is needlessly chatty for two rarely-changed
	/// booleans; ten minutes keeps us far inside the free tier's 5M downloads/month.
	/// Note this only ticks while the process is alive — a suspended app does not poll.
	private static let pollIntervalSeconds = 600

	/// - Parameter sdkKey: environment-specific SDK key. `nil`/empty → returns `nil`, and
	///   the caller falls back to a static defaults provider.
	init?(sdkKey: String?) {
		guard let sdkKey, !sdkKey.isEmpty else { return nil }
		client = ConfigCatClient.get(sdkKey: sdkKey) { options in
			options.pollingMode = PollingModes.autoPoll(autoPollIntervalInSeconds: Self.pollIntervalSeconds)
		}
	}

	func currentSnapshot() -> FeatureFlagSnapshot {
		let snapshot = client.snapshot()
		var values: [FeatureFlagKey: Bool] = [:]
		for key in FeatureFlagKey.allCases {
			values[key] = snapshot.getValue(for: key.rawValue, defaultValue: key.defaultValue)
		}
		return FeatureFlagSnapshot(values: values)
	}

	func refresh() async {
		await client.forceRefresh()
	}

	/// The SDK key for this build. Debug builds talk to the ConfigCat **Test**
	/// environment; everything else talks to **Production** — mirroring how
	/// `ClerkPublishableKey` / `ClerkPublishableKeyLive` already split.
	static func sdkKeyFromInfoPlist() -> String? {
		let key = AppEnvironment.isDebugConfiguration ? "ConfigCatSDKKey" : "ConfigCatSDKKeyLive"
		return Bundle.main.object(forInfoDictionaryKey: key) as? String
	}
}
```

- [ ] **Step 5: Verify it compiles**

Run: `cd ios && xcodebuild build -project MLBrowser.xcodeproj -scheme "ML Browser" -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: the file compiles. Other call sites may still fail — that's Task 5.

> ⚠️ **If the compiler reports a Sendability/strict-concurrency error** on `ConfigCatClient` (the spec flags this as unverified), do **not** force it with `@unchecked Sendable`. Stop and report — the fallback is to keep `refresh()` on the main actor.

- [ ] **Step 6: Commit**

```bash
git add ios/MLBrowser/iOS/Tools/FeatureFlags/ConfigCatFeatureFlagProvider.swift ios/MLBrowser-Info.plist ios/Secrets.template.xcconfig ios/Config/Secrets.template.xcconfig
git commit -m "[AIA-0350] Add ConfigCat provider and secrets wiring"
```

---

### Task 5: `FeatureFlagsState`, composition root, and all call sites

**Files:**
- Create: `ios/MLBrowser/iOS/State/FeatureFlagsState.swift`
- Modify: `ios/MLBrowser/iOS/State/DependencyContainer.swift`
- Modify: `ios/MLBrowser/iOS/State/Appstate.swift:133`
- Modify: `ios/MLBrowser/iOS/State/SubscriptionState.swift:88-100`
- Modify: `ios/MLBrowser/iOS/UI/MLBrowser.swift:60-67`
- Modify: `ios/MLBrowser/iOS/UI/Subscription/SubscriptionGateView.swift`
- Modify: `ios/MLBrowser/iOS/UI/SettingsView/SettingsView.swift:282,298`
- Modify: `ios/MLBrowser/iOS/UI/FileImporter/ModelImportView.swift:195`
- Modify: `ios/MLBrowserUnitTests/SubscriptionStateTests.swift:95`

**Interfaces:**
- Consumes: everything above.
- Produces: `@MainActor final class FeatureFlagsState: ObservableObject { @Published private(set) var snapshot: FeatureFlagSnapshot; init(provider: FeatureFlagProviding); func refresh() async }`

> This task is deliberately one unit: the type change to `FeatureFlags` breaks all 7 production reads at once, so the app cannot compile until they all move. A reviewer cannot accept half of it.

**Per-flag application policy (from the spec — do not deviate):**
- `isModelCatalogEnabled` → **live**. Read `appState.featureFlags.snapshot` in the view body.
- `isPaymentsEnabled` → **launch only**. Captured once into `SubscriptionState`; a mid-session flip must **not** swap the app root for a paywall while the user is mid-detection.

- [ ] **Step 1: Create `FeatureFlagsState`**

```swift
//
//  FeatureFlagsState.swift
//  AI Archeology
//
//  Remote feature flags (AIA-0350).
//

import Foundation
import Combine

/// Publishes the current ``FeatureFlagSnapshot`` to the UI.
///
/// `@MainActor` because Harmonize requires it of every `*State`
/// (`testStateObjectsAreMainActor`). It imports no SwiftUI/UIKit
/// (`testStateTypesAvoidSwiftUIImports_Aspirational`).
///
/// Seeded synchronously at construction so the first frame has real values; `refresh()`
/// republishes once ConfigCat's cache sync or a poll completes.
@MainActor
final class FeatureFlagsState: ObservableObject {
	@Published private(set) var snapshot: FeatureFlagSnapshot

	private let provider: FeatureFlagProviding

	init(provider: FeatureFlagProviding) {
		self.provider = provider
		self.snapshot = provider.currentSnapshot()
	}

	/// Best-effort refresh. Never throws; on failure the previous snapshot stands.
	func refresh() async {
		await provider.refresh()
		let refreshed = provider.currentSnapshot()
		if refreshed != snapshot {
			snapshot = refreshed
		}
	}
}
```

- [ ] **Step 2: Wire the composition root**

In `ios/MLBrowser/iOS/State/DependencyContainer.swift`, add alongside the other lazy services (tabs to match):

```swift
	lazy var featureFlagProvider: FeatureFlagProviding = {
		// UI tests and previews must never hit the network; a bad/missing key also
		// falls back to compiled defaults rather than failing the launch.
		if AppEnvironment.isRunningUnderAnyTests {
			return StaticFeatureFlagProvider()
		}
		return ConfigCatFeatureFlagProvider(sdkKey: ConfigCatFeatureFlagProvider.sdkKeyFromInfoPlist())
			?? StaticFeatureFlagProvider()
	}()

	lazy var featureFlagsState: FeatureFlagsState = {
		FeatureFlagsState(provider: self.featureFlagProvider)
	}()
```

Then pass `featureFlagsState` into `makeAppState()` and into `SubscriptionState(provider:flags:)` (Step 4).

- [ ] **Step 3: Hold it on `AppState` and refresh off the launch path**

In `Appstate.swift`, add a stored `let featureFlags: FeatureFlagsState` (injected via the initializer from `makeAppState()`), and change line 133:

```swift
		// 3b. Install the StoreKit transaction listener and drain pending/unfinished
		// transactions (Ask-to-Buy, interrupted) at launch, BEFORE any purchase UI
		// can appear, then publish the initial entitlement (AIA-0343).
		if featureFlags.snapshot.isPaymentsEnabled {
			await subscriptionState.start()
		}
```

After `isReady = true`, kick a non-blocking refresh (must not delay readiness):

```swift
		// Best-effort remote flag refresh. Deliberately after `isReady`: launch must
		// never wait on ConfigCat (AIA-0350).
		Task { await featureFlags.refresh() }
```

- [ ] **Step 4: Inject flags into `SubscriptionState`**

Replace lines 86–100 of `SubscriptionState.swift`:

```swift
	private let provider: SubscriptionProviding

	/// Captured **once** at construction, deliberately not observed. `isPaymentsEnabled`
	/// applies at a session boundary only: the subscription gate is the app root, so a
	/// mid-session flip would drop a paywall on a user who is mid-detection, or release
	/// an unpaid user from it. A remote change takes effect on next launch (AIA-0350).
	private let isPaymentsEnabled: Bool

	init(provider: SubscriptionProviding, isPaymentsEnabled: Bool) {
		self.provider = provider
		self.isPaymentsEnabled = isPaymentsEnabled
		// Republish when the background Transaction.updates listener changes entitlement
		// (Ask-to-Buy approval, renewal, refund/revocation) — otherwise the gate would
		// read a stale value until relaunch.
		provider.onEntitlementChange = { [weak self] in self?.sync() }
	}

	/// Whether a feature should be unlocked: requires both the payments flag and a
	/// live entitlement. This is the single gate the UI should consult.
	var isPremiumUnlocked: Bool {
		isPaymentsEnabled && isSubscribed
	}

	/// Whether the payments surface is enabled for this session. Views that need the
	/// flag itself (not entitlement) read this rather than a global.
	var isPaymentsSurfaceEnabled: Bool { isPaymentsEnabled }
```

- [ ] **Step 5: Update `SubscriptionGateView` (explicit injection — it sits above `ContentView`)**

Replace the `body` and the doc line that referenced the old global:

```swift
/// Bypassed entirely when the payments flag is off, so the feature can ship dark and
/// existing flows are unaffected until payments are turned on. The flag is read from
/// `subscriptionState`, captured at launch (AIA-0350) — this view is the app root, so it
/// must not swap under the user mid-session.
struct SubscriptionGateView<Content: View>: View {
    @ObservedObject var subscriptionState: SubscriptionState
    @ObservedObject var authState: AuthState
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if subscriptionState.isPaymentsSurfaceEnabled == false || subscriptionState.isSubscribed {
                content()
            } else {
                PaywallView(subscriptionState: subscriptionState, authState: authState, isRootGate: true)
            }
        }
        // Re-check entitlement on foreground: a subscription that lapses while backgrounded
        // may push no `Transaction.updates` event, so without this the gate could stay open
        // on a stale entitlement until the next cold launch.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard subscriptionState.isPaymentsSurfaceEnabled else { return }
            Task { await subscriptionState.start() }
        }
    }
}
```

No change is needed in `MLBrowser.swift` if the flag rides on `subscriptionState` — verify by reading lines 56–73 and confirming it still compiles.

- [ ] **Step 6: Update `SettingsView` (lines 282, 298)**

```swift
			if subscriptionState.isPaymentsSurfaceEnabled && subscriptionState.isSubscribed {
```

and

```swift
					Text(subscriptionState.isPaymentsSurfaceEnabled ? L10n.Subscription.notSubscribed : L10n.Auth.Account.freeBeta)
```

- [ ] **Step 7: Update `ModelImportView` (line 195) — live flag**

Add `@EnvironmentObject var appState: AppState` if not already present, then:

```swift
			if appState.featureFlags.snapshot.isModelCatalogEnabled {
```

⚠️ This view is presented via a sheet (`DrawerContent.swift:74`). Per AGENTS.md §3, environment objects do **not** reliably cross `.sheet` boundaries on Mac (Designed for iPad) — **re-inject `appState` on that sheet** and verify on the Mac target.

- [ ] **Step 8: Fix the test seam (`SubscriptionStateTests.swift:95`)**

```swift
		XCTAssertEqual(sut.isPremiumUnlocked, FeatureFlagKey.isPaymentsEnabled.defaultValue)
```

Update the `SubscriptionState(provider:)` construction in that file to `SubscriptionState(provider:isPaymentsEnabled:)`.

- [ ] **Step 9: Verify nothing references the old API**

```bash
grep -rn 'FeatureFlags\.' ios --include='*.swift'
```

Expected: **no output**.

- [ ] **Step 10: Build and run the full unit suite**

```bash
cd ios && xcodebuild test -project MLBrowser.xcodeproj -scheme "ML Browser" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MLBrowserUnitTests 2>&1 | tail -20
```

Expected: PASS, no regressions.

- [ ] **Step 11: Run the architecture lint**

Run: `./scripts/harmonize.sh`

Expected: PASS. If `FeatureFlagsState` trips the SwiftUI-import rule, remove the import — do **not** add it to the ratchet baseline.

- [ ] **Step 12: Commit**

```bash
git add -A ios/MLBrowser ios/MLBrowserUnitTests
git commit -m "[AIA-0350] Read feature flags from remote snapshot at all call sites"
```

---

### Task 6: UI-test determinism, dashboard setup, and docs

**Files:**
- Modify: `ios/MLBrowser/iOS/Tools/Testability/UITestLaunchConfiguration.swift`
- Modify: `ios/AGENTS.md` (§3 Feature flags)
- Modify: `ios/TestFlight/WhatToTest.en-US.txt`

**Interfaces:**
- Consumes: `FeatureFlagKey`, `StaticFeatureFlagProvider`.
- Produces: `UITestLaunchConfiguration.featureFlagOverrides: [String: Bool]?`, `currentVersion = 6`.

- [ ] **Step 1: Bump the launch-config schema**

In `UITestLaunchConfiguration.swift`: change `static let currentVersion = 5` to `= 6`, and add:

```swift
	/// Force specific feature flags for a scenario, keyed by `FeatureFlagKey.rawValue`
	/// (AIA-0350). `nil` keeps the baseline (every flag at its compiled default). UI tests
	/// never reach ConfigCat — `DependencyContainer` uses `StaticFeatureFlagProvider`
	/// under tests — so this is the only way to vary a flag in a UI test.
	var featureFlagOverrides: [String: Bool]?
```

- [ ] **Step 2: Honour the overrides in the composition root**

In `DependencyContainer.featureFlagProvider`, replace the test branch:

```swift
		if AppEnvironment.isRunningUnderAnyTests {
			let raw = UITestLaunchConfiguration.fromEnvironment?.featureFlagOverrides ?? [:]
			var overrides: [FeatureFlagKey: Bool] = [:]
			for (key, value) in raw {
				guard let flag = FeatureFlagKey(rawValue: key) else {
					fatalError("Unknown feature flag override '\(key)' — a UI test must never proceed on a misread configuration")
				}
				overrides[flag] = value
			}
			return StaticFeatureFlagProvider(overrides: overrides)
		}
```

- [ ] **Step 3: Verify the UI suite still passes**

```bash
cd ios && xcodebuild test -project MLBrowser.xcodeproj -scheme "ML Browser" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MLBrowserUITests 2>&1 | tail -20
```

Expected: PASS. A version mismatch trap here means a stale `UI_TEST_CONFIG` — rebuild the test target.

- [ ] **Step 4: Configure the ConfigCat dashboard**

In both **Test** and **Production** environments of `Main Config`:
1. Create `isModelCatalogEnabled`, type Boolean, value **On**.
2. Create `isPaymentsEnabled`, type Boolean, value **On**.
3. Delete the sample `isMyFirstFeatureEnabled`.
4. Publish changes in **both** environments.

Both `true` everywhere preserves current behaviour exactly (maintainer's decision).

- [ ] **Step 5: Update AGENTS.md §3 "Feature flags"**

Replace the "For now flags live in source code" and "A proper flag system is a separate, later PR" bullets: flags are now remote via ConfigCat (AIA-0350); `FeatureFlagKey` carries the key + compiled default; defaults fail open; add new flags in both ConfigCat environments **before** shipping code that reads them. Add a changelog entry under §16 dated 2026-07-15.

- [ ] **Step 6: Update WhatToTest**

Add to `ios/TestFlight/WhatToTest.en-US.txt`: no user-visible change; feature flags are now remotely configurable.

- [ ] **Step 7: Verify the whole gate**

```bash
./scripts/swiftlint.sh && ./scripts/harmonize.sh
cd ios && xcodebuild test -project MLBrowser.xcodeproj -scheme "ML Browser" \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```

Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add -A ios/MLBrowser/iOS/Tools/Testability ios/MLBrowser/iOS/State ios/AGENTS.md ios/TestFlight
git commit -m "[AIA-0350] Add UI-test flag overrides and document remote flags"
```

---

## Manual verification before PR

The unit suite cannot prove the ConfigCat integration works — it uses the static provider. Verify for real:

1. Run a **Debug** build on the simulator → it uses the ConfigCat **Test** environment.
2. In the ConfigCat dashboard (Test), flip `isModelCatalogEnabled` to **Off** and publish.
3. Within ~10 minutes (or relaunch), the catalog entry point in `ModelImportView` disappears. **Turn it back On and publish.**
4. Confirm the ConfigCat **Usage & Quota** page shows a non-zero config-JSON download count — it currently reads "your feature flags were never downloaded", so a non-zero value is proof the app really connected.
5. Turn Wi-Fi off, delete and reinstall the app, launch → both features still work (compiled defaults, fail-open).
