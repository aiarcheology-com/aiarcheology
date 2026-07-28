//
//  SubscriptionStateTests.swift
//  MLBrowserUnitTests
//
//  AIA-0343: subscription / entitlement state machine coverage.
//

import XCTest
@testable import ML_Browser

@MainActor
final class SubscriptionStateTests: XCTestCase {

	// MARK: - Initial state

	func testInitialState_BeforeStart_IsNotSubscribed() {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true)
		XCTAssertFalse(sut.isSubscribed)
	}

	func testStart_NotSubscribedProvider_StaysNotSubscribed() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true)
		await sut.start()
		XCTAssertFalse(sut.isSubscribed)
		// No entitlement → no transaction id for the refund sheet.
		XCTAssertNil(sut.currentTransactionID)
	}

	func testStart_SubscribedProvider_IsSubscribed() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed), isPaymentsEnabled: true)
		await sut.start()
		XCTAssertTrue(sut.isSubscribed)
		// Entitled → a transaction id is exposed so the refund sheet can target it.
		XCTAssertNotNil(sut.currentTransactionID)
	}

	// MARK: - Transitions

	func testBackgroundEntitlementChange_Republishes() async {
		// A change delivered by the background Transaction.updates listener (Ask-to-Buy
		// approval, refund/revocation) must reach the published state via onEntitlementChange,
		// not just the provider's private state — otherwise the gate stays stale.
		let provider = MockSubscriptionProvider(outcome: .notSubscribed)
		let sut = SubscriptionState(provider: provider, isPaymentsEnabled: true)
		await sut.start()
		XCTAssertFalse(sut.isSubscribed)

		provider.simulateEntitlementChange(to: .subscribed)   // e.g. Ask-to-Buy approved
		XCTAssertTrue(sut.isSubscribed)

		provider.simulateEntitlementChange(to: .notSubscribed) // e.g. refund / revocation
		XCTAssertFalse(sut.isSubscribed)
	}

	func testRestore_FromNotSubscribed_BecomesSubscribed() async {
		// Mirrors a restore that finds a prior purchase: the provider flips to entitled
		// and the state republishes on the next sync.
		let provider = MockSubscriptionProvider(outcome: .notSubscribed)
		let sut = SubscriptionState(provider: provider, isPaymentsEnabled: true)
		await sut.start()
		XCTAssertFalse(sut.isSubscribed)

		let outcome = await sut.restore()
		XCTAssertEqual(outcome, .restored)
		XCTAssertTrue(sut.isSubscribed)
	}

	func testPurchase_FromNotSubscribed_BecomesSubscribed() async {
		// Exercises the purchase → entitled transition. `SubscriptionState.purchase(_:)`
		// requires a real `Product` (unconstructable outside the StoreKitTest framework),
		// so we simulate the purchase on the provider, then republish via the same `sync()`
		// path a real purchase would drive.
		let provider = MockSubscriptionProvider(outcome: .notSubscribed)
		let sut = SubscriptionState(provider: provider, isPaymentsEnabled: true)
		await sut.start()
		XCTAssertFalse(sut.isSubscribed)

		provider.simulatePurchaseForTesting()
		_ = await sut.restore() // republish from the now-entitled provider
		XCTAssertTrue(sut.isSubscribed)
	}

	// MARK: - Gate logic

	func testIsPremiumUnlocked_RequiresEntitlement() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed), isPaymentsEnabled: true)
		await sut.start()
		// Payments flag is on by default (AIA-0343); without entitlement, premium is locked.
		XCTAssertFalse(sut.isPremiumUnlocked)
	}

	func testIsPremiumUnlocked_WithEntitlement_TracksFlag() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed), isPaymentsEnabled: true)
		await sut.start()
		// With an entitlement and payments on, the gate unlocks.
		XCTAssertTrue(sut.isPremiumUnlocked)
	}

	/// The remote kill-switch path (AIA-0350): payments off must lock the surface even for
	/// a subscriber. The old compile-time flag could not express this, so it went untested.
	func testIsPremiumUnlocked_WithEntitlementButPaymentsOff_IsLocked() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed), isPaymentsEnabled: false)
		await sut.start()
		XCTAssertTrue(sut.isSubscribed, "entitlement should still be observed")
		XCTAssertFalse(sut.isPremiumUnlocked, "payments off must lock the premium surface")
		XCTAssertFalse(sut.isPaymentsSurfaceEnabled)
	}

	/// AIA-0350: the payments flag is captured **once**, at construction, and deliberately not
	/// observed. `SubscriptionGateView` is the app root, so honouring a mid-session flip would
	/// either drop a paywall on a user mid-detection or release an unpaid one from behind it —
	/// a remote change must take effect on the next launch, not on the next poll.
	///
	/// The flags snapshot really does change here (asserted), so this cannot pass merely because
	/// nothing moved.
	func testPaymentsSurface_CapturedAtConstruction_SurvivesLaterFlagFlip() async {
		let flagProvider = MutablePaymentsFlagProvider(
			initial: FeatureFlagSnapshot(values: [.isPaymentsEnabled: true])
		)
		let flags = FeatureFlagsState(provider: flagProvider)
		XCTAssertTrue(flags.snapshot.isPaymentsEnabled, "precondition: the session starts with payments on")

		let sut = SubscriptionState(
			provider: MockSubscriptionProvider(outcome: .subscribed),
			isPaymentsEnabled: flags.snapshot.isPaymentsEnabled
		)
		await sut.start()
		XCTAssertTrue(sut.isPaymentsSurfaceEnabled)
		XCTAssertTrue(sut.isPremiumUnlocked)

		// A remote poll lands with payments switched off.
		flagProvider.emit(FeatureFlagSnapshot(values: [.isPaymentsEnabled: false]))
		await flags.refresh()
		XCTAssertFalse(flags.snapshot.isPaymentsEnabled, "the snapshot must actually have flipped")

		XCTAssertTrue(sut.isPaymentsSurfaceEnabled, "the captured flag must not follow a mid-session flip")
		XCTAssertTrue(sut.isPremiumUnlocked, "…so the root gate cannot swap under the user")
	}

	// MARK: - Free trial

	/// A free trial is an active entitlement: the trial user is both subscribed and in-trial,
	/// and passes the gate. Until `MockSubscriptionProvider.isInTrial` became settable it was a
	/// hardcoded `false`, so this whole axis was unreachable from any test.
	func testStart_TrialSubscriber_IsSubscribedAndInTrial() async {
		let sut = SubscriptionState(
			provider: MockSubscriptionProvider(outcome: .subscribed, isInTrial: true),
			isPaymentsEnabled: true
		)
		await sut.start()
		XCTAssertTrue(sut.isSubscribed, "a free trial is an active entitlement")
		XCTAssertTrue(sut.isInTrial)
		XCTAssertTrue(sut.isPremiumUnlocked, "a trial user must pass the whole-app gate")
	}

	/// The paired negative, so the positive above cannot pass because `isInTrial` is stuck on:
	/// a paying subscriber (the default) is entitled but not in a trial.
	func testStart_PaidSubscriber_IsNotInTrial() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed), isPaymentsEnabled: true)
		await sut.start()
		XCTAssertTrue(sut.isSubscribed)
		XCTAssertFalse(sut.isInTrial, "the default mock must stay out of trial")
	}

	// MARK: - Outcome plumbing (AIA-0376)

	/// `purchase(_:)` cannot be exercised here — it needs a real `Product`, which is
	/// unconstructable outside the StoreKitTest framework (see
	/// `testPurchase_FromNotSubscribed_BecomesSubscribed` above for the same limitation).
	/// Its outcome forwarding is identical to `restore()`'s, covered below, and the
	/// user-facing half is covered by ``SubscriptionNoticeTests``.
	///
	/// An `SKTestSession` harness was expected to close this gap (the optional item on
	/// AIA-0376). AIA-0518 established that it cannot on iOS 26.5: the session loads a
	/// `.storekit` configuration, so products resolve, but every state-changing call fails —
	/// `disableDialogs` does not stick and `buyProduct` returns `notEntitled`, identically from
	/// the command line, from the Xcode IDE, and from a UI test that creates the session before
	/// launching the app. What that harness would have covered is instead covered as pure rules
	/// in ``EntitlementResolverTests``; the StoreKit round-trip itself stays uncovered.
	func testRestore_ForwardsProviderOutcome() async {
		let provider = MockSubscriptionProvider(outcome: .notSubscribed)
		let sut = SubscriptionState(provider: provider, isPaymentsEnabled: true)
		await sut.start()

		for expected: RestoreOutcome in [.nothingToRestore, .failed] {
			provider.restoreOutcome = expected
			let outcome = await sut.restore()
			XCTAssertEqual(outcome, expected)
			XCTAssertFalse(sut.isSubscribed)
		}
	}
}

/// The user-facing half of AIA-0376: which outcomes speak, and which stay quiet.
///
/// This is where the bug lived — not in StoreKit, but in the mapping from outcome to
/// something the user can read. It is tested directly because the mock cannot construct a
/// `Product`, so the paywall renders its "unavailable" state and no UI test can reach the
/// Subscribe button.
final class SubscriptionNoticeTests: XCTestCase {

	/// Success dismisses the paywall and cancellation is the user's own decision — alerting
	/// on either is noise. These two silences are deliberate; every other silence was the bug.
	func testPurchase_SubscribedAndCancelled_SayNothing() {
		XCTAssertNil(SubscriptionNotice.forPurchase(.subscribed))
		XCTAssertNil(SubscriptionNotice.forPurchase(.cancelled))
	}

	/// The reported symptom: a failed purchase left the spinner stopping and nothing else.
	func testPurchase_Failed_ShowsErrorNotice() throws {
		let notice = try XCTUnwrap(SubscriptionNotice.forPurchase(.failed))
		XCTAssertEqual(notice.title, L10n.Alert.Error.title)
		XCTAssertEqual(notice.message, L10n.Paywall.Failed.message)
	}

	/// Ask-to-Buy is not a failure. It must be reported, but never under an error title —
	/// the purchase is waiting for a parent, not broken.
	func testPurchase_Pending_ShowsNonErrorNotice() throws {
		let notice = try XCTUnwrap(SubscriptionNotice.forPurchase(.pending))
		XCTAssertEqual(notice.title, L10n.Paywall.Pending.title)
		XCTAssertNotEqual(notice.title, L10n.Alert.Error.title, "pending is not an error")
	}

	/// A successful restore needs no alert: the entitlement lands in published state and the
	/// gate re-renders, which is the answer.
	func testRestore_Restored_SaysNothing() {
		XCTAssertNil(SubscriptionNotice.forRestore(.restored))
	}

	/// "You own nothing" is a correct answer from the store, not a malfunction.
	func testRestore_NothingToRestore_ShowsNonErrorNotice() throws {
		let notice = try XCTUnwrap(SubscriptionNotice.forRestore(.nothingToRestore))
		XCTAssertEqual(notice.title, L10n.Paywall.RestoreEmpty.title)
		XCTAssertNotEqual(notice.title, L10n.Alert.Error.title, "an empty account is not an error")
	}

	func testRestore_Failed_ShowsErrorNotice() throws {
		let notice = try XCTUnwrap(SubscriptionNotice.forRestore(.failed))
		XCTAssertEqual(notice.title, L10n.Alert.Error.title)
		XCTAssertEqual(notice.message, L10n.Paywall.RestoreFailed.message)
	}

	// MARK: - Refund (AIA-0448)

	/// A submitted request is a receipt, not an outcome: the copy must confirm it reached
	/// Apple without promising money back — the decision arrives later as a revocation.
	func testRefund_Submitted_ShowsNonErrorNotice() throws {
		let notice = try XCTUnwrap(SubscriptionNotice.forRefund(.success(.success)))
		XCTAssertEqual(notice.title, L10n.Subscription.Refund.Submitted.title)
		XCTAssertNotEqual(notice.title, L10n.Alert.Error.title, "a filed request is not an error")
	}

	/// The user closed Apple's form themselves — the same deliberate silence as a
	/// cancelled purchase.
	func testRefund_UserCancelled_SaysNothing() {
		XCTAssertNil(SubscriptionNotice.forRefund(.success(.userCancelled)))
	}

	/// Apple is already reviewing an earlier request; telling the user so is an answer,
	/// not a malfunction.
	func testRefund_Duplicate_ShowsNonErrorNotice() throws {
		let notice = try XCTUnwrap(SubscriptionNotice.forRefund(.failure(.duplicateRequest)))
		XCTAssertEqual(notice.title, L10n.Subscription.Refund.Duplicate.title)
		XCTAssertNotEqual(notice.title, L10n.Alert.Error.title, "an already-filed request is not an error")
	}

	func testRefund_Failed_ShowsErrorNotice() throws {
		let notice = try XCTUnwrap(SubscriptionNotice.forRefund(.failure(.failed)))
		XCTAssertEqual(notice.title, L10n.Alert.Error.title)
		XCTAssertEqual(notice.message, L10n.Subscription.Refund.Failed.message)
	}
}

/// A flag provider whose resolved values change after construction, standing in for what
/// ConfigCat's auto-poll does mid-session. `FeatureFlagsState.refresh()` republishes from it,
/// so the flip is observed deterministically rather than by racing the change stream.
private final class MutablePaymentsFlagProvider: FeatureFlagProviding, @unchecked Sendable {
	private let lock = NSLock()
	private var snapshot: FeatureFlagSnapshot

	init(initial: FeatureFlagSnapshot) {
		snapshot = initial
	}

	func currentSnapshot() -> FeatureFlagSnapshot {
		lock.lock()
		defer { lock.unlock() }
		return snapshot
	}

	func refresh() async {}

	/// Finishes immediately: this test drives republication through `refresh()`, so an
	/// observation task that could never fire would just leak.
	func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

	func setUser(id: String, custom: [String: String]) {}
	func clearUser() {}

	/// Simulates new config landing in the SDK's cache.
	func emit(_ next: FeatureFlagSnapshot) {
		lock.lock()
		snapshot = next
		lock.unlock()
	}
}
