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
		guard settings.analyticsEnabled != enabled else { return }
		settings.analyticsEnabled = enabled
		if enabled {
			tracker.activate()
		} else {
			tracker.deactivate()
		}
	}

	/// Used by the whole-app reset path. Unlike `setAnalyticsEnabled(false)`, this also tears
	/// down a currently active transport when Settings has already been reset elsewhere.
	func resetAnalyticsChoice() {
		detectionRunCount = 0
		settings.analyticsEnabled = false
		settings.analyticsChoiceMade = false
		shouldShowChoice = isAnalyticsFeatureEnabled
		tracker.deactivate()
	}

	func track(_ event: AnalyticsEvent) {
		guard isAnalyticsFeatureEnabled, settings.analyticsEnabled else { return }
		tracker.track(event)
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
}
