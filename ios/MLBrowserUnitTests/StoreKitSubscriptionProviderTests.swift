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

	// MARK: - Cancelling a purchase the account already owns (AIA-0782)

	/// The reported dead end. StoreKit answers `.userCancelled` both for a dismissed purchase sheet
	/// and for its own "You are currently subscribed" dialog; when the second is what happened, the
	/// store has just confirmed ownership and the customer must not be returned to the wall.
	func testCancellation_AccountIsEntitled_ReportsSubscribed() async {
		let provider = makeProvider(entitlements: [candidate(transactionID: 7, expiresAt: expiryDate)])

		let outcome = await provider.outcomeAfterCancellation { [] }

		XCTAssertEqual(outcome, .subscribed)
		XCTAssertTrue(provider.isSubscribed)
	}

	/// An ordinary change of mind stays an ordinary change of mind. This is the case that must not
	/// regress: telling someone who tapped Cancel that they just subscribed would be worse than the
	/// bug being fixed.
	func testCancellation_NothingOwned_ReportsCancelled() async {
		let provider = makeProvider(entitlements: [])

		let outcome = await provider.outcomeAfterCancellation { [] }

		XCTAssertEqual(outcome, .cancelled)
		XCTAssertFalse(provider.isSubscribed)
	}

	/// The entitlement is **re-read**, not read from whatever was published before. The dead end
	/// begins with an empty local store — that is why the wall was up — so a check against stale
	/// state would answer "not subscribed" for exactly the customer this exists for.
	func testCancellation_EntitlementArrivesDuringThePurchase_IsSeen() async {
		let candidates = Box<[EntitlementCandidate]>([])
		let provider = StoreKitSubscriptionProvider(
			accountIdentifierSource: { nil },
			entitlementSource: { candidates.value }
		)
		await provider.refreshEntitlement()
		XCTAssertFalse(provider.isSubscribed, "precondition: the local store starts empty")

		// What the App Store's ownership check leaves behind while the dialog is on screen.
		candidates.value = [candidate(transactionID: 9, expiresAt: expiryDate)]

		let outcome = await provider.outcomeAfterCancellation { [] }

		XCTAssertEqual(outcome, .subscribed)
		XCTAssertEqual(provider.currentTransactionID, 9)
		XCTAssertEqual(provider.currentExpirationDate, expiryDate)
	}

	/// The other half of the dead end, and the half that fires when the local store stays empty —
	/// which is the state the wall was up for in the first place. The store says a subscription
	/// exists; the customer is sent to Restore rather than back to a Subscribe button.
	func testCancellation_NoLocalEntitlementButTheStoreReportsOne_RecommendsRestore() async {
		let provider = makeProvider(entitlements: [])

		let outcome = await provider.outcomeAfterCancellation {
			[SubscriptionStatusCandidate(productID: SubscriptionProduct.monthly, state: .subscribed, isVerified: true)]
		}

		XCTAssertEqual(outcome, .restoreRecommended)
		XCTAssertFalse(provider.isSubscribed, "recommending a restore must not fabricate an entitlement")
	}

	/// A local entitlement outranks the status query, and the query is not even made: the customer
	/// is already through, and `.subscribed` opens the gate while `.restoreRecommended` only talks
	/// about it.
	func testCancellation_EntitledLocally_DoesNotAskTheStoreAndReportsSubscribed() async {
		let provider = makeProvider(entitlements: [candidate(transactionID: 5, expiresAt: expiryDate)])
		let asked = Box(false)

		let outcome = await provider.outcomeAfterCancellation {
			asked.value = true
			return []
		}

		XCTAssertEqual(outcome, .subscribed)
		XCTAssertFalse(asked.value, "the status query is wasted work once the entitlement is in hand")
	}

	/// A revoked transaction is not ownership. Refunded customers reach this branch too, and
	/// `EntitlementResolver` — not this method — is what keeps them out; the wiring must not
	/// second-guess it into letting them through.
	func testCancellation_RevokedTransaction_ReportsCancelled() async {
		let provider = makeProvider(entitlements: [candidate(transactionID: 3, revokedAt: revocationDate)])

		let outcome = await provider.outcomeAfterCancellation { [] }

		XCTAssertEqual(outcome, .cancelled)
		XCTAssertFalse(provider.isSubscribed)
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

	// MARK: - purchase outcome (AIA-0947)

	/// Success and failure through ``MockSubscriptionProvider.purchaseOutcome``.
	///
	/// Does not call ``StoreKitSubscriptionProvider.purchase(_:)`` or `Product.products(for:)`.
	/// Those talk to StoreKit and do not return in this unit host.
	func testPurchase_MockSurface_SuccessAndFailure() {
		let mock = MockSubscriptionProvider(outcome: .notSubscribed)
		mock.purchaseOutcome = .subscribed
		XCTAssertEqual(mock.applyConfiguredPurchaseOutcome(), .subscribed)
		XCTAssertTrue(mock.isSubscribed)

		// A failed purchase does not clear a subscription the mock already recorded, so the
		// failure case starts from the unsigned-in outcome.
		let failing = MockSubscriptionProvider(outcome: .notSubscribed)
		failing.purchaseOutcome = .failed
		XCTAssertEqual(failing.applyConfiguredPurchaseOutcome(), .failed)
		XCTAssertFalse(failing.isSubscribed)
	}
}
