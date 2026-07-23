//
//  Analytics.swift
//  AI Archeology
//
//  Provider-neutral analytics API (AIA-0350).
//

import Combine
import Foundation

/// The deliberately small, allow-listed event surface for optional analytics. New events must be
/// added here rather than passing arbitrary names or parameters through from UI code.
enum AnalyticsEvent: Equatable {
	case paywallShown
	case subscribeTapped
	case modelImported(source: ModelAcquisitionSource)
	case detectionSessionSummary(runCountBucket: DetectionRunCountBucket)

	var name: String {
		switch self {
		case .paywallShown: "com.aiarcheology.paywall.shown"
		case .subscribeTapped: "com.aiarcheology.subscribe.tapped"
		case .modelImported: "com.aiarcheology.model.imported"
		case .detectionSessionSummary: "com.aiarcheology.detection.session_summary"
		}
	}

	var parameters: [String: String] {
		switch self {
		case .paywallShown, .subscribeTapped:
			[:]
		case let .modelImported(source):
			["source": source.rawValue]
		case let .detectionSessionSummary(runCountBucket):
			["run_count_bucket": runCountBucket.rawValue]
		}
	}
}

/// The only model-acquisition detail allowed to leave the device. Model name, URL, filename,
/// catalog title, and provider identifier are intentionally excluded.
enum ModelAcquisitionSource: String, Equatable {
	case fileImport = "file_import"
	case catalog = "catalog"
	case directDownload = "direct_download"
}

/// A coarse per-app-session count. Exact run counts are intentionally never transmitted.
enum DetectionRunCountBucket: String, Equatable {
	case oneToFive = "1_5"
	case sixToTwenty = "6_20"
	case twentyOneOrMore = "21_plus"

	static func bucket(for runCount: Int) -> DetectionRunCountBucket? {
		switch runCount {
		case 1...5: .oneToFive
		case 6...20: .sixToTwenty
		case 21...: .twentyOneOrMore
		default: nil
		}
	}
}

/// Provider-neutral analytics boundary. App UI and feature state use this API only; adapters for
/// TelemetryDeck or a future provider belong behind it in the composition root.
@MainActor
protocol AnalyticsTracking: AnyObject {
	func activate()
	func deactivate()
	func track(_ event: AnalyticsEvent)
}

@MainActor
final class NoOpAnalyticsTracking: AnalyticsTracking {
	func activate() {}
	func deactivate() {}
	func track(_: AnalyticsEvent) {}
}

/// Main-actor state combining the remote feature switch with the user's local choice.
///
/// The effective state is `ConfigCat isAnalyticsEnabled && Settings.analyticsEnabled`. The
/// provider is never activated while either part is false.
@MainActor
final class AnalyticsState: ObservableObject {
	private let settings: Settings
	private let tracker: AnalyticsTracking
	private let featureFlags: FeatureFlagsState
	private var detectionRunCount = 0
	/// Events recorded before the user answers the analytics choice (the login/paywall funnel).
	/// Held in memory ONLY — never persisted, never logged — and flushed to the transport iff the
	/// user enables analytics; discarded on decline, remote-flag-off, reset, or app termination.
	/// This defers reporting until consent without anything leaving the device beforehand (AIA-0447).
	private var pendingPreConsentEvents: [AnalyticsEvent] = []
	/// Safety bound so a repeated `onAppear` cannot grow the buffer without limit — not a functional
	/// cap (the pre-consent surface is two payload-free events). Drop-oldest on overflow.
	private static let maxPendingPreConsentEvents = 16
	private var featureFlagObservation: AnyCancellable?

	/// True only while the remote feature is enabled and the user has not made a first choice.
	@Published private(set) var shouldShowChoice: Bool
	/// Drives visibility of the Settings control. It changes live with ConfigCat.
	@Published private(set) var isAnalyticsFeatureEnabled: Bool

	init(settings: Settings, tracker: AnalyticsTracking, featureFlags: FeatureFlagsState) {
		self.settings = settings
		self.tracker = tracker
		self.featureFlags = featureFlags
		isAnalyticsFeatureEnabled = featureFlags.snapshot.isAnalyticsEnabled
		shouldShowChoice = featureFlags.snapshot.isAnalyticsEnabled && settings.analyticsChoiceMade.not
		applyRemoteFeatureFlag(featureFlags.snapshot.isAnalyticsEnabled)
		featureFlagObservation = featureFlags.$snapshot
			.dropFirst()
			.sink { [weak self] snapshot in
				self?.applyRemoteFeatureFlag(snapshot.isAnalyticsEnabled)
			}
	}

	func chooseAnalytics(enabled: Bool) {
		guard isAnalyticsFeatureEnabled else { return }
		settings.analyticsChoiceMade = true
		shouldShowChoice = false
		setAnalyticsEnabled(enabled)
	}

	func setAnalyticsEnabled(_ enabled: Bool) {
		guard isAnalyticsFeatureEnabled else { return }
		// Discard the pre-consent buffer on ANY disable, before the equality guard below — the
		// decline path calls this from the default `analyticsEnabled == false` state, where the
		// guard would otherwise return early and leave buffered events behind (AIA-0447).
		if !enabled { pendingPreConsentEvents.removeAll() }
		guard settings.analyticsEnabled != enabled else { return }
		settings.analyticsEnabled = enabled
		if enabled {
			tracker.activate()
			flushPendingPreConsentEvents()
		} else {
			tracker.deactivate()
		}
	}

	/// Delivers the pre-consent buffer to the transport once analytics is enabled, then clears it.
	/// Clears BEFORE iterating so a re-entrant `track` during delivery cannot double-send (AIA-0447).
	private func flushPendingPreConsentEvents() {
		let pending = pendingPreConsentEvents
		pendingPreConsentEvents.removeAll()
		for event in pending {
			tracker.track(event)
		}
	}

	/// Used by the whole-app reset path. Unlike `setAnalyticsEnabled(false)`, this also tears
	/// down a currently active transport when Settings has already been reset elsewhere.
	func resetAnalyticsChoice() {
		detectionRunCount = 0
		pendingPreConsentEvents.removeAll()
		settings.analyticsEnabled = false
		settings.analyticsChoiceMade = false
		shouldShowChoice = isAnalyticsFeatureEnabled
		tracker.deactivate()
	}

	func track(_ event: AnalyticsEvent) {
		guard isAnalyticsFeatureEnabled else { return }
		if settings.analyticsEnabled {
			tracker.track(event)
		} else if settings.analyticsChoiceMade == false {
			// Consent pending (pre-login/paywall funnel): record locally, deferred until the user
			// decides. Sent only if they enable analytics; discarded on decline (AIA-0447).
			pendingPreConsentEvents.append(event)
			let overflow = pendingPreConsentEvents.count - Self.maxPendingPreConsentEvents
			if overflow > 0 { pendingPreConsentEvents.removeFirst(overflow) }
		}
		// Otherwise the user declined (choiceMade && !enabled) — drop.
	}

	func recordDetectionRun() {
		guard isAnalyticsFeatureEnabled, settings.analyticsEnabled else { return }
		detectionRunCount += 1
	}

	/// Emits at most one coarse detection summary per app session.
	func flushDetectionSessionSummary() {
		guard isAnalyticsFeatureEnabled, settings.analyticsEnabled,
			let bucket = DetectionRunCountBucket.bucket(for: detectionRunCount) else { return }
		tracker.track(.detectionSessionSummary(runCountBucket: bucket))
		detectionRunCount = 0
	}

	private func applyRemoteFeatureFlag(_ isEnabled: Bool) {
		isAnalyticsFeatureEnabled = isEnabled
		guard isEnabled else {
			shouldShowChoice = false
			detectionRunCount = 0
			pendingPreConsentEvents.removeAll()
			tracker.deactivate()
			return
		}

		if settings.analyticsEnabled {
			shouldShowChoice = false
			tracker.activate()
		} else {
			shouldShowChoice = settings.analyticsChoiceMade.not
		}
	}

	#if DEBUG
	/// Test-only: number of events currently buffered pre-consent. Not part of the production API.
	var pendingPreConsentCount: Int { pendingPreConsentEvents.count }
	#endif
}
