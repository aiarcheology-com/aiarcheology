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
		for key in FeatureFlagKey.allCases where Self.failClosedKeys.contains(key).not {
			XCTAssertTrue(key.defaultValue, "\(key.rawValue): defaults fail open unless it must fail closed")
		}
	}

	/// The flags that earn a `false` compiled default, named one at a time.
	///
	/// Deliberately an allowlist rather than a relaxed assertion above: a *new* flag that defaults
	/// to `false` by accident still fails `test_defaults_matchShippedBehaviour`, because the only
	/// way out is to be listed here on purpose. The pairing below then asserts the exception
	/// positively, so a listed flag that quietly flips back to `true` fails too.
	private static let failClosedKeys: Set<FeatureFlagKey> = [.isFindingShareLinkEnabled, .isPaymentsEnabled]

	/// A share link is worthless until `link.aiarcheology.com` serves an association file, which is
	/// infrastructure outside this repository. Failing open would let a ConfigCat outage — or a
	/// first launch, before any sync — hand a user a link that opens Safari on a host that is not
	/// answering, and a dead link already posted to social media cannot be recalled.
	func test_failClosedFlags_defaultOff() {
		for key in Self.failClosedKeys {
			XCTAssertFalse(key.defaultValue, "\(key.rawValue) must fail closed")
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
		XCTAssertEqual(FeatureFlagKey.isRatingPromptEnabled.rawValue, "isRatingPromptEnabled")
		XCTAssertEqual(FeatureFlagKey.isAppMessagingEnabled.rawValue, "isAppMessagingEnabled")
		XCTAssertEqual(
			FeatureFlagKey.isCrossDeviceAnalyticsIdentityEnabled.rawValue,
			"isCrossDeviceAnalyticsIdentityEnabled"
		)
		XCTAssertEqual(FeatureFlagKey.isFreeAccessPeriodEnabled.rawValue, "isFreeAccessPeriodEnabled")
		XCTAssertEqual(FeatureFlagKey.isFindingShareLinkEnabled.rawValue, "isFindingShareLinkEnabled")
		XCTAssertEqual(
			FeatureFlagKey.isDetailedApplicationLogEnabled.rawValue,
			"isDetailedApplicationLogEnabled"
		)
		// Non-boolean settings share the same dashboard-key contract (AIA-0115).
		XCTAssertEqual(RemoteSettingKey.appMessages, "appMessages")
	}

	/// The application-log brake maps to its own key and defaults open (AIA-0602).
	///
	/// Failing open is load-bearing here rather than conventional: this ships to gather diagnostics
	/// on the first release in two years, so a `false` default would let a ConfigCat outage — or a
	/// first launch, before any sync — silently disable the thing being relied on to see what broke.
	/// A wrong raw value would be invisible for the same reason a missed lookup is: it just returns
	/// the default, which looks exactly like "the flag is on".
	func test_detailedApplicationLogFlag_defaultsOpenAndMapsToItsKey() {
		XCTAssertTrue(FeatureFlagKey.isDetailedApplicationLogEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagSnapshot.defaults.isDetailedApplicationLogEnabled)
		XCTAssertFalse(
			FeatureFlagSnapshot(values: [.isDetailedApplicationLogEnabled: false])
				.isDetailedApplicationLogEnabled
		)
	}

	/// The rating-prompt flag maps to its own key and defaults open (AIA-0117).
	func test_ratingPromptFlag_defaultsOpenAndMapsToItsKey() {
		XCTAssertTrue(FeatureFlagKey.isRatingPromptEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagSnapshot.defaults.isRatingPromptEnabled)
		XCTAssertFalse(FeatureFlagSnapshot(values: [.isRatingPromptEnabled: false]).isRatingPromptEnabled)
	}

	/// The free-access-window flag maps to its own key and defaults open (AIA-0556).
	///
	/// The default is not a preference here, it is load-bearing. This flag is launch-captured, and
	/// a genuine first launch has no mirror, so it resolves to `defaultValue` — and a first launch
	/// is the only moment a window can be granted. A `false` default would make the feature
	/// unreachable for every new user while every test still passed, because tests inject a
	/// synchronous provider and never take that branch. `test_defaults_matchShippedBehaviour`
	/// covers the whole enum; this pins the reasoning to the one flag it actually decides.
	func test_freeAccessPeriodFlag_defaultsOpenAndMapsToItsKey() {
		XCTAssertTrue(FeatureFlagKey.isFreeAccessPeriodEnabled.defaultValue)
		XCTAssertTrue(FeatureFlagSnapshot.defaults.isFreeAccessPeriodEnabled)
		XCTAssertFalse(FeatureFlagSnapshot(values: [.isFreeAccessPeriodEnabled: false]).isFreeAccessPeriodEnabled)
	}

	// MARK: - Launch-captured flags (AIA-0513)

	/// The defect this guards: a flag captured once at launch reads the snapshot before the
	/// ConfigCat SDK has synced, so it gets the compiled default on every launch and the dashboard
	/// is inert in both directions. `isPaymentsEnabled` was in that state since AIA-0350 — the
	/// payments kill switch could not be turned off. Unit tests could not see it because they
	/// inject the resolved boolean; this pins the resolution itself.
	func test_launchCapturedFlag_prefersTheMirrorOverAnUnsyncedSnapshot() {
		// What a cold launch actually looks like: the snapshot is unsynced. Payments are pinned
		// open here because the compiled default has been closed since AIA-0955, and this test is
		// about the mirror overriding whatever the snapshot says, not about the default itself.
		let unsynced = FeatureFlagSnapshot(values: [.isPaymentsEnabled: true])
		XCTAssertTrue(unsynced.isPaymentsEnabled, "precondition: the unsynced snapshot is open")

		// ...while the previous session observed the dashboard turning payments off.
		let mirror = ["isPaymentsEnabled": false]

		XCTAssertFalse(
			LaunchCapturedFlags.resolve(.isPaymentsEnabled, mirror: mirror, snapshot: unsynced),
			"a launch-captured flag must honour the observed dashboard value, not the compiled default"
		)
	}

	/// No mirror yet — a genuine first launch, or any test, where the static provider is
	/// synchronous and the snapshot is therefore trustworthy at construction.
	func test_launchCapturedFlag_withoutAMirror_fallsBackToTheSnapshot() {
		let snapshot = FeatureFlagSnapshot(values: [.isPaymentsEnabled: false])
		XCTAssertFalse(LaunchCapturedFlags.resolve(.isPaymentsEnabled, mirror: [:], snapshot: snapshot))
		XCTAssertTrue(LaunchCapturedFlags.resolve(.isModelCatalogEnabled, mirror: [:], snapshot: snapshot))
	}

	/// The mirror must carry every flag, so adding one cannot silently opt it out of the fix.
	func test_mirror_capturesEveryFlag() {
		let mirrored = LaunchCapturedFlags.mirror(from: FeatureFlagSnapshot.defaults)
		XCTAssertEqual(Set(mirrored.keys), Set(FeatureFlagKey.allCases.map(\.rawValue)))
		for key in FeatureFlagKey.allCases {
			XCTAssertEqual(mirrored[key.rawValue], key.defaultValue, "\(key.rawValue) mirrored wrongly")
		}
	}

	/// A round trip: what one session mirrors is what the next session captures.
	func test_mirrorThenResolve_roundTripsTheObservedValue() {
		let observed = FeatureFlagSnapshot(values: [.isPaymentsEnabled: false, .isAnalyticsEnabled: false])
		let mirror = LaunchCapturedFlags.mirror(from: observed)
		for key in FeatureFlagKey.allCases {
			XCTAssertEqual(
				LaunchCapturedFlags.resolve(key, mirror: mirror, snapshot: .defaults),
				observed[key],
				"\(key.rawValue) did not survive the mirror round trip"
			)
		}
	}

	/// The **wiring**, not just the pure helper. The pure tests above pass whether or not anything
	/// actually persists a snapshot, which is exactly the gap that hid the original bug one level
	/// down — so this drives a real republish through a real `FeatureFlagsState` and asserts the
	/// mirror lands in `Settings`.
	@MainActor
	func test_mirror_persistsObservedSnapshotsButNeverTheSeed() async {
		let settings = Settings()
		settings.reset()
		settings.remoteFlagLaunchValues = [:]
		let provider = ChangingFeatureFlagProvider(initial: .defaults)
		let flags = FeatureFlagsState(provider: provider)
		let sut = FlagLaunchValueMirror(flags: flags, settings: settings)
		defer { withExtendedLifetime(sut) {} }

		// The seed is the compiled defaults and must NOT be persisted — writing it would overwrite
		// a real dashboard value with a placeholder on every launch.
		XCTAssertTrue(settings.remoteFlagLaunchValues.isEmpty, "the compiled-default seed was persisted")

		// Config lands, with payments switched off.
		let republished = expectation(description: "republished")
		let token = flags.$snapshot.dropFirst().sink { _ in republished.fulfill() }
		provider.emit(FeatureFlagSnapshot(values: [.isPaymentsEnabled: false]))
        await fulfillment(of: [republished], timeout: 2)
		token.cancel()

		XCTAssertEqual(settings.remoteFlagLaunchValues["isPaymentsEnabled"], false,
					   "an observed dashboard value must be mirrored for the next launch")
		// And the next launch resolves from it rather than from an unsynced snapshot.
		XCTAssertFalse(LaunchCapturedFlags.resolve(.isPaymentsEnabled,
												   mirror: settings.remoteFlagLaunchValues,
												   snapshot: .defaults))
		settings.reset()
	}

	/// A genuine first launch has no mirror and runs on this default (AIA-0955). Open, a new install
	/// after the production switch would still meet the priced Welcome screen and be granted a
	/// free-access window before the dashboard value could reach it.
	func test_payments_defaultsClosed() {
		XCTAssertFalse(FeatureFlagKey.isPaymentsEnabled.defaultValue)
		XCTAssertFalse(LaunchCapturedFlags.resolve(.isPaymentsEnabled, mirror: [:], snapshot: .defaults))
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
