//
//  AnalyticsTests.swift
//  MLBrowserUnitTests
//

import Combine
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
		// Nothing is sent and the transport is never initialized before consent...
		XCTAssertEqual(tracker.activations, 0)
		XCTAssertTrue(tracker.events.isEmpty)
		// ...but the pre-consent funnel event is buffered, not dropped (AIA-0447).
		XCTAssertEqual(analytics.pendingPreConsentCount, 1)
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

	// MARK: - Pre-consent buffering (AIA-0447)

	func testPreConsentEventsBufferThenFlushInOrderOnEnable() {
		analytics.track(.paywallShown)
		analytics.track(.subscribeTapped)
		// Deferred while the choice is pending: nothing reaches the transport yet.
		XCTAssertTrue(tracker.events.isEmpty)
		XCTAssertEqual(tracker.activations, 0)
		XCTAssertEqual(analytics.pendingPreConsentCount, 2)

		analytics.chooseAnalytics(enabled: true)

		XCTAssertEqual(tracker.activations, 1)
		XCTAssertEqual(tracker.events, [.paywallShown, .subscribeTapped])
		XCTAssertEqual(analytics.pendingPreConsentCount, 0)
	}

	func testPreConsentEventsDiscardedOnDeclineAndNeverResurrected() {
		analytics.track(.paywallShown)
		analytics.track(.subscribeTapped)
		XCTAssertEqual(analytics.pendingPreConsentCount, 2)

		analytics.chooseAnalytics(enabled: false)
		XCTAssertEqual(analytics.pendingPreConsentCount, 0)
		XCTAssertTrue(tracker.events.isEmpty)
		XCTAssertEqual(tracker.activations, 0)
		// Declining from the default-off state must not churn the transport either — the discard
		// happens before setAnalyticsEnabled's equality guard returns (guard-order regression lock).
		XCTAssertEqual(tracker.deactivations, 0)

		// Post-decline events are dropped, not re-buffered.
		analytics.track(.paywallShown)
		XCTAssertEqual(analytics.pendingPreConsentCount, 0)

		// A later opt-in via the Settings toggle must deliver ZERO of the declined events.
		analytics.setAnalyticsEnabled(true)
		XCTAssertTrue(tracker.events.isEmpty)
	}

	func testFeatureFlagOffDoesNotBuffer() {
		let disabledAnalytics = AnalyticsState(
			settings: settings,
			tracker: RecordingAnalyticsTracker(),
			featureFlags: FeatureFlagsState(
				provider: StaticFeatureFlagProvider(overrides: [.isAnalyticsEnabled: false])
			)
		)

		disabledAnalytics.track(.paywallShown)

		// Feature off → the event is dropped outright, never buffered.
		XCTAssertEqual(disabledAnalytics.pendingPreConsentCount, 0)
	}

	func testRepeatedEnableFlushesBufferOnlyOnce() {
		analytics.track(.paywallShown)
		analytics.chooseAnalytics(enabled: true)
		analytics.setAnalyticsEnabled(true)   // already enabled → no-op, no re-flush

		XCTAssertEqual(tracker.events, [.paywallShown])
		XCTAssertEqual(tracker.activations, 1)
		XCTAssertEqual(analytics.pendingPreConsentCount, 0)
	}

	func testPreConsentBufferIsCappedDroppingOldest() {
		// Overflow with paywallShown, then a final subscribeTapped — the newest events win.
		for _ in 0..<40 { analytics.track(.paywallShown) }
		analytics.track(.subscribeTapped)
		XCTAssertEqual(analytics.pendingPreConsentCount, 16)   // maxPendingPreConsentEvents

		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(tracker.events.count, 16)
		XCTAssertEqual(tracker.events.last, .subscribeTapped)  // the most recent event is retained
	}

	func testResetAnalyticsChoiceClearsBuffer() {
		analytics.track(.paywallShown)
		XCTAssertEqual(analytics.pendingPreConsentCount, 1)

		analytics.resetAnalyticsChoice()

		XCTAssertEqual(analytics.pendingPreConsentCount, 0)
	}

	func testRemoteFeatureFlagOffClearsBufferAndCannotResurrect() async {
		let provider = ChangingAnalyticsFeatureFlagProvider(
			initial: FeatureFlagSnapshot(values: [.isAnalyticsEnabled: true])
		)
		let flags = FeatureFlagsState(provider: provider)
		let localTracker = RecordingAnalyticsTracker()
		let sut = AnalyticsState(settings: settings, tracker: localTracker, featureFlags: flags)
		sut.track(.paywallShown)
		XCTAssertEqual(sut.pendingPreConsentCount, 1)

		// The remote kill-switch must drop buffered pre-consent events.
		await republish(provider, into: flags, FeatureFlagSnapshot(values: [.isAnalyticsEnabled: false]))
		XCTAssertEqual(sut.pendingPreConsentCount, 0)

		// And the dropped events can never resurrect: re-enable the flag and opt in — nothing flushes.
		await republish(provider, into: flags, FeatureFlagSnapshot(values: [.isAnalyticsEnabled: true]))
		sut.chooseAnalytics(enabled: true)
		XCTAssertTrue(localTracker.events.isEmpty)
	}

	/// Emits a new snapshot and waits for `FeatureFlagsState` to republish it (mirrors the live
	/// ConfigCat auto-poll path). `FeatureFlagsState` republishes only on an actual value change.
	private func republish(
		_ provider: ChangingAnalyticsFeatureFlagProvider,
		into flags: FeatureFlagsState,
		_ next: FeatureFlagSnapshot
	) async {
		let republished = expectation(description: "snapshot republished")
		let cancellable = flags.$snapshot.dropFirst().sink { _ in republished.fulfill() }
		provider.emit(next)
		await fulfillment(of: [republished], timeout: 2)
		cancellable.cancel()
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

/// A feature-flag provider whose value flips after construction, standing in for ConfigCat's
/// auto-poll. Mirrors the double in FeatureFlagsTests so this file stays self-contained.
private final class ChangingAnalyticsFeatureFlagProvider: FeatureFlagProviding, @unchecked Sendable {
	private let lock = NSLock()
	private var snapshot: FeatureFlagSnapshot
	private let stream: AsyncStream<Void>
	private let continuation: AsyncStream<Void>.Continuation

	init(initial: FeatureFlagSnapshot) {
		snapshot = initial
		(stream, continuation) = AsyncStream<Void>.makeStream(
			of: Void.self,
			bufferingPolicy: .bufferingNewest(1)
		)
	}

	func currentSnapshot() -> FeatureFlagSnapshot {
		lock.lock()
		defer { lock.unlock() }
		return snapshot
	}

	func refresh() async {}

	func changes() -> AsyncStream<Void> { stream }

	func setUser(id: String, custom: [String: String]) {}
	func clearUser() {}

	func emit(_ next: FeatureFlagSnapshot) {
		lock.lock()
		snapshot = next
		lock.unlock()
		continuation.yield()
	}
}
