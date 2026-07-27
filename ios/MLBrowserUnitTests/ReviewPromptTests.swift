//
//  ReviewPromptTests.swift
//  MLBrowserUnitTests
//
//  AIA-0117: the rating-request policy and its bookkeeping.
//

import XCTest
@testable import ML_Browser

@MainActor
final class ReviewPromptTests: XCTestCase {
	private var settings: Settings!
	/// Injected clock. Tests move this rather than sleeping.
	private var now = Date(timeIntervalSince1970: 1_800_000_000)

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		settings.reset()
		// `reset()` deliberately preserves `ratingPromptLastRequestDate` (it is anti-nag memory,
		// not a preference), and unit tests share `UserDefaults.standard` — so a value written by
		// an earlier run would leak into this one. Clear it explicitly.
		settings.ratingPromptLastRequestDate = nil
		now = Date(timeIntervalSince1970: 1_800_000_000)
	}

	override func tearDown() async throws {
		settings.reset()
		settings.ratingPromptLastRequestDate = nil
		settings = nil
		try await super.tearDown()
	}

	private func makeCoordinator(
		flagEnabled: Bool = true,
		isSuppressedEnvironment: Bool = false
	) -> ReviewPromptCoordinator {
		ReviewPromptCoordinator(
			settings: settings,
			featureFlags: FeatureFlagsState(
				provider: StaticFeatureFlagProvider(overrides: [.isRatingPromptEnabled: flagEnabled])
			),
			isSuppressedEnvironment: isSuppressedEnvironment,
			now: { self.now }
		)
	}

	// MARK: - ReviewPromptPolicy

	func testShouldRequest_BelowRequiredCount_IsFalse() {
		XCTAssertFalse(ReviewPromptPolicy.shouldRequest(
			eventCount: ReviewPromptPolicy.requiredEventCount - 1, lastRequestDate: nil, now: now
		))
	}

	func testShouldRequest_AtRequiredCountAndNeverAsked_IsTrue() {
		XCTAssertTrue(ReviewPromptPolicy.shouldRequest(
			eventCount: ReviewPromptPolicy.requiredEventCount, lastRequestDate: nil, now: now
		))
	}

	func testShouldRequest_WithinCooldown_IsFalse() {
		let last = now.addingTimeInterval(-ReviewPromptPolicy.minimumRequestInterval + 1)
		XCTAssertFalse(ReviewPromptPolicy.shouldRequest(eventCount: 10, lastRequestDate: last, now: now))
	}

	func testShouldRequest_ExactlyAtCooldownBoundary_IsTrue() {
		let last = now.addingTimeInterval(-ReviewPromptPolicy.minimumRequestInterval)
		XCTAssertTrue(ReviewPromptPolicy.shouldRequest(eventCount: 10, lastRequestDate: last, now: now))
	}

	/// A clock moved backwards (NTP correction, restored backup, user changing the date) must not
	/// read as "asked very long ago" and unlock an immediate re-ask.
	func testShouldRequest_LastRequestInTheFuture_IsFalse() {
		let last = now.addingTimeInterval(60 * 60 * 24 * 365)
		XCTAssertFalse(ReviewPromptPolicy.shouldRequest(eventCount: 10, lastRequestDate: last, now: now))
	}

	/// The interval exists to keep our own requests within Apple's cap of three *displays* per
	/// 365 days. Walking the calendar is what pins that claim down — a shorter interval (90 days)
	/// would silently admit five.
	func testCooldown_AdmitsAtMostThreeRequestsPerYear() {
		var requests = 0
		var last: Date?
		var clock = now
		let end = now.addingTimeInterval(365 * 24 * 60 * 60)
		while clock < end {
			if ReviewPromptPolicy.shouldRequest(eventCount: 99, lastRequestDate: last, now: clock) {
				requests += 1
				last = clock
			}
			clock = clock.addingTimeInterval(24 * 60 * 60)
		}
		XCTAssertEqual(requests, 3, "The 122-day interval must admit exactly three requests per year")
	}

	// MARK: - ReviewPromptCoordinator

	func testRecordPositiveMoment_IncrementsPersistedCount() {
		let sut = makeCoordinator()
		sut.recordPositiveMoment(.findingSaved)
		sut.recordPositiveMoment(.findingSaved)
		XCTAssertEqual(settings.ratingPromptEventCount, 2)
	}

	func testConsume_WithoutAnyMoment_IsFalse() {
		let sut = makeCoordinator()
		settings.ratingPromptEventCount = 99
		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: false))
	}

	func testConsume_AfterEnoughMoments_RequestsAndResetsCount() {
		let sut = makeCoordinator()
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertTrue(sut.consumePendingRequest(.findingSaved, isTourActive: false))
		XCTAssertEqual(settings.ratingPromptEventCount, 0)
		XCTAssertEqual(settings.ratingPromptLastRequestDate, now)
	}

	/// A second dismissal with no new moment must not ask again.
	func testConsume_TwiceWithoutNewMoment_AsksOnce() {
		let sut = makeCoordinator()
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertTrue(sut.consumePendingRequest(.findingSaved, isTourActive: false))
		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: false))
	}

	/// An **ineligible** consume must still end the moment. Without this, deleting
	/// `pendingMoment = nil` would leave the moment alive after a suppressed consume, and the next
	/// unrelated dismissal — a cancelled capture, say — would fire the prompt.
	///
	/// `testConsume_TwiceWithoutNewMoment_AsksOnce` cannot catch that: there the first consume
	/// succeeds, so the zeroed count and the fresh cooldown independently force the second to
	/// `false` whether or not the moment was cleared. Here nothing is ever spent, so the pending
	/// flag is the only thing that can stop the second call.
	func testConsume_WhenIneligible_StillClearsThePendingMoment() {
		let sut = makeCoordinator()
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: true))
		XCTAssertFalse(
			sut.consumePendingRequest(.findingSaved, isTourActive: false),
			"the tour-suppressed consume must have ended the moment, not parked it for a later dismissal"
		)
		XCTAssertNil(settings.ratingPromptLastRequestDate)
		XCTAssertEqual(settings.ratingPromptEventCount, ReviewPromptPolicy.requiredEventCount)
	}

	func testConsume_WithinCooldown_IsFalseAndKeepsCount() {
		let sut = makeCoordinator()
		settings.ratingPromptLastRequestDate = now.addingTimeInterval(-60)
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: false))
		XCTAssertEqual(settings.ratingPromptEventCount, ReviewPromptPolicy.requiredEventCount)
	}

	func testConsume_FlagOff_IsFalseAndSpendsNothing() {
		let sut = makeCoordinator(flagEnabled: false)
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: false))
		XCTAssertNil(settings.ratingPromptLastRequestDate)
		XCTAssertEqual(settings.ratingPromptEventCount, ReviewPromptPolicy.requiredEventCount)
	}

	/// TestFlight, tests and previews all land here. The count must survive so a tester promoted to
	/// the App Store build keeps their history, and the cooldown must not start.
	func testConsume_SuppressedEnvironment_IsFalseAndSpendsNothing() {
		let sut = makeCoordinator(isSuppressedEnvironment: true)
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: false))
		XCTAssertNil(settings.ratingPromptLastRequestDate)
		XCTAssertEqual(settings.ratingPromptEventCount, ReviewPromptPolicy.requiredEventCount)
	}

	func testConsume_DuringTour_IsFalseAndSpendsNothing() {
		let sut = makeCoordinator()
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: true))
		XCTAssertNil(settings.ratingPromptLastRequestDate)
		XCTAssertEqual(settings.ratingPromptEventCount, ReviewPromptPolicy.requiredEventCount)
	}

	/// A date stamped under a clock set forward, then corrected, must not suppress the prompt until
	/// that future date — it is clamped to now so the cooldown restarts from the present.
	func testConsume_LastRequestDateInTheFuture_ClampsAndRecoversAfterCooldown() {
		let sut = makeCoordinator()
		settings.ratingPromptLastRequestDate = now.addingTimeInterval(365 * 24 * 60 * 60 * 4)
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertFalse(sut.consumePendingRequest(.findingSaved, isTourActive: false))
		XCTAssertEqual(settings.ratingPromptLastRequestDate, now, "the future date must be clamped to now")

		// Without the clamp this would stay suppressed for years rather than one cooldown.
		now = now.addingTimeInterval(ReviewPromptPolicy.minimumRequestInterval)
		sut.recordPositiveMoment(.findingSaved)
		XCTAssertTrue(sut.consumePendingRequest(.findingSaved, isTourActive: false))
	}

	/// `AppState` — and so this coordinator — is shared by every window of the `WindowGroup`, so an
	/// unrelated sheet closing (potentially in another window) must not spend a moment it did not
	/// record. The moment survives for the flow that owns it.
	func testConsume_DifferentSource_DoesNotSpendAnotherFlowsMoment() {
		let sut = makeCoordinator()
		for _ in 0..<ReviewPromptPolicy.requiredEventCount { sut.recordPositiveMoment(.findingSaved) }

		XCTAssertFalse(sut.consumePendingRequest(.modelImported, isTourActive: false))
		XCTAssertNil(settings.ratingPromptLastRequestDate)
		XCTAssertTrue(sut.consumePendingRequest(.findingSaved, isTourActive: false))
	}

	/// The count is the user's own history of good moments; "Restore Defaults" clears it, but the
	/// anti-nag date deliberately survives so a reset cannot be used to re-trigger the prompt.
	func testReset_ClearsCountButKeepsLastRequestDate() {
		settings.ratingPromptEventCount = 7
		settings.ratingPromptLastRequestDate = now

		settings.reset()

		XCTAssertEqual(settings.ratingPromptEventCount, 0)
		XCTAssertEqual(settings.ratingPromptLastRequestDate, now)
	}
}
