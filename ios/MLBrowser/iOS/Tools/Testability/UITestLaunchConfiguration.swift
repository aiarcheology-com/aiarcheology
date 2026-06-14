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
	static let currentVersion = 1

	/// The baseline home URL — `about:blank`, so a "home page is set" launch makes a load
	/// **decision** without any network traffic (tests assert the decision, not the render).
	static let baselineHome = "about:blank"

	static let environmentKey = "UI_TEST_CONFIG"

	enum PageScenario: String, Codable {
		case home
		case blank
		case last
	}

	var version: Int = currentVersion

	/// Present the welcome wizard (`keepSlideShowActive = true`). Baseline skips it.
	var presentWizard: Bool?
	/// Which page the browser should decide to load. `nil` keeps the baseline (home).
	var pageScenario: PageScenario?
	/// Optional custom home URL for `pageScenario == .home`.
	var defaultPageOverride: String?
	/// The page to seed for `pageScenario == .last`.
	var lastPage: String?
	/// Override fullscreen-detection setting. `nil` keeps the baseline (off).
	var fullscreenDetection: Bool?

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
		settings.keepSlideShowActive = false
		settings.snapAfterAppStart = false
		settings.isDetectionPaused = false
		settings.fullscreenDetection = false
		settings.reopenLastPage = false
		settings.lastPage = nil
		settings.defaultPage = URL(string: baselineHome)
		settings.historySize = 30
		settings.tiledDetection = true

		// 2) Scenario deltas.
		if config.presentWizard == true {
			settings.keepSlideShowActive = true
		}

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
		}

		if let fullscreen = config.fullscreenDetection {
			settings.fullscreenDetection = fullscreen
		}
	}
}
