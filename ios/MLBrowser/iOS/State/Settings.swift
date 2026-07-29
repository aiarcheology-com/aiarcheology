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
		static let disableDetectionAnimations = "disableDetectionAnimations"
		/// Legacy key retained so the rename `tiledDetection`→`pyramidTiling` (AIA-0426) keeps every
		/// existing user's persisted value.
		static let pyramidTiling = "tiledDetection"
		static let grid3x3Tiling = "grid3x3Tiling"
		static let tiledBorders = "tiledBorders"
		/// Optional TelemetryDeck analytics. Both values default to false: a fresh install sends
		/// no telemetry and presents a choice after the app's auth/subscription gates (AIA-0447).
		static let analyticsEnabled = "analyticsEnabled"
		static let analyticsChoiceMade = "analyticsChoiceMade"
		/// Which account the stored analytics choice belongs to (AIA-0437).
		static let analyticsConsentAccountHash = "analyticsConsentAccountHash"
		static let analyticsAccountEnabled = "analyticsAccountEnabled"
		static let signInOfferShown = "signInOfferShown"
		/// Which account has already had each once-per-account funnel event reported (AIA-0437).
		/// Stored as the same SHA-256 as the consent hash, never a raw account id.
		static let analyticsActivationReportedAccountHash = "analyticsActivationReportedAccountHash"
		static let analyticsSignedInReportedAccountHash = "analyticsSignedInReportedAccountHash"
		/// Last-known remote values of every feature flag, mirrored for the next launch (AIA-0513).
		static let remoteFlagLaunchValues = "remoteFlagLaunchValues"
		/// A user's screenshot-reporting decision (AIA-0454). An absent value means the user has
		/// not decided yet; `true` enables offers and `false` disables them.
		static let screenshotDetectionEnabled = "screenshotDetectionEnabled"
		/// Previous AIA-0454 state. It is read once to preserve an explicit "Don't ask again"
		/// answer, then removed because a former `supportPromptShown` value was not a decision.
		static let legacySupportPromptShown = "supportPromptShown"
		static let legacySupportPromptDeclined = "supportPromptDeclined"
		/// Winning moments accumulated since the last review request (AIA-0117). A suppressed or
		/// ineligible moment keeps its count; the only two things that zero it are spending a
		/// request and `reset()`, and losing the count can only ever delay a prompt.
		static let ratingPromptEventCount = "ratingPromptEventCount"
		/// When the app last *requested* a review — never when one was *displayed*, which StoreKit
		/// does not report. Absent until the first request.
		static let ratingPromptLastRequestDate = "ratingPromptLastRequestDate"
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

	/// When enabled, detection overlays render as a static marker instead of animating
	/// (no per-frame pulse/scale/fade), cutting the animation CPU/GPU cost. Detections still
	/// appear and clear with the data. Off by default (today's animated behavior).
	@Published public var disableDetectionAnimations: Bool {
		didSet {
			defaults.set(disableDetectionAnimations, forKey: UserDefaultsKeys.disableDetectionAnimations)
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

	/// Which account the stored analytics choice belongs to, as a SHA-256 of the Clerk account id
	/// so no raw account identifier is ever persisted (AIA-0437).
	///
	/// Consent is **per account**, not per device. A device-wide choice plus an account-derived
	/// analytics identity would mean account B is tracked under a cross-device identity that only
	/// account A ever agreed to. When the signed-in account does not match this hash, the stored
	/// choice does not apply: the user is asked again and the state fails closed until they answer.
	///
	/// Only one account's choice is remembered at a time, so alternating between two accounts on
	/// one device asks each time it switches. That is the deliberate trade for not keeping a
	/// per-account consent ledger on the device.
	///
	/// `nil` means "no choice belongs to any account yet" — either a fresh install, or a legacy
	/// device-wide choice that has not yet been bound to an account by `AnalyticsState`.
	@Published public var analyticsConsentAccountHash: String? {
		didSet {
			Self.write(analyticsConsentAccountHash, forKey: UserDefaultsKeys.analyticsConsentAccountHash, to: defaults)
		}
	}

	/// The account bucket's on/off value, paired with ``analyticsConsentAccountHash`` (AIA-0536).
	///
	/// Separate from ``analyticsEnabled`` because there are two consent buckets and one flag cannot
	/// hold two independent answers. ``analyticsEnabled`` belongs to the anonymous/device-wide
	/// bucket; this one belongs to whichever account the hash names. Nothing that writes one bucket
	/// ever touches the other, which is what stops each from silently overwriting the other's answer
	/// and re-prompting forever.
	///
	/// Shared across accounts — only the hash is per-account — so whoever consented last owns the
	/// value, and the hash is what gates who may use it.
	@Published public var analyticsAccountEnabled: Bool {
		didSet {
			defaults.set(analyticsAccountEnabled, forKey: UserDefaultsKeys.analyticsAccountEnabled)
		defaults.set(signInOfferShown, forKey: UserDefaultsKeys.signInOfferShown)
		}
	}

	/// Whether the one-time "sign in to keep your findings" offer has already been presented
	/// (AIA-0536).
	///
	/// Marked when the offer is **shown**, not when a finding is saved. A save that yields no offer —
	/// because the review prompt won that dismissal, or the tour is running — must not silently
	/// consume the single chance to ask.
	@Published public var signInOfferShown: Bool {
		didSet {
			defaults.set(signInOfferShown, forKey: UserDefaultsKeys.signInOfferShown)
		}
	}

	/// Which account has already reported `subscription.activated` (AIA-0437).
	///
	/// Persisted because the event marks a **conversion**: without it, every launch of an already
	/// subscribed user would report a fresh activation and the metric would silently become a
	/// retention count. Keyed by account hash rather than a `Bool` so a second account on the same
	/// device neither inherits the first one's suppression nor clears it.
	@Published public var analyticsActivationReportedAccountHash: String? {
		didSet {
			Self.write(analyticsActivationReportedAccountHash, forKey: UserDefaultsKeys.analyticsActivationReportedAccountHash, to: defaults)
		}
	}

	/// Which account has already reported `account.signed_in` (AIA-0437). Same contract: the event
	/// is a funnel stage, not a launch counter, so it must survive relaunches.
	@Published public var analyticsSignedInReportedAccountHash: String? {
		didSet {
			Self.write(analyticsSignedInReportedAccountHash, forKey: UserDefaultsKeys.analyticsSignedInReportedAccountHash, to: defaults)
		}
	}

	/// The dashboard's last-known value for each feature flag, keyed by `FeatureFlagKey.rawValue`,
	/// mirrored on every snapshot republish and read back at the NEXT launch (AIA-0513).
	///
	/// Exists because a flag captured once at launch never sees its dashboard value at all. The
	/// snapshot is seeded synchronously in `FeatureFlagsState.init`, and the ConfigCat SDK has not
	/// synced by then — not even from its own on-disk cache — so a launch-time read returns the
	/// compiled default on *every* launch and the remote switch is inert in both directions. Flags
	/// read live are unaffected: they observe the republish. Flags captured once never do.
	///
	/// Empty means nothing has been observed yet (first launch, or any test), and the resolver
	/// falls back to the live snapshot — which is what keeps the static test provider working.
	///
	/// Deliberately NOT cleared by `reset()`: this mirrors remote configuration, not a user
	/// preference, and forgetting it would resurrect the inert state until the next sync.
	@Published public var remoteFlagLaunchValues: [String: Bool] {
		didSet {
			defaults.set(remoteFlagLaunchValues, forKey: UserDefaultsKeys.remoteFlagLaunchValues)
		}
	}

	/// Writes an optional string, removing the key when `nil`.
	///
	/// `set(_:forKey:)` with a `nil` optional goes through the `Any?` overload, where removal has
	/// historically not been guaranteed equivalent. The other optionals in this type already branch
	/// explicitly; this keeps "no value" stored exactly one way.
	private static func write(_ value: String?, forKey key: String, to defaults: UserDefaults) {
		if let value {
			defaults.set(value, forKey: key)
		} else {
			defaults.removeObject(forKey: key)
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

	/// Winning moments (a finding saved, a model imported/converted) since the last review request
	/// (AIA-0117). See ``ReviewPromptPolicy``.
	@Published public var ratingPromptEventCount: Int {
		didSet {
			defaults.set(ratingPromptEventCount, forKey: UserDefaultsKeys.ratingPromptEventCount)
		}
	}

	/// When the app last asked for a review. `nil` until the first request (AIA-0117).
	///
	/// Deliberately **not** cleared by ``reset()``: how recently the user was asked is anti-nag
	/// memory, not a preference they set, so "Restore Defaults" (AIA-0303) must not turn into a
	/// licence to ask again immediately.
	@Published public var ratingPromptLastRequestDate: Date? {
		didSet {
			if let ratingPromptLastRequestDate {
				defaults.set(ratingPromptLastRequestDate, forKey: UserDefaultsKeys.ratingPromptLastRequestDate)
			} else {
				defaults.removeObject(forKey: UserDefaultsKeys.ratingPromptLastRequestDate)
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
            // Off by default: preserves today's animated detection overlays; turning it
            // on renders detections as static markers to cut the animation cost.
            UserDefaultsKeys.disableDetectionAnimations: false,
            // On by default: simulator verification confirmed the edge-detection win
            // (AIA-0217 plan, decision 1); the toggle exists to opt out of the 6x
            // inference cost.
            UserDefaultsKeys.pyramidTiling: true,
            // 3x3 tiling and the debug tile-border overlay are opt-in (AIA-0426).
            UserDefaultsKeys.grid3x3Tiling: false,
			UserDefaultsKeys.tiledBorders: false,
			UserDefaultsKeys.analyticsEnabled: false,
			UserDefaultsKeys.analyticsChoiceMade: false,
			UserDefaultsKeys.analyticsAccountEnabled: false,
			UserDefaultsKeys.signInOfferShown: false,
			UserDefaultsKeys.ratingPromptEventCount: 0
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
		self.disableDetectionAnimations = defaults.bool(forKey: UserDefaultsKeys.disableDetectionAnimations)
		self.pyramidTiling = defaults.bool(forKey: UserDefaultsKeys.pyramidTiling)
		self.grid3x3Tiling = defaults.bool(forKey: UserDefaultsKeys.grid3x3Tiling)
		self.tiledBorders = defaults.bool(forKey: UserDefaultsKeys.tiledBorders)
		self.analyticsEnabled = defaults.bool(forKey: UserDefaultsKeys.analyticsEnabled)
		self.analyticsChoiceMade = defaults.bool(forKey: UserDefaultsKeys.analyticsChoiceMade)
		self.analyticsAccountEnabled = defaults.bool(forKey: UserDefaultsKeys.analyticsAccountEnabled)
		self.signInOfferShown = defaults.bool(forKey: UserDefaultsKeys.signInOfferShown)
		self.analyticsConsentAccountHash = defaults.string(forKey: UserDefaultsKeys.analyticsConsentAccountHash)
		self.analyticsActivationReportedAccountHash = defaults.string(forKey: UserDefaultsKeys.analyticsActivationReportedAccountHash)
		self.analyticsSignedInReportedAccountHash = defaults.string(forKey: UserDefaultsKeys.analyticsSignedInReportedAccountHash)
		self.remoteFlagLaunchValues = defaults.dictionary(forKey: UserDefaultsKeys.remoteFlagLaunchValues) as? [String: Bool] ?? [:]
		self.ratingPromptEventCount = defaults.integer(forKey: UserDefaultsKeys.ratingPromptEventCount)
		// There is no `defaults.date(forKey:)`; an absent key must stay `nil` rather than become a
		// 1970 date, which `shouldRequest` would read as "asked very long ago".
		self.ratingPromptLastRequestDate = defaults.object(forKey: UserDefaultsKeys.ratingPromptLastRequestDate) as? Date
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
		disableDetectionAnimations = false
		pyramidTiling = true
		grid3x3Tiling = false
		tiledBorders = false
		analyticsEnabled = false
		analyticsChoiceMade = false
		analyticsAccountEnabled = false
		signInOfferShown = false
		analyticsConsentAccountHash = nil
		analyticsActivationReportedAccountHash = nil
		analyticsSignedInReportedAccountHash = nil
		screenshotDetectionEnabled = nil
		// Count only: `ratingPromptLastRequestDate` deliberately survives a reset (AIA-0117) so
		// "Restore Defaults" cannot be used — deliberately or accidentally — to re-trigger the
		// review prompt. Anti-nag memory is not a user preference.
		ratingPromptEventCount = 0

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
		defaults.set(disableDetectionAnimations, forKey: UserDefaultsKeys.disableDetectionAnimations)
		defaults.set(pyramidTiling, forKey: UserDefaultsKeys.pyramidTiling)
		defaults.set(grid3x3Tiling, forKey: UserDefaultsKeys.grid3x3Tiling)
		defaults.set(tiledBorders, forKey: UserDefaultsKeys.tiledBorders)
		defaults.set(analyticsEnabled, forKey: UserDefaultsKeys.analyticsEnabled)
		defaults.set(analyticsChoiceMade, forKey: UserDefaultsKeys.analyticsChoiceMade)
		defaults.set(analyticsAccountEnabled, forKey: UserDefaultsKeys.analyticsAccountEnabled)
		defaults.set(ratingPromptEventCount, forKey: UserDefaultsKeys.ratingPromptEventCount)
		defaults.removeObject(forKey: UserDefaultsKeys.analyticsConsentAccountHash)
		defaults.removeObject(forKey: UserDefaultsKeys.analyticsActivationReportedAccountHash)
		defaults.removeObject(forKey: UserDefaultsKeys.analyticsSignedInReportedAccountHash)
		defaults.removeObject(forKey: UserDefaultsKeys.screenshotDetectionEnabled)
		defaults.removeObject(forKey: UserDefaultsKeys.legacySupportPromptShown)
		defaults.removeObject(forKey: UserDefaultsKeys.legacySupportPromptDeclined)
	}

}
