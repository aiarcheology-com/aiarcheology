//
//  FeatureFlagsTests.swift
//  AI ArcheologyTests
//
//  Remote feature flags (AIA-0350).
//

import XCTest
import Combine
@testable import ML_Browser

final class FeatureFlagsTests: XCTestCase {

	/// The compiled defaults must preserve today's shipped behaviour exactly: every feature on.
	/// This is the offline / first-launch / outage path — the flags deliberately fail *open*
	/// (AGENTS.md §3 "Defaults fail open"; see also the spec's "Honest limits of the kill switch").
	///
	/// Rollout is the ConfigCat value's job, not the compiled default's. Only a flag that *must*
	/// fail closed — one whose failure mode is worse than a mild annoyance — earns a `false` here.
	func test_defaults_matchShippedBehaviour() {
		for key in FeatureFlagKey.allCases {
			XCTAssertTrue(key.defaultValue, "\(key.rawValue): defaults fail open unless it must fail closed")
		}
	}

	/// The ConfigCat key is the rawValue — an explicit literal, never left to Swift's
	/// implicit synthesis from the case name. This test is the guard against a rename
	/// silently repointing the lookup at a key the dashboard has never heard of; that
	/// failure is invisible at runtime, because a missed lookup just returns the default.
	/// These strings must match the keys published in ConfigCat exactly.
	func test_rawValues_areTheConfigCatKeys() {
		XCTAssertEqual(FeatureFlagKey.isModelCatalogEnabled.rawValue, "isModelCatalogEnabled")
		XCTAssertEqual(FeatureFlagKey.isPaymentsEnabled.rawValue, "isPaymentsEnabled")
		XCTAssertEqual(FeatureFlagKey.isAnalyticsEnabled.rawValue, "isAnalyticsEnabled")
		XCTAssertEqual(FeatureFlagKey.isSupportReportingEnabled.rawValue, "isSupportReportingEnabled")
		XCTAssertEqual(FeatureFlagKey.isRefundRequestEnabled.rawValue, "isRefundRequestEnabled")
		XCTAssertEqual(FeatureFlagKey.isRatingPromptEnabled.rawValue, "isRatingPromptEnabled")
		XCTAssertEqual(FeatureFlagKey.isAppMessagingEnabled.rawValue, "isAppMessagingEnabled")
		// Non-boolean settings share the same dashboard-key contract (AIA-0115).
		XCTAssertEqual(RemoteSettingKey.appMessages, "appMessages")
	}

	/// The rating-prompt flag maps to its own key and defaults open (AIA-0117).
	func test_ratingPromptFlag_defaultsOpenAndMapsToItsKey() {
		XCTAssertTrue(FeatureFlagKey.isRatingPromptEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagSnapshot.defaults.isRatingPromptEnabled)
		XCTAssertFalse(FeatureFlagSnapshot(values: [.isRatingPromptEnabled: false]).isRatingPromptEnabled)
	}

	/// The refund-row flag maps to its own key and defaults open (AIA-0461).
	func test_refundRequestFlag_defaultsOpenAndMapsToItsKey() {
		XCTAssertTrue(FeatureFlagKey.isRefundRequestEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagSnapshot.defaults.isRefundRequestEnabled)
		XCTAssertFalse(FeatureFlagSnapshot(values: [.isRefundRequestEnabled: false]).isRefundRequestEnabled)
	}

	func test_defaultsSnapshot_usesEveryKeysDefault() {
		let sut = FeatureFlagSnapshot.defaults
		for key in FeatureFlagKey.allCases {
			XCTAssertEqual(sut[key], key.defaultValue, "\(key.rawValue) should use its default")
		}
	}

	/// A snapshot built from partial remote data falls back per-key — the path taken when
	/// ConfigCat is reachable but a flag has not been created yet.
	func test_snapshot_missingKeyFallsBackToDefault() {
		let sut = FeatureFlagSnapshot(values: [.isPaymentsEnabled: false])
		XCTAssertFalse(sut.isPaymentsEnabled)
		XCTAssertEqual(sut.isModelCatalogEnabled, FeatureFlagKey.isModelCatalogEnabled.defaultValue)
		XCTAssertTrue(sut.isAnalyticsEnabled)
	}

	func test_snapshot_remoteValuesWin() {
		let sut = FeatureFlagSnapshot(values: [.isModelCatalogEnabled: false, .isPaymentsEnabled: false, .isAnalyticsEnabled: true])
		XCTAssertFalse(sut.isModelCatalogEnabled)
		XCTAssertFalse(sut.isPaymentsEnabled)
		XCTAssertTrue(sut.isAnalyticsEnabled)
	}

	/// The appMessages payload rides the snapshot (AIA-0115): empty when absent, carried
	/// verbatim when served, and part of equality so a message edit republishes like a flag flip.
	func test_snapshot_appMessagesJSON_defaultsEmptyAndParticipatesInEquality() {
		XCTAssertEqual(FeatureFlagSnapshot.defaults.appMessagesJSON, "")
		let payload = #"[{"id":"m1"}]"#
		let sut = FeatureFlagSnapshot(appMessagesJSON: payload)
		XCTAssertEqual(sut.appMessagesJSON, payload)
		XCTAssertNotEqual(sut, FeatureFlagSnapshot.defaults)
	}

	/// The messaging flag maps to its own key and defaults open (AIA-0115): safe because the
	/// content setting defaults to empty, so the open failure mode is "no messages".
	func test_appMessagingFlag_defaultsOpenAndMapsToItsKey() {
		XCTAssertTrue(FeatureFlagKey.isAppMessagingEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagSnapshot.defaults.isAppMessagingEnabled)
		XCTAssertFalse(FeatureFlagSnapshot(values: [.isAppMessagingEnabled: false]).isAppMessagingEnabled)
	}
}

final class StaticFeatureFlagProviderTests: XCTestCase {

	func test_withoutOverrides_returnsDefaults() {
		let sut = StaticFeatureFlagProvider()
		XCTAssertEqual(sut.currentSnapshot(), FeatureFlagSnapshot.defaults)
	}

	func test_overrides_win() {
		let sut = StaticFeatureFlagProvider(overrides: [.isPaymentsEnabled: false])
		XCTAssertFalse(sut.currentSnapshot().isPaymentsEnabled)
		XCTAssertTrue(sut.currentSnapshot().isModelCatalogEnabled)
	}

	/// UI tests inject deterministic messages through the same static seam (AIA-0115).
	func test_appMessagesJSON_isCarriedIntoTheSnapshot() {
		let payload = #"[{"id":"m1"}]"#
		let sut = StaticFeatureFlagProvider(appMessagesJSON: payload)
		XCTAssertEqual(sut.currentSnapshot().appMessagesJSON, payload)
	}

	/// `refresh()` must be a no-op that never touches the network in tests.
	func test_refresh_doesNotChangeValues() async {
		let sut = StaticFeatureFlagProvider(overrides: [.isPaymentsEnabled: false])
		await sut.refresh()
		XCTAssertFalse(sut.currentSnapshot().isPaymentsEnabled)
	}

	/// Its values never change, so the stream must *finish* rather than park forever —
	/// otherwise every test and preview would leak an observation task that can never fire.
	func test_changes_finishesImmediately() async {
		let sut = StaticFeatureFlagProvider()
		for await _ in sut.changes() {
			XCTFail("A static provider must never signal a change")
		}
	}
}

/// A provider whose resolved values change after construction, standing in for what
/// ConfigCat's auto-poll does: update the values, then signal — with no call from us.
private final class ChangingFeatureFlagProvider: FeatureFlagProviding, @unchecked Sendable {
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

	/// Simulates new config landing in the SDK's cache.
	func emit(_ next: FeatureFlagSnapshot) {
		lock.lock()
		snapshot = next
		lock.unlock()
		continuation.yield()
	}
}

@MainActor
final class FeatureFlagsStateTests: XCTestCase {

	func test_seedsSynchronouslyFromProvider() {
		let provider = StaticFeatureFlagProvider(overrides: [.isModelCatalogEnabled: false])
		let sut = FeatureFlagsState(provider: provider)
		XCTAssertFalse(sut.snapshot.isModelCatalogEnabled)
	}

	/// The regression that matters. ConfigCat's auto-poll refreshes the SDK's own cache
	/// without calling anything of ours, so a state that only republished on the launch
	/// `refresh()` would leave a dashboard flip invisible until the next relaunch — the
	/// "live" flag would not actually be live.
	func test_providerChange_republishesWithoutAnyRefreshCall() async {
		let provider = ChangingFeatureFlagProvider(initial: .defaults)
		let sut = FeatureFlagsState(provider: provider)
		XCTAssertTrue(sut.snapshot.isModelCatalogEnabled, "precondition: starts enabled")

		let republished = expectation(description: "snapshot republished after remote change")
		let cancellable = sut.$snapshot
			.dropFirst()
			.sink { if !$0.isModelCatalogEnabled { republished.fulfill() } }

		provider.emit(FeatureFlagSnapshot(values: [.isModelCatalogEnabled: false]))

		await fulfillment(of: [republished], timeout: 2)
		cancellable.cancel()
		XCTAssertFalse(sut.snapshot.isModelCatalogEnabled)
	}
}
