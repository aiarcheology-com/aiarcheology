//
//  StoreKitSubscriptionProviderTests.swift
//  MLBrowserUnitTests
//
//  AIA-0518: the provider's own wiring — how a resolved entitlement becomes published state,
//  and what a purchase gets tagged with.
//
//  `EntitlementResolverTests` covers the *rule*; nothing covered the *wiring*. An inverted
//  `isSubscribed`, a swapped transaction id, or a dropped expiry would have left every resolver
//  test green while the paywall did the opposite of what it should.
//
//  Nothing here touches StoreKit or Clerk. `start()` and `restore()` are deliberately never
//  called: they make real round-trips (`Transaction.unfinished`, `AppStore.sync()`) that a unit
//  test must not perform and cannot control on a runtime where `SKTestSession` does not work.
//

import StoreKit
import XCTest
@testable import ML_Browser

/// A mutable holder for values a test changes *after* the provider has captured them. A captured
/// `var` warns ("mutated after capture by sendable closure") and would read a copy; the box makes
/// the closure read whatever the test has since put in it.
@MainActor
private final class Box<T> {
	var value: T
	init(_ value: T) { self.value = value }
}

@MainActor
final class StoreKitSubscriptionProviderTests: XCTestCase {

	private let expiryDate = Date(timeIntervalSince1970: 1_800_000_000)
	private let revocationDate = Date(timeIntervalSince1970: 1_700_000_000)
	private let accountID = "user_2aaaaaaaaaaaaaaaaaaaaaaaaa"

	private func candidate(
		transactionID: UInt64 = 1,
		revokedAt: Date? = nil,
		expiresAt: Date? = nil,
		isIntroductoryOffer: Bool = false
	) -> EntitlementCandidate {
		EntitlementCandidate(
			productID: SubscriptionProduct.monthly,
			transactionID: transactionID,
			isAutoRenewable: true,
			revocationDate: revokedAt,
			expirationDate: expiresAt,
			isIntroductoryOffer: isIntroductoryOffer
		)
	}

	private func makeProvider(
		entitlements candidates: [EntitlementCandidate],
		accountIdentifier: String? = nil
	) -> StoreKitSubscriptionProvider {
		StoreKitSubscriptionProvider(
			accountIdentifierSource: { accountIdentifier },
			entitlementSource: { candidates }
		)
	}

	// MARK: - Published entitlement state

	/// Before anything is read the provider must be closed, not open: the gate trusts these
	/// values, and a provider that starts entitled would flash the app open on every launch.
	func testInitialState_IsNotSubscribed() {
		let provider = makeProvider(entitlements: [])

		XCTAssertFalse(provider.isSubscribed)
		XCTAssertNil(provider.currentTransactionID)
		XCTAssertNil(provider.currentExpirationDate)
		XCTAssertFalse(provider.isInTrial)
	}

	func testRefresh_NoEntitlements_PublishesNotSubscribed() async {
		let provider = makeProvider(entitlements: [])

		await provider.refreshEntitlement()

		XCTAssertFalse(provider.isSubscribed)
		XCTAssertNil(provider.currentTransactionID)
		XCTAssertNil(provider.currentExpirationDate)
		XCTAssertFalse(provider.isInTrial)
	}

	/// Each published property gets a distinguishable value and its own assertion, so a swap
	/// between the transaction id and the expiry — or either being dropped — cannot pass.
	func testRefresh_ActiveEntitlement_PublishesEveryFieldFromTheResolvedEntitlement() async {
		let provider = makeProvider(entitlements: [
			candidate(transactionID: 4242, expiresAt: expiryDate, isIntroductoryOffer: true)
		])

		await provider.refreshEntitlement()

		XCTAssertTrue(provider.isSubscribed)
		XCTAssertEqual(provider.currentTransactionID, 4242)
		XCTAssertEqual(provider.currentExpirationDate, expiryDate)
		XCTAssertTrue(provider.isInTrial)
	}

	/// The paired negative for the trial flag, so the positive above cannot pass with it stuck on.
	func testRefresh_PaidEntitlement_IsSubscribedButNotInTrial() async {
		let provider = makeProvider(entitlements: [
			candidate(transactionID: 7, expiresAt: expiryDate, isIntroductoryOffer: false)
		])

		await provider.refreshEntitlement()

		XCTAssertTrue(provider.isSubscribed)
		XCTAssertFalse(provider.isInTrial)
	}

	/// The refund path through the provider rather than the resolver alone: a revoked
	/// entitlement must publish as no entitlement, and must not leave a stale transaction id
	/// behind for the expiry and trial fields to be read from.
	func testRefresh_OnlyRevokedEntitlement_PublishesNotSubscribed() async {
		let provider = makeProvider(entitlements: [candidate(transactionID: 99, revokedAt: revocationDate)])

		await provider.refreshEntitlement()

		XCTAssertFalse(provider.isSubscribed)
		XCTAssertNil(provider.currentTransactionID)
		XCTAssertNil(provider.currentExpirationDate)
		XCTAssertFalse(provider.isInTrial)
	}

	/// Losing an entitlement has to clear every field, not just the flag — a stale expiry would
	/// keep a "renews on…" date on screen for someone who no longer has a subscription. This is
	/// the transition a refund actually produces, arriving via `Transaction.updates`.
	func testRefresh_EntitlementLost_ClearsThePreviouslyPublishedFields() async {
		let candidates = Box([candidate(transactionID: 11, expiresAt: expiryDate, isIntroductoryOffer: true)])
		let provider = StoreKitSubscriptionProvider(
			accountIdentifierSource: { nil },
			entitlementSource: { candidates.value }
		)

		await provider.refreshEntitlement()
		XCTAssertTrue(provider.isSubscribed)

		candidates.value = []
		await provider.refreshEntitlement()

		XCTAssertFalse(provider.isSubscribed)
		XCTAssertNil(provider.currentTransactionID)
		XCTAssertNil(provider.currentExpirationDate)
		XCTAssertFalse(provider.isInTrial)
	}

	/// The provider hands the resolver what it was given, unreordered: the first eligible
	/// entitlement wins, and every published field is read off whichever one that is.
	func testRefresh_MultipleEntitlements_PublishesTheFirstEligibleOne() async {
		let provider = makeProvider(entitlements: [
			candidate(transactionID: 1, revokedAt: revocationDate),
			candidate(transactionID: 2, expiresAt: expiryDate),
			candidate(transactionID: 3, expiresAt: expiryDate.addingTimeInterval(86_400))
		])

		await provider.refreshEntitlement()

		XCTAssertEqual(provider.currentTransactionID, 2)
		XCTAssertEqual(provider.currentExpirationDate, expiryDate)
	}

	/// The provider consults the shipping product set. Passing an empty one at the call site
	/// would lock out every subscriber while every resolver test stayed green.
	func testRefresh_ForeignProductOnly_PublishesNotSubscribed() async {
		let foreign = EntitlementCandidate(
			productID: "com.example.other.monthly",
			transactionID: 8,
			isAutoRenewable: true,
			revocationDate: nil,
			expirationDate: expiryDate,
			isIntroductoryOffer: false
		)
		let provider = makeProvider(entitlements: [foreign])

		await provider.refreshEntitlement()

		XCTAssertFalse(provider.isSubscribed)
	}

	// MARK: - Purchase tagging

	/// A signed-in purchase carries the account tag a future backend reconciles against. This is
	/// the only reachable assertion on that: `purchase(_:)` needs a `Product`, which cannot be
	/// constructed here, so a regression that silently stopped tagging would otherwise ship.
	func testPurchaseOptions_SignedIn_TagsTheAccount() throws {
		let provider = makeProvider(entitlements: [], accountIdentifier: accountID)

		let expected = try XCTUnwrap(AppAccountToken.make(from: accountID))
		XCTAssertEqual(provider.purchaseOptions(), [.appAccountToken(expected)])
	}

	/// Signed out means no tag at all, rather than a constant one — every anonymous purchase
	/// sharing a token would reconcile them all to a single phantom account.
	func testPurchaseOptions_SignedOut_TagsNothing() {
		let provider = makeProvider(entitlements: [], accountIdentifier: nil)

		XCTAssertTrue(provider.purchaseOptions().isEmpty)
	}

	/// The account is read at purchase time, not captured at construction: someone who signs in
	/// after launch must still have their purchase tagged.
	func testPurchaseOptions_AccountArrivesAfterConstruction_IsStillTagged() throws {
		let currentAccount = Box<String?>(nil)
		let provider = StoreKitSubscriptionProvider(
			accountIdentifierSource: { currentAccount.value },
			entitlementSource: { [] }
		)
		XCTAssertTrue(provider.purchaseOptions().isEmpty)

		currentAccount.value = accountID

		let expected = try XCTUnwrap(AppAccountToken.make(from: accountID))
		XCTAssertEqual(provider.purchaseOptions(), [.appAccountToken(expected)])
	}
}
