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

	// MARK: - updateAuthContext (AIA-0536)

	/// `.suspended` is the absence of a transition, not a state to act on. ``AuthState`` writes no
	/// identifier when validation fails offline, so there is nothing here to react to — and reacting
	/// anyway would deactivate a consented transport on every offline foreground, whose
	/// re-activation rebuilds the transport and re-emits its automatic session signal.
	func testUpdateAuthContext_Suspended_LeavesAConsentedTransportUntouched() {
		analytics.chooseAnalytics(enabled: true)
		let callsBefore = tracker.calls
		XCTAssertTrue(callsBefore.contains(.activate))

		analytics.updateAuthContext(.suspended(Self.accountA))
		analytics.updateAuthContext(.suspended(nil))

		XCTAssertEqual(tracker.calls, callsBefore)
	}

	/// `.indeterminate` **is** a transition. `AuthState` clears the outgoing account before it
	/// suspends (AIA-0437), so the identity must stop being used for the whole validation
	/// round-trip; ignoring it would leave the transport attributing to an account on its way out.
	func testUpdateAuthContext_Indeterminate_TearsDownAConsentedAccountsTransport() {
		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(tracker.deactivations, 0)

		analytics.updateAuthContext(.indeterminate)

		XCTAssertEqual(tracker.deactivations, 1)
	}

	/// Signed out and unresolved both clear the identity today, which is what makes routing the
	/// coordinator through the context behaviour-preserving. They stop being interchangeable once
	/// consent itself is scope-aware — only `.anonymous` is a scope that can answer a question.
	func testUpdateAuthContext_Anonymous_ClearsLikeIndeterminate() {
		analytics.chooseAnalytics(enabled: true)

		analytics.updateAuthContext(.anonymous)

		XCTAssertEqual(tracker.deactivations, 1)
	}

	func testUpdateAuthContext_Validated_InstallsThatAccountsIdentity() {
		analytics.updateAuthContext(.validated(Self.accountB))
		analytics.chooseAnalytics(enabled: true)

		XCTAssertEqual(tracker.identities, [Self.accountB])
	}

	// MARK: - Scoped consent (AIA-0536)

	/// A fresh state with no scope selected — `setUp` installs an account, which these need to avoid.
	private func makeUnscopedState(
		tracker: RecordingAnalyticsTracker,
		accountIdentity: Bool = true
	) -> AnalyticsState {
		AnalyticsState(
			settings: settings,
			tracker: tracker,
			featureFlags: featureFlags,
			isAccountIdentityEnabled: accountIdentity
		)
	}

	/// **The first scope selection of a session is never a boundary.** Written as
	/// `lastKnownScope != arriving`, `nil != .anonymous` is true and this event — every cold-launch
	/// funnel — would be discarded before it could ever be delivered. Events recorded before any
	/// scope existed cannot belong to another scope, because there was none.
	func testFirstScopeSelection_IsNotABoundary_AndDeliversTheLaunchFunnel() {
		let launchTracker = RecordingAnalyticsTracker()
		let launch = makeUnscopedState(tracker: launchTracker)

		launch.track(.paywallShown)
		XCTAssertEqual(launch.pendingPreConsentCount, 1)

		launch.updateAuthContext(.validated(Self.accountA))
		launch.chooseAnalytics(enabled: true)

		XCTAssertEqual(launchTracker.events, [.paywallShown])
	}

	/// An account's buffered funnel must not be delivered under the anonymous bucket when that
	/// bucket opts in. Sign-out is reachable outside the consent gate, so this interleaving is real.
	func testBoundary_AccountBuffersThenAnonymousConsents_DiscardsTheAccountsEvents() {
		analytics.track(.paywallShown)
		XCTAssertEqual(analytics.pendingPreConsentCount, 1)

		analytics.updateAuthContext(.anonymous)
		analytics.chooseAnalytics(enabled: true)

		XCTAssertTrue(tracker.events.isEmpty, "account A's buffered funnel was delivered anonymously")
	}

	/// And the mirror image: anonymous activity must not be delivered under an account that signs in
	/// afterwards.
	func testBoundary_AnonymousBuffersThenAccountConsents_DiscardsTheAnonymousEvents() {
		let mixedTracker = RecordingAnalyticsTracker()
		let mixed = makeUnscopedState(tracker: mixedTracker)

		mixed.updateAuthContext(.anonymous)
		mixed.track(.paywallShown)
		XCTAssertEqual(mixed.pendingPreConsentCount, 1)

		mixed.updateAuthContext(.validated(Self.accountA))
		mixed.chooseAnalytics(enabled: true)

		XCTAssertTrue(mixedTracker.events.isEmpty, "anonymous activity was delivered under account A")
	}

	/// The transport transition the bucket merge newly creates: before it, the anonymous bucket could
	/// never be consented under the flag, so `(active, still enabled)` with no account was
	/// unreachable. Signing out into an already-consented anonymous bucket must hand the identity
	/// over, not tear the transport down and rebuild it.
	func testSignOutIntoConsentedAnonymousBucket_HandsOverWithoutTearingDown() {
		let handoverTracker = RecordingAnalyticsTracker()
		let handover = makeUnscopedState(tracker: handoverTracker)

		handover.updateAuthContext(.anonymous)
		handover.chooseAnalytics(enabled: true)
		handover.updateAuthContext(.validated(Self.accountA))
		handover.chooseAnalytics(enabled: true)
		let callsBefore = handoverTracker.calls.count

		handover.updateAuthContext(.anonymous)

		let afterSignOut = Array(handoverTracker.calls.dropFirst(callsBefore))
		XCTAssertEqual(afterSignOut, [.identity(nil)])
	}

	/// Rolling the cross-device flag back must honour the answer already given, not re-ask and not
	/// silently widen it. The two buckets are the same bucket, so this is a no-op by construction —
	/// which is exactly why they were merged rather than stored separately.
	func testFlagRollback_AnonymousConsentIsHonouredUnderDeviceWideMode() {
		let anonTracker = RecordingAnalyticsTracker()
		let anon = makeUnscopedState(tracker: anonTracker)
		anon.updateAuthContext(.anonymous)
		anon.chooseAnalytics(enabled: true)

		let rolledBackTracker = RecordingAnalyticsTracker()
		let rolledBack = makeUnscopedState(tracker: rolledBackTracker, accountIdentity: false)

		XCTAssertEqual(rolledBack.consentPresentation, .resolved)
		rolledBack.track(.paywallShown)
		XCTAssertEqual(rolledBackTracker.events, [.paywallShown])
	}

	/// An account's answer must never be readable as an anonymous one, in either flag state. This is
	/// the leak the merge has to *not* reintroduce: only the hash is per-account, so the account
	/// bucket's stored value is worthless without it.
	func testAccountConsent_IsNotVisibleToTheAnonymousBucket() {
		analytics.chooseAnalytics(enabled: true)
		XCTAssertTrue(settings.analyticsAccountEnabled)

		let rolledBackTracker = RecordingAnalyticsTracker()
		let rolledBack = makeUnscopedState(tracker: rolledBackTracker, accountIdentity: false)

		XCTAssertEqual(rolledBack.consentPresentation, .ask)
		rolledBack.track(.paywallShown)
		XCTAssertTrue(rolledBackTracker.events.isEmpty)
	}

	/// `.suspended` selects no scope, but the gate has to tell "resolving" from "cannot resolve" —
	/// otherwise an offline user waits on a spinner that will never finish.
	func testPresentation_DistinguishesPendingFromUnavailable() {
		let offlineTracker = RecordingAnalyticsTracker()
		let offline = makeUnscopedState(tracker: offlineTracker)

		XCTAssertEqual(offline.consentPresentation, .pending)

		offline.updateAuthContext(.suspended(nil))
		XCTAssertEqual(offline.consentPresentation, .unavailable)

		offline.updateAuthContext(.indeterminate)
		XCTAssertEqual(offline.consentPresentation, .pending)
	}

	/// The Settings toggle reads this, and it must reflect the scope in force rather than the
	/// anonymous bucket's raw field — otherwise an account-scoped user is shown someone else's answer.
	func testIsAnalyticsEnabled_TracksTheActiveScopeNotTheStoredAnonymousField() {
		let scopedTracker = RecordingAnalyticsTracker()
		let scoped = makeUnscopedState(tracker: scopedTracker)
		scoped.updateAuthContext(.anonymous)
		scoped.chooseAnalytics(enabled: true)

		XCTAssertTrue(scoped.isAnalyticsEnabled)
		XCTAssertTrue(settings.analyticsEnabled)

		// An account arrives that has never answered. The stored anonymous field is still `true`,
		// but nothing is in force for this scope.
		scoped.updateAuthContext(.validated(Self.accountA))

		XCTAssertFalse(scoped.isAnalyticsEnabled)
		XCTAssertTrue(settings.analyticsEnabled)
	}

	func testResetAnalyticsChoice_ClearsBothBuckets() {
		analytics.chooseAnalytics(enabled: true)
		analytics.updateAuthContext(.anonymous)
		analytics.chooseAnalytics(enabled: true)

		analytics.resetAnalyticsChoice()

		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertFalse(settings.analyticsChoiceMade)
		XCTAssertFalse(settings.analyticsAccountEnabled)
		XCTAssertNil(settings.analyticsConsentAccountHash)
	}

	// MARK: - Sign-out ask deferral (AIA-0536)

	/// Sign-out is a disengagement act: revealing the unanswered anonymous bucket must not pop a
	/// consent question over someone who just signed out. The state still *asks* — analytics stays
	/// off, failing closed — but the gate is told to stay quiet.
	func testSignOut_WithUnansweredAnonymousBucket_DefersTheAsk() {
		// setUp installed account A; signing out reveals the anonymous bucket, never answered.
		analytics.updateAuthContext(.anonymous)

		XCTAssertEqual(analytics.consentPresentation, .ask)
		XCTAssertTrue(analytics.isAskDeferredAfterSignOut)
	}

	/// Signing in clears the deferral: the account question is about the identity just established,
	/// so asking at that moment is contextual rather than nagging.
	func testSignIn_AfterADeferredAsk_ClearsTheDeferral() {
		analytics.updateAuthContext(.anonymous)
		XCTAssertTrue(analytics.isAskDeferredAfterSignOut)

		analytics.updateAuthContext(.validated(Self.accountB))

		XCTAssertEqual(analytics.consentPresentation, .ask)
		XCTAssertFalse(analytics.isAskDeferredAfterSignOut)
	}

	/// Restore Defaults is the user ASKING to be re-asked — the deferral must not swallow it.
	func testReset_AfterADeferredAsk_ClearsTheDeferral() {
		analytics.updateAuthContext(.anonymous)
		XCTAssertTrue(analytics.isAskDeferredAfterSignOut)

		analytics.resetAnalyticsChoice()

		XCTAssertEqual(analytics.consentPresentation, .ask)
		XCTAssertFalse(analytics.isAskDeferredAfterSignOut)
	}

	/// A cold launch as anonymous is an *arrival*, not a sign-out: the first scope selection of a
	/// session never defers, so the gate's full-screen arrival ask is untouched.
	func testFirstAnonymousSelection_IsAnArrivalNotADeferral() {
		let launchTracker = RecordingAnalyticsTracker()
		let launch = makeUnscopedState(tracker: launchTracker)

		launch.updateAuthContext(.anonymous)

		XCTAssertEqual(launch.consentPresentation, .ask)
		XCTAssertFalse(launch.isAskDeferredAfterSignOut)
	}

	/// Answering — from anywhere — ends the deferral along with the question.
	func testAnswering_ClearsTheDeferral() {
		analytics.updateAuthContext(.anonymous)
		XCTAssertTrue(analytics.isAskDeferredAfterSignOut)

		analytics.chooseAnalytics(enabled: false)

		XCTAssertEqual(analytics.consentPresentation, .resolved)
		XCTAssertFalse(analytics.isAskDeferredAfterSignOut)
	}

	func testDefaultIsOffAndDoesNotInitializeOrSend() {
		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertFalse(settings.analyticsChoiceMade)
		XCTAssertEqual(analytics.consentPresentation, .ask)
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
		XCTAssertEqual(disabledAnalytics.consentPresentation, .resolved)
		disabledAnalytics.chooseAnalytics(enabled: true)
		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertEqual(disabledTracker.activations, 0)
	}

	func testActiveChoiceInitializesAndSendsOnlyAllowListedEvent() {
		analytics.chooseAnalytics(enabled: true)

		// An account's answer lands in the account bucket and touches neither anonymous key —
		// that separation is what stops either bucket overwriting the other (AIA-0536).
		XCTAssertTrue(settings.analyticsAccountEnabled)
		XCTAssertNotNil(settings.analyticsConsentAccountHash)
		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertFalse(settings.analyticsChoiceMade)
		XCTAssertEqual(analytics.consentPresentation, .resolved)
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
		XCTAssertEqual(analytics.consentPresentation, .ask)
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
	/// **Behaviour changed by AIA-0536, deliberately.** The count used to be discarded on a scope
	/// change; it is now *spent* under the outgoing scope first. Discarding was safe but lossy, and
	/// it destroyed the summary of exactly the sessions where somebody signs in partway through —
	/// which is the normal shape once login is contextual rather than a launch gate.
	///
	/// The invariant that matters is unchanged and still asserted below: nothing A did is ever
	/// attributed to B. The flush happens while A is still the selected scope, which is why
	/// `flushDetectionSessionSummary()` has to run *before* the scope is reassigned — its own guard
	/// reads the effective state, so afterwards it would silently drop.
	func testUpdateAccountIdentity_DifferentAccountArrives_SpendsTheCountUnderTheOutgoingAccount() {
		// A consents and does some work.
		analytics.chooseAnalytics(enabled: true)
		for _ in 0..<7 { analytics.recordDetectionRun() }

		// The account changes under it. A's seven runs are reported here, under A.
		analytics.updateAccountIdentity(Self.accountB)

		XCTAssertEqual(tracker.events.last, .detectionSessionSummary(runCountBucket: .sixToTwenty))
		XCTAssertEqual(tracker.identities, [Self.accountA], "the summary must be attributed to A")

		// B consents. Backgrounding must not report A's runs a second time, now under B.
		analytics.chooseAnalytics(enabled: true)
		analytics.flushDetectionSessionSummary()
		XCTAssertEqual(
			tracker.events.filter { if case .detectionSessionSummary = $0 { true } else { false } }.count,
			1,
			"account A's detection activity was reported again under account B"
		)

		// And B's own activity still reports normally, so this is a hand-off rather than a mute.
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

		XCTAssertEqual(legacy.consentPresentation, .ask)

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

		XCTAssertEqual(anonymous.consentPresentation, .pending)
		anonymous.chooseAnalytics(enabled: true)
		anonymous.setAnalyticsEnabled(true)
		anonymous.track(.paywallShown)
		anonymous.recordDetectionRun()
		anonymous.flushDetectionSessionSummary()

		XCTAssertFalse(settings.analyticsEnabled)
		XCTAssertTrue(anonymousTracker.calls.isEmpty)
	}

	/// Consent does not travel with the device: a second account is asked for itself, and until it
	/// answers nothing is sent for it — even though the account bucket's stored value is still on
	/// from A. That value is shared; the hash is what decides who may use it (AIA-0536).
	func testUpdateAccountIdentity_SecondAccountAfterFirstConsented_DoesNotInheritConsent() {
		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(analytics.consentPresentation, .resolved)

		analytics.updateAccountIdentity(Self.accountB)

		XCTAssertEqual(analytics.consentPresentation, .ask)
		XCTAssertEqual(tracker.deactivations, 1)
		XCTAssertTrue(settings.analyticsAccountEnabled)

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
