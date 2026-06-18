//
//  Settings.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation

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
		static let tiledDetection = "tiledDetection"
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

	/// AIA-0217: when enabled, each detection snapshot runs through 6 regions (4 quadrants
	/// + center + full frame) instead of one full-frame pass — edge artifacts reach the
	/// model at roughly double resolution at the cost of 6× inference per snapshot.
	@Published public var tiledDetection: Bool {
		didSet {
			defaults.set(tiledDetection, forKey: UserDefaultsKeys.tiledDetection)
		}
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
            UserDefaultsKeys.tiledDetection: true
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
		self.tiledDetection = defaults.bool(forKey: UserDefaultsKeys.tiledDetection)
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
		tiledDetection = true

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
		defaults.set(tiledDetection, forKey: UserDefaultsKeys.tiledDetection)
	}
}
