//
//  UITestLaunchConfiguration.swift
//  AI Archeology
//
//  Deterministic launch state for UI tests (AIA-0189).
//

import Foundation

/// Deterministic launch state for UI tests. A test JSON-encodes this into the
/// `UI_TEST_CONFIG` launch-environment variable; the app decodes and applies it to the
/// live ``Settings`` at the end of `Settings.init()`, gated by
/// `AppEnvironment.isRunningUITests`.
///
/// A **full baseline** is applied on every launch so persisted `UserDefaults` cannot
/// bleed across scenarios; the scenario fields below are deltas over that baseline.
/// When no `UI_TEST_CONFIG` is present the baseline alone is applied — every UI-test
/// launch therefore starts from one known state.
///
/// The whole type is dead code in shipping builds: nothing calls ``applyIfNeeded(to:)``
/// unless `isRunningUITests` is true, which requires the `UI_TESTING=1` launch marker the
/// test target sets.
struct UITestLaunchConfiguration: Codable {

	/// Schema version. Bump when the fields change; a mismatch traps loudly so a stale
	/// test config can never silently pass.
	static let currentVersion = 16

	/// The baseline home URL for the "home page is set" scenario. A real, parseable URL
	/// (RFC-2606 reserved domain) so it exercises the genuine home-load decision; tests
	/// assert the decision (`intendedPageKind`), not the render, so the page is never awaited.
	static let baselineHome = "https://example.com"

	static let environmentKey = "UI_TEST_CONFIG"

	enum PageScenario: String, Codable {
		case home
		case blank
		case last
		/// Load a bundled local-HTML fixture via `WKWebView.loadFileURL` (AIA-0316). Requires
		/// `fixtureName`. Network-free; mutually exclusive with the other scenarios.
		case localFixture
	}

	enum AnalyticsScenario: String, Codable {
		case prompt
		case disabled
		case enabled
	}

	var version: Int = currentVersion

	/// Force-start the interactive onboarding tour on launch, bypassing the
	/// `hasSeenOnboardingTour` gate (AIA-0333). Baseline leaves the tour off. Consumed by the
	/// composition root (`AppState.initialize()`) via ``shouldStartOnboardingTour``, which arms the
	/// tour; `SubscriptionGateView` starts it once nothing is owed the screen ahead of it (AIA-0567).
	var startOnboardingTour: Bool?
	/// Which page the browser should decide to load. `nil` keeps the baseline (home).
	var pageScenario: PageScenario?
	/// Optional custom home URL for `pageScenario == .home`.
	var defaultPageOverride: String?
	/// The page to seed for `pageScenario == .last`.
	var lastPage: String?
	/// Resource base name of the bundled HTML fixture for `pageScenario == .localFixture`
	/// (e.g. `"uitest_page"` → `uitest_page.html` in the app bundle).
	var fixtureName: String?
	/// Override fullscreen-detection setting. `nil` keeps the baseline (off).
	var fullscreenDetection: Bool?
	/// Override the disable-detection-animations setting. `nil` keeps the baseline (off = animated).
	var disableDetectionAnimations: Bool?
	/// Optional snapshot cadence for start-lifecycle coverage. Kept inside Settings' supported
	/// 1...10-second range so UI tests exercise the production timer contract.
	var snapFrequency: Double?
	/// Route model downloads through `StubDownloadURLProtocol` (AIA-0318) so tests never hit the
	/// network. `nil`/`false` keeps the real network path.
	var stubDownloads: Bool?
	/// Seed the downloaded FastViT test fixture ENABLED (AIA-0375), so classification
	/// tests exercise the real model without scripting the drawer. `nil`/`false`
	/// keeps the baseline (only the two first-party demos, both disabled).
	var enableClassifyDemo: Bool?
	/// Auto-open the first seeded model's settings in post-import **type-review** mode on the
	/// drawer's first appearance (AIA-0402), so UI tests can exercise the confirmation banner /
	/// red-Disabled footnote without driving the un-scriptable file import. Consumed by
	/// ``shouldReviewFirstModelType``; `nil`/`false` keeps the baseline (no review).
	var reviewFirstModelType: Bool?
	/// Force specific feature flags for a scenario, keyed by `FeatureFlagKey.rawValue`
	/// (AIA-0350). `nil` keeps the baseline (every flag at its compiled default).
	/// UI tests never reach ConfigCat — `DependencyContainer` uses `StaticFeatureFlagProvider`
	/// under tests — so this is the only way to vary a flag in a UI test. An unknown key
	/// traps, consistent with this type's "never proceed on a misread configuration" rule.
	var featureFlagOverrides: [String: Bool]?
	/// Deterministic first-run analytics state. The baseline skips the choice for existing UI
	/// suites; dedicated tests opt into `.prompt` and prove it precedes auth/subscription gates.
	var analyticsScenario: AnalyticsScenario?
	/// Raw JSON for the `appMessages` remote setting (AIA-0115), injected into
	/// `StaticFeatureFlagProvider` so UI tests can serve deterministic messages. Deliberately
	/// separate from `featureFlagOverrides`, which stays strictly `FeatureFlagKey` → Bool.
	/// `nil` keeps the baseline (no messages).
	var appMessagesJSON: String?
	/// Pre-date the app-managed free-access window (AIA-0556) as though it had been granted this
	/// many days ago. `nil`/absent keeps the baseline: no anchor, so a launch that may grant one
	/// behaves like a genuine first install.
	///
	/// It exists because **every UI-test launch is a fresh install**: `Settings.init()` wipes the
	/// ephemeral suite and `DependencyContainer` swaps the Keychain mirror for an in-memory store, so
	/// relaunching cannot carry a window forward and the expired-wall state is otherwise unreachable
	/// from a test. Seeding the *fast* half alone is enough —
	/// `FreeAccessAnchorService.reconciledWindow()` folds an absent durable record into it and
	/// repairs the mirror on the way past.
	var freeAccessAnchorAgeDays: Int?

	/// Seed the anchor with its day-0 screen **not yet shown** (AIA-0955). `nil`/`false` keeps the
	/// default `day0Shown: true`. The one state that owes the priced Welcome screen from a previous
	/// launch — a force-quit before it rendered — which a payments-off session must not raise.
	var freeAccessDay0Unshown: Bool?

	/// A shared-finding link to deliver at launch, as if `onOpenURL` had handed it over (AIA-0835).
	///
	/// The deeplink is the whole feature and a UI test cannot otherwise reach it: there is no way to
	/// hand the app a URL from XCUITest without driving Safari, which is slow and flaky. Applied
	/// only under `isRunningUITests`, like everything else in this type.
	var sharedLinkURL: String?

	/// How many times ``sharedLinkURL`` is delivered on this launch. `nil` means once (AIA-0836).
	///
	/// Exists because the duplicate-import guarantee cannot be tested across two launches: every
	/// UI-test launch is a fresh install — `Settings.init()` wipes the ephemeral suite and
	/// `DataController` destroys the UI-test store — so relaunching with the same link stores it into
	/// an empty database and proves nothing. Delivering twice inside one session is also the honest
	/// shape of the real case: a user re-scanning a printed card while the app is open.
	var sharedLinkDeliveries: Int?

	#if DEBUG
	/// Use the real Clerk provider instead of `MockAuthProvider` for this launch (AIA-0984).
	/// `nil`/`false` keeps the baseline: every UI test runs on the mock.
	///
	/// It exists for the headless-parity sign-in flow, which must sign in and out through Clerk's
	/// own `AuthView` and `UserProfileView` on the **development** instance with a
	/// `+clerk_test` address — the flow the headless build drives against the same instance. Read
	/// only by ``requestsRealAuth``; `DependencyContainer.authProviderSelection` traps when the
	/// build has no `pk_` key or does not point at development, so it never falls back to the mock.
	/// `#if DEBUG`, like the mock it replaces, so Release neither decodes nor honours it.
	///
	/// Removal: delete this field, ``requestsRealAuth``, its input to the selection, and the
	/// parity sign-in flow that sets it.
	var usesRealAuth: Bool?
	#endif

	/// Decoded from the launch environment, or `nil` if absent. Traps on malformed input
	/// or version mismatch — a UI test must never proceed on a misread configuration.
	static var fromEnvironment: UITestLaunchConfiguration? {
		guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
		guard let data = raw.data(using: .utf8) else {
			fatalError("\(environmentKey) is not valid UTF-8")
		}
		do {
			let config = try JSONDecoder().decode(UITestLaunchConfiguration.self, from: data)
			guard config.version == currentVersion else {
				fatalError("\(environmentKey) version \(config.version) != expected \(currentVersion)")
			}
			return config
		} catch {
			fatalError("Failed to decode \(environmentKey): \(error)")
		}
	}

	/// Applies a full deterministic baseline, then scenario deltas, to the live `Settings`.
	/// No-op outside UI tests. `@MainActor` because `Settings` is main-actor isolated.
	///
	/// The three steps below were one function until it crossed the cyclomatic-complexity limit. They
	/// are split along the seams the original already marked in comments, and they run in the same
	/// order they always did — baseline first, because both delta steps overwrite parts of it.
	@MainActor
	static func applyIfNeeded(to settings: Settings) {
		guard AppEnvironment.isRunningUITests else { return }
		let config = fromEnvironment ?? UITestLaunchConfiguration()
		applyBaseline(to: settings)
		applyPageScenario(config, to: settings)
		applyDetectionAndAnalyticsDeltas(config, to: settings)
	}

	/// Every setting the tests depend on, re-applied every launch, so no scenario can inherit state
	/// from the one before it.
	@MainActor
	private static func applyBaseline(to settings: Settings) {
		settings.snapAfterAppStart = false
		settings.snapFrequency = 3.0
		settings.isDetectionPaused = false
		settings.fullscreenDetection = false
		settings.disableDetectionAnimations = false
		settings.reopenLastPage = false
		settings.lastPage = nil
		settings.defaultPage = URL(string: baselineHome)
		settings.historySize = 30
		settings.pyramidTiling = true
		settings.analyticsEnabled = false
		settings.analyticsChoiceMade = true
		// The launch-value mirror must never leak across launches in the harness: the composition
		// root prefers it over the static provider's overrides (AIA-0437, generalised in AIA-0513).
		settings.remoteFlagLaunchValues = [:]
		// Not a `Settings` property, so `Settings.init()`'s suite wipe is the only thing clearing it
		// today. Cleared explicitly anyway: this is the file that promises a full baseline on every
		// launch, and a seeded window bleeding into the next scenario would silently turn a
		// first-install test into a day-N one (AIA-0556).
		settings.persistenceStore.removeObject(forKey: FreeAccessAnchorService.defaultsKey)
	}

	/// Which page the app opens on. Every branch that cannot be satisfied traps rather than falling
	/// back, so a misconfigured scenario fails loudly instead of asserting the wrong behaviour.
	@MainActor
	static func applyPageScenario(_ config: UITestLaunchConfiguration, to settings: Settings) {
		switch config.pageScenario {
		case .blank:
			settings.defaultPage = nil
			settings.reopenLastPage = false
		case .last:
			settings.reopenLastPage = true
			// Trap rather than silently fall back to the home page (which would let a
			// misconfigured `.last` scenario pass while asserting the wrong behavior).
			guard let lastPageString = config.lastPage, let url = URL(string: lastPageString) else {
				fatalError("\(environmentKey) pageScenario=.last requires a parseable lastPage")
			}
			settings.lastPage = url
		case .home, .none:
			if let override = config.defaultPageOverride, let url = URL(string: override) {
				settings.defaultPage = url
			}
		case .localFixture:
			// Load a bundled local-HTML fixture from the app bundle. Trap rather than fall back to a
			// network page, so a misconfigured fixture can never silently pass. Carried on a transient
			// `launchFixtureURL` (not `defaultPage`) to skip persistence, validation, and history.
			guard let name = config.fixtureName,
				  let url = Bundle.main.url(forResource: name, withExtension: "html") else {
				fatalError("\(environmentKey) pageScenario=.localFixture requires a bundled HTML fixture named '\(config.fixtureName ?? "<nil>")'")
			}
			settings.launchFixtureURL = url
		}
	}

	/// The remaining deltas: detection toggles, snapshot cadence, the analytics scenario, and the
	/// seeded free-access window.
	@MainActor
	static func applyDetectionAndAnalyticsDeltas(_ config: UITestLaunchConfiguration, to settings: Settings) {
		if let fullscreen = config.fullscreenDetection {
			settings.fullscreenDetection = fullscreen
		}

		if let disableDetectionAnimations = config.disableDetectionAnimations {
			settings.disableDetectionAnimations = disableDetectionAnimations
		}

		if let snapFrequency = config.snapFrequency {
			guard (1.0...10.0).contains(snapFrequency) else {
				fatalError("\(environmentKey) snapFrequency must be within 1...10 seconds, got \(snapFrequency)")
			}
			settings.snapFrequency = snapFrequency
		}

		switch config.analyticsScenario {
		case .prompt:
			settings.analyticsEnabled = false
			settings.analyticsChoiceMade = false
		case .disabled, .none:
			break
		case .enabled:
			settings.analyticsEnabled = true
		}

		if let ageDays = config.freeAccessAnchorAgeDays {
			seedFreeAccessAnchor(ageDays: ageDays, day0Shown: config.freeAccessDay0Unshown != true, in: settings)
		}
	}

	/// Writes a free-access anchor granted `ageDays` ago into the fast store (AIA-0556).
	///
	/// `day0Shown` is seeded `true`, which is not a detail: a window that had never been explained
	/// owes its day-0 paywall no matter how old it is, so a mid-window scenario would meet that
	/// screen instead of whatever it named. A real user that far in has already met it, and this
	/// seeds the state they are actually in.
	@MainActor
	private static func seedFreeAccessAnchor(ageDays: Int, day0Shown: Bool, in settings: Settings) {
		let calendar = Calendar.current
		// Trap rather than fall back to "no anchor": a scenario that silently degraded into a fresh
		// install would assert the wrong thing and pass.
		// A negative age is a misconfigured scenario, not a supported one: it would seed a window
		// granted in the *future*, which reconciliation now repairs — so the test would quietly
		// assert against a freshly re-anchored day-0 window instead of the state it named.
		guard ageDays >= 0 else {
			fatalError("\(environmentKey) freeAccessAnchorAgeDays must be non-negative, got \(ageDays)")
		}
		guard let grantedAt = calendar.date(byAdding: .day, value: -ageDays, to: Date()) else {
			fatalError("\(environmentKey) freeAccessAnchorAgeDays=\(ageDays) is not a representable date")
		}
		let frozen = FreeAccessWindow.record(grantedAt: grantedAt, thresholds: .standard, calendar: calendar)
		let record = FreeAccessWindow.Record(
			grantedAt: frozen.grantedAt,
			expiresAt: frozen.expiresAt,
			maxObservedDate: frozen.maxObservedDate,
			day0Shown: day0Shown
		)
		guard let data = try? JSONEncoder().encode(record) else {
			fatalError("\(environmentKey) could not encode the seeded free-access anchor")
		}
		settings.persistenceStore.set(data, forKey: FreeAccessAnchorService.defaultsKey)
	}

	/// Whether this launch should force-start the onboarding tour (AIA-0333). The single
	/// consumer of `startOnboardingTour`. Always false outside UI tests.
	static var shouldStartOnboardingTour: Bool {
		guard AppEnvironment.isRunningUITests else { return false }
		return fromEnvironment?.startOnboardingTour == true
	}

	#if DEBUG
	/// Whether this launch asks for the real Clerk provider (AIA-0984). The single consumer of
	/// `usesRealAuth`. Always false outside UI tests.
	static var requestsRealAuth: Bool {
		guard AppEnvironment.isRunningUITests else { return false }
		return fromEnvironment?.usesRealAuth == true
	}
	#endif

	/// Whether this launch should auto-open the first seeded model's settings in type-review mode
	/// (AIA-0402). The single consumer of `reviewFirstModelType`. Always false outside UI tests.
	static var shouldReviewFirstModelType: Bool {
		guard AppEnvironment.isRunningUITests else { return false }
		return fromEnvironment?.reviewFirstModelType == true
	}
}
