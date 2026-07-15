//
//  AnalyticsTests.swift
//  MLBrowserUnitTests
//

import XCTest
@testable import ML_Browser

@MainActor
final class AnalyticsTests: XCTestCase {
	private var settings: Settings!
	private var tracker: RecordingAnalyticsTracker!
	private var analytics: AnalyticsState!
	private var featureFlags: FeatureFlagsState!

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		settings.reset()
		tracker = RecordingAnalyticsTracker()
		featureFlags = FeatureFlagsState(provider: StaticFeatureFlagProvider(overrides: [.isAnalyticsEnabled: true]))
		analytics = AnalyticsState(settings: settings, tracker: tracker, featureFlags: featureFlags)
	}

	override func tearDown() async throws {
		settings.reset()
		analytics = nil
		featureFlags = nil
		tracker = nil
		settings = nil
		try await super.tearDown()
	}

	func testDefaultIsOffAndDoesNotInitializeOrSend() {
		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertFalse(settings.analyticsChoiceMade)
		XCTAssertTrue(analytics.shouldShowChoice)
		XCTAssertEqual(tracker.activations, 0)

		analytics.track(.paywallShown)
		analytics.recordDetectionRun()
		analytics.flushDetectionSessionSummary()
		XCTAssertTrue(tracker.events.isEmpty)
	}

	func testFeatureFlagOffHidesChoiceAndBlocksActivation() {
		let disabledFeatureFlags = FeatureFlagsState(
			provider: StaticFeatureFlagProvider(overrides: [.isAnalyticsEnabled: false])
		)
		let disabledTracker = RecordingAnalyticsTracker()
		let disabledAnalytics = AnalyticsState(
			settings: settings,
			tracker: disabledTracker,
			featureFlags: disabledFeatureFlags
		)

		XCTAssertFalse(disabledAnalytics.isAnalyticsFeatureEnabled)
		XCTAssertFalse(disabledAnalytics.shouldShowChoice)
		disabledAnalytics.chooseAnalytics(enabled: true)
		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertEqual(disabledTracker.activations, 0)
	}

	func testActiveChoiceInitializesAndSendsOnlyAllowListedEvent() {
		analytics.chooseAnalytics(enabled: true)

		XCTAssertTrue(settings.analyticsEnabled)
		XCTAssertTrue(settings.analyticsChoiceMade)
		XCTAssertFalse(analytics.shouldShowChoice)
		XCTAssertEqual(tracker.activations, 1)

		analytics.track(.modelImported(source: .catalog))
		XCTAssertEqual(tracker.events, [.modelImported(source: .catalog)])
		XCTAssertEqual(tracker.events.first?.name, "com.aiarcheology.model.imported")
		XCTAssertEqual(tracker.events.first?.parameters, ["source": "catalog"])
	}

	func testTurningAnalyticsOffTerminatesAndBlocksFutureSignals() {
		analytics.chooseAnalytics(enabled: true)
		analytics.track(.paywallShown)
		analytics.setAnalyticsEnabled(false)
		analytics.track(.subscribeTapped)
		analytics.recordDetectionRun()
		analytics.flushDetectionSessionSummary()

		XCTAssertEqual(tracker.deactivations, 1)
		XCTAssertEqual(tracker.events, [.paywallShown])
	}

	func testRestoreDefaultsResetsAnalyticsToOffAndShowsTheChoiceAgain() {
		analytics.chooseAnalytics(enabled: true)
		analytics.recordDetectionRun()

		analytics.resetAnalyticsChoice()

		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertFalse(settings.analyticsChoiceMade)
		XCTAssertTrue(analytics.shouldShowChoice)
		XCTAssertEqual(tracker.deactivations, 1)
	}

	func testDetectionSummaryUsesCoarseBucketsAndOneSignalPerFlush() {
		analytics.chooseAnalytics(enabled: true)
		for _ in 0..<5 { analytics.recordDetectionRun() }
		analytics.flushDetectionSessionSummary()
		for _ in 0..<20 { analytics.recordDetectionRun() }
		analytics.flushDetectionSessionSummary()

		XCTAssertEqual(tracker.events, [
			.detectionSessionSummary(runCountBucket: .oneToFive),
			.detectionSessionSummary(runCountBucket: .sixToTwenty)
		])
		XCTAssertEqual(DetectionRunCountBucket.bucket(for: 21), .twentyOneOrMore)
		XCTAssertNil(DetectionRunCountBucket.bucket(for: 0))
	}
}

@MainActor
private final class RecordingAnalyticsTracker: AnalyticsTracking {
	private(set) var activations = 0
	private(set) var deactivations = 0
	private(set) var events: [AnalyticsEvent] = []

	func activate() { activations += 1 }
	func deactivate() { deactivations += 1 }
	func track(_ event: AnalyticsEvent) { events.append(event) }
}
