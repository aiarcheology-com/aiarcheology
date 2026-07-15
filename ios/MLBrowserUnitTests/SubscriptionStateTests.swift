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

		await sut.restore()
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
		await sut.restore() // republish from the now-entitled provider
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
}
