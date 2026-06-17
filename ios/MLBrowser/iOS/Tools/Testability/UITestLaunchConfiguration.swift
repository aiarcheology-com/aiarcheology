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
	static let currentVersion = 3

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

	var version: Int = currentVersion

	/// Force-start the interactive onboarding tour on launch, bypassing the
	/// `hasSeenOnboardingTour` gate (AIA-0333). Baseline leaves the tour off. Consumed by the
	/// view layer (`ContentView.handleOnAppear`) via ``shouldStartOnboardingTour``.
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
	/// Route model downloads through `StubDownloadURLProtocol` (AIA-0318) so tests never hit the
	/// network. `nil`/`false` keeps the real network path.
	var stubDownloads: Bool?

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
	@MainActor
	static func applyIfNeeded(to settings: Settings) {
		guard AppEnvironment.isRunningUITests else { return }
		let config = fromEnvironment ?? UITestLaunchConfiguration()

		// 1) Full baseline — every setting the tests depend on, re-applied every launch.
		settings.snapAfterAppStart = false
		settings.isDetectionPaused = false
		settings.fullscreenDetection = false
		settings.reopenLastPage = false
		settings.lastPage = nil
		settings.defaultPage = URL(string: baselineHome)
		settings.historySize = 30
		settings.tiledDetection = true

		// 2) Scenario deltas.
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

		if let fullscreen = config.fullscreenDetection {
			settings.fullscreenDetection = fullscreen
		}
	}

	/// Whether this launch should force-start the onboarding tour (AIA-0333). The single
	/// consumer of `startOnboardingTour`. Always false outside UI tests.
	static var shouldStartOnboardingTour: Bool {
		guard AppEnvironment.isRunningUITests else { return false }
		return fromEnvironment?.startOnboardingTour == true
	}
}
