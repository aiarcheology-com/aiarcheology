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
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed))
		XCTAssertFalse(sut.isSubscribed)
	}

	func testStart_NotSubscribedProvider_StaysNotSubscribed() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed))
		await sut.start()
		XCTAssertFalse(sut.isSubscribed)
	}

	func testStart_SubscribedProvider_IsSubscribed() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed))
		await sut.start()
		XCTAssertTrue(sut.isSubscribed)
	}

	// MARK: - Transitions

	func testRestore_FromNotSubscribed_BecomesSubscribed() async {
		// Mirrors a restore that finds a prior purchase: the provider flips to entitled
		// and the state republishes on the next sync.
		let provider = MockSubscriptionProvider(outcome: .notSubscribed)
		let sut = SubscriptionState(provider: provider)
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
		let sut = SubscriptionState(provider: provider)
		await sut.start()
		XCTAssertFalse(sut.isSubscribed)

		provider.simulatePurchaseForTesting()
		await sut.restore() // republish from the now-entitled provider
		XCTAssertTrue(sut.isSubscribed)
	}

	// MARK: - Gate logic

	func testIsPremiumUnlocked_RequiresEntitlement() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .notSubscribed))
		await sut.start()
		// Payments flag is on by default (AIA-0343); without entitlement, premium is locked.
		XCTAssertFalse(sut.isPremiumUnlocked)
	}

	func testIsPremiumUnlocked_WithEntitlement_TracksFlag() async {
		let sut = SubscriptionState(provider: MockSubscriptionProvider(outcome: .subscribed))
		await sut.start()
		// With an entitlement, the gate follows the payments flag.
		XCTAssertEqual(sut.isPremiumUnlocked, FeatureFlags.isPaymentsEnabled)
	}
}
