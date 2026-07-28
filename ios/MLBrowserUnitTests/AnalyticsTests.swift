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
		analytics = AnalyticsState(settings: settings, tracker: tracker, featureFlags: featureFlags, isAccountIdentityEnabled: true)
		// Consent is per account since AIA-0437, so nothing can be consented to — or sent — until
		// an account is signed in. Tests that exercise the signed-out/anonymous path override this.
		analytics.updateAccountIdentity(Self.accountA)
	}

	/// Stable stand-ins for Clerk account ids (`user_…`).
	static let accountA = "user_2aaaaaaaaaaaaaaaaaaaaaaaaa"
	static let accountB = "user_2bbbbbbbbbbbbbbbbbbbbbbbbb"

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
			featureFlags: disabledFeatureFlags,
			isAccountIdentityEnabled: true
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
			),
			isAccountIdentityEnabled: true
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

	/// The merge-blocker regression lock (found by MANUAL testing, invisible to unit tests that
	/// inject the boolean): the mode is captured once per launch, and the ConfigCat snapshot is not
	/// synced at capture time — so the dashboard can only ever take effect if each session mirrors
	/// the observed value for the NEXT launch to capture. This pins the mirror write.
	func testRemoteRepublish_MirrorsTheIdentityFlagForTheNextLaunch() async {
		let provider = ChangingAnalyticsFeatureFlagProvider(
			initial: FeatureFlagSnapshot(values: [.isAnalyticsEnabled: true])
		)
		let flags = FeatureFlagsState(provider: provider)
		// The mirror deliberately survives `reset()` (it is remote config, not a preference), so a
		// value written by an earlier test in this process is still in UserDefaults — clear it, or
		// this test measures contamination rather than behaviour.
		settings.analyticsAccountIdentityRemoteValue = nil
		// Retained for the test's duration: the mirror is written by the instance's own Combine
		// subscription, so `_ =` would deallocate it and silently write nothing.
		let sut = AnalyticsState(settings: settings, tracker: RecordingAnalyticsTracker(), featureFlags: flags, isAccountIdentityEnabled: true)
		defer { withExtendedLifetime(sut) {} }

		// Nothing observed yet: the mirror must stay nil — persisting the construction-time
		// snapshot would stomp a previously mirrored dashboard value with compiled defaults.
		XCTAssertNil(settings.analyticsAccountIdentityRemoteValue)

		// The dashboard turns the identity off; config lands mid-session.
		await republish(provider, into: flags, FeatureFlagSnapshot(values: [
			.isAnalyticsEnabled: true, .isCrossDeviceAnalyticsIdentityEnabled: false
		]))
		XCTAssertEqual(settings.analyticsAccountIdentityRemoteValue, false)

		// And back on: the mirror tracks the latest observation, not the first.
		await republish(provider, into: flags, FeatureFlagSnapshot(values: [
			.isAnalyticsEnabled: true, .isCrossDeviceAnalyticsIdentityEnabled: true
		]))
		XCTAssertEqual(settings.analyticsAccountIdentityRemoteValue, true)
	}

	/// Device-wide mode must be structurally unable to receive an account identity — not merely
	/// protected by the coordinator happening not to exist. If the composition root's two reads of
	/// the flag ever diverged, a coordinator could push account ids at a device-wide
	/// `AnalyticsState`; this pins that the push is inert.
	func testUpdateAccountIdentity_InDeviceWideMode_IsInert() {
		let localTracker = RecordingAnalyticsTracker()
		let sut = AnalyticsState(settings: settings, tracker: localTracker, featureFlags: featureFlags, isAccountIdentityEnabled: false)

		sut.chooseAnalytics(enabled: true)
		sut.updateAccountIdentity(Self.accountA)
		sut.track(.modelImported(source: .catalog))

		// Delivery works (device-wide consent was given) but no identity ever reaches the tracker,
		// and no account-scoped consent state is minted.
		XCTAssertEqual(localTracker.events, [.modelImported(source: .catalog)])
		XCTAssertTrue(localTracker.identities.isEmpty)
		XCTAssertNil(settings.analyticsConsentAccountHash)
	}

	func testRemoteFeatureFlagOffClearsBufferAndCannotResurrect() async {
		let provider = ChangingAnalyticsFeatureFlagProvider(
			initial: FeatureFlagSnapshot(values: [.isAnalyticsEnabled: true])
		)
		let flags = FeatureFlagsState(provider: provider)
		let localTracker = RecordingAnalyticsTracker()
		let sut = AnalyticsState(settings: settings, tracker: localTracker, featureFlags: flags, isAccountIdentityEnabled: true)
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

	// MARK: - Cross-device account identity (AIA-0437)

	/// The identity reaches the transport only when the remote feature is on AND *this* account has
	/// consented — and only ever as part of bringing the transport up.
	func testChooseAnalytics_ConsentedAccount_IsTheOnlyWayAnIdentityReachesTheTracker() {
		// Signed in, but this account has not answered the choice yet.
		XCTAssertTrue(tracker.identities.isEmpty)
		XCTAssertEqual(tracker.activations, 0)

		analytics.chooseAnalytics(enabled: true)

		XCTAssertEqual(tracker.identities, [Self.accountA])
		XCTAssertEqual(tracker.calls, [.identity(Self.accountA), .activate])
	}

	/// Sign-out tears the transport down. `deactivate()` is what clears the transport's identity
	/// (see ``AnalyticsTracking``), so no separate identity call is expected here — what must not
	/// happen is anything continuing to reach the transport under the account that just left.
	func testUpdateAccountIdentity_Nil_DeactivatesAndStopsAttributingToTheOutgoingAccount() {
		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(tracker.identities, [Self.accountA])

		analytics.updateAccountIdentity(nil)

		XCTAssertEqual(tracker.deactivations, 1)
		XCTAssertEqual(tracker.calls.last, .deactivate)

		analytics.track(.paywallShown)
		XCTAssertTrue(tracker.events.isEmpty)
		XCTAssertEqual(tracker.deactivations, 1)
	}

	/// The ordering AIA-0437 turns on. The transport binds the account when a signal is *enqueued*,
	/// so a flush that ran before the identity was installed would attribute this account's funnel
	/// to whoever the transport was pointed at last. Asserted on index order, not membership.
	func testChooseAnalytics_AfterPreConsentEvent_InstallsIdentityBeforeFlushingTheBuffer() {
		analytics.track(.paywallShown)
		XCTAssertEqual(analytics.pendingPreConsentCount, 1)

		analytics.chooseAnalytics(enabled: true)

		guard let identityIndex = tracker.calls.firstIndex(of: .identity(Self.accountA)),
			let flushIndex = tracker.calls.firstIndex(of: .track(.paywallShown)) else {
			return XCTFail("expected an identity and a flushed event, got \(tracker.calls)")
		}
		XCTAssertLessThan(identityIndex, flushIndex)
		XCTAssertEqual(tracker.calls, [.identity(Self.accountA), .activate, .track(.paywallShown)])
	}

	/// Sign Out is reachable from the root paywall, outside the consent gate: A's buffered funnel
	/// must never be delivered under B's identity.
	func testUpdateAccountIdentity_DifferentAccountArrives_DiscardsThePreConsentBuffer() {
		analytics.track(.paywallShown)
		XCTAssertEqual(analytics.pendingPreConsentCount, 1)

		analytics.updateAccountIdentity(Self.accountB)

		XCTAssertEqual(analytics.pendingPreConsentCount, 0)
		// B opting in therefore delivers none of A's funnel.
		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(tracker.identities, [Self.accountB])
		XCTAssertTrue(tracker.events.isEmpty)
	}

	/// The once-per-account markers have to be *persisted*, not remembered in memory.
	///
	/// This is the regression that already happened once on this branch: with the dedup held in a
	/// `Set` on a live object, `account.signed_in` quietly became a launch counter, and every test
	/// still passed — because none of them outlived a single instance. Constructing a second
	/// `AnalyticsState` over the same `Settings` is what a relaunch actually looks like, and it is
	/// the only shape of test that can fail if the storage is taken away again.
	func testFunnelEvents_AcrossARelaunch_AreNotReportedASecondTime() {
		analytics.chooseAnalytics(enabled: true)
		analytics.reportAccountSignedInIfNeeded()
		analytics.reportSubscriptionActivationIfNeeded()
		XCTAssertEqual(tracker.events, [.accountSignedIn, .subscriptionActivated])

		// Same person, same device, next launch: fresh objects over the persisted settings.
		let relaunchTracker = RecordingAnalyticsTracker()
		let relaunched = AnalyticsState(
			settings: settings,
			tracker: relaunchTracker,
			featureFlags: featureFlags,
			isAccountIdentityEnabled: true
		)
		relaunched.updateAccountIdentity(Self.accountA)
		relaunched.reportAccountSignedInIfNeeded()
		relaunched.reportSubscriptionActivationIfNeeded()

		XCTAssertTrue(
			relaunchTracker.events.isEmpty,
			"a relaunch re-reported a once-per-account event: \(relaunchTracker.events)"
		)

		// A *different* account on that same device still gets its own first report, so the
		// suppression is scoped to the account rather than to the device.
		relaunched.updateAccountIdentity(Self.accountB)
		relaunched.chooseAnalytics(enabled: true)
		relaunched.reportAccountSignedInIfNeeded()
		XCTAssertEqual(relaunchTracker.events, [.accountSignedIn])
	}

	/// The same leak in the one piece of state that is not an event yet.
	///
	/// `detectionRunCount` accrues silently while an account is consented and is only spent when
	/// the app backgrounds, so an account change in between would report A's activity in a summary
	/// carrying B's identity. That is the whole defect the buffer discard exists to prevent, in a
	/// counter rather than a queue — and it is easy to miss precisely because nothing is queued.
	func testUpdateAccountIdentity_DifferentAccountArrives_DiscardsTheDetectionCount() {
		// A consents and does some work.
		analytics.chooseAnalytics(enabled: true)
		for _ in 0..<7 { analytics.recordDetectionRun() }

		// The account changes under it, and the incoming account consents too.
		analytics.updateAccountIdentity(Self.accountB)
		analytics.chooseAnalytics(enabled: true)

		// Backgrounding must not attribute A's seven runs to B. With the counter cleared there is
		// no bucket to report at all, so nothing is sent.
		analytics.flushDetectionSessionSummary()
		XCTAssertFalse(
			tracker.events.contains { if case .detectionSessionSummary = $0 { true } else { false } },
			"account A's detection activity was reported under account B"
		)

		// And B's own activity still reports normally, so the fix is a reset rather than a mute.
		for _ in 0..<3 { analytics.recordDetectionRun() }
		analytics.flushDetectionSessionSummary()
		XCTAssertEqual(tracker.events.last, .detectionSessionSummary(runCountBucket: .oneToFive))
	}

	/// The production shape of the same leak: Sign Out is reachable from the root paywall, so the
	/// account B arrives after is `nil`, not A. Comparing against the immediately previous value
	/// instead of the last non-`nil` one would let A's funnel through under B's identity.
	func testUpdateAccountIdentity_DifferentAccountAfterSignOut_DiscardsThePreConsentBuffer() {
		analytics.track(.paywallShown)

		analytics.updateAccountIdentity(nil)
		analytics.updateAccountIdentity(Self.accountB)

		XCTAssertEqual(analytics.pendingPreConsentCount, 0)
		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(tracker.identities, [Self.accountB])
		XCTAssertTrue(tracker.events.isEmpty)
	}

	/// ...but signing out and back in as the *same* person keeps their own events, which is why the
	/// comparison is against the last non-`nil` account rather than the immediately previous value.
	func testUpdateAccountIdentity_SameAccountSignsBackIn_PreservesThePreConsentBuffer() {
		analytics.track(.paywallShown)

		analytics.updateAccountIdentity(nil)
		analytics.updateAccountIdentity(Self.accountA)

		XCTAssertEqual(analytics.pendingPreConsentCount, 1)
		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(tracker.events, [.paywallShown])
	}

	/// Regression lock: `activate()` rebuilds the transport's configuration and drops the identity it
	/// held, so a remote off→on flip with consent already given has to re-install it — otherwise the
	/// session resumes under the anonymous installation identity.
	func testRemoteFeatureFlagOffThenOn_WithConsentAlreadyGiven_ReappliesTheIdentity() async {
		let provider = ChangingAnalyticsFeatureFlagProvider(
			initial: FeatureFlagSnapshot(values: [.isAnalyticsEnabled: true])
		)
		let flags = FeatureFlagsState(provider: provider)
		let localTracker = RecordingAnalyticsTracker()
		let sut = AnalyticsState(settings: settings, tracker: localTracker, featureFlags: flags, isAccountIdentityEnabled: true)
		sut.updateAccountIdentity(Self.accountA)
		sut.chooseAnalytics(enabled: true)
		XCTAssertEqual(localTracker.identities, [Self.accountA])

		await republish(provider, into: flags, FeatureFlagSnapshot(values: [.isAnalyticsEnabled: false]))
		XCTAssertEqual(localTracker.deactivations, 1)

		await republish(provider, into: flags, FeatureFlagSnapshot(values: [.isAnalyticsEnabled: true]))

		XCTAssertEqual(localTracker.identities, [Self.accountA, Self.accountA])
		XCTAssertEqual(Array(localTracker.calls.suffix(2)), [.identity(Self.accountA), .activate])
	}

	/// Same rebuild hazard on the reset-then-re-consent path.
	func testResetAnalyticsChoice_ThenFreshConsent_ReappliesTheIdentity() {
		analytics.chooseAnalytics(enabled: true)
		analytics.resetAnalyticsChoice()
		XCTAssertEqual(tracker.deactivations, 1)

		analytics.chooseAnalytics(enabled: true)

		XCTAssertEqual(tracker.identities, [Self.accountA, Self.accountA])
		XCTAssertEqual(tracker.activations, 2)
		XCTAssertEqual(Array(tracker.calls.suffix(2)), [.identity(Self.accountA), .activate])
	}

	/// Feature flag off: exactly the pre-AIA-0437 contract. The choice is device-wide and answerable
	/// with no account signed in, and no account identifier ever reaches the transport. Nothing calls
	/// `updateAccountIdentity` here on purpose — with the flag off the coordinator is never built.
	func testFeatureOff_DeviceWideChoiceStillWorksAndNoAccountIdentityIsSent() {
		let legacyTracker = RecordingAnalyticsTracker()
		let legacy = AnalyticsState(
			settings: settings,
			tracker: legacyTracker,
			featureFlags: featureFlags,
			isAccountIdentityEnabled: false
		)

		XCTAssertTrue(legacy.shouldShowChoice)

		legacy.chooseAnalytics(enabled: true)
		legacy.track(.paywallShown)

		XCTAssertTrue(settings.analyticsEnabled)
		XCTAssertTrue(settings.analyticsChoiceMade)
		// Consent stays device-scoped — no per-account hash is recorded.
		XCTAssertNil(settings.analyticsConsentAccountHash)
		XCTAssertEqual(legacyTracker.activations, 1)
		XCTAssertEqual(legacyTracker.events, [.paywallShown])
		XCTAssertTrue(legacyTracker.identities.allSatisfy { $0 == nil })
	}

	/// Feature on but nobody ever signs in: there is nobody to ask and nobody to attribute to, so
	/// the transport is never touched at all — not even activated anonymously.
	func testFeatureOn_NoAccountEverSet_NeverTouchesTheTracker() {
		let anonymousTracker = RecordingAnalyticsTracker()
		let anonymous = AnalyticsState(
			settings: settings,
			tracker: anonymousTracker,
			featureFlags: featureFlags,
			isAccountIdentityEnabled: true
		)

		XCTAssertFalse(anonymous.shouldShowChoice)
		anonymous.chooseAnalytics(enabled: true)
		anonymous.setAnalyticsEnabled(true)
		anonymous.track(.paywallShown)
		anonymous.recordDetectionRun()
		anonymous.flushDetectionSessionSummary()

		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertTrue(anonymousTracker.calls.isEmpty)
	}

	/// Consent does not travel with the device: a second account is asked for itself, and until it
	/// answers nothing is sent for it — even though the device-level toggle is still on from A.
	func testUpdateAccountIdentity_SecondAccountAfterFirstConsented_DoesNotInheritConsent() {
		analytics.chooseAnalytics(enabled: true)
		XCTAssertFalse(analytics.shouldShowChoice)

		analytics.updateAccountIdentity(Self.accountB)

		XCTAssertTrue(analytics.shouldShowChoice)
		XCTAssertEqual(tracker.deactivations, 1)
		XCTAssertTrue(settings.analyticsEnabled)

		analytics.track(.paywallShown)
		// The Settings toggle must not enable sending for someone who never answered.
		analytics.setAnalyticsEnabled(true)

		XCTAssertTrue(tracker.events.isEmpty)
		XCTAssertEqual(tracker.identities, [Self.accountA])
		XCTAssertEqual(analytics.pendingPreConsentCount, 1)
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

/// Shared with `AccountAnalyticsCoordinatorTests` (hence not file-private): the coordinator's whole
/// contract is which calls reach the transport, in which order.
@MainActor
final class RecordingAnalyticsTracker: AnalyticsTracking {
	/// Every call the tracker received, in order. Ordering is the assertion that matters for
	/// AIA-0437: the identity must be installed before any buffered event is delivered, or the
	/// flush attributes the previous account's funnel to the incoming one.
	enum Call: Equatable {
		case activate
		case deactivate
		case track(AnalyticsEvent)
		case identity(String?)
	}

	private(set) var calls: [Call] = []

	var activations: Int { calls.filter { $0 == .activate }.count }
	var deactivations: Int { calls.filter { $0 == .deactivate }.count }
	var events: [AnalyticsEvent] { calls.compactMap { if case let .track(event) = $0 { event } else { nil } } }

	/// Built with `reduce`, not `compactMap`: the payload is itself `String?`, so compacting would
	/// silently drop every `.identity(nil)` — exactly the sign-out clears these tests must assert.
	var identities: [String?] {
		calls.reduce(into: []) { result, call in
			if case let .identity(id) = call { result.append(id) }
		}
	}

	func activate() { calls.append(.activate) }
	func deactivate() { calls.append(.deactivate) }
	func track(_ event: AnalyticsEvent) { calls.append(.track(event)) }
	func updateAccountIdentity(_ identifier: String?) { calls.append(.identity(identifier)) }
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
