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

	// MARK: - subscription.activated

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
