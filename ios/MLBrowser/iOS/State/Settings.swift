//
//  Settings.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import SwiftUI
import UIKit

@MainActor
protocol Validatable {
	func validate() throws
}

enum ValidationError: Error {
	case invalidData(String)
}

// TODO: use another way to handle the defaults, @dynamicMemberLookup, or so
final class Settings: ObservableObject, Validatable {

	private enum UserDefaultsKeys {
		static let lastPage = "lastPage"
		static let isDetectionPaused = "isDetectionPaused"
		static let reopenLastPage = "reopenLastPage"
		static let isFirstLaunch = "isFirstLaunch"
		static let showIdentifiers = "showIdentifiers"
		static let snapAfterAppStart = "snapAfterAppStart"
		static let snapFrequency = "snapFrequency"
		static let resetHistory = "resetHistory"
		static let sizeHistory = "sizeHistory"
		static let defaultPage = "defaultPage"
		static let removeAnnotationOnDrag = "removeAnnotationOnDrag"
		static let entityId = "entityId"
		static let fullscreenDetection = "fullscreenDetection"
		/// Legacy key retained so the rename `tiledDetection`→`pyramidTiling` (AIA-0426) keeps every
		/// existing user's persisted value.
		static let pyramidTiling = "tiledDetection"
		static let grid3x3Tiling = "grid3x3Tiling"
		static let tiledBorders = "tiledBorders"
		/// Optional TelemetryDeck analytics. Both values default to false: a fresh install sends
		/// no telemetry and presents a choice before the app's auth/subscription gates.
		static let analyticsEnabled = "analyticsEnabled"
		static let analyticsChoiceMade = "analyticsChoiceMade"
		/// A user's screenshot-reporting decision (AIA-0454). An absent value means the user has
		/// not decided yet; `true` enables offers and `false` disables them.
		static let screenshotDetectionEnabled = "screenshotDetectionEnabled"
		/// Previous AIA-0454 state. It is read once to preserve an explicit "Don't ask again"
		/// answer, then removed because a former `supportPromptShown` value was not a decision.
		static let legacySupportPromptShown = "supportPromptShown"
		static let legacySupportPromptDeclined = "supportPromptDeclined"
	}

	public var isFirstLaunchMarked: Bool = false

	@Published public var isDetectionPaused: Bool = false

	@Published public var applicationResetButtonToggle: Bool = false

	@Published public var historySize: Int {
		didSet {
			defaults.set(historySize, forKey: UserDefaultsKeys.sizeHistory)
		}
	}

	@Published public var snapAfterAppStart: Bool {
		didSet {
			defaults.set(snapAfterAppStart, forKey: UserDefaultsKeys.snapAfterAppStart)
		}
	}

	@Published public var reopenLastPage: Bool {
		didSet {
			defaults.set(reopenLastPage, forKey: UserDefaultsKeys.reopenLastPage)
		}
	}

	@Published public var snapFrequency: Double {
		didSet {
			defaults.set(snapFrequency, forKey: UserDefaultsKeys.snapFrequency)
		}
	}

	@Published public var resetHistory: Bool {
		didSet {
			defaults.set(resetHistory, forKey: UserDefaultsKeys.resetHistory)
		}
	}

	@Published public var defaultPage: URL? {
		didSet {
			defaults.set(defaultPage, forKey: UserDefaultsKeys.defaultPage)
		}
	}

	@Published public var lastPage: URL? {
		didSet {
			defaults.set(lastPage, forKey: UserDefaultsKeys.lastPage)
		}
	}

	/// A bundled local-HTML page the browser should load on launch instead of the home page.
	/// Set only by `UITestLaunchConfiguration.applyIfNeeded` under `AppEnvironment.isRunningUITests`
	/// (AIA-0316 UI-test harness); deliberately **not** persisted to `UserDefaults` and never read in
	/// shipping. Carried separately from `defaultPage` so it skips persistence, the address-bar/
	/// validation host checks, and history creation.
	public var launchFixtureURL: URL?

	/// A remote page the browser should load on first launch when the onboarding tour
	/// auto-starts, so the address-bar step points at a real demo page (the Bavaria LiDAR
	/// geoportal) instead of the default home (AIA-0333). Set once by `AppState.initialize()`
	/// before the UI appears; **not** persisted. Loaded through the normal pipeline (unlike
	/// `launchFixtureURL`, which is a local file), so it records history and fills the bar.
	public var onboardingInitialPage: URL?

	@Published public var removeAnnotationOnDrag: Bool {
		didSet {
			defaults.set(removeAnnotationOnDrag, forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		}
	}

	@Published public var showIdentifiers: Bool {
		didSet {
			defaults.set(showIdentifiers, forKey: UserDefaultsKeys.showIdentifiers)
		}
	}

	/// When enabled, starting detection hides the browser chrome (fullscreen mode
	/// with the floating toggle button). When disabled, detection runs with the
	/// chrome visible and no floating button is shown.
	@Published public var fullscreenDetection: Bool {
		didSet {
			defaults.set(fullscreenDetection, forKey: UserDefaultsKeys.fullscreenDetection)
		}
	}

	/// AIA-0217/AIA-0426: the "Pyramid" tiling scheme — each detection snapshot runs through 6
	/// regions (4 quadrants + center + full frame) instead of one full-frame pass, so edge
	/// artifacts reach the model at ~double resolution at the cost of 6× inference per snapshot.
	/// Persisted under the legacy `"tiledDetection"` key so existing users keep their value.
	@Published public var pyramidTiling: Bool {
		didSet {
			defaults.set(pyramidTiling, forKey: UserDefaultsKeys.pyramidTiling)
		}
	}

	/// AIA-0426: the "3x3" tiling scheme — 9 grid cells + a full-frame pass (10 regions). Independent
	/// of `pyramidTiling`; both on runs the union of their regions. Off by default (opt-in).
	@Published public var grid3x3Tiling: Bool {
		didSet {
			defaults.set(grid3x3Tiling, forKey: UserDefaultsKeys.grid3x3Tiling)
		}
	}

	/// AIA-0426 debug aid: when on, a red border is drawn around each tile fed to the detector so the
	/// tile split is visible. Purely visual — never affects detection. Off by default.
	@Published public var tiledBorders: Bool {
		didSet {
			defaults.set(tiledBorders, forKey: UserDefaultsKeys.tiledBorders)
		}
	}

	/// Optional product analytics. Off by default; changing it is mediated by `AnalyticsState`,
	/// which initializes or terminates the SDK accordingly.
	@Published public var analyticsEnabled: Bool {
		didSet {
			defaults.set(analyticsEnabled, forKey: UserDefaultsKeys.analyticsEnabled)
		}
	}

	/// Records that the first-run analytics choice has been shown and answered. It is separate
	/// from `analyticsEnabled` so choosing "Not now" remains a valid, durable off choice.
	@Published public var analyticsChoiceMade: Bool {
		didSet {
			defaults.set(analyticsChoiceMade, forKey: UserDefaultsKeys.analyticsChoiceMade)
		}
	}

	/// Whether screenshot detection should offer a problem report (AIA-0454).
	///
	/// `nil` is intentionally distinct from `true` and `false`: it means the user has not yet
	/// answered the first screenshot offer. Choosing "Report a problem" stores `true`, so offers
	/// continue for later screenshots; choosing "Don't ask again" stores `false`. This is the
	/// same preference exposed by Settings → About → Report a problem.
	@Published public var screenshotDetectionEnabled: Bool? {
		didSet {
			if let screenshotDetectionEnabled {
				defaults.set(screenshotDetectionEnabled, forKey: UserDefaultsKeys.screenshotDetectionEnabled)
			} else {
				defaults.removeObject(forKey: UserDefaultsKeys.screenshotDetectionEnabled)
			}
		}
	}

	/// The tiling scheme(s) currently enabled, derived from the two independent toggles. Empty when
	/// both are off (the detector then runs full-frame only).
	var tilingSchemes: TilingScheme {
		var schemes: TilingScheme = []
		if pyramidTiling { schemes.insert(.pyramid) }
		if grid3x3Tiling { schemes.insert(.grid3x3) }
		return schemes
	}

	@Published public var entityId: UUID? {
		didSet {
			defaults.set(entityId?.uuidString, forKey: UserDefaultsKeys.entityId)
		}
	}

	@Published public var isFirstLaunch: Bool { // is being reseted in MLBrowser
		didSet {
			defaults.set(isFirstLaunch, forKey: UserDefaultsKeys.isFirstLaunch)
		}
	}

	/// Persistence store. Real builds use `.standard`; UI-test launches use an ephemeral
	/// suite so test config never pollutes (or is polluted by) the simulator's real
	/// defaults (AIA-0298).
	private let defaults: UserDefaults

	private static let uiTestSuiteName = "com.aiarcheology.uitests"

	init() {
		// UI-test launches get an ephemeral suite, cleared each launch, so deterministic
		// test state never touches the real `standard` domain (AIA-0298).
		let defaults: UserDefaults
		if AppEnvironment.isRunningUITests {
			// Fail fast: silently falling back to .standard would defeat the isolation and
			// re-pollute the simulator's real defaults (AIA-0298).
			guard let suite = UserDefaults(suiteName: Self.uiTestSuiteName) else {
				fatalError("Could not create UI-test UserDefaults suite '\(Self.uiTestSuiteName)'")
			}
			suite.removePersistentDomain(forName: Self.uiTestSuiteName)
			defaults = suite
		} else {
			defaults = .standard
		}
		self.defaults = defaults

		let defaultValues: [String: Any] = [
			UserDefaultsKeys.sizeHistory: 30,
            UserDefaultsKeys.reopenLastPage: false,
            UserDefaultsKeys.isFirstLaunch: true,
            UserDefaultsKeys.showIdentifiers: false,
            UserDefaultsKeys.snapAfterAppStart: false,
            UserDefaultsKeys.snapFrequency: 3.0,
            UserDefaultsKeys.resetHistory: false,
            // swiftlint:disable:next force_unwrapping
            UserDefaultsKeys.defaultPage: URL(string: "https://www.google.com")!,
            UserDefaultsKeys.removeAnnotationOnDrag: false,
            UserDefaultsKeys.entityId: UUID().uuidString,
            // Off by default: hitting play and losing the chrome surprises
            // first-time users; fullscreen detection is an opt-in.
            UserDefaultsKeys.fullscreenDetection: false,
            // On by default: simulator verification confirmed the edge-detection win
            // (AIA-0217 plan, decision 1); the toggle exists to opt out of the 6x
            // inference cost.
            UserDefaultsKeys.pyramidTiling: true,
            // 3x3 tiling and the debug tile-border overlay are opt-in (AIA-0426).
            UserDefaultsKeys.grid3x3Tiling: false,
			UserDefaultsKeys.tiledBorders: false,
			UserDefaultsKeys.analyticsEnabled: false,
			UserDefaultsKeys.analyticsChoiceMade: false
        ]

		// Register default values
		defaults.register(defaults: defaultValues)
		self.historySize = defaults.integer(forKey: UserDefaultsKeys.sizeHistory)
		self.reopenLastPage = defaults.bool(forKey: UserDefaultsKeys.reopenLastPage)
		self.isFirstLaunch = defaults.bool(forKey: UserDefaultsKeys.isFirstLaunch)
		self.showIdentifiers = defaults.bool(forKey: UserDefaultsKeys.showIdentifiers)
		self.snapAfterAppStart = defaults.bool(forKey: UserDefaultsKeys.snapAfterAppStart)
		self.snapFrequency = defaults.double(forKey: UserDefaultsKeys.snapFrequency)
		self.resetHistory = defaults.bool(forKey: UserDefaultsKeys.resetHistory)
		self.defaultPage = defaults.url(forKey: UserDefaultsKeys.defaultPage)
		self.lastPage = defaults.url(forKey: UserDefaultsKeys.lastPage)
		self.removeAnnotationOnDrag = defaults.bool(forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		self.fullscreenDetection = defaults.bool(forKey: UserDefaultsKeys.fullscreenDetection)
		self.pyramidTiling = defaults.bool(forKey: UserDefaultsKeys.pyramidTiling)
		self.grid3x3Tiling = defaults.bool(forKey: UserDefaultsKeys.grid3x3Tiling)
		self.tiledBorders = defaults.bool(forKey: UserDefaultsKeys.tiledBorders)
		self.analyticsEnabled = defaults.bool(forKey: UserDefaultsKeys.analyticsEnabled)
		self.analyticsChoiceMade = defaults.bool(forKey: UserDefaultsKeys.analyticsChoiceMade)
		if let storedScreenshotDetection = defaults.object(forKey: UserDefaultsKeys.screenshotDetectionEnabled) as? Bool {
			self.screenshotDetectionEnabled = storedScreenshotDetection
		} else if defaults.bool(forKey: UserDefaultsKeys.legacySupportPromptDeclined) {
			// `supportPromptDeclined` was the old explicit "no". A shown-but-not-declined alert
			// does not say whether the user chose Report or Cancel, so let that user decide again.
			self.screenshotDetectionEnabled = false
			defaults.set(false, forKey: UserDefaultsKeys.screenshotDetectionEnabled)
		} else {
			self.screenshotDetectionEnabled = nil
		}
		defaults.removeObject(forKey: UserDefaultsKeys.legacySupportPromptShown)
		defaults.removeObject(forKey: UserDefaultsKeys.legacySupportPromptDeclined)
		if let uuidString = defaults.string(forKey: UserDefaultsKeys.entityId),
		   let uuid = UUID(uuidString: uuidString) {
			self.entityId = uuid
		}

		// UI-test seam: overwrite the just-loaded values with a deterministic baseline
		// (+ scenario deltas) so persisted state can't bleed between test launches.
		// No-op outside UI tests. Safe here because Settings is the leaf singleton built
		// before any consumer (Guide/BrowserState) reads it.
		UITestLaunchConfiguration.applyIfNeeded(to: self)
	}

	func validate() throws {
		if (snapFrequency >= 1.0 && snapFrequency <= 10.0).not {
			throw ValidationError.invalidData("Settings's snapFrequency is required between 1.0 and 10.0!")
		}
		// A blank home page is valid: allow empty/nil and about:blank (any case). Otherwise
		// the value must be a *loadable* URL — a real http(s) input WITH a host. "https://"
		// classifies as `.url` but has no host and can never load, so require host != nil
		// (AIA-0298).
		if let page = defaultPage?.absoluteString,
			page.isEmpty == false,
			page.lowercased() != "about:blank" {
			let isLoadableURL = page.browserInputType == .url && defaultPage?.host() != nil
			if isLoadableURL.not {
				throw ValidationError.invalidData("Settings's defaultPage must be empty, about:blank, or a valid URL with a host.")
			}
		}
		if entityId.isNil || entityId?.uuidString.isEmpty == true {
			throw ValidationError.invalidData("Settings's entityId is required.")
		}
	}

	func reset() {
		isDetectionPaused = false
		historySize = 30
		reopenLastPage = false
		isFirstLaunchMarked = false
		isFirstLaunch = true
		showIdentifiers = false
		snapAfterAppStart = false
		snapFrequency = 3.0
		resetHistory = false
		defaultPage = URL(string: "https://www.google.com")
		removeAnnotationOnDrag = false
		entityId = UUID()
		lastPage = nil
		fullscreenDetection = false
		pyramidTiling = true
		grid3x3Tiling = false
		tiledBorders = false
		analyticsEnabled = false
		analyticsChoiceMade = false
		screenshotDetectionEnabled = nil

		defaults.removeObject(forKey: UserDefaultsKeys.lastPage)
		defaults.set(historySize, forKey: UserDefaultsKeys.sizeHistory)
		defaults.set(reopenLastPage, forKey: UserDefaultsKeys.reopenLastPage)
		defaults.set(isFirstLaunch, forKey: UserDefaultsKeys.isFirstLaunch)
		defaults.set(showIdentifiers, forKey: UserDefaultsKeys.showIdentifiers)
		defaults.set(snapAfterAppStart, forKey: UserDefaultsKeys.snapAfterAppStart)
		defaults.set(snapFrequency, forKey: UserDefaultsKeys.snapFrequency)
		defaults.set(resetHistory, forKey: UserDefaultsKeys.resetHistory)
		defaults.set(defaultPage, forKey: UserDefaultsKeys.defaultPage)
		defaults.set(removeAnnotationOnDrag, forKey: UserDefaultsKeys.removeAnnotationOnDrag)
		defaults.set(entityId?.uuidString, forKey: UserDefaultsKeys.entityId)
		defaults.set(fullscreenDetection, forKey: UserDefaultsKeys.fullscreenDetection)
		defaults.set(pyramidTiling, forKey: UserDefaultsKeys.pyramidTiling)
		defaults.set(grid3x3Tiling, forKey: UserDefaultsKeys.grid3x3Tiling)
		defaults.set(tiledBorders, forKey: UserDefaultsKeys.tiledBorders)
		defaults.set(analyticsEnabled, forKey: UserDefaultsKeys.analyticsEnabled)
		defaults.set(analyticsChoiceMade, forKey: UserDefaultsKeys.analyticsChoiceMade)
		defaults.removeObject(forKey: UserDefaultsKeys.screenshotDetectionEnabled)
		defaults.removeObject(forKey: UserDefaultsKeys.legacySupportPromptShown)
		defaults.removeObject(forKey: UserDefaultsKeys.legacySupportPromptDeclined)
	}

}
