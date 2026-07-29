//
//  AccountAnalyticsCoordinatorTests.swift
//  MLBrowserUnitTests
//
//  Account → analytics identity and the two funnel events (AIA-0437).
//

import XCTest
@testable import ML_Browser

@MainActor
final class AccountAnalyticsCoordinatorTests: XCTestCase {

	/// Stable stand-ins for Clerk account ids (`user_…`).
	static let accountA = "user_2aaaaaaaaaaaaaaaaaaaaaaaaa"
	static let accountB = "user_2bbbbbbbbbbbbbbbbbbbbbbbbb"

	private var settings: Settings!
	private var tracker: RecordingAnalyticsTracker!
	private var analytics: AnalyticsState!
	private var authProvider: MockAuthProvider!
	private var authState: AuthState!
	private var subscriptionProvider: MockSubscriptionProvider!
	private var subscriptionState: SubscriptionState!
	/// Retained deliberately: the coordinator's behaviour lives entirely in Combine subscriptions,
	/// so one left as a local would deallocate and stop working with no compile error.
	private var coordinator: AccountAnalyticsCoordinator!

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		settings.reset()
		tracker = RecordingAnalyticsTracker()
		analytics = AnalyticsState(
			settings: settings,
			tracker: tracker,
			featureFlags: FeatureFlagsState(
				provider: StaticFeatureFlagProvider(overrides: [.isAnalyticsEnabled: true])
			),
			isAccountIdentityEnabled: true
		)
	}

	override func tearDown() async throws {
		settings.reset()
		coordinator = nil
		subscriptionState = nil
		subscriptionProvider = nil
		authState = nil
		authProvider = nil
		analytics = nil
		tracker = nil
		settings = nil
		try await super.tearDown()
	}

	/// Builds the real graph the composition root builds: a real `AuthState` over `MockAuthProvider`
	/// and a real `SubscriptionState` over `MockSubscriptionProvider`.
	private func makeCoordinator(
		auth: MockAuthProvider.Outcome = .ready,
		accountID: String? = AccountAnalyticsCoordinatorTests.accountA,
		subscription: MockSubscriptionProvider.Outcome = .notSubscribed
	) {
		authProvider = MockAuthProvider(outcome: auth, accountID: accountID)
		authState = AuthState(provider: authProvider)
		subscriptionProvider = MockSubscriptionProvider(outcome: subscription)
		subscriptionState = SubscriptionState(provider: subscriptionProvider, isPaymentsEnabled: true)
		coordinator = AccountAnalyticsCoordinator(
			analytics: analytics,
			authState: authState,
			subscriptionState: subscriptionState
		)
	}

	// MARK: - account.signed_in

	/// A sign-in event, not a launch counter: neither a foreground re-validation nor the same person
	/// signing out and back in during this session announces the account a second time.
	func testAccountSignedIn_SameAccountRevalidatedAndReSignedIn_FiresExactlyOnce() async {
		makeCoordinator()
		await authState.start()
		// A's sign-in is buffered pre-consent; opting in flushes it to the transport.
		analytics.chooseAnalytics(enabled: true)
		XCTAssertEqual(tracker.events, [.accountSignedIn])

		await authState.refresh()
		XCTAssertEqual(tracker.events, [.accountSignedIn])

		await authState.signOut()
		authProvider.setOutcomeForTesting(.ready)
		await authState.refresh()

		XCTAssertEqual(tracker.events, [.accountSignedIn])
		XCTAssertEqual(tracker.identities.last ?? nil, Self.accountA)
	}

	/// An in-place A→B switch publishes nothing on the gate, so B is announced off the identity
	/// change alone. A single `Bool` "already announced" flag would suppress B entirely.
	func testAccountSignedIn_SwitchFromAToB_AnnouncesTheIncomingAccount() async {
		makeCoordinator()
		await authState.start()

		authProvider.setAccountIDForTesting(Self.accountB)
		await authState.refresh()

		// B answers the choice; A's buffered sign-in was discarded when B arrived (AIA-0437), so the
		// one event that reaches the transport is B's, under B's identity.
		analytics.chooseAnalytics(enabled: true)

		XCTAssertEqual(tracker.calls, [.identity(Self.accountB), .activate, .track(.accountSignedIn)])
	}

	/// A consents, then an in-place switch to B. The transport must lose A's identity *before* it
	/// ever gains B's: `AuthState` clears the outgoing account before it suspends, and the
	/// coordinator has to act on that window rather than wait for B to land.
	func testSwitchFromConsentedAToConsentedB_ClearsBeforeItInstalls() async {
		makeCoordinator()
		await authState.start()
		analytics.chooseAnalytics(enabled: true)

		authProvider.setAccountIDForTesting(Self.accountB)
		await authState.refresh()
		analytics.chooseAnalytics(enabled: true)

		guard let teardown = tracker.calls.firstIndex(of: .deactivate),
			let installB = tracker.calls.firstIndex(of: .identity(Self.accountB)) else {
			return XCTFail("expected A's transport to be torn down and B's identity installed, got \(tracker.calls)")
		}
		XCTAssertLessThan(teardown, installB)
		XCTAssertEqual(tracker.identities, [Self.accountA, Self.accountB])
	}

	/// Losing connectivity is not a change of account. Before AIA-0536 this held by accident —
	/// `.offline` never touches the published identifier, so nothing woke the coordinator. It now
	/// holds on purpose, and this pins it: a flaky connection foregrounding repeatedly would
	/// otherwise deactivate and rebuild the transport each time, re-emitting its session signal and
	/// inflating user counts for someone who never went anywhere.
	func testOfflineRevalidation_ConsentedAccount_DoesNotDisturbTheTransport() async {
		makeCoordinator()
		await authState.start()
		analytics.chooseAnalytics(enabled: true)
		let callsBefore = tracker.calls

		authProvider.setOutcomeForTesting(.offline)
		await authState.refresh()
		await authState.refresh()

		XCTAssertEqual(authState.effectiveContext, .suspended(Self.accountA))
		XCTAssertEqual(tracker.calls, callsBefore)
	}

	/// Exercises the **wired** path, which a test calling `AnalyticsState` directly cannot.
	///
	/// The coordinator must forward `.suspended` even though it is not an attribution transition:
	/// it is the only signal that separates "no scope yet, still resolving" from "no scope, and none
	/// is coming". An earlier draft filtered it out here, which left the analytics branch dead in the
	/// app — `.unavailable` unreachable, and a cold-offline user held on a spinner indefinitely —
	/// while the direct `AnalyticsState` test carried on passing.
	func testColdOfflineLaunch_ReachesUnavailableThroughTheWiredCoordinator() async {
		makeCoordinator(auth: .offline)

		await authState.start()

		XCTAssertEqual(authState.effectiveContext, .suspended(nil))
		XCTAssertEqual(analytics.consentPresentation, .unavailable)
		XCTAssertTrue(tracker.calls.isEmpty)
	}

	/// A consented account recovering from an offline blip must not disturb the transport at any
	/// point in the round-trip. `testOfflineRevalidation…` stops at the blip; this carries through
	/// the recovery, where the context re-delivers `.validated(A)` after `.suspended(A)` — a
	/// re-delivery the old identifier-keyed pipeline never produced.
	func testOfflineRecovery_ConsentedAccount_StaysSilentAcrossTheWholeRoundTrip() async {
		makeCoordinator()
		await authState.start()
		analytics.chooseAnalytics(enabled: true)
		let callsBefore = tracker.calls

		authProvider.setOutcomeForTesting(.offline)
		await authState.refresh()
		authProvider.setOutcomeForTesting(.ready)
		await authState.refresh()

		XCTAssertEqual(authState.effectiveContext, .validated(Self.accountA))
		XCTAssertEqual(tracker.calls, callsBefore)
	}

	// MARK: - subscription.activated

	// MARK: - Anonymous-purchase provenance (AIA-0536)

	/// Under paywall-first, buying happens before signing in — often instead of it. So an account
	/// holding an entitlement no longer implies that account bought it, and crediting whoever signs
	/// in next would invent a conversion.
	func testAnonymousPurchaseThenSignIn_ReportsNoActivationForTheArrivingAccount() async {
		makeCoordinator(auth: .signedOut, accountID: nil, subscription: .subscribed)
		await subscriptionState.start()
		await authState.start()

		XCTAssertTrue(settings.subscriptionObservedAnonymously, "an entitlement seen while signed out is anonymous")

		// B signs in afterwards and consents. Nothing about the purchase becomes theirs.
		authProvider.setOutcomeForTesting(.ready)
		authProvider.setAccountIDForTesting(Self.accountB)
		await authState.refresh()
		analytics.chooseAnalytics(enabled: true)

		XCTAssertNil(settings.analyticsActivationReportedAccountHash)
		XCTAssertFalse(tracker.events.contains(.subscriptionActivated))
	}

	/// The provenance is persisted, so a relaunch cannot forget it and re-attribute the purchase on
	/// the next cold start.
	func testAnonymousProvenance_SurvivesIntoANewCoordinator() async {
		makeCoordinator(auth: .signedOut, accountID: nil, subscription: .subscribed)
		await subscriptionState.start()
		await authState.start()
		XCTAssertTrue(settings.subscriptionObservedAnonymously)

		// A fresh graph over the same Settings — what a relaunch produces.
		makeCoordinator(subscription: .subscribed)
		await subscriptionState.start()
		await authState.start()
		analytics.chooseAnalytics(enabled: true)

		XCTAssertNil(settings.analyticsActivationReportedAccountHash)
		XCTAssertFalse(tracker.events.contains(.subscriptionActivated))
	}

	/// **The launch-ordering trap.** Entitlement resolves before auth, so a signed-in subscriber's
	/// entitlement lands while the context is still `.indeterminate` — indistinguishable from
	/// anonymity if you look only at the account id. Marking provenance there would suppress every
	/// signed-in subscriber's activation, on every launch, permanently.
	func testSignedInSubscriberAtLaunch_IsNotMarkedAnonymousDespiteEntitlementArrivingFirst() async {
		makeCoordinator(subscription: .subscribed)

		// Deliberately the production order: entitlement first, auth second.
		await subscriptionState.start()
		XCTAssertFalse(settings.subscriptionObservedAnonymously, "auth had not resolved — that is not anonymity")

		await authState.start()
		analytics.chooseAnalytics(enabled: true)

		XCTAssertFalse(settings.subscriptionObservedAnonymously)
		XCTAssertTrue(tracker.events.contains(.subscriptionActivated))
	}

	/// A lapse clears the provenance: the next entitlement is a fresh purchase and must be judged on
	/// its own, not inherited from the one it replaced.
	func testEntitlementLapses_ClearsAnonymousProvenance() async {
		makeCoordinator(auth: .signedOut, accountID: nil, subscription: .subscribed)
		await subscriptionState.start()
		await authState.start()
		XCTAssertTrue(settings.subscriptionObservedAnonymously)

		subscriptionProvider.simulateEntitlementChange(to: .notSubscribed)

		XCTAssertFalse(settings.subscriptionObservedAnonymously)
	}

	/// An activation with no identity would land on the anonymous device identity and could never be
	/// joined to the account that paid, so it must not be emitted at all.
	func testSubscriptionActivated_EntitlementWithNoAccount_NeverFires() async {
		makeCoordinator(auth: .signedOut, accountID: nil, subscription: .subscribed)

		await subscriptionState.start()
		await authState.start()

		XCTAssertTrue(subscriptionState.isSubscribed)
		XCTAssertNil(settings.analyticsActivationReportedAccountHash)
		// Not even buffered — the event was never handed to analytics.
		XCTAssertEqual(analytics.pendingPreConsentCount, 0)
		XCTAssertTrue(tracker.calls.isEmpty)
	}

	/// Entitlement resolves before auth at launch, so the account arriving is what re-checks it.
	/// The persisted marker is what stops every later launch reporting a fresh "activation" —
	/// which would make the event measure retention rather than conversion.
	func testSubscriptionActivated_ConsentedAccountHoldingEntitlement_FiresExactlyOnce() async {
		makeCoordinator(subscription: .subscribed)

		await subscriptionState.start()
		await authState.start()
		analytics.chooseAnalytics(enabled: true)

		XCTAssertEqual(tracker.events, [.accountSignedIn, .subscriptionActivated])
		XCTAssertNotNil(settings.analyticsActivationReportedAccountHash)

		// A later re-observation of the same entitlement is not a second conversion.
		subscriptionProvider.simulateEntitlementChange(to: .notSubscribed)
		subscriptionProvider.simulateEntitlementChange(to: .subscribed)

		XCTAssertEqual(tracker.events, [.accountSignedIn, .subscriptionActivated])
		XCTAssertNotNil(settings.analyticsActivationReportedAccountHash)
	}

	/// The activation is driven by the entitlement, never by paywall intent — a tap on Subscribe is
	/// not a conversion.
	func testSubscriptionActivated_PaywallTapWithoutEntitlement_ProducesNoActivation() async {
		makeCoordinator(subscription: .notSubscribed)
		await subscriptionState.start()
		await authState.start()
		analytics.chooseAnalytics(enabled: true)

		analytics.track(.subscribeTapped)

		XCTAssertEqual(tracker.events, [.accountSignedIn, .subscribeTapped])
		XCTAssertNil(settings.analyticsActivationReportedAccountHash)
	}
}
